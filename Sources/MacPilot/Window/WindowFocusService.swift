// WindowFocusService.swift
//
// The single entry point for bringing a switcher target to the foreground.
// macOS foregrounding is a chain — application activation, Space transfer,
// window raise, AX focus — and any single link can silently fail (cooperative
// activation can drop requests from a background process, an AX server can be
// slow, a minimized window needs restoring first). The pipeline therefore
// verifies the result after every attempt and retries before giving up, the
// way the system ⌘Tab switcher behaves.

import AppKit
import ApplicationServices
import Foundation
import OSLog

// MARK: - Pure policies

/// How long to wait before each retry; index 0 is the delay before the second
/// attempt. Chosen so a failing target still lands within roughly a second —
/// the switcher must never hang the user's shortcut for several seconds.
enum WindowFocusRetryPolicy {
    static let retryDelays: [Duration] = [.milliseconds(150), .milliseconds(400)]
    static let maximumAttempts = retryDelays.count + 1

    static func delayBeforeAttempt(_ attempt: Int) -> Duration {
        guard attempt >= 1 else { return .zero }
        return retryDelays[min(attempt - 1, retryDelays.count - 1)]
    }
}

/// Decides whether one focus attempt may be treated as successful. Pure so the
/// acceptance rules stay testable.
enum WindowFocusVerificationPolicy {
    static func isVerified(
        targetProcessID: pid_t,
        ownProcessID: pid_t,
        frontmostProcessID: pid_t?,
        ownApplicationIsActive: Bool,
        focusedWindowMatchesTarget: Bool?
    ) -> Bool {
        guard frontmostProcessID == targetProcessID else { return false }
        if targetProcessID == ownProcessID {
            // MacPilot is an LSUIElement process: frontmostApplication alone
            // does not prove its windows came forward, NSApp.isActive does.
            return ownApplicationIsActive
        }
        // Frontmost is the strong signal. A focused-window probe that
        // positively names a different window means the raise did not land
        // even though the application activated. An inconclusive probe (no AX
        // window element, or the target's AX server lagging) must not block
        // acceptance.
        return focusedWindowMatchesTarget != false
    }
}

/// Where an attempt is allowed to run. AX aimed at MacPilot's own process
/// re-enters AppKit and must stay on the main actor; AX aimed at another
/// process can block on that process's accessibility server and must stay off
/// the run loop that also delivers the keyboard event tap.
enum WindowFocusExecutionPolicy {
    static func runsOnMainActor(targetProcessID: pid_t, ownProcessID: pid_t) -> Bool {
        targetProcessID == ownProcessID
    }
}

// MARK: - Inputs and outcomes

/// The immutable facts one focus attempt needs. AXUIElement is not Sendable,
/// but the element is only ever touched by the single task that runs the
/// attempt, mirroring the previous WindowSwitcherFocusRequest.
struct WindowFocusTarget: @unchecked Sendable {
    let processID: pid_t
    let axWindow: AXUIElement?
    let windowNumber: CGWindowID?
    let isMinimized: Bool
    let ownProcessID: pid_t

    init(
        processID: pid_t,
        axWindow: AXUIElement?,
        windowNumber: CGWindowID?,
        isMinimized: Bool,
        ownProcessID: pid_t
    ) {
        self.processID = processID
        self.axWindow = axWindow
        self.windowNumber = windowNumber
        self.isMinimized = isMinimized
        self.ownProcessID = ownProcessID
    }

    init(item: WindowSwitcherItem, ownProcessID: pid_t) {
        self.init(
            processID: item.processID,
            axWindow: item.axWindow,
            windowNumber: item.windowID ?? item.windowNumber,
            isMinimized: item.isMinimized,
            ownProcessID: ownProcessID
        )
    }
}

/// What one attempt actually did, for diagnostics and tests.
struct WindowFocusAttemptOutcome: Sendable, Equatable {
    var foundApplication = false
    var unhidApplication = false
    var activatedApplication = false
    /// `NSRunningApplication.activate` refused the request and the app was
    /// brought forward through its accessibility element instead.
    var activatedThroughAccessibility = false
    var restoredWindow = false
    var raisedWindow = false
    var setWindowMain = false
    var setWindowFocused = false
    var ownWindowOrderedFront = false
}

/// The three public ways to bring another application forward, in the order
/// the switcher tries them.
///
/// macOS 14 made activation cooperative: a background `LSUIElement` process
/// calling `NSRunningApplication.activate` is answered `false`, and the target
/// window then stays behind even though its AX raise succeeded. Measured on
/// macOS 27: `activate=false` on every attempt while `raise=true` and
/// `axFocus=true` — the "switcher does nothing" report. Setting the app's
/// `AXFrontmost` attribute is the documented way to raise an application from a
/// background process and does not consume the activation budget, so it is the
/// fallback, not the first choice.
enum WindowFocusActivationStep: Equatable, Sendable {
    case activateFromCurrentApplication
    case accessibilityFrontmost
}

/// Every step to try after the primary activation returned `false`.
///
/// Pure so the tripwire test can pin the ladder: collapsing it back to one
/// `activate()` call is exactly the regression that leaves the switcher
/// looking dead on macOS 14+.
enum WindowFocusActivationPolicy {
    static func steps(afterPrimaryActivationSucceeded succeeded: Bool) -> [WindowFocusActivationStep] {
        succeeded ? [] : [.activateFromCurrentApplication, .accessibilityFrontmost]
    }
}

struct WindowFocusActivationActions {
    var activate: @Sendable (NSRunningApplication) -> Bool
    var activateFromCurrentApplication: @Sendable (NSRunningApplication) -> Bool
    var setFrontmost: @Sendable (pid_t) -> Bool

    func perform(
        _ step: WindowFocusActivationStep,
        application: NSRunningApplication,
        processID: pid_t
    ) -> Bool {
        switch step {
        case .activateFromCurrentApplication:
            return activateFromCurrentApplication(application)
        case .accessibilityFrontmost:
            return setFrontmost(processID)
        }
    }

    static let live = WindowFocusActivationActions(
        activate: { $0.activate(options: [.activateAllWindows]) },
        activateFromCurrentApplication: { application in
            application.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        },
        setFrontmost: { processID in
            let element = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(element, 0.1)
            return AXUIElementSetAttributeValue(
                element,
                kAXFrontmostAttribute as CFString,
                true as CFTypeRef
            ) == .success
        }
    )
}

/// Foreground state as observed while deciding whether an attempt succeeded.
struct WindowFocusEnvironmentProbe: Sendable, Equatable {
    var frontmostProcessID: pid_t?
    var ownApplicationIsActive: Bool
    var focusedWindowMatchesTarget: Bool?

    @MainActor
    static func read(_ target: WindowFocusTarget) -> WindowFocusEnvironmentProbe {
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedWindowMatchesTarget: Bool?
        if frontmostProcessID == target.processID, let axWindow = target.axWindow {
            focusedWindowMatchesTarget = Self.focusedWindowMatches(
                axWindow: axWindow,
                processID: target.processID
            )
        }
        return WindowFocusEnvironmentProbe(
            frontmostProcessID: frontmostProcessID,
            ownApplicationIsActive: NSApp.isActive,
            focusedWindowMatchesTarget: focusedWindowMatchesTarget
        )
    }

    /// Returns nil when the probe cannot name the focused window at all; only
    /// a positive answer naming a different window counts as a mismatch.
    private static func focusedWindowMatches(axWindow: AXUIElement, processID: pid_t) -> Bool? {
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return CFEqual(value as! AXUIElement, axWindow)
    }
}

// MARK: - Executor

enum WindowFocusExecutor {
    /// One blocking attempt. The service guarantees own-process targets run on
    /// the main actor (WindowFocusExecutionPolicy); external targets run on a
    /// background task.
    static func perform(
        _ target: WindowFocusTarget,
        actions: WindowFocusActivationActions = .live
    ) -> WindowFocusAttemptOutcome {
        var outcome = WindowFocusAttemptOutcome()
        guard let application = NSRunningApplication(processIdentifier: target.processID) else {
            return outcome
        }
        outcome.foundApplication = true
        if application.isHidden {
            outcome.unhidApplication = application.unhide()
        }
        if target.processID == target.ownProcessID {
            // Own-process targets always run on the main actor
            // (WindowFocusExecutionPolicy); trap loudly if that ever changes,
            // because the AppKit calls below require it.
            let ownOutcome = MainActor.assumeIsolated {
                Self.activateOwnApplication(target)
            }
            outcome.activatedApplication = ownOutcome.activatedApplication
            outcome.ownWindowOrderedFront = ownOutcome.orderedWindowFront
        } else {
            // .activateAllWindows is what keeps multi-window applications
            // (Chrome, Electron) from activating without any window coming
            // forward.
            outcome.activatedApplication = actions.activate(application)
            // A cooperative denial is not a dead end: the raise below only
            // means something once the owning application is frontmost.
            for step in WindowFocusActivationPolicy.steps(
                afterPrimaryActivationSucceeded: outcome.activatedApplication
            ) {
                guard actions.perform(step, application: application, processID: target.processID) else {
                    continue
                }
                outcome.activatedApplication = true
                outcome.activatedThroughAccessibility = step == .accessibilityFrontmost
                break
            }
        }
        guard let axWindow = target.axWindow else { return outcome }
        AXUIElementSetMessagingTimeout(axWindow, 0.1)
        if target.isMinimized {
            outcome.restoredWindow = AXUIElementSetAttributeValue(
                axWindow,
                kAXMinimizedAttribute as CFString,
                false as CFTypeRef
            ) == .success
        }
        outcome.raisedWindow = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
        outcome.setWindowMain = AXUIElementSetAttributeValue(
            axWindow,
            kAXMainAttribute as CFString,
            true as CFTypeRef
        ) == .success
        outcome.setWindowFocused = AXUIElementSetAttributeValue(
            axWindow,
            kAXFocusedAttribute as CFString,
            true as CFTypeRef
        ) == .success
        return outcome
    }

    /// MacPilot is an LSUIElement process: activating itself through
    /// NSRunningApplication does not order its SwiftUI scene windows front.
    /// The AppKit path — self-activation plus making the target NSWindow key —
    /// is also what transfers to that window's Space.
    @MainActor
    private static func activateOwnApplication(
        _ target: WindowFocusTarget
    ) -> (activatedApplication: Bool, orderedWindowFront: Bool) {
        // The AppKit self-activation call has no result value; the
        // verification pass decides whether it landed.
        NSApp.activate(ignoringOtherApps: true)
        guard let windowNumber = target.windowNumber,
              let window = NSApp.windows.first(where: {
                  CGWindowID($0.windowNumber) == windowNumber
              }) else {
            return (true, false)
        }
        window.makeKeyAndOrderFront(nil)
        return (true, true)
    }
}

// MARK: - Service

@MainActor
enum WindowFocusService {
    private static let logger = Logger(
        subsystem: "com.misswell.macpilot",
        category: "WindowFocus"
    )
    private static let verificationTimeout = Duration.milliseconds(350)
    private static let verificationPollInterval = Duration.milliseconds(50)

    static func focus(_ item: WindowSwitcherItem) async -> Bool {
        await focus(
            WindowFocusTarget(item: item, ownProcessID: ProcessInfo.processInfo.processIdentifier)
        )
    }

    static func focus(
        _ target: WindowFocusTarget,
        performer: @escaping @Sendable (WindowFocusTarget) -> WindowFocusAttemptOutcome = { WindowFocusExecutor.perform($0) },
        environment: @escaping @MainActor (WindowFocusTarget) -> WindowFocusEnvironmentProbe = WindowFocusEnvironmentProbe.read,
        verificationTimeout: Duration = WindowFocusService.verificationTimeout,
        pollInterval: Duration = WindowFocusService.verificationPollInterval,
        retryDelay: (Int) -> Duration = WindowFocusRetryPolicy.delayBeforeAttempt
    ) async -> Bool {
        for attempt in 0..<WindowFocusRetryPolicy.maximumAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: retryDelay(attempt))
                guard !Task.isCancelled else { return false }
            }
            let outcome: WindowFocusAttemptOutcome
            if WindowFocusExecutionPolicy.runsOnMainActor(
                targetProcessID: target.processID,
                ownProcessID: target.ownProcessID
            ) {
                outcome = performer(target)
            } else {
                outcome = await Task.detached(priority: .userInitiated) {
                    performer(target)
                }.value
            }
            logger.notice("""
                focus attempt \(attempt + 1, privacy: .public)/\(WindowFocusRetryPolicy.maximumAttempts, privacy: .public) \
                pid \(target.processID, privacy: .public): activate=\(outcome.activatedApplication, privacy: .public) \
                axFrontmost=\(outcome.activatedThroughAccessibility, privacy: .public) \
                unhide=\(outcome.unhidApplication, privacy: .public) restore=\(outcome.restoredWindow, privacy: .public) \
                raise=\(outcome.raisedWindow, privacy: .public) axFocus=\(outcome.setWindowFocused, privacy: .public) \
                ownOrderFront=\(outcome.ownWindowOrderedFront, privacy: .public)
                """)
            let verified = await verify(
                target,
                environment: environment,
                timeout: verificationTimeout,
                pollInterval: pollInterval
            )
            if verified { return true }
            guard !Task.isCancelled else { return false }
        }
        logger.error(
            "focus pipeline exhausted \(WindowFocusRetryPolicy.maximumAttempts, privacy: .public) attempts for pid \(target.processID, privacy: .public)"
        )
        DiagnosticLog.write(
            "WindowSwitcher",
            "Window focus pipeline exhausted retries for pid \(target.processID)",
            level: .warning
        )
        return false
    }

    /// Polls until the foreground state confirms the target, the timeout
    /// expires, or the owning task is cancelled. A verified target returns
    /// immediately — the common case adds no perceptible latency.
    private static func verify(
        _ target: WindowFocusTarget,
        environment: @MainActor (WindowFocusTarget) -> WindowFocusEnvironmentProbe,
        timeout: Duration,
        pollInterval: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let probe = environment(target)
            if WindowFocusVerificationPolicy.isVerified(
                targetProcessID: target.processID,
                ownProcessID: target.ownProcessID,
                frontmostProcessID: probe.frontmostProcessID,
                ownApplicationIsActive: probe.ownApplicationIsActive,
                focusedWindowMatchesTarget: probe.focusedWindowMatchesTarget
            ) {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return false }
        }
    }
}
