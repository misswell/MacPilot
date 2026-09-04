import AppKit

/// 菜单分组渲染规则，独立于扩展实例以便单元测试：
/// 空分组直接跳过；折叠时渲染为带图标的子菜单容器；
/// 展开时渲染为禁用的分组标题 + 平铺菜单项（前置分隔线）。
enum MenuSectionLayout {
    static func append(
        to menu: NSMenu,
        title: String,
        sectionSymbol: String,
        symbolLoader: (String) -> NSImage?,
        collapsed: Bool,
        items: [NSMenuItem]
    ) {
        guard !items.isEmpty else { return }

        if collapsed {
            let submenu = NSMenu(title: title)
            for item in items {
                submenu.addItem(item)
            }
            let container = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            container.submenu = submenu
            container.image = symbolLoader(sectionSymbol)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(container)
        } else {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in items {
                menu.addItem(item)
            }
        }
    }
}
