import CoreGraphics
import Testing
@testable import MacPilot

@MainActor
struct SmoothScrollRecoveryTests {
    @MainActor final class Tap: SmoothScrollEventTap {
        var isValid = true
        var isEnabled = false
        var acceptsEnable = true
        func setEnabled(_ enabled: Bool) { isEnabled = enabled && acceptsEnable }
        func invalidate() { isValid = false; isEnabled = false }
    }

    @MainActor final class Harness {
        var trusted = true
        var failures = 0
        var attempts = 0
        var taps: [Tap] = []
        var tick: (@MainActor () -> Void)?
        var schedules = 0
        var cancellations = 0
        var callback: CGEventTapCallBack?
        var userInfo: UnsafeMutableRawPointer?
        lazy var controller = SmoothScrollController(
            isTrusted: { [unowned self] in self.trusted },
            makeEventTap: { [unowned self] _, callback, userInfo in
                self.callback = callback
                self.userInfo = userInfo
                self.attempts += 1
                if self.failures > 0 { self.failures -= 1; return nil }
                let tap = Tap()
                self.taps.append(tap)
                return tap
            },
            scheduleRecovery: { [unowned self] action in
                self.schedules += 1
                self.tick = action
                return { [unowned self] in self.tick = nil; self.cancellations += 1 }
            }
        )
        func scrollDelta() throws -> Int64 {
            let event = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0
            ))
            if taps.last?.isEnabled == true {
                _ = callback?(OpaquePointer(bitPattern: 1)!, .scrollWheel, event, userInfo)
            }
            return event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        }

        var reverseOnly: SmoothScrollSettings {
            var settings = SmoothScrollSettings()
            settings.reverseScrollingEnabled = true
            return settings
        }
    }

    @Test func failedStartupRetriesWithoutSettingsChangesOrRestart() throws {
        let h = Harness()
        h.failures = 2
        h.controller.activate(settings: h.reverseOnly)
        defer { h.controller.shutdown() }
        #expect(h.controller.activeEventTapCount == 0)
        #expect(try h.scrollDelta() == 4)
        h.tick?()
        h.tick?()
        #expect(try h.scrollDelta() == -4)
        #expect(h.attempts == 3)
        #expect(h.controller.isActive)
        #expect(h.taps.last?.isEnabled == true)
    }

    @Test func permissionBecomingReadyAfterStartupRecoversAutomatically() {
        let h = Harness()
        h.trusted = false
        h.controller.activate(settings: h.reverseOnly)
        defer { h.controller.shutdown() }
        #expect(h.attempts == 0)
        h.trusted = true
        h.tick?()
        #expect(h.controller.isActive)
        #expect(h.taps.last?.isEnabled == true)
    }

    @Test func disabledTapIsReenabledAndInvalidTapIsReplaced() {
        let h = Harness()
        h.controller.activate(settings: h.reverseOnly)
        defer { h.controller.shutdown() }
        h.taps[0].isEnabled = false
        h.tick?()
        #expect(h.taps[0].isEnabled)
        #expect(h.attempts == 1)
        h.taps[0].isValid = false
        h.tick?()
        #expect(h.attempts == 2)
        #expect(h.taps.last?.isEnabled == true)
        #expect(h.controller.activeEventTapCount == 1)
    }

    @Test func shutdownCancelsRecoveryAndStaleTicksCannotReinstallTap() {
        let h = Harness()
        h.controller.activate(settings: h.reverseOnly)
        let staleTick = h.tick
        h.controller.shutdown()
        staleTick?()
        #expect(h.cancellations == 1)
        #expect(h.attempts == 1)
        #expect(h.controller.activeEventTapCount == 0)
    }

    @Test func healthyTapIsRetainedAndDisablingSettingsStopsRecovery() {
        let h = Harness()
        h.controller.activate(settings: h.reverseOnly)
        h.controller.activate(settings: h.reverseOnly)
        h.tick?()
        #expect(h.attempts == 1)
        h.controller.activate(settings: SmoothScrollSettings())
        #expect(h.tick == nil)
        #expect(h.cancellations == 1)
        #expect(!h.taps[0].isValid)
    }

    @Test func tapThatRefusesReenableIsReplacedWithoutDuplicateMonitor() {
        let h = Harness()
        h.controller.activate(settings: h.reverseOnly)
        defer { h.controller.shutdown() }
        h.taps[0].isEnabled = false
        h.taps[0].acceptsEnable = false
        h.tick?()
        #expect(!h.taps[0].isValid)
        #expect(h.taps.last?.isEnabled == true)
        #expect(h.attempts == 2)
        #expect(h.schedules == 1)
    }

    @Test func pendingRecoveryUsesLatestDirectionSettings() throws {
        let h = Harness()
        h.failures = 2
        h.controller.activate(settings: h.reverseOnly)
        defer { h.controller.shutdown() }
        var latest = h.reverseOnly
        latest.reverseVertical = false
        latest.reverseHorizontal = true
        h.controller.activate(settings: latest)
        h.tick?()
        #expect(h.controller.isActive)
        #expect(try h.scrollDelta() == 4)
        #expect(h.schedules == 1)
    }

    @Test func permissionRevocationRemovesTapAndGrantRestoresIt() {
        let h = Harness()
        h.controller.activate(settings: h.reverseOnly)
        defer { h.controller.shutdown() }
        h.trusted = false
        h.tick?()
        #expect(h.controller.activeEventTapCount == 0)
        #expect(!h.taps[0].isValid)
        h.trusted = true
        h.tick?()
        #expect(h.attempts == 2)
        #expect(h.controller.isActive)
    }
}
