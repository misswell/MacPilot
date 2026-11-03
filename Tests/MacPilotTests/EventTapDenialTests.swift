import CoreGraphics
import Testing
@testable import MacPilot

/// The two ways a session tap can be missing are not interchangeable: one is a
/// prompt away, the other needs the system's Accessibility switch re-toggled.
/// Collapsing them into "permission granted" is what made 平滑滚动 / 鼠标反向 /
/// ⌥Tab die silently on macOS 27 while every page still showed a green badge.
struct EventTapDenialTests {
    @Test func aListedButRefusedGrantIsReportedAsASystemDenial() {
        #expect(EventTapDenial(isProcessTrusted: true) == .systemDenied)
        #expect(EventTapDenial(isProcessTrusted: false) == .accessibilityMissing)
    }

    @Test func recoveryPolicyNeverWaitsLessThanTheFirstPassAndNeverGivesUp() {
        let policy = EventTapRecoveryPolicy()
        #expect(policy.interval(afterFailures: 0) == policy.firstInterval)
        #expect(policy.interval(afterFailures: 1) == policy.firstInterval)
        #expect(policy.interval(afterFailures: 10_000) == policy.maximumInterval)
    }

    @Test func anEmptyPolicyStillProducesALegalWait() {
        let policy = EventTapRecoveryPolicy(intervals: [])
        #expect(policy.firstInterval > 0)
        #expect(policy.maximumInterval > 0)
        #expect(policy.interval(afterFailures: 3) > 0)
    }
}
