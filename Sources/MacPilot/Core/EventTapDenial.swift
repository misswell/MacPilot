import CoreGraphics
import Foundation

/// Why a session-level event tap could not be installed.
///
/// `AXIsProcessTrusted()` is not the whole story. A build can be listed under
/// 系统设置 › 隐私与安全性 › 辅助功能 and still be refused by WindowServer:
/// `CGEvent.tapCreate` answers nil and the unified log carries
/// "Sender lacks privileges to install non-process event taps". Everything
/// that rides on the tap then dies at once — smooth scrolling, wheel reversal,
/// ⌥Tab switching, the screenshot shortcut — while the app only knows
/// "trusted but no tap".
///
/// Keeping the two cases apart is what lets the app say something true and do
/// something useful about each: a missing grant is one prompt away, a refused
/// grant is one toggle (关闭再打开辅助功能开关) away, and neither needs a
/// relaunch of the app.
enum EventTapDenial: String, Equatable, Sendable {
    /// No Accessibility grant at all; asking for one is the repair.
    case accessibilityMissing
    /// The grant is listed, yet the system refused the tap. Re-toggling the
    /// app's Accessibility switch re-registers it; the app must keep retrying
    /// so the feature recovers the moment the system allows it again.
    case systemDenied

    init(isProcessTrusted: Bool) {
        self = isProcessTrusted ? .systemDenied : .accessibilityMissing
    }
}

/// Retry cadence shared by the features that must keep an event tap alive.
///
/// A refused install used to be retried every three seconds for as long as the
/// app ran. That is useless — the verdict does not change until the system
/// changes its mind — and expensive: one measured session produced 408
/// WindowServer denials in ten minutes, each a cross-process round trip. Back
/// off, but never stop: a re-granted permission has to recover on its own.
struct EventTapRecoveryPolicy: Equatable, Sendable {
    let intervals: [TimeInterval]

    init(intervals: [TimeInterval] = [3, 3, 3, 10, 30, 60]) {
        self.intervals = intervals.isEmpty ? [30] : intervals
    }

    var firstInterval: TimeInterval { intervals[0] }
    var maximumInterval: TimeInterval { intervals[intervals.count - 1] }

    /// Interval to wait after `failures` consecutive refused or missing taps.
    /// The first passes keep the old three seconds, so a transient startup race
    /// still heals within one tick; later passes settle at the cap.
    func interval(afterFailures failures: Int) -> TimeInterval {
        let index = Swift.min(Swift.max(failures - 1, 0), intervals.count - 1)
        return intervals[index]
    }
}
