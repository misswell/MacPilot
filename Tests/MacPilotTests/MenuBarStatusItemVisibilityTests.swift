import AppKit
import Testing
@testable import MacPilot

@MainActor
struct MenuBarStatusItemVisibilityTests {
    @Test func switchingOffAndOnOverridesRestoredHiddenStatus() {
        let bar = StatusBar()
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(notificationCenter: center, screens: { [] },
            menuFactory: { _ in NSMenu() }, makeStatusItem: { bar.makeItem() },
            removeItem: { bar.remove($0) })
        defer { controller.setEnabled(false); controller.stop() }
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        #expect(bar.items.last?.isVisible == true)
        controller.setEnabled(false)
        #expect(bar.items.last?.isVisible == false)
        controller.setEnabled(true)
        #expect(controller.isInserted)
        #expect(bar.items.count == 2)
        #expect(bar.items.last?.isVisible == true)
        #expect(bar.items.last?.autosaveName == "MacPilotStatusItem")
    }

    @Test func anAlreadyPersistedHiddenItemIsVisibleAtLaunchWhenEnabled() {
        let bar = StatusBar()
        bar.savedVisibility = false
        let center = NotificationCenter()
        let controller = MenuBarDisplayController(notificationCenter: center, screens: { [] },
            menuFactory: { _ in NSMenu() }, makeStatusItem: { bar.makeItem() },
            removeItem: { bar.remove($0) })
        defer { controller.setEnabled(false); controller.stop() }
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        #expect(bar.items.last?.isVisible == true)
        #expect(controller.isEnabled)
    }

    @MainActor
    private final class StatusBar {
        var savedVisibility = true
        var items: [Item] = []
        func makeItem() -> Item {
            let item = Item(bar: self)
            items.append(item)
            return item
        }
        func remove(_ item: any MenuBarStatusItem) { item.isVisible = false }
    }

    private final class Item: MenuBarStatusItem {
        unowned let bar: StatusBar
        init(bar: StatusBar) { self.bar = bar }
        // AppKit restores its own persisted visibility when autosaveName is
        // attached. Merely allocating a fresh item does not guarantee visibility.
        var autosaveName: NSStatusItem.AutosaveName! {
            didSet { isVisible = bar.savedVisibility }
        }
        var isVisible = true { didSet { bar.savedVisibility = isVisible } }
        var button: NSStatusBarButton? { nil }
        var menu: NSMenu?
    }
}
