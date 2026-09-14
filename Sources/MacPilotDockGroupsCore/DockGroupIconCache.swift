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

import AppKit
import Foundation

/// 图标缓存键：Bundle ID + 版本 + 尺寸。
public struct DockGroupIconCacheKey: Hashable, Sendable {
    public var bundleIdentifier: String
    public var version: String
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
}

/// 需求第 12 节的磁盘图标缓存。所有写入都被限制在缓存目录内。
/// 只在主线程使用（图标渲染本身就需要 AppKit 主线程）。
@MainActor
public final class DockGroupIconCache {
    private let directory: URL
    private let fileManager: FileManager
    /// 进程内的一级缓存，避免同一帧里反复读盘。
    private var memory: [DockGroupIconCacheKey: NSImage] = [:]

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func image(for key: DockGroupIconCacheKey) -> NSImage? {
        if let cached = memory[key] { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let image = NSImage(data: data)
        else { return nil }
        memory[key] = image
        return image
    }

    /// 写失败一律忽略：缓存只是加速手段，绝不能因为缓存失败导致图标显示不出来。
    public func store(_ image: NSImage, for key: DockGroupIconCacheKey) {
        memory[key] = image
        guard let png = Self.pngData(from: image) else { return }
        // 先过守卫，确保写入目标在缓存目录内（需求第 23 节）。
        guard let target = try? ManagedPathGuard.requireManaged(fileURL(for: key), root: directory) else {
            return
        }
        try? fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? png.write(to: target, options: .atomic)
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

    public func cacheFileURL(for key: DockGroupIconCacheKey) -> URL {
        fileURL(for: key)
    }

    public var cacheDirectory: URL { directory }

    private func fileURL(for key: DockGroupIconCacheKey) -> URL {
        directory.appendingPathComponent(key.fileName)
    }

    /// PNG 编码：只把内存里的位图写成 PNG，不涉及任何目标 App 文件。
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
