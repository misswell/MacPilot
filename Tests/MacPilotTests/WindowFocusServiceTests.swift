import AppKit
import Foundation
import Testing
@testable import MacPilot

private final class WindowFocusThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false

    func record() {
        lock.lock()
        observedMainThread = Thread.isMainThread
        lock.unlock()
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMainThread
    }
}

private final class WindowFocusAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class WindowFocusActivationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WindowFocusActivationStep] = []

    func record(_ step: WindowFocusActivationStep) {
        lock.lock()
        recorded.append(step)
        lock.unlock()
    }

    var steps: [WindowFocusActivationStep] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

struct WindowFocusServiceTests {
    @Test @MainActor func externalWindowFocusRunsOffMainActor() async {
        let probe = WindowFocusThreadProbe()
        let ownProcessID = ProcessInfo.processInfo.processIdentifier

        _ = await WindowFocusService.focus(
            WindowFocusTarget(
                processID: ownProcessID + 1,
                axWindow: nil,
                windowNumber: nil,
                isMinimized: false,
                ownProcessID: ownProcessID
            ),
            externalAttempt: { _ in
                probe.record()
                return WindowFocusAttemptOutcome()
            },
            environment: { _ in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(!probe.ranOnMainThread)
    }

    @Test @MainActor func ownWindowFocusRunsOnMainActor() async {
        let probe = WindowFocusThreadProbe()
        let ownProcessID = ProcessInfo.processInfo.processIdentifier

        _ = await WindowFocusService.focus(
            WindowFocusTarget(
                processID: ownProcessID,
                axWindow: nil,
                windowNumber: nil,
                isMinimized: false,
                ownProcessID: ownProcessID
            ),
            ownProcessAttempt: { _ in
                probe.record()
                return WindowFocusAttemptOutcome()
            },
            environment: { _ in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(probe.ranOnMainThread)
    }

    @Test @MainActor func focusPipelineRetriesUntilTheTargetVerifies() async {
        let probe = WindowFocusAttemptProbe()
        let target = WindowFocusTarget(
            processID: 4242,
            axWindow: nil,
            windowNumber: nil,
            isMinimized: false,
            ownProcessID: 4243
        )

        let verified = await WindowFocusService.focus(
            target,
            externalAttempt: { _ in
                probe.record()
                var outcome = WindowFocusAttemptOutcome()
                outcome.activatedApplication = true
                return outcome
            },
            environment: { target in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: probe.attemptCount >= 2 ? target.processID : nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(verified)
        #expect(probe.attemptCount == 2)
    }

    @Test @MainActor func focusPipelineGivesUpAfterTheFinalRetryWithoutVerification() async {
        let probe = WindowFocusAttemptProbe()
        let target = WindowFocusTarget(
            processID: 4242,
            axWindow: nil,
            windowNumber: nil,
            isMinimized: false,
            ownProcessID: 4243
        )

        let verified = await WindowFocusService.focus(
            target,
            externalAttempt: { _ in
                probe.record()
                return WindowFocusAttemptOutcome()
            },
            environment: { _ in
                WindowFocusEnvironmentProbe(
                    frontmostProcessID: nil,
                    ownApplicationIsActive: false,
                    focusedWindowMatchesTarget: nil
                )
            },
            verificationTimeout: .zero,
            pollInterval: .zero,
            retryDelay: { _ in .zero }
        )

        #expect(!verified)
        #expect(probe.attemptCount == WindowFocusRetryPolicy.maximumAttempts)
    }

    @Test func retryDelaysGrowAndClampAtTheFinalDelay() {
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(0) == .zero)
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(1) == .milliseconds(150))
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(2) == .milliseconds(400))
        #expect(WindowFocusRetryPolicy.delayBeforeAttempt(99) == .milliseconds(400))
        #expect(WindowFocusRetryPolicy.maximumAttempts == 3)
    }

    @Test func verificationRequiresTheTargetApplicationToFrontmost() {
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: nil,
            ownApplicationIsActive: true,
            focusedWindowMatchesTarget: nil
        ))
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 20,
            ownApplicationIsActive: true,
            focusedWindowMatchesTarget: nil
        ))
        #expect(WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 10,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: nil
        ))
        // A positive AX probe naming a different window blocks acceptance…
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 10,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: false
        ))
        // …while an inconclusive probe must not.
        #expect(WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 10,
            ownProcessID: 20,
            frontmostProcessID: 10,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: true
        ))
        // MacPilot's own windows additionally require NSApp.isActive.
        #expect(WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 20,
            ownProcessID: 20,
            frontmostProcessID: 20,
            ownApplicationIsActive: true,
            focusedWindowMatchesTarget: nil
        ))
        #expect(!WindowFocusVerificationPolicy.isVerified(
            targetProcessID: 20,
            ownProcessID: 20,
            frontmostProcessID: 20,
            ownApplicationIsActive: false,
            focusedWindowMatchesTarget: nil
        ))
    }

    @Test func focusExecutorReportsAMissingApplicationWithoutSideEffects() async {
        let outcome = await WindowFocusExecutor.perform(
            WindowFocusTarget(
                processID: -1,
                axWindow: nil,
                windowNumber: nil,
                isMinimized: false,
                ownProcessID: -1
            )
        )

        #expect(!outcome.foundApplication)
        #expect(!outcome.activatedApplication)
        #expect(!outcome.raisedWindow)
    }

    /// macOS 14 answers a background `LSUIElement` process with
    /// `activate == false`; measured on macOS 27 with `raise=true` and
    /// `axFocus=true` in the same attempt. Without the escalated steps the
    /// switcher closes its panel and leaves the target behind — "切换没有把
    /// 窗口带到前台".
    @Test func refusedCooperativeActivationEscalatesToAccessibilityFrontmost() {
        #expect(WindowFocusActivationPolicy.steps(afterPrimaryActivationSucceeded: true).isEmpty)
        #expect(WindowFocusActivationPolicy.steps(afterPrimaryActivationSucceeded: false) == [
            .activateFromCurrentApplication,
            .accessibilityFrontmost
        ])
    }

    @Test func activationActionsDispatchEveryEscalationStep() {
        let application = NSRunningApplication.current
        let probe = WindowFocusActivationProbe()
        let actions = WindowFocusActivationActions(
            activate: { _ in false },
            activateFromCurrentApplication: { _ in
                probe.record(.activateFromCurrentApplication)
                return false
            },
            setFrontmost: { _ in
                probe.record(.accessibilityFrontmost)
                return true
            }
        )

        #expect(!actions.perform(
            .activateFromCurrentApplication,
            application: application,
            processID: application.processIdentifier
        ))
        #expect(actions.perform(
            .accessibilityFrontmost,
            application: application,
            processID: application.processIdentifier
        ))
        #expect(probe.steps == [.activateFromCurrentApplication, .accessibilityFrontmost])
    }
}
