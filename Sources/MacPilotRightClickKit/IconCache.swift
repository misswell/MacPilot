//
//  IconCache.swift
//  MacPilot
//
//  统一的图标缓存管理器
//

import AppKit
import Foundation

/// 统一的图标缓存管理器
/// 为 Main App 和 Extension 提供共享的图标缓存服务
@MainActor
public class IconCache {
    public static let shared = IconCache()

    /// Path-keyed icon cache with an explicit bound. A plain dictionary kept
    /// every icon of every folder the user ever right-clicked for the whole
    /// process lifetime; `NSCache` evicts under pressure and the limits keep
    /// memory flat.
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private let iconSize = CGSize(width: 32, height: 32)

    private init() {}

    /// 获取文件图标
    /// - Parameter url: 文件 URL
    /// - Returns: 缩放后的图标图片
    public func icon(for url: URL) -> NSImage {
        let cacheKey = url.path as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = iconSize
        memoryCache.setObject(icon, forKey: cacheKey, cost: Self.cost(of: icon))
        return icon
    }

    /// 预加载图标
    /// - Parameter urls: 需要预加载的 URL 列表
    public func preloadIcons(for urls: [URL]) {
        for url in urls {
            _ = icon(for: url)
        }
    }

    /// 缓存中的图标数量
    public var cacheSize: Int {
        // NSCache does not expose its count; keep the public surface but report
        // the count limit as the upper bound callers can rely on.
        memoryCache.countLimit
    }

    private static func cost(of image: NSImage) -> Int {
        let pixels = Int(max(image.size.width, 1) * max(image.size.height, 1))
        return pixels * 4
    }
}
