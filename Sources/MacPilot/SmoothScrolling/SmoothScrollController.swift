@preconcurrency import ApplicationServices
@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// Low-level presenter for smooth wheel scrolling.
///
/// A single CGEvent tap reads physical wheel events on the main run loop,
/// classifies them with `SmoothScrollGate`, feeds accepted deltas into a
/// CVDisplayLink-backed interpolator, then posts synthetic continuous scroll
/// events directly to the original target process.
@MainActor
final class SmoothScrollController {
    var activeEventTapCount: Int { eventTap == nil ? 0 : 1 }
    private let runtime = SmoothScrollRuntime()
    private var activeSettings = SmoothScrollSettings()
    private var eventTap: (any SmoothScrollEventTap)?
    private let isTrusted: () -> Bool
    private let makeEventTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> (any SmoothScrollEventTap)?
    private let scheduleRecovery: (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    private var cancelRecovery: (() -> Void)?
    private let recoveryPolicy = EventTapRecoveryPolicy()
    /// Consecutive installs that ended without a usable tap. Drives the retry
    /// cadence so a refused tap stops hammering WindowServer every three
    /// seconds while still healing the moment the system allows it.
    private var consecutiveFailures = 0
    /// Why the wheel tap is currently missing, for the settings page.
    private(set) var denial: EventTapDenial?
    /// Told once per state change — never on every retry.
    var denialDidChange: ((EventTapDenial?) -> Void)?
    private var wantsInputTap = false
    private var lastPhysicalWheelTime: CFTimeInterval = 0
    private var commandHeld = false
    private var excludedBundleIdentifiers: Set<String> = []
    private var reversedExcludedBundleIdentifiers: Set<String> = []
    private var processBundleIdentifiers: [pid_t: String] = [:]
    private var excludedProcessIDs: Set<pid_t> = []
    private var reversedExcludedProcessIDs: Set<pid_t> = []
    private let workspaceObservers = ObserverBag()
    private(set) var isActive = false

    private let eventMask: CGEventMask = CGEventMask(
        (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    )

    init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        makeEventTap: @escaping (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> (any SmoothScrollEventTap)? = {
            SystemSmoothScrollEventTap(mask: $0, callback: $1, userInfo: $2)
        },
        scheduleRecovery: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void) = { interval, action in
            // One-shot passes, re-armed by the controller: the wait grows after
            // each refusal, and only the next failure decides the next wait.
            let timer = Timer(timeInterval: interval, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
            timer.tolerance = min(0.5, interval / 4)
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
    ) {
        self.isTrusted = isTrusted
        self.makeEventTap = makeEventTap
        self.scheduleRecovery = scheduleRecovery
    }

    func activate(settings: SmoothScrollSettings) {
        activeSettings = settings.clamped()
        let exclusionsChanged = refreshExcludedApplicationCacheIfNeeded()
        guard activeSettings.requiresInputTap else {
            deactivate()
            return
        }
        wantsInputTap = true
        // Workspace observers stay installed while the feature wants a tap,
        // even when the tap is missing: an app switch is the cheapest moment to
        // retry, and it is exactly when a re-granted permission must land
        // without waiting out the backoff.
        installWorkspaceObservers()
        guard isTrusted() else {
            record(.accessibilityMissing)
            tearDownInputTap()
            scheduleNextPassIfNeeded()
            return
        }
        if let tap = eventTap, !tap.isValid {
            tearDownInputTap()
        }
        if exclusionsChanged {
            runtime.stop()
            lastPhysicalWheelTime = 0
        }

        // Settings must reach the runtime before the tap can deliver its
        // first event; the runtime does not re-apply them per event.
        runtime.update(settings: activeSettings)

        if !isActive {
            guard let tap = makeEventTap(eventMask, Self.eventTapCallback, Unmanaged.passUnretained(self).toOpaque()) else {
                // The system refused a session-level tap. That is not a
                // transient code problem on our side: WindowServer answers nil
                // while the Accessibility grant is listed, and the only repair
                // is the system allowing it again. Keep the intent, retry with
                // backoff, and say so in the page instead of dying silently.
                record(.systemDenied)
                scheduleNextPassIfNeeded()
                return
            }
            eventTap = tap
            tap.setEnabled(true)
            guard tap.isValid && tap.isEnabled else {
                tearDownInputTap()
                record(.systemDenied)
                scheduleNextPassIfNeeded()
                return
            }
            isActive = true
            installWorkspaceObservers()
            // Record before clearing the counter so the log names how many
            // refusals the install had to outlive.
            record(nil)
            consecutiveFailures = 0
        }

        // Never start the display link here. `SmoothScrollRuntime.update(event:)`
        // starts it lazily on the first accepted wheel event and stops it when
        // the glide drains, so an idle tap costs nothing between scrolls.
        //
        // Do not stop it either while smoothing stays enabled: `activate()` runs
        // on every settings mutation, and `stop()` resets the phase machine,
        // which would strand the began/changed events already delivered to the
        // target app without their matching end phase.
        if !activeSettings.isEnabled {
            runtime.stop()
        }
        // One self-check stays armed even with a healthy tap: a session tap can
        // be invalidated without the callback ever running, and the user must
        // not be the one who notices.
        scheduleNextPassIfNeeded()
    }

    /// A failed install is not the user's intent changing: keep retrying, but
    /// on a cadence that stops punishing WindowServer for a verdict only the
    /// system can change. Also covers disabled taps whose system notification
    /// never reached the callback.
    private func recoverInputTapIfNeeded() {
        guard wantsInputTap else { return }
        // The timer that called this pass has already fired; clearing the slot
        // (without cancelling) is what lets the next pass be armed below.
        cancelRecovery = nil
        guard isTrusted() else {
            record(.accessibilityMissing)
            tearDownInputTap()
            consecutiveFailures += 1
            scheduleNextPassIfNeeded()
            return
        }
        if let tap = eventTap, tap.isValid {
            if tap.isEnabled {
                consecutiveFailures = 0
                record(nil)
                scheduleNextPassIfNeeded()
                return
            }
            runtime.stop()
            lastPhysicalWheelTime = 0
            commandHeld = false
            tap.setEnabled(true)
            if tap.isValid && tap.isEnabled {
                consecutiveFailures = 0
                record(nil)
                scheduleNextPassIfNeeded()
                return
            }
        }
        tearDownInputTap()
        consecutiveFailures += 1
        activate(settings: activeSettings)
    }

    /// One pending pass at a time. `activate()` runs on every settings change,
    /// so a pending pass is reused instead of stacked.
    private func scheduleNextPassIfNeeded() {
        guard wantsInputTap, cancelRecovery == nil else { return }
        let interval = isActive
            ? recoveryPolicy.maximumInterval
            : recoveryPolicy.interval(afterFailures: consecutiveFailures)
        cancelRecovery = scheduleRecovery(interval) { [weak self] in
            self?.recoverInputTapIfNeeded()
        }
    }

    /// Records the tap state once per transition. Logging every retry is what
    /// buried the real cause (408 WindowServer denials in ten minutes) and
    /// made the failure invisible in the app.
    private func record(_ denial: EventTapDenial?, logInstall: Bool = true) {
        guard denial != self.denial else { return }
        let previous = self.denial
        self.denial = denial
        switch denial {
        case .none:
            if logInstall, previous != nil {
                DiagnosticLog.write(
                    "SmoothScroll",
                    "Wheel event tap installed after \(consecutiveFailures) refused attempt(s)"
                )
            }
        case .accessibilityMissing:
            DiagnosticLog.write(
                "SmoothScroll",
                "Wheel event tap not created: Accessibility is not granted",
                level: .warning
            )
        case .systemDenied:
            DiagnosticLog.write(
                "SmoothScroll",
                "Wheel event tap refused by WindowServer although Accessibility is granted "
                    + "(Sender lacks privileges to install non-process event taps); "
                    + "smooth scrolling and mouse reversal stay off until the system allows it",
                level: .warning
            )
        }
        denialDidChange?(denial)
    }

    func deactivate() {
        wantsInputTap = false
        cancelRecovery?()
        cancelRecovery = nil
        consecutiveFailures = 0
        tearDownInputTap()
        removeWorkspaceObservers()
        record(nil, logInstall: false)
    }

    private func tearDownInputTap() {
        isActive = false
        if let tap = eventTap {
            tap.invalidate()
            eventTap = nil
        }
        clearExcludedApplicationCache()
        commandHeld = false
        lastPhysicalWheelTime = 0
        runtime.stop()
    }

    func shutdown() {
        deactivate()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<SmoothScrollController>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            controller.handleTapEvent(type: type, event: event)
        }
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            runtime.stop()
            if let tap = eventTap { tap.setEnabled(true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let held = event.flags.contains(.maskCommand)
            if held { runtime.stop() }
            commandHeld = held
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.eventSourceUserData) != SmoothScrollRuntime.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let settings = activeSettings
        let targetProcessID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let vertical = SmoothScrollWheelEventParser.axis(.vertical, in: event)
        let horizontal = SmoothScrollWheelEventParser.axis(.horizontal, in: event)
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: shouldBypassSmoothing(for: targetProcessID),
            shouldReverseExcludedTarget: shouldReverseExcludedApplication(for: targetProcessID),
            isRemoteSmoothed: SmoothScrollWheelEventParser.isRemoteSmoothed(event),
            vertical: vertical,
            horizontal: horizontal,
            isTrackpadLike: SmoothScrollWheelEventParser.isTrackpadLike(event),
            settings: settings,
            commandBlocked: settings.blockSmoothWhileCommandHeld && commandHeld
        )

        switch decision.action {
        case .bypassExcluded(let reverse):
            // Excluded apps do not enter the smoothing pipeline, but their
            // independent reversal must also cover events carrying trackpad
            // phase metadata. Keep this before the normal input classification.
            if reverse {
                _ = SmoothScrollWheelEventParser.reverse(.vertical, in: event)
                _ = SmoothScrollWheelEventParser.reverse(.horizontal, in: event)
            }
            runtime.stop()
            lastPhysicalWheelTime = 0
            return Unmanaged.passUnretained(event)
        case .passThroughRemoteSmoothed, .passThroughInvalidAxes:
            return Unmanaged.passUnretained(event)
        case .smooth:
            reverseOriginalEvent(decision, in: event)
        case .passThroughTrackpadLike:
            // Some mouse drivers set the same continuous/phase fields as a
            // trackpad. They must bypass smoothing, but not independent reversal.
            reverseOriginalEvent(decision, in: event)
            return Unmanaged.passUnretained(event)
        case .passThroughSmoothingDisabled:
            reverseOriginalEvent(decision, in: event)
            runtime.stop()
            lastPhysicalWheelTime = 0
            return Unmanaged.passUnretained(event)
        case .passThroughCommandBlocked:
            reverseOriginalEvent(decision, in: event)
            runtime.stop()
            return Unmanaged.passUnretained(event)
        }

        let now = CFAbsoluteTimeGetCurrent()
        let velocityInterval = lastPhysicalWheelTime == 0 ? SmoothScrollVelocityBoost.slowInterval : now - lastPhysicalWheelTime
        let velocityBoost = SmoothScrollVelocityBoost.factor(
            interval: velocityInterval,
            enabled: settings.adaptiveSpeedEnabled,
            maximum: settings.adaptiveSpeedMaximum
        )
        let plan = SmoothScrollPlanner.plan(vertical: vertical, horizontal: horizontal, settings: settings)
        var boostedPlan = plan
        if plan.consumesAnyAxis {
            boostedPlan.verticalTarget *= velocityBoost
            boostedPlan.horizontalTarget *= velocityBoost
        }
        defer { lastPhysicalWheelTime = now }

        guard plan.consumesAnyAxis else { return Unmanaged.passUnretained(event) }

        let accepted = runtime.update(
            event: event,
            verticalTarget: boostedPlan.verticalTarget,
            horizontalTarget: boostedPlan.horizontalTarget
        )

        // A disabled axis keeps its physical delta on the original event so that
        // apps still receive real (non-synthetic) horizontal scrolling while the
        // vertical axis is being smoothed.
        if plan.passThroughVertical || plan.passThroughHorizontal {
            if boostedPlan.verticalTarget != 0 { SmoothScrollWheelEventParser.clear(.vertical, in: event) }
            if boostedPlan.horizontalTarget != 0 { SmoothScrollWheelEventParser.clear(.horizontal, in: event) }
            return Unmanaged.passUnretained(event)
        }
        return accepted ? nil : Unmanaged.passUnretained(event)
    }

    private func reverseOriginalEvent(_ decision: SmoothScrollGateDecision, in event: CGEvent) {
        if decision.reverseOriginalVertical {
            _ = SmoothScrollWheelEventParser.reverse(.vertical, in: event)
        }
        if decision.reverseOriginalHorizontal {
            _ = SmoothScrollWheelEventParser.reverse(.horizontal, in: event)
        }
    }

    /// Rebuilds the exclusion caches only when the configured bundle
    /// identifiers actually changed, so slider drags do not re-enumerate
    /// `NSWorkspace.shared.runningApplications` on every tick.
    private func refreshExcludedApplicationCacheIfNeeded() -> Bool {
        let excludedIdentifiers = Set(
            activeSettings.excludedApplicationBundleIdentifiers.map {
                SmoothScrollApplicationExclusions.canonicalIdentifier($0)
            }
        )
        let reversedIdentifiers = Set(
            activeSettings.excludedApplicationReverseBundleIdentifiers.map {
                SmoothScrollApplicationExclusions.canonicalIdentifier($0)
            }
        )
        guard excludedIdentifiers != excludedBundleIdentifiers
                || reversedIdentifiers != reversedExcludedBundleIdentifiers else {
            return false
        }
        excludedBundleIdentifiers = excludedIdentifiers
        reversedExcludedBundleIdentifiers = reversedIdentifiers
        rebuildProcessCaches()
        return true
    }

    private func rebuildProcessCaches() {
        processBundleIdentifiers.removeAll(keepingCapacity: true)
        excludedProcessIDs.removeAll(keepingCapacity: true)
        reversedExcludedProcessIDs.removeAll(keepingCapacity: true)

        guard !excludedBundleIdentifiers.isEmpty else { return }
        for application in NSWorkspace.shared.runningApplications {
            updateProcessCache(for: application)
        }
    }

    private func clearExcludedApplicationCache() {
        excludedBundleIdentifiers.removeAll(keepingCapacity: false)
        reversedExcludedBundleIdentifiers.removeAll(keepingCapacity: false)
        processBundleIdentifiers.removeAll(keepingCapacity: false)
        excludedProcessIDs.removeAll(keepingCapacity: false)
        reversedExcludedProcessIDs.removeAll(keepingCapacity: false)
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            workspaceObservers.add(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceApplicationChange(application, notificationName: name)
                }
            }, center: center)
        }
    }

    private func removeWorkspaceObservers() {
        workspaceObservers.removeAll()
    }

    private func handleWorkspaceApplicationChange(
        _ application: NSRunningApplication,
        notificationName: NSNotification.Name
    ) {
        // A refused tap is retried on the next app switch instead of waiting
        // out the backoff: the Accessibility state can only change while the
        // user is elsewhere, and this is the signal that they are back.
        if denial != nil, notificationName == NSWorkspace.didActivateApplicationNotification {
            consecutiveFailures = 0
            activate(settings: activeSettings)
            return
        }
        if notificationName == NSWorkspace.didTerminateApplicationNotification {
            let processID = application.processIdentifier
            processBundleIdentifiers.removeValue(forKey: processID)
            excludedProcessIDs.remove(processID)
            reversedExcludedProcessIDs.remove(processID)
            return
        }

        updateProcessCache(for: application)
        if notificationName == NSWorkspace.didActivateApplicationNotification,
           excludedProcessIDs.contains(application.processIdentifier) {
            runtime.stop()
            lastPhysicalWheelTime = 0
        }
    }

    private func updateProcessCache(for application: NSRunningApplication) {
        let processID = application.processIdentifier
        guard processID > 0 else { return }
        guard let bundleIdentifier = application.bundleIdentifier else {
            processBundleIdentifiers.removeValue(forKey: processID)
            excludedProcessIDs.remove(processID)
            reversedExcludedProcessIDs.remove(processID)
            return
        }
        processBundleIdentifiers[processID] = bundleIdentifier
        let isExcluded = SmoothScrollApplicationExclusions.contains(bundleIdentifier, in: excludedBundleIdentifiers)
        if isExcluded {
            excludedProcessIDs.insert(processID)
        } else {
            excludedProcessIDs.remove(processID)
        }
        if isExcluded,
           SmoothScrollApplicationExclusions.contains(bundleIdentifier, in: reversedExcludedBundleIdentifiers) {
            reversedExcludedProcessIDs.insert(processID)
        } else {
            reversedExcludedProcessIDs.remove(processID)
        }
    }

    private func shouldBypassSmoothing(for processID: pid_t) -> Bool {
        guard processID > 0, !excludedBundleIdentifiers.isEmpty else { return false }
        if excludedProcessIDs.contains(processID) { return true }
        if let bundleIdentifier = processBundleIdentifiers[processID] {
            return SmoothScrollApplicationExclusions.contains(bundleIdentifier, in: excludedBundleIdentifiers)
        }
        // Never query NSWorkspace/NSRunningApplication from the event tap. A
        // just-launched process is covered by the workspace observer shortly;
        // until then, let the normal smoothing path continue without blocking
        // the input callback.
        return false
    }

    private func shouldReverseExcludedApplication(for processID: pid_t) -> Bool {
        guard processID > 0, !reversedExcludedBundleIdentifiers.isEmpty else { return false }
        if reversedExcludedProcessIDs.contains(processID) { return true }
        if let bundleIdentifier = processBundleIdentifiers[processID] {
            return SmoothScrollApplicationExclusions.contains(
                bundleIdentifier,
                in: reversedExcludedBundleIdentifiers
            )
        }
        return false
    }
}
