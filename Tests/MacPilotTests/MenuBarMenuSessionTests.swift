import AppKit
import Combine
import SwiftUI
import Testing
@testable import MacPilot

@MainActor
struct MenuBarMenuSessionTests {
    @Test func sessionKeepsSubmenuIdentityAndRowsWhenSourceMenuRefreshes() throws {
        let sourceMenu = makeMenu(
            screenTitle: "Current Screen",
            memoryTitle: "Memory",
            cpuTitle: "CPU",
            screenRows: ["Built-in Display"],
            memoryRows: ["Used: 8 GB"],
            cpuRows: ["Load: 12%"]
        )
        let menuSource = MenuSourceState(sourceMenu)
        let controller = MenuBarDisplayController(
            notificationCenter: NotificationCenter(),
            screens: { [] },
            pointer: { .zero },
            menuFactory: { _ in menuSource.menu }
        )
        defer { controller.stop() }

        let session = try #require(controller.prepareMenuSession())
        let originalSubmenus = try session.menu.items.map { try #require($0.submenu) }
        let originalSubmenuIDs = originalSubmenus.map(ObjectIdentifier.init)
        let originalRows = originalSubmenus.map { $0.items.map(\.title) }

        // Model a SwiftUI refresh while this session's popup is still alive:
        // replace one atomic submenu, remove another item, and update a title.
        sourceMenu.items[0].title = "Current Screen (refreshed)"
        sourceMenu.items[0].submenu = makeSubmenu("Screen", rows: ["Replacement Display"])
        sourceMenu.removeItem(at: 1)
        sourceMenu.items[1].title = "CPU (refreshed)"
        sourceMenu.items[1].submenu?.removeAllItems()
        sourceMenu.items[1].submenu?.addItem(withTitle: "Load: 99%", action: nil, keyEquivalent: "")

        #expect(session.menu.items.map(\.title) == ["Current Screen", "Memory", "CPU"])
        let sessionSubmenus = try session.menu.items.map { try #require($0.submenu) }
        #expect(sessionSubmenus.map(ObjectIdentifier.init) == originalSubmenuIDs)
        #expect(sessionSubmenus.map { $0.items.map(\.title) } == originalRows)

        let nextSession = try #require(controller.prepareMenuSession())
        #expect(nextSession.menu.items.map(\.title) == ["Current Screen (refreshed)", "CPU (refreshed)"])
        #expect(nextSession.menu.items.compactMap(\.submenu).map { $0.items.map(\.title) } == [
            ["Replacement Display"], ["Load: 99%"]
        ])
    }

    @Test func snapshotPreservesDisabledStateKeyEquivalentAndSectionHeader() throws {
        let sourceMenu = NSMenu()
        sourceMenu.addItem(.sectionHeader(title: "Hardware"))
        let disabledItem = NSMenuItem(title: "Unavailable", action: nil, keyEquivalent: "d")
        disabledItem.isEnabled = false
        disabledItem.state = .on
        disabledItem.keyEquivalentModifierMask = [.command, .option]
        disabledItem.allowsKeyEquivalentWhenHidden = true
        sourceMenu.addItem(disabledItem)

        let menuSource = MenuSourceState(sourceMenu)
        let controller = MenuBarDisplayController(
            notificationCenter: NotificationCenter(),
            screens: { [] },
            pointer: { .zero },
            menuFactory: { _ in menuSource.menu }
        )
        defer { controller.stop() }

        let session = try #require(controller.prepareMenuSession())
        #expect(session.menu.items.count == 2)
        let header = try #require(session.menu.items.first)
        #expect(header.isSectionHeader)
        #expect(header.title == "Hardware")

        let snapshotDisabledItem = try #require(session.menu.items.dropFirst().first)
        #expect(!snapshotDisabledItem.isEnabled)
        #expect(snapshotDisabledItem.state == .on)
        #expect(snapshotDisabledItem.keyEquivalent == "d")
        #expect(snapshotDisabledItem.keyEquivalentModifierMask == [.command, .option])
        #expect(snapshotDisabledItem.allowsKeyEquivalentWhenHidden)
    }

    @Test func hostingMenuExposesSwiftUIItemsAndForwardsActionWithoutOpeningPopup() throws {
        guard #available(macOS 14.4, *) else { return }
        let state = HostingMenuProbeState()
        let menu = NSHostingMenu(rootView: MenuBarHostingMenuProbe {
            state.didInvokeAction = true
        })

        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()

        let actionItem = try #require(findItem(titled: "Action", in: menu))
        #expect(actionItem.isEnabled)
        let action = try #require(actionItem.action)
        let app = NSApplication.shared
        let handled = app.sendAction(action, to: actionItem.target, from: actionItem)
        #expect(handled)
        #expect(state.didInvokeAction)
    }

    @Test func snapshotHostingButtonStillInvokesItsClosureAfterPublishedRefresh() async throws {
        guard #available(macOS 14.4, *) else { return }
        _ = NSApplication.shared
        let state = LiveHostingMenuState()
        let sourceMenu = NSHostingMenu(rootView: LiveMenuProbe(state: state))
        update(sourceMenu)
        let sourceActionItem = try #require(findItem(titled: "Action", in: sourceMenu))
        let originalSourceAction = try #require(sourceActionItem.action)
        var originalSourceTarget = sourceActionItem.target
        let menuSource = MenuSourceState(sourceMenu)
        let controller = MenuBarDisplayController(
            notificationCenter: NotificationCenter(),
            screens: { [] },
            pointer: { .zero },
            menuFactory: { _ in menuSource.menu }
        )
        defer { controller.stop() }

        let session = try #require(controller.prepareMenuSession())
        #expect(sourceActionItem.action == originalSourceAction)
        #expect(sourceActionItem.target === originalSourceTarget)
        let snapshotAction = try #require(findItem(titled: "Action", in: session.menu))
        #expect(ObjectIdentifier(type(of: snapshotAction)) == ObjectIdentifier(NSMenuItem.self))
        originalSourceTarget = nil

        state.titles = ["Updated"]
        for _ in 0..<4 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        update(sourceMenu)

        let refreshedItem = findItem(titled: "Updated", in: sourceMenu)
        #expect(refreshedItem != nil)
        guard refreshedItem != nil else { return }
        #expect(findItem(titled: "Action", in: session.menu) != nil)
        #expect(findItem(titled: "Updated", in: session.menu) == nil)
        let action = try #require(snapshotAction.action)
        let targetResponds = (snapshotAction.target as? NSObject)?.responds(to: action) == true
        #expect(targetResponds)
        if targetResponds {
            let handled = NSApplication.shared.sendAction(action, to: snapshotAction.target, from: snapshotAction)
            #expect(handled)
            #expect(state.actionCount == 1)
        }
    }

    @Test func hostingMenuInstallsIntoTheMenuAppKitAlreadyOwns() throws {
        guard #available(macOS 14.4, *) else { return }
        let state = HostingMenuProbeState()
        let source = NSHostingMenu(rootView: MenuBarHostingMenuProbe {
            state.didInvokeAction = true
        })
        // The production path: the status item's own menu is the destination,
        // so AppKit sized and placed a popup that already has its final rows.
        let attached = NSMenu()
        attached.autoenablesItems = false
        attached.addItem(withTitle: "stale", action: nil, keyEquivalent: "")

        let session = MenuBarMenuSession(source: source, installingInto: attached)

        #expect(session.menu === attached)
        #expect(attached.items.map(\.title) == ["Parent"])
        let actionItem = try #require(findItem(titled: "Action", in: attached))
        let action = try #require(actionItem.action)
        #expect(NSApplication.shared.sendAction(action, to: actionItem.target, from: actionItem))
        #expect(state.didInvokeAction)
    }

    private func makeMenu(
        screenTitle: String,
        memoryTitle: String,
        cpuTitle: String,
        screenRows: [String],
        memoryRows: [String],
        cpuRows: [String]
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(title: screenTitle, submenu: makeSubmenu("Screen", rows: screenRows)))
        menu.addItem(menuItem(title: memoryTitle, submenu: makeSubmenu("Memory", rows: memoryRows)))
        menu.addItem(menuItem(title: cpuTitle, submenu: makeSubmenu("CPU", rows: cpuRows)))
        return menu
    }

    private func menuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func makeSubmenu(_ title: String, rows: [String]) -> NSMenu {
        let menu = NSMenu(title: title)
        for row in rows {
            menu.addItem(withTitle: row, action: nil, keyEquivalent: "")
        }
        return menu
    }

    private func findItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let nested = findItem(titled: title, in: submenu) {
                return nested
            }
        }
        return nil
    }

    private func update(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        let submenus = menu.items.compactMap(\.submenu)
        for submenu in submenus { update(submenu) }
    }
}

@MainActor
private final class MenuSourceState {
    var menu: NSMenu

    init(_ menu: NSMenu) { self.menu = menu }
}

@MainActor
private final class HostingMenuProbeState {
    var didInvokeAction = false
}

private struct MenuBarHostingMenuProbe: View {
    let action: () -> Void

    var body: some View {
        Menu("Parent") {
            Button("Action", action: action)
        }
    }
}

@MainActor
private final class LiveHostingMenuState: ObservableObject {
    @Published var titles = ["Action"]
    private(set) var actionCount = 0

    func recordAction() { actionCount += 1 }
}

private struct LiveMenuProbe: View {
    @ObservedObject var state: LiveHostingMenuState

    var body: some View {
        Menu("Parent") {
            ForEach(state.titles, id: \.self) { title in
                Button(title) { state.recordAction() }
            }
        }
    }
}

@MainActor
struct MenuBarIconLabelTests {
    /// The status-item label is only the icon. Building the full command tree
    /// in the label is what re-rendered the whole menu on every model tick and
    /// delayed the menu popup; the label view must stay at the icon.
    @Test func iconLabelViewDoesNotBuildTheCommandTree() {
        _ = NSApplication.shared
        let model = MacPilotModel()
        let controller = MenuBarDisplayController(
            notificationCenter: NotificationCenter(),
            screens: { [] },
            pointer: { .zero },
            menuFactory: { _ in NSMenu() }
        )
        defer { controller.stop() }
        let label = MenuBarView.iconLabel(model: model, context: controller).environmentObject(model)
        let host = NSHostingView(rootView: AnyView(label))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 22)
        host.layoutSubtreeIfNeeded()
        // An icon-only label has no descendant NSMenu-bearing buttons.
        let buttons = collectButtons(host)
        #expect(buttons.isEmpty)
    }

    /// The full menu view carries the command content; the icon label carries
    /// none. Assert on the view flag rather than AppKit buttons: SwiftUI defers
    /// button materialization, but the flag decides whether the menu body is
    /// in the view tree at all.
    @Test func fullMenuViewCarriesCommandContentAndIconLabelDoesNot() {
        _ = NSApplication.shared
        let model = MacPilotModel()
        let controller = MenuBarDisplayController(
            notificationCenter: NotificationCenter(),
            screens: { [] },
            pointer: { .zero },
            menuFactory: { _ in NSMenu() }
        )
        defer { controller.stop() }
        #expect(MenuBarView.mainMenu(model: model, context: controller).showsMenuContent)
        #expect(!MenuBarView.iconLabel(model: model, context: controller).showsMenuContent)
    }

    private func collectButtons(_ view: NSView) -> [NSView] {
        var found: [NSView] = []
        if view is NSButton { found.append(view) }
        for sub in view.subviews { found += collectButtons(sub) }
        return found
    }
}
