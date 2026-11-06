import AppKit
import Testing
@testable import MacPilot

/// 多显示器 + 设置窗口在场时，应用激活是异步的：AppKit 在 `didBecomeActive`
/// 之后仍会继续排窗口，另一块屏上的普通窗口可能再抢走 key。面板必须在那段
/// settle 期间反复重拿 key，否则 `resignKey` 的延迟关闭会把它收掉
/// （用户看到「闪一下消失」）。
@MainActor
struct QuickSearchPanelActivationTests {
    private final class State {
        var isActive = false
        var settleWork: (@MainActor () -> Void)?
        var reclaimed = 0
        var settled = 0
    }

    private func recovery(_ state: State, center: NotificationCenter) -> QuickSearchPanelActivationRecovery {
        let recovery = QuickSearchPanelActivationRecovery(
            notificationCenter: center,
            applicationIsActive: { state.isActive },
            scheduleSettle: { work in state.settleWork = work }
        )
        recovery.onActivated = { state.reclaimed += 1 }
        recovery.onSettled = { state.settled += 1 }
        return recovery
    }

    @Test func anAlreadyActiveApplicationDoesNotArmRecovery() {
        let state = State()
        state.isActive = true
        let center = NotificationCenter()
        let subject = recovery(state, center: center)

        subject.armIfApplicationIsInactive()

        #expect(!subject.isRecovering)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(state.reclaimed == 0)
    }

    @Test func becomingActiveKeepsRecoveringUntilTheSettleWindowEnds() {
        let state = State()
        let center = NotificationCenter()
        let subject = recovery(state, center: center)

        subject.armIfApplicationIsInactive()
        #expect(subject.isRecovering)

        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(state.reclaimed == 1)
        #expect(subject.isRecovering)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(state.reclaimed == 1)

        state.settleWork?()
        #expect(!subject.isRecovering)
        #expect(state.settled == 1)
    }

    @Test func closingThePanelDuringSettlePreventsTheSettledCallback() {
        let state = State()
        let center = NotificationCenter()
        let subject = recovery(state, center: center)

        subject.armIfApplicationIsInactive()
        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(state.reclaimed == 1)

        subject.disarm()
        state.settleWork?()

        #expect(state.settled == 0)
        #expect(!subject.isRecovering)
    }

    @Test func closingThePanelDisarmsPendingRecovery() {
        let state = State()
        let center = NotificationCenter()
        let subject = recovery(state, center: center)

        subject.armIfApplicationIsInactive()
        subject.disarm()
        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(state.reclaimed == 0)
        #expect(!subject.isRecovering)
    }

    @Test func resignDoesNotCloseWhileActivationIsStillRecovering() {
        #expect(!QuickSearchPanelResignPolicy.shouldClose(
            isPresented: true,
            isKeyWindow: false,
            isRecoveringActivation: true
        ))
        #expect(QuickSearchPanelResignPolicy.shouldClose(
            isPresented: true,
            isKeyWindow: false,
            isRecoveringActivation: false
        ))
        #expect(!QuickSearchPanelResignPolicy.shouldClose(
            isPresented: true,
            isKeyWindow: true,
            isRecoveringActivation: false
        ))
        #expect(!QuickSearchPanelResignPolicy.shouldClose(
            isPresented: false,
            isKeyWindow: false,
            isRecoveringActivation: false
        ))
    }
}
