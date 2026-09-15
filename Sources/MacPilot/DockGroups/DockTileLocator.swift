//
//  DockTileLocator.swift
//  MacPilot
//
//  读出 Dock 上每个分组 Helper 图标的位置（需求：浮层必须贴在**图标**旁边，
//  而不是跟着鼠标落点跑）。
//
//  为什么必须由 MacPilot 来读：
//  Helper 是 MacPilot 生成并 ad-hoc 重签的另一个 App，它自己没有辅助功能授权——
//  真机实测 `AXIsProcessTrusted()` 为 false，读 Dock 的辅助功能树直接返回
//  `-25211`（kAXErrorAPIDisabled）。所以「图标在哪」只能由**已经拿到授权的
//  MacPilot** 读出来，写进 `groups.json`，Helper 只读不算。
//
//  只读不写：这里只调用辅助功能 API 读取 Dock 的公开属性，
//  不注入、不修改任何进程，也不碰第三方 App。
//

import AppKit
import ApplicationServices
import MacPilotDockGroupsCore

@MainActor
enum DockTileLocator {
    /// Dock 进程（`com.apple.dock`）。
    private static let dockBundleIdentifier = "com.apple.dock"
    /// 图标位置的通用容器角色：Dock 的辅助功能树只有两层（容器 → 图标项）。
    private static let maximumDepth = 4

    /// 辅助功能权限是否已经拿到。没有授权时所有读取都会失败（`-25211`）。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 读取这些 Helper App 在 Dock 上的图标位置。
    ///
    /// - Parameter helperAppURLs: 分组各自的 Helper App 路径。
    /// - Returns: 标准化后的 App 路径 → 图标矩形（Cocoa 全局坐标）。
    ///   没有辅助功能授权、Dock 没在跑、或者这个 App 没被固定到 Dock 上，
    ///   都会让对应的键缺失；调用方按「不知道位置」处理即可。
    static func tileRects(forHelperAppsAt helperAppURLs: [URL]) -> [String: CGRect] {
        let wanted = Set(helperAppURLs.map { $0.standardizedFileURL.path })
        guard !wanted.isEmpty else { return [:] }
        // 没有授权就静默退出：绝不在这里触发权限提示
        // （需求：权限申请只保留给用户显式点击的「授权」按钮）。
        guard AXIsProcessTrusted() else { return [:] }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: dockBundleIdentifier)
            .first
        else { return [:] }
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY, primaryHeight > 0 else { return [:] }
        let screens = NSScreen.screens.map(\.frame)

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        var tiles: [(path: String, rect: CGRect)] = []
        collectTiles(
            in: application,
            depth: 0,
            wanted: wanted,
            primaryHeight: primaryHeight,
            screens: screens,
            into: &tiles
        )
        return Self.matchingRects(tiles: tiles, wanted: wanted)
    }

    /// 这个矩形是否落在某块屏幕上。
    ///
    /// Dock 自动隐藏时（或显示器刚重新配置过、Dock 还没回到屏幕上时）整条 Dock
    /// 的 AX 坐标会跑到屏幕外面（实测容器 x = -52）。那种几何对 Helper 毫无用处，
    /// 存进去只会让浮层算错位置，所以宁可不存 —— Helper 会退回按点击位置落点。
    static func intersectsAnyScreen(_ rect: CGRect, screens: [CGRect]) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return screens.contains { $0.intersects(rect) }
    }

    // MARK: - 纯函数（可单测）

    /// 把 `(路径, 矩形)` 列表收敛成「路径 → 矩形」，同一个 App 只保留第一个图标。
    static func matchingRects(
        tiles: [(path: String, rect: CGRect)],
        wanted: Set<String>
    ) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for tile in tiles where wanted.contains(tile.path) {
            guard result[tile.path] == nil else { continue }
            result[tile.path] = tile.rect
        }
        return result
    }

    /// 辅助功能 API 给的是「主屏左上角为原点」的全局坐标，浮层用的是 Cocoa 坐标
    /// （主屏左下角为原点、y 向上）。同一个全局坐标系里只有 y 方向需要翻。
    static func cocoaRect(fromTopLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - 读取辅助功能树

    private static func collectTiles(
        in element: AXUIElement,
        depth: Int,
        wanted: Set<String>,
        primaryHeight: CGFloat,
        screens: [CGRect],
        into tiles: inout [(path: String, rect: CGRect)]
    ) {
        guard depth <= maximumDepth else { return }
        for child in children(of: element) {
            if let url = url(of: child) {
                let path = url.standardizedFileURL.path
                if wanted.contains(path), let rect = frame(of: child) {
                    let cocoa = cocoaRect(fromTopLeft: rect, primaryHeight: primaryHeight)
                    if intersectsAnyScreen(cocoa, screens: screens) {
                        tiles.append((path, cocoa))
                    }
                }
                // 图标项不再往下找，Dock 的树到这里就到底了。
                continue
            }
            collectTiles(
                in: child,
                depth: depth + 1,
                wanted: wanted,
                primaryHeight: primaryHeight,
                screens: screens,
                into: &tiles
            )
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func url(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else {
            return nil
        }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = point(of: element, attribute: kAXPositionAttribute as String),
              let size = size(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func point(of element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
