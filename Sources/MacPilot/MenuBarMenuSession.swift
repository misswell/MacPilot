import AppKit

/// A popup owns a fixed AppKit tree. SwiftUI may keep updating the source
/// hosting menu, but cannot replace a submenu the user is currently selecting.
@MainActor
final class MenuBarMenuSession {
    let menu: NSMenu
    private let source: NSMenu
    private var actions: [ActionRelay] = []

    /// Builds the snapshot in a new menu, or fills `destination` when the
    /// status item already owns the menu AppKit will display. Filling in place
    /// lets the final rows exist before AppKit sizes and places the popup.
    init(source: NSMenu, installingInto destination: NSMenu? = nil) {
        self.source = source
        var actions: [ActionRelay] = []
        let menu = destination ?? NSMenu(title: source.title)
        Self.fill(menu, from: source, actions: &actions)
        self.menu = menu
        self.actions = actions
    }

    private static func snapshot(_ source: NSMenu, actions: inout [ActionRelay]) -> NSMenu {
        let result = NSMenu(title: source.title)
        fill(result, from: source, actions: &actions)
        return result
    }

    private static func fill(_ menu: NSMenu, from source: NSMenu, actions: inout [ActionRelay]) {
        // Hosting menus and their submenus materialize lazily. Resolve them
        // before copying, without starting native menu tracking or a popup.
        source.delegate?.menuNeedsUpdate?(source)
        source.update()
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.font = source.font
        menu.minimumWidth = source.minimumWidth
        menu.showsStateColumn = source.showsStateColumn
        for original in source.items {
            let item = snapshotItem(original)
            if let submenu = original.submenu {
                item.submenu = snapshot(submenu, actions: &actions)
            }
            if let action = original.action {
                let relay = ActionRelay(item: original, action: action)
                actions.append(relay)
                item.target = relay
                item.action = #selector(ActionRelay.invoke(_:))
            }
            menu.addItem(item)
        }
    }

    private static func snapshotItem(_ original: NSMenuItem) -> NSMenuItem {
        // Hosting menu items may subclass NSMenuItem and share action storage
        // when copied. Build plain items so the visible tree is independent.
        if original.isSeparatorItem { return .separator() }
        let item = original.isSectionHeader
            ? NSMenuItem.sectionHeader(title: original.title)
            : NSMenuItem(title: original.title, action: nil, keyEquivalent: original.keyEquivalent)
        item.attributedTitle = original.attributedTitle
        item.image = original.image
        item.state = original.state
        item.onStateImage = original.onStateImage
        item.offStateImage = original.offStateImage
        item.mixedStateImage = original.mixedStateImage
        item.isEnabled = original.isEnabled
        item.isHidden = original.isHidden
        item.isAlternate = original.isAlternate
        item.keyEquivalentModifierMask = original.keyEquivalentModifierMask
        item.allowsKeyEquivalentWhenHidden = original.allowsKeyEquivalentWhenHidden
        item.indentationLevel = original.indentationLevel
        item.toolTip = original.toolTip
        item.tag = original.tag
        item.representedObject = original.representedObject
        return item
    }

    @MainActor
    private final class ActionRelay: NSObject {
        private let item: NSMenuItem
        private let action: Selector
        private let target: AnyObject?

        init(item: NSMenuItem, action: Selector) {
            self.item = item
            self.action = action
            target = item.target
        }

        @objc func invoke(_ sender: NSMenuItem) {
            // AppKit targets are weak. Retain both the original target and
            // sender even if a source refresh discards that row while tracking.
            NSApplication.shared.sendAction(action, to: target, from: item)
        }
    }
}
