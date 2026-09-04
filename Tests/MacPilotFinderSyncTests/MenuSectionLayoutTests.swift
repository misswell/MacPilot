import AppKit
import Foundation
import Testing
@testable import MacPilotFinderSync
@testable import MacPilotRightClickKit

struct MenuSectionLayoutTests {
    private func makeItems(_ titles: [String]) -> [NSMenuItem] {
        titles.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
    }

    @Test func emptySectionsAreSkipped() {
        let menu = NSMenu(title: "MacPilot")

        MenuSectionLayout.append(
            to: menu,
            title: "Actions",
            sectionSymbol: "bolt.square",
            symbolLoader: { _ in nil },
            collapsed: false,
            items: []
        )

        #expect(menu.items.isEmpty)
    }

    @Test func expandedSectionRendersSeparatorHeaderAndItems() {
        let menu = NSMenu(title: "MacPilot")
        let items = makeItems(["A", "B"])

        MenuSectionLayout.append(
            to: menu,
            title: "Actions",
            sectionSymbol: "bolt.square",
            symbolLoader: { _ in nil },
            collapsed: false,
            items: items
        )

        #expect(menu.items.count == 4)
        #expect(menu.items[0].isSeparatorItem)
        #expect(menu.items[1].title == "Actions")
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[2].title == "A")
        #expect(menu.items[3].title == "B")
    }

    @Test func collapsedSectionRendersSubmenuContainer() {
        let menu = NSMenu(title: "MacPilot")
        let items = makeItems(["A", "B"])

        MenuSectionLayout.append(
            to: menu,
            title: "Actions",
            sectionSymbol: "bolt.square",
            symbolLoader: { _ in NSImage() },
            collapsed: true,
            items: items
        )

        #expect(menu.items.count == 2)
        #expect(menu.items[0].isSeparatorItem)
        let container = menu.items[1]
        #expect(container.title == "Actions")
        #expect(container.submenu?.items.map(\.title) == ["A", "B"])
    }
}

/// 菜单点击解析契约：构建阶段的 tag 与点击阶段的 tag 必须来自同一映射。
struct MenuTagResolutionTests {
    private func makeConfig() -> MenuConfigPayload {
        MenuConfigPayload(
            version: 1,
            actions: [
                ActionMenuItem(id: "copy-path", name: "Copy Path", icon: "doc.on.doc", tag: 0),
                ActionMenuItem(id: "open-terminal", name: "Open Terminal", icon: "terminal", tag: 1),
            ],
            apps: [
                AppMenuItem(id: "com.apple.Terminal", name: "Terminal", icon: "app", tag: 0),
            ],
            newFiles: [
                NewFileMenuItem(id: "txt", name: "TXT", ext: ".txt", icon: "doc.text"),
            ],
            commonDirs: [
                CommonDirMenuItem(id: "desktop", name: "Desktop", icon: "desktopcomputer", url: nil),
            ]
        )
    }

    @Test func clickedTagsResolveBackToTheConfiguredItems() {
        let config = makeConfig()

        #expect(config.actions.first(where: { MenuTag.forAction($0.id) == MenuTag.forAction("copy-path") })?.id == "copy-path")
        #expect(config.actions.first(where: { MenuTag.forAction($0.id) == MenuTag.forAction("open-terminal") })?.id == "open-terminal")
        #expect(config.apps.first(where: { MenuTag.forApp($0.id) == MenuTag.forApp("com.apple.Terminal") })?.id == "com.apple.Terminal")
        #expect(config.newFiles.first(where: { MenuTag.forNewFile($0.id) == MenuTag.forNewFile("txt") })?.id == "txt")
        #expect(config.commonDirs.first(where: { MenuTag.forCommonDir($0.id) == MenuTag.forCommonDir("desktop") })?.id == "desktop")
    }

    @Test func unknownTagsResolveToNothing() {
        let config = makeConfig()

        #expect(config.actions.first(where: { MenuTag.forAction($0.id) == MenuTag.forAction("missing") }) == nil)
        #expect(config.apps.first(where: { MenuTag.forApp($0.id) == MenuTag.forApp("com.missing.App") }) == nil)
    }
}
