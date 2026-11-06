import AppKit
import Testing
@testable import MacPilot

/// 多显示器 + 设置窗口在场时，应用激活是异步的：AppKit 会在激活完成时把
/// 另一块屏上的普通窗口选成 key window。面板必须在那之后重新拿回 key，
/// 否则 `resignKey` 的延迟关闭会把它收掉（用户看到「闪一下消失」）。
@MainActor
struct QuickSearchPanelActivationTests {
    private final class State {
        var isActive = false
        var activations = 0
    }

    private func recovery(
        _ state: State,
        center: NotificationCenter,
        onActivated: @escaping () -> Void
    ) -> QuickSearchPanelActivationRecovery {
        let recovery = QuickSearchPanelActivationRecovery(
            notificationCenter: center,
            applicationIsActive: { state.isActive }
        )
        recovery.onActivated = onActivated
        return recovery
    }

    @Test func anAlreadyActiveApplicationDoesNotArmRecovery() {
        let state = State()
        state.isActive = true
        let center = NotificationCenter()
        var reclaimed = 0
        let subject = recovery(state, center: center) { reclaimed += 1 }

        subject.armIfApplicationIsInactive()

        #expect(!subject.isArmed)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(reclaimed == 0)
    }

    @Test func becomingActiveReclaimsThePanelExactlyOnce() {
        let state = State()
        let center = NotificationCenter()
        var reclaimed = 0
        let subject = recovery(state, center: center) { reclaimed += 1 }

        subject.armIfApplicationIsInactive()
        #expect(subject.isArmed)

        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(reclaimed == 1)
        #expect(!subject.isArmed)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(reclaimed == 1)
    }

    @Test func closingThePanelDisarmsPendingRecovery() {
        let state = State()
        let center = NotificationCenter()
        var reclaimed = 0
        let subject = recovery(state, center: center) { reclaimed += 1 }

        subject.armIfApplicationIsInactive()
        subject.disarm()
        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(reclaimed == 0)
        #expect(!subject.isArmed)
    }

    @Test func resignDoesNotCloseWhileActivationIsStillPending() {
        #expect(!QuickSearchPanelResignPolicy.shouldClose(
            isPresented: true,
            isKeyWindow: false,
            isAwaitingActivation: true
        ))
        #expect(QuickSearchPanelResignPolicy.shouldClose(
            isPresented: true,
            isKeyWindow: false,
            isAwaitingActivation: false
        ))
        #expect(!QuickSearchPanelResignPolicy.shouldClose(
            isPresented: true,
            isKeyWindow: true,
            isAwaitingActivation: false
        ))
        #expect(!QuickSearchPanelResignPolicy.shouldClose(
            isPresented: false,
            isKeyWindow: false,
            isAwaitingActivation: false
        ))
    }
}
