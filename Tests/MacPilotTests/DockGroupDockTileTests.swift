//
//  DockGroupDockTileTests.swift
//  MacPilotTests
//
//  锁住两件事：
//  1. 「图标外观」这个新偏好怎么解析成实际绘制外观（`.icns` 没有外观变体，
//     Dock 图标靠重建 Helper 跟随系统）；
//  2. MacPilot 从 Dock 辅助功能树读到的图标几何是怎么被采信/丢弃的。
//

import AppKit
import CoreGraphics
import MacPilotDockGroupsCore
import Testing
@testable import MacPilot

@MainActor
struct DockGroupIconStyleTests {
    /// 跟随系统：深色模式用深色版本，浅色模式用浅色版本。
    @Test func systemStyleFollowsTheAppearance() {
        #expect(DockGroupIconStyle.system.appearance(isDark: false) == .light)
        #expect(DockGroupIconStyle.system.appearance(isDark: true) == .dark)
    }

    /// 固定浅色 / 固定深色：不管系统是什么外观都不变。
    @Test func fixedStylesIgnoreTheAppearance() {
        #expect(DockGroupIconStyle.light.appearance(isDark: false) == .light)
        #expect(DockGroupIconStyle.light.appearance(isDark: true) == .light)
        #expect(DockGroupIconStyle.dark.appearance(isDark: false) == .dark)
        #expect(DockGroupIconStyle.dark.appearance(isDark: true) == .dark)
    }

    /// 旧配置里没有这个键：默认跟随系统，且不影响其它字段。
    @Test func legacyConfigurationWithoutTheKeyDefaultsToFollowingTheSystem() throws {
        let json = """
        {
          "groups": [
            {
              "id": "dev",
              "name": "Dev",
              "icon": { "source": "composite", "value": "" },
              "layout": "grid",
              "apps": [],
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DockGroupsDocument.self, from: Data(json.utf8))
        let group = try #require(document.groups.first)
        #expect(group.iconStyle == .system)
        #expect(group.dockTile == nil)
    }

    /// 新字段能原样存回 `groups.json`（Helper 与 MacPilot 共用这份配置）。
    @Test func iconStyleAndDockTileSurviveARoundTrip() throws {
        let tile = DockGroupDockTile(
            rect: CGRect(x: 5, y: 197.44, width: 49.33, height: 37.33),
            updatedAt: DockGroupTimestamp.now()
        )
        let document = DockGroupsDocument(groups: [
            DockGroup(id: "dev", name: "Dev", iconStyle: .dark, dockTile: tile)
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DockGroupsDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.groups.first?.iconStyle == .dark)
        #expect(decoded.groups.first?.dockTile?.rect == CGRect(x: 5, y: 197.44, width: 49.33, height: 37.33))
    }
}

@MainActor
struct DockTileAnchorTests {
    /// 点击点落在图标里 ⇒ 用图标中心；落到外面 ⇒ 判断为「这份几何过期了」。
    @Test func containsUsesAToleranceForSmallDrift() {
        let tile = DockGroupDockTile(x: 5, y: 197.44, width: 49.33, height: 37.33)
        #expect(tile.contains(pointer: CGPoint(x: 29, y: 216)))
        #expect(tile.contains(pointer: CGPoint(x: 29, y: 197.44 + 37.33 + 6)))
        #expect(!tile.contains(pointer: CGPoint(x: 29, y: 197.44 - 60)))
    }

    /// 位置没变（只差亚像素）就不该写盘。
    @Test func isCloseIgnoresSubPixelDrift() {
        let first = DockGroupDockTile(x: 5, y: 197.44, width: 49.33, height: 37.33)
        let same = DockGroupDockTile(x: 5.2, y: 197.6, width: 49.5, height: 37.2)
        let moved = DockGroupDockTile(x: 5, y: 234.77, width: 49.33, height: 37.33)
        #expect(first.isClose(to: same))
        #expect(!first.isClose(to: moved))
    }
}

@MainActor
struct DockTileLocatorTests {
    /// 辅助功能坐标（主屏左上角为原点）→ Cocoa 全局坐标（主屏左下角为原点）。
    @Test func topLeftRectIsFlippedIntoCocoaCoordinates() {
        let cocoa = DockTileLocator.cocoaRect(
            fromTopLeft: CGRect(x: 5, y: 845.23, width: 49.33, height: 37.33),
            primaryHeight: 1080
        )
        #expect(cocoa == CGRect(x: 5, y: 1080 - (845.23 + 37.33), width: 49.33, height: 37.33))
        // 翻转后上边缘与原矩形的上边缘对称：都在距顶部 845.23 的地方。
        #expect(1080 - cocoa.maxY == 845.23)
    }

    /// 只保留我们关心的 Helper，且同一个 App 只取第一个图标。
    @Test func matchingRectsKeepsOnlyOurHelpers() {
        let dev = "/Users/me/Library/Application Support/MacPilot/DockGroups/Dev.app"
        let other = "/Applications/Zed.app"
        let rects = DockTileLocator.matchingRects(
            tiles: [
                (path: other, rect: CGRect(x: 0, y: 0, width: 40, height: 40)),
                (path: dev, rect: CGRect(x: 5, y: 100, width: 49, height: 37)),
                (path: dev, rect: CGRect(x: 999, y: 999, width: 49, height: 37))
            ],
            wanted: [dev]
        )
        #expect(rects.count == 1)
        #expect(rects[dev] == CGRect(x: 5, y: 100, width: 49, height: 37))
    }

    /// 没有任何 Helper 时不必去读 Dock 的辅助功能树。
    @Test func noHelpersMeansNoLookup() {
        #expect(DockTileLocator.tileRects(forHelperAppsAt: []).isEmpty)
    }
}

@MainActor
struct DockTileUsabilityTests {
    /// Dock 自动隐藏、或显示器刚重新配置过时，整条 Dock 的 AX 坐标会跑到屏幕外
    /// （实测容器 x = -52）。这种几何必须丢掉，否则浮层会按一个错误的位置落点。
    @Test func offScreenDockGeometryIsRejected() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let hiddenDockTile = CGRect(x: -57.15, y: 166.16, width: 52.15, height: 40.15)
        #expect(!DockTileLocator.intersectsAnyScreen(hiddenDockTile, screens: [screen]))

        let restingTile = CGRect(x: 5, y: 166.16, width: 50.69, height: 38.69)
        #expect(DockTileLocator.intersectsAnyScreen(restingTile, screens: [screen]))

        // 部分压在屏幕边缘上仍然可用（Dock 放大时会越出一点点）。
        #expect(DockTileLocator.intersectsAnyScreen(CGRect(x: -2, y: 100, width: 50, height: 38), screens: [screen]))
        // 完全在屏幕下方（接了外接屏、Dock 还在原来那块上）。
        #expect(!DockTileLocator.intersectsAnyScreen(CGRect(x: 2100, y: 100, width: 50, height: 38), screens: [screen]))
        // 空矩形不算。
        #expect(!DockTileLocator.intersectsAnyScreen(.zero, screens: [screen]))
    }
}
