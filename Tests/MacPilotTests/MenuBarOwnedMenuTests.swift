import AppKit
import Testing
@testable import MacPilot

/// The status item must own a real `NSMenu`: AppKit is the only thing that puts
/// a status-menu popup where the menu bar puts it. A controller that positions
/// the popup itself (`popUp(positioning:at:in:)`) lands a few points too high —
/// measured on macOS 27: `bounds.maxY` (bottom edge) still 6pt above the bar,
/// `bounds.minY` 24pt above it, while the owned-menu path sits 1pt below it.
/// These tests fail if the popup ever goes back to a hand-computed anchor.
@MainActor
struct MenuBarOwnedMenuTests {
    @Test func statusItemOwnsTheMenuAppKitPositionsAndTracks() throws {
        let bar = StatusBar()
        let center = NotificationCenter()
        let controller = makeController(center: center, bar: bar, source: { MenuSource(rows: ["row"]) })
        defer { controller.setEnabled(false); controller.stop() }

        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        let item = try #require(bar.items.last)
        let menu = try #require(item.menu)
        #expect(menu.delegate === controller)
        #expect(!menu.autoenablesItems)
        // The button must not drive the popup itself: a status item with a menu
        // and an action would send the action instead of showing the menu.
        #expect(item.button == nil || item.button?.action == nil)
    }

    @Test func ownedMenuIsFilledFromAFreshSnapshotEachTimeItOpens() throws {
        let bar = StatusBar()
        let center = NotificationCenter()
        let source = MenuSource(rows: ["first"])
        let controller = makeController(center: center, bar: bar, source: { source })
        defer { controller.setEnabled(false); controller.stop() }
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        let item = try #require(bar.items.last)
        let menu = try #require(item.menu)

        controller.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["first"])

        source.rows = ["second", "third"]
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["second", "third"])
        // Rebuilding must keep the exact menu AppKit already owns attached.
        #expect(bar.items.last?.menu === menu)
    }

    @Test func updatingAForeignMenuIsIgnored() throws {
        let bar = StatusBar()
        let center = NotificationCenter()
        let controller = makeController(center: center, bar: bar, source: { MenuSource(rows: ["row"]) })
        defer { controller.setEnabled(false); controller.stop() }
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        let launched = try #require(bar.items.last)
        let owned = try #require(launched.menu)
        let foreign = NSMenu()

        controller.menuNeedsUpdate(foreign)

        #expect(foreign.items.isEmpty)
        #expect(owned.items.isEmpty)
    }

    @Test func attachedMenuKeepsActionsWorkingThroughTheRelay() throws {
        let bar = StatusBar()
        let center = NotificationCenter()
        let receiver = Receiver()
        let controller = makeController(center: center, bar: bar, source: {
            let source = MenuSource(rows: ["act"])
            source.action = #selector(Receiver.fire(_:))
            source.target = receiver
            return source
        })
        defer { controller.setEnabled(false); controller.stop() }
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        let item = try #require(bar.items.last)
        let menu = try #require(item.menu)

        controller.menuNeedsUpdate(menu)
        let row = try #require(menu.items.first)
        _ = NSApplication.shared.sendAction(row.action!, to: row.target, from: row)

        #expect(receiver.count == 1)
        controller.menuDidClose(menu)
    }

    /// macOS 27 performs a chosen menu item's action after `menuDidClose`,
    /// not before it. `NSMenuItem` holds its target weakly, so a snapshot
    /// dropped synchronously at close time has zeroed every relay target by
    /// the time AppKit dispatches — the click closed the menu and nothing
    /// ran. The snapshot must outlive the close long enough for that dispatch,
    /// then still be released so the hosting source does not outlive the popup.
    @Test func relayTargetsSurviveThePostCloseActionDispatchAndDropOneTurnLater() throws {
        let bar = StatusBar()
        let center = NotificationCenter()
        let receiver = Receiver()
        var pendingDrops: [@MainActor () -> Void] = []
        var holder: MenuSource?
        let controller = makeController(center: center, bar: bar, source: {
            let source = MenuSource(rows: ["act"])
            source.action = #selector(Receiver.fire(_:))
            source.target = receiver
            holder = source
            return source
        }, scheduleDeferred: { work in pendingDrops.append(work) })
        defer { controller.setEnabled(false); controller.stop() }
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        let menu = try #require(bar.items.last?.menu)

        controller.menuNeedsUpdate(menu)
        weak var weakSourceMenu: NSMenu? = holder?.menu
        holder = nil
        let row = try #require(menu.items.first)

        // The macOS 27 order: close first, dispatch second. The relay must
        // still answer here — this is exactly where the old code went dead.
        controller.menuDidClose(menu)
        _ = NSApplication.shared.sendAction(row.action!, to: row.target, from: row)
        #expect(receiver.count == 1)
        #expect(weakSourceMenu != nil)

        // And the snapshot is still dropped afterwards, so the hosting source
        // does not outlive the popup.
        #expect(pendingDrops.count == 1)
        pendingDrops.removeFirst()()
        #expect(weakSourceMenu == nil)
    }

    private func makeController(
        center: NotificationCenter,
        bar: StatusBar,
        source: @escaping @MainActor () -> MenuSource,
        scheduleDeferred: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
    ) -> MenuBarDisplayController {
        MenuBarDisplayController(
            notificationCenter: center,
            screens: { [] },
            menuFactory: { _ in source().menu },
            makeStatusItem: { bar.makeItem() },
            removeItem: { bar.remove($0) },
            scheduleDeferred: scheduleDeferred
        )
    }

    @MainActor
    final class MenuSource {
        var rows: [String] { didSet { builtMenu = nil } }
        weak var target: AnyObject? { didSet { builtMenu = nil } }
        var action: Selector? { didSet { builtMenu = nil } }
        private var builtMenu: NSMenu?
        init(rows: [String]) { self.rows = rows }
        /// Memoized so the snapshot's source is a single instance a test can
        /// watch with a weak reference; mutations rebuild it.
        var menu: NSMenu {
            if let builtMenu { return builtMenu }
            let menu = NSMenu()
            for row in rows {
                let item = NSMenuItem(title: row, action: action, keyEquivalent: "")
                item.target = target
                menu.addItem(item)
            }
            builtMenu = menu
            return menu
        }
    }

    @MainActor
    final class Receiver: NSObject {
        private(set) var count = 0
        @objc func fire(_ sender: NSMenuItem) { count += 1 }
    }

    @MainActor
    final class StatusBar {
        var items: [Item] = []
        func makeItem() -> Item {
            let item = Item()
            items.append(item)
            return item
        }
        func remove(_ item: any MenuBarStatusItem) { item.isVisible = false }
    }

    final class Item: MenuBarStatusItem {
        var autosaveName: NSStatusItem.AutosaveName!
        var isVisible = true
        var button: NSStatusBarButton? { nil }
        var menu: NSMenu?
    }
}
