//
//  DockGroupIconCache.swift
//  MacPilotDockGroupsCore
//
//  需求第 12 节：
//  - 图标只从系统读取（`NSWorkspace.icon(forFile:)`），不缓存完整 App，
//    不修改目标 App 的图标，更不往目标 App 的 Resources 里写文件；
//  - MacPilot 只缓存自己的 PNG 缩略图，位置在
//    `~/Library/Caches/MacPilot/DockGroups/`；
//  - 缓存随时可以整个删掉，删掉只影响首屏速度，不影响任何目标应用。
//
//  缓存键带上 App 版本，因此第三方 App 升级换图标后会自动重新取图，
//  不会一直显示旧图标。
//
//  落盘的一定是**按目标尺寸重绘过的缩略图**（见 DockGroupIconThumbnail）：
//  32pt 的图标存 64px，单个文件几 KB。早期版本把 1024×1024 原图直接存了进来
//  （单个 1–3 MB、271 个 App 共 308 MB），这里会在读取时把尺寸超标的旧文件
//  判为失效并删除，`removeOversizedThumbnails()` 负责主动清一次。
//

import AppKit
import Foundation

/// 图标缓存键：Bundle ID + 版本 + 尺寸。
public struct DockGroupIconCacheKey: Hashable, Sendable {
    public var bundleIdentifier: String
    public var version: String
    /// 显示尺寸（点）。
    public var size: Int

    public init(bundleIdentifier: String, version: String, size: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.size = size
    }

    /// 文件名：`<bundle id>@<version>@<size>.png`，经过净化后不会带路径分隔符。
    public var fileName: String {
        let identifier = DockGroupPaths.sanitizedFileName(bundleIdentifier)
        let version = DockGroupPaths.sanitizedFileName(version)
        return "\(identifier)@\(version)@\(size).png"
    }

    /// 该尺寸允许的最大像素边长（32pt → 64px，默认 2× 屏）。
    public var pixelSize: Int {
        DockGroupIconThumbnail.pixelSize(forPoints: CGFloat(size))
    }

    /// 与缓存自身的缩放倍率保持一致。
    func pixelSize(forScale scale: CGFloat) -> Int {
        DockGroupIconThumbnail.pixelSize(forPoints: CGFloat(size), scale: scale)
    }
}

/// 需求第 12 节的磁盘图标缓存。所有写入都被限制在缓存目录内。
/// 只在主线程使用（图标渲染本身就需要 AppKit 主线程）。
@MainActor
public final class DockGroupIconCache {
    private let directory: URL
    private let fileManager: FileManager
    private let scale: CGFloat
    /// 进程内的一级缓存，避免同一帧里反复读盘；只放受限的小图。
    private var memory: [DockGroupIconCacheKey: NSImage] = [:]

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        scale: CGFloat = CGFloat(DockGroupIconThumbnail.pixelScale)
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.scale = max(1, scale)
    }

    public func image(for key: DockGroupIconCacheKey) -> NSImage? {
        if let cached = memory[key] { return cached }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }

        // 旧版本把 1024×1024 原图当缩略图存了下来：尺寸超标一律判为失效并删除，
        // 让调用方重新生成一张受限的小图，而不是把大图继续读进内存。
        guard let pixels = DockGroupIconThumbnail.pngPixelSize(in: data),
              pixels.width <= key.pixelSize(forScale: scale),
              pixels.height <= key.pixelSize(forScale: scale),
              let image = NSImage(data: data)
        else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        image.size = NSSize(width: key.size, height: key.size)
        memory[key] = image
        return image
    }

    /// 写失败一律忽略：缓存只是加速手段，绝不能因为缓存失败导致图标显示不出来。
    ///
    /// 传入的图可以是系统图标原图；这里会先按 key 的尺寸重绘成小图，
    /// 只把小图放进内存缓存、只把小图编码落盘。
    @discardableResult
    public func store(_ image: NSImage, for key: DockGroupIconCacheKey) -> NSImage? {
        guard let thumbnail = DockGroupIconThumbnail.image(
            from: image,
            pointSize: CGFloat(key.size),
            pixelSize: key.pixelSize(forScale: scale)
        ) else { return nil }
        memory[key] = thumbnail
        guard let png = DockGroupIconThumbnail.pngData(from: thumbnail) else { return thumbnail }
        write(png, for: key)
        return thumbnail
    }

    /// 后台线程已经渲染好的缩略图 PNG：只做尺寸校验 + 落盘，不再重新编码。
    @discardableResult
    public func storeThumbnailPNG(_ data: Data, for key: DockGroupIconCacheKey) -> NSImage? {
        let allowed = key.pixelSize(forScale: scale)
        guard let pixels = DockGroupIconThumbnail.pngPixelSize(in: data),
              pixels.width <= allowed,
              pixels.height <= allowed,
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: key.size, height: key.size)
        memory[key] = image
        write(data, for: key)
        return image
    }

    /// 需求第 26 节：卸载时清理 MacPilot 自己的缓存；第三方 App 不受影响。
    /// 校验同样先于「目录是否存在」，避免根目录配错时报出假成功。
    @discardableResult
    public func removeAll() -> Bool {
        memory.removeAll()
        guard let target = try? ManagedPathGuard.requireManaged(directory, root: directory) else {
            return false
        }
        guard fileManager.fileExists(atPath: target.path) else { return true }
        do {
            try fileManager.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// 清掉历史版本留下的超大「缩略图」（按文件名里的点尺寸判断像素上限）。
    /// - Returns: 删除的文件数。
    @discardableResult
    public func removeOversizedThumbnails() -> Int {
        guard let target = try? ManagedPathGuard.requireManaged(directory, root: directory),
              fileManager.fileExists(atPath: target.path),
              let entries = try? fileManager.contentsOfDirectory(
                  at: target,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return 0 }

        var removed = 0
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            guard let expected = Self.expectedPixelSize(ofFileName: entry.lastPathComponent, scale: scale),
                  let pixels = DockGroupIconThumbnail.pngPixelSize(at: entry),
                  pixels.width > expected || pixels.height > expected,
                  (try? ManagedPathGuard.requireManaged(entry, root: directory)) != nil
            else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        if removed > 0 { memory.removeAll() }
        return removed
    }

    public func cacheFileURL(for key: DockGroupIconCacheKey) -> URL {
        fileURL(for: key)
    }

    public var cacheDirectory: URL { directory }

    private func fileURL(for key: DockGroupIconCacheKey) -> URL {
        directory.appendingPathComponent(key.fileName)
    }

    /// 写入前先过守卫，确保写入目标在缓存目录内（需求第 23 节）。
    private func write(_ png: Data, for key: DockGroupIconCacheKey) {
        guard let target = try? ManagedPathGuard.requireManaged(fileURL(for: key), root: directory) else {
            return
        }
        try? fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? png.write(to: target, options: .atomic)
    }

    /// 从 `...@32.png` 这样的文件名反推允许的像素边长。
    static func expectedPixelSize(ofFileName name: String, scale: CGFloat) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        guard let last = stem.split(separator: "@").last, let points = Int(last) else { return nil }
        return DockGroupIconThumbnail.pixelSize(forPoints: CGFloat(points), scale: scale)
    }
}
