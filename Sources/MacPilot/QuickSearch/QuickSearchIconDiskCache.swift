//
//  QuickSearchIconDiskCache.swift
//  MacPilot
//
//  快速搜索图标的落盘缓存：应用图标只在第一次出现时向图标服务要一遍，
//  之后直接读 `~/Library/Caches/MacPilot/QuickSearch/Icons/` 下的小 PNG。
//
//  缓存键包含应用路径、包修改时间和显示尺寸：应用升级（包被替换）后键自动变化，
//  不会继续显示旧图标。条目本身有刷新周期，过期的图先照常显示，再在后台重建。
//  整个目录随时可以删除，删掉只影响下一次的取图时间。
//

import CryptoKit
import Foundation

final class QuickSearchIconDiskCache: @unchecked Sendable {
    struct Entry {
        let png: Data
        /// 超过刷新周期的旧图：可以先显示，同时后台重建。
        let isStale: Bool
    }

    static let shared = QuickSearchIconDiskCache()

    /// 图标多久重建一次。应用自身升级由缓存键里的修改时间立刻触发，
    /// 这个周期只兜底系统图标样式变化。
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    /// 超过这个时间的文件不再有命中可能，写入时顺手清掉。
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    /// 只收自己生成的小缩略图；异常大的文件一律当作脏数据。
    static let maximumEntryBytes = 512 * 1024

    let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var hasScheduledPrune = false

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches", isDirectory: true)
            self.directory = caches
                .appendingPathComponent("MacPilot", isDirectory: true)
                .appendingPathComponent("QuickSearch", isDirectory: true)
                .appendingPathComponent("Icons", isDirectory: true)
        }
    }

    func entry(for url: URL, pointSize: CGFloat, now: Date = Date()) -> Entry? {
        let file = fileURL(for: url, pointSize: pointSize)
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              let png = try? Data(contentsOf: file)
        else { return nil }
        guard png.count <= Self.maximumEntryBytes else {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return Entry(png: png, isStale: now.timeIntervalSince(modified) > Self.refreshInterval)
    }

    /// 写失败一律忽略：缓存只是加速手段，不能因为它失败影响图标显示。
    func store(_ png: Data, for url: URL, pointSize: CGFloat) {
        guard png.count <= Self.maximumEntryBytes else { return }
        let file = fileURL(for: url, pointSize: pointSize)
        try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
        schedulePruneIfNeeded()
    }

    func remove(for url: URL, pointSize: CGFloat) {
        try? fileManager.removeItem(at: fileURL(for: url, pointSize: pointSize))
    }

    func cacheFileURL(for url: URL, pointSize: CGFloat) -> URL {
        fileURL(for: url, pointSize: pointSize)
    }

    /// 清掉过期条目。文件自带「最近生成时间」，删除后下次用到再生成即可。
    @discardableResult
    func prune(now: Date = Date()) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified,
                  now.timeIntervalSince(modified) > Self.retentionInterval
            else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    private func fileURL(for url: URL, pointSize: CGFloat) -> URL {
        directory.appendingPathComponent(fileName(for: url, pointSize: pointSize))
    }

    /// 路径 + 包修改时间 + 尺寸。应用升级后包修改时间变化，旧条目自然失效。
    private func fileName(for url: URL, pointSize: CGFloat) -> String {
        let standardized = url.standardizedFileURL
        let modified = (try? standardized.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let identity = "\(standardized.path)\u{0}\(modified)\u{0}\(Int(pointSize.rounded()))"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private func schedulePruneIfNeeded() {
        lock.lock()
        let shouldPrune = !hasScheduledPrune
        hasScheduledPrune = true
        lock.unlock()
        guard shouldPrune else { return }
        Task.detached(priority: .utility) { [self] in
            _ = prune()
        }
    }
}
