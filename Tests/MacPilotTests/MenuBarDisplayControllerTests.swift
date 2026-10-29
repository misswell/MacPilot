import AppKit
import Combine
import Foundation
import MacPilotDisplayControlCore
import Testing
@testable import MacPilot

@MainActor
struct MenuBarDisplayControllerTests {
    @Test func menuAnchorUsesTheBottomEdgeInEitherCoordinateSystem() {
        let bounds = NSRect(x: 3, y: 5, width: 24, height: 22)
        #expect(MenuBarDisplayController.menuAnchor(in: bounds, isFlipped: true) == NSPoint(x: 3, y: 27))
        #expect(MenuBarDisplayController.menuAnchor(in: bounds, isFlipped: false) == NSPoint(x: 3, y: 5))
    }

    @Test func displayRemovalAndRestoreEachReattachTheMenuBarController() async {
        let state = TestDisplayState([screen("left", x: -1_280), screen("right", x: 0)])
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { state.screens })
        defer { controller.stop() }
        let changes = observeInsertions(controller)

        state.screens = [screen("left", x: -1_280)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertions(2, changes))

        state.screens = [screen("left", x: -1_280), screen("right", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertions(4, changes))
        #expect(changes.count == 4)
        #expect(controller.isInserted)
    }

    @Test func sameTopologyNotificationDoesNotReattachTheMenuBarController() async {
        let current = [screen("left", x: -1_280), screen("right", x: 0)]
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { current })
        defer { controller.stop() }
        let changes = observeInsertions(controller)

        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(40))

        #expect(changes.count == 0)
        #expect(controller.isInserted)
    }

    @Test func quickRemoveAndRestoreStillReattachesOnceWhenFinalTopologyMatches() async {
        let left = screen("left", x: -1_280)
        let right = screen("right", x: 0)
        let state = TestDisplayState([left, right])
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { state.screens })
        defer { controller.stop() }
        let changes = observeInsertions(controller)

        state.screens = [left]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        state.screens = [left, right]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(await waitForInsertions(2, changes))
        #expect(changes.count == 2)
        #expect(controller.isInserted)
    }

    @Test func nestedMenusKeepTheCapturedUUIDAndDelayReattachmentUntilTrackingEnds() async {
        let left = screen("left", x: -1_280)
        let right = screen("right", x: 0)
        let state = TestDisplayState([left, right], pointer: CGPoint(x: -500, y: 200))
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { state.screens }, pointer: { state.pointer })
        defer { controller.stop() }
        let changes = observeInsertions(controller)
        let mainMenu = NSMenu()
        let nestedMenu = NSMenu()

        center.post(name: NSMenu.didBeginTrackingNotification, object: mainMenu)
        #expect(controller.targetUUID == "left")
        state.pointer = CGPoint(x: 500, y: 200)
        center.post(name: NSMenu.didBeginTrackingNotification, object: nestedMenu)
        #expect(controller.targetUUID == "left")

        state.screens = [left]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(controller.targetUUID == nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(changes.count == 0)

        center.post(name: NSMenu.didEndTrackingNotification, object: mainMenu)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(changes.count == 0)

        center.post(name: NSMenu.didEndTrackingNotification, object: nestedMenu)
        #expect(await waitForInsertions(2, changes))
        #expect(controller.isInserted)
    }

    @Test func pointerInsideNegativeOriginDisplaySelectsThatDisplay() {
        let center = NotificationCenter()
        let controller = makeController(
            center: center,
            screens: { [screen("left", x: -1_280), screen("main", x: 0)] },
            pointer: { CGPoint(x: -1_000, y: 250) }
        )
        defer { controller.stop() }

        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())

        #expect(controller.targetUUID == "left")
    }

    @Test func topologyChangeInvalidatesTheTargetAndNeverFallsBackToMain() {
        let state = TestDisplayState([screen("main", x: 0), screen("external", x: 1_920)],
                                     pointer: CGPoint(x: 2_000, y: 200))
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { state.screens }, pointer: { state.pointer })
        defer { controller.stop() }
        let menu = NSMenu()

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(controller.targetUUID == "external")

        state.screens = [screen("main", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(controller.targetUUID == nil)

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        state.pointer = CGPoint(x: 8_000, y: 8_000)
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        #expect(controller.targetUUID == nil)
    }

    @Test func stopCancelsAQueuedReattachment() async {
        let state = TestDisplayState([screen("main", x: 0), screen("external", x: 1_920)])
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(
            notificationCenter: center,
            screens: { state.screens },
            debounce: .milliseconds(100),
            insertionDelay: .milliseconds(5)
        )
        let changes = observeInsertions(controller)

        state.screens = [screen("main", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        controller.stop()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(changes.count == 0)
        #expect(controller.isInserted)
    }

    @Test func stopDuringTheRemovedWindowRestoresInsertionAndCancelsTheRemainder() async {
        let state = TestDisplayState([screen("main", x: 0), screen("external", x: 1_920)])
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(
            notificationCenter: center,
            screens: { state.screens },
            debounce: .milliseconds(2),
            insertionDelay: .milliseconds(80)
        )
        let changes = observeInsertions(controller)

        state.screens = [screen("main", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertionState(false, controller))

        controller.stop()
        #expect(controller.isInserted)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.isInserted)
        #expect(changes.count == 2)
    }

    @Test func topologyChangeDuringTheRemovedWindowStillFinishesInserted() async {
        let main = screen("main", x: 0)
        let external = screen("external", x: 1_920)
        let third = screen("third", x: 3_840)
        let state = TestDisplayState([main, external])
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(
            notificationCenter: center,
            screens: { state.screens },
            debounce: .milliseconds(2),
            insertionDelay: .milliseconds(70)
        )
        let changes = observeInsertions(controller)
        defer { controller.stop() }

        state.screens = [main]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertionState(false, controller))

        state.screens = [main, third]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Cancelling the first pass synchronously restores the icon, then
        // starts a replacement pass. That interim `true` is not completion:
        // wait for both remove/insert pairs, rather than a wall-clock delay.
        #expect(await waitForInsertions(4, changes))

        #expect(controller.isInserted)
        #expect(changes.count == 4)
    }

    @Test func topologyChangeWhileAMenuTracksDuringTheRemovedWindowRestoresTheItem() async {
        let main = screen("main", x: 0)
        let external = screen("external", x: 1_920)
        let third = screen("third", x: 3_840)
        let state = TestDisplayState([main, external])
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(
            notificationCenter: center,
            screens: { state.screens },
            debounce: .milliseconds(2),
            insertionDelay: .milliseconds(70)
        )
        let changes = observeInsertions(controller)
        defer { controller.stop() }
        let menu = NSMenu()

        state.screens = [main]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertionState(false, controller))

        // A menu starts tracking while the status item sits removed, then the
        // topology changes again. Cancelling the in-flight reattachment must
        // restore the item at once — waiting for tracking to end would hide
        // the icon for as long as the menu stays open.
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        state.screens = [main, third]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertionState(true, controller))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(controller.isInserted)

        // Tracking ends: the pending topology change still re-runs the dance.
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(await waitForInsertionState(true, controller))
        try? await Task.sleep(for: .milliseconds(120))
        #expect(controller.isInserted)
    }

    @Test func disablingTheIconStopsReattachmentAndReenablingRestoresIt() async {
        let state = TestDisplayState([screen("main", x: 0), screen("external", x: 1_920)])
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { state.screens })
        defer { controller.stop() }

        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(!controller.isInserted)

        // 用户关掉图标后，显示器拓扑变化不得把它重新装回来——
        // 否则「隐藏菜单栏图标」会被一次分辨率切换撤销。
        state.screens = [screen("main", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!controller.isInserted)

        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.isInserted)
    }

    @Test func disablingTheIconMidReattachmentDoesNotLeaveItInserted() async {
        let state = TestDisplayState([screen("main", x: 0), screen("external", x: 1_920)])
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(
            notificationCenter: center,
            screens: { state.screens },
            debounce: .milliseconds(2),
            insertionDelay: .milliseconds(80)
        )
        defer { controller.stop() }

        state.screens = [screen("main", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertionState(false, controller))

        controller.setEnabled(false)
        try? await Task.sleep(for: .milliseconds(120))

        #expect(!controller.isInserted)
        #expect(!controller.isEnabled)
    }

    @Test func selfHealNeverFightsTheUserAndRespectsTheSwitch() async {
        let state = TestDisplayState([screen("main", x: 0), screen("external", x: 1_920)])
        let center = NotificationCenter()
        let controller = makeController(center: center, screens: { state.screens })
        defer { controller.stop() }

        state.screens = [screen("main", x: 0)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await waitForInsertionState(false, controller))

        // 菜单正在跟踪时自愈必须让路，否则会重建一个用户正看着的菜单。
        let menu = NSMenu()
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        controller.selfHeal()
        #expect(!controller.isInserted)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(await waitForInsertionState(true, controller))

        // 用户关掉图标后，自愈不得把它装回来。
        controller.setEnabled(false)
        controller.selfHeal()
        #expect(!controller.isInserted)

        controller.setEnabled(true)
        #expect(controller.isInserted)
    }

    private func makeController(
        center: NotificationCenter,
        screens: @escaping @MainActor () -> [MenuBarDisplay],
        pointer: @escaping @MainActor () -> CGPoint = { .zero }
    ) -> MenuBarDisplayController {
        MenuBarDisplayController(
            notificationCenter: center,
            screens: screens,
            pointer: pointer,
            debounce: .milliseconds(5),
            insertionDelay: .milliseconds(5),
            menuFactory: nil
        )
    }

    private func screen(_ uuid: String, x: CGFloat) -> MenuBarDisplay {
        MenuBarDisplay(uuid: uuid, frame: CGRect(x: x, y: 0, width: 1_280, height: 800))
    }

    private func observeInsertions(_ controller: MenuBarDisplayController) -> ChangeCounter {
        let counter = ChangeCounter()
        controller.$isInserted.dropFirst().sink { _ in counter.increment() }.store(in: &counter.cancellables)
        return counter
    }

    private func waitForInsertions(_ target: Int, _ counter: ChangeCounter) async -> Bool {
        for _ in 0..<200 {
            if counter.count >= target { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return counter.count >= target
    }

    private func waitForInsertionState(_ expected: Bool, _ controller: MenuBarDisplayController) async -> Bool {
        for _ in 0..<200 {
            if controller.isInserted == expected { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return controller.isInserted == expected
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var cancellables = Set<AnyCancellable>()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

@MainActor
private final class TestDisplayState {
    var screens: [MenuBarDisplay]
    var pointer: CGPoint

    init(_ screens: [MenuBarDisplay], pointer: CGPoint = .zero) {
        self.screens = screens
        self.pointer = pointer
    }
}
