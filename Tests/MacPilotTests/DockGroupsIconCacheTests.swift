import AppKit
import Foundation
import MacPilotDockGroupsCore
import Testing
@testable import MacPilot

/// Dock 分组图标路径的回归测试。
///
/// 背景（2026-09-14 卡死）：应用选择器会一次列出两百多个 App，早期实现
/// 在视图 body 里同步调用 `NSWorkspace.icon(forFile:)`，并把 1024×1024 的
/// 原图当作「缩略图」编码落盘。271 个 App 把主线程按住约 111 秒，
/// 进程 footprint 涨到 3.1 GB，缓存目录里躺着 308 MB 的大图。
///
/// 这里锁住三条不变量：
/// 1. 落盘/内存缓存里的缩略图必须按请求尺寸受限；
/// 2. 历史遗留的超大缓存文件会被判为失效并清掉；
/// 3. 视图侧取图标绝不同步做重活——先拿占位（nil），后台加载完成后再补齐。
struct DockGroupsIconCacheTests {

    // MARK: - 夹具

    private func makeCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotIconCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 一张 1024×1024 的「系统图标原图」。
    private func makeLargeSourceImage(side: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        return image
    }

    private func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
        let data = try #require(
            DockGroupIconThumbnail.pngData(from: image, pointSize: CGFloat(pixelSize), pixelSize: pixelSize)
        )
        try data.write(to: url)
    }

    // MARK: - 需求第 12 节：缩略图必须受限

    /// 32pt 的键存 1024×1024 的原图，落盘的也必须是 64px 的小图。
    @MainActor
    @Test func cachedThumbnailIsBoundedToTheRequestedPixelSize() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = DockGroupIconCache(directory: directory)
        let key = DockGroupIconCacheKey(bundleIdentifier: "com.example.big", version: "1.0", size: 32)
        let stored = try #require(cache.store(makeLargeSourceImage(), for: key))

        let url = cache.cacheFileURL(for: key)
        let pixels = try #require(DockGroupIconThumbnail.pngPixelSize(at: url))
        #expect(pixels.width <= key.pixelSize)
        #expect(pixels.height <= key.pixelSize)
        #expect(key.pixelSize == 64)

        // 单文件从 1–3 MB 降到几 KB：这里给一个远低于旧行为的宽松上限。
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? .max) < 200_000)

        // 内存缓存里也必须是这张小图，而不是原图。
        let rep = try #require(stored.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(rep.pixelsWide <= key.pixelSize)

        let reloaded = try #require(cache.image(for: key))
        let reloadedRep = try #require(reloaded.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(reloadedRep.pixelsWide <= key.pixelSize)
    }

    /// 旧版本留下的 1024×1024 缓存文件不能再被读进内存，且会被就地删除。
    @MainActor
    @Test func oversizedLegacyCacheFileIsTreatedAsAMissAndDeleted() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = DockGroupIconCache(directory: directory)
        let key = DockGroupIconCacheKey(bundleIdentifier: "com.example.legacy", version: "1.0", size: 32)
        let url = cache.cacheFileURL(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(makeLargeSourceImage(), to: url, pixelSize: 1024)

        #expect(cache.image(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// 主动清理只删超标的旧文件，正常的小缩略图与其他文件必须原样保留。
    @MainActor
    @Test func removeOversizedThumbnailsDeletesOnlyTheBigOnes() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = DockGroupIconCache(directory: directory)
        let legacyURL = cache.cacheFileURL(
            for: DockGroupIconCacheKey(bundleIdentifier: "com.example.legacy", version: "1.0", size: 32)
        )
        let currentURL = cache.cacheFileURL(
            for: DockGroupIconCacheKey(bundleIdentifier: "com.example.current", version: "1.0", size: 32)
        )
        let foreignURL = directory.appendingPathComponent("notes.txt")

        try writePNG(makeLargeSourceImage(), to: legacyURL, pixelSize: 1024)
        try writePNG(makeLargeSourceImage(), to: currentURL, pixelSize: 64)
        try Data("keep me".utf8).write(to: foreignURL)

        #expect(cache.removeOversizedThumbnails() == 1)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: currentURL.path))
        #expect(FileManager.default.fileExists(atPath: foreignURL.path))
    }

    /// 系统图标经过 `InstalledAppResolver.icon` 后必须已经是一张受限的小图。
    @Test func installedAppIconIsBoundedToTheRequestedPixelSize() throws {
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: app.path))

        let icon = try #require(InstalledAppResolver.icon(for: app, size: 32))
        let rep = try #require(icon.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(rep.pixelsWide <= 64)
        #expect(rep.pixelsHigh <= 64)
        #expect(icon.size.width <= 32.5)
    }

    // MARK: - 需求第 11、12 节：视图侧不得同步取图

    /// 首次取图必须立刻返回 nil（视图显示占位），真正的取图在后台完成；
    /// 旧实现会在这里同步返回一张图——正是那一版把主线程按住了 111 秒。
    @MainActor
    @Test func iconLookupsReturnAPlaceholderBeforeLoadingInTheBackground() async throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let model = DockGroupsModel(
            store: DockGroupStore(rootDirectory: workspace.root),
            helperManager: workspace.makeHelperManager(),
            iconCacheDirectory: cacheDirectory
        )
        let app = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let reference = try #require(InstalledAppResolver.makeReference(from: app))

        #expect(model.icon(for: reference, size: 32) == nil)

        // 后台加载完成后（`iconRevision` 是给 SwiftUI 的刷新信号）图标才可用。
        for _ in 0 ..< 100 where model.iconRevision == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.iconRevision > 0)

        let icon = try #require(model.icon(for: reference, size: 32))
        let rep = try #require(icon.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(rep.pixelsWide <= 64)
        // 落盘的是小图，不是 1024×1024 原图。
        let key = DockGroupIconCacheKey(
            bundleIdentifier: reference.bundleIdentifier ?? app.path,
            version: InstalledAppResolver.freshVersion(of: app) ?? "",
            size: 32
        )
        let cachedURL = cacheDirectory.appendingPathComponent(key.fileName)
        let pixels = try #require(DockGroupIconThumbnail.pngPixelSize(at: cachedURL))
        #expect(pixels.width <= 64)
    }

    /// 编辑器标题栏每次 body 求值都会取分组图标，必须命中缓存而不是重绘。
    @MainActor
    @Test func groupIconIsRenderedOncePerContentSignature() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }
        let cacheDirectory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let model = DockGroupsModel(
            store: DockGroupStore(rootDirectory: workspace.root),
            helperManager: workspace.makeHelperManager(),
            iconCacheDirectory: cacheDirectory
        )
        let group = DockGroup(id: "dev", name: "Dev")
        let first = model.groupIcon(for: group, size: 72)
        let second = model.groupIcon(for: group, size: 72)
        #expect(first === second)
        #expect(model.groupIcon(for: group, size: 32) !== first)
    }
}
