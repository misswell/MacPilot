//
//  ClipboardHistoryStorage.swift
//  MacPilot
//
//  剪贴板历史的磁盘职责：加载、防抖保存、终止前落盘、旧版内联数据迁移。
//

import Foundation
import OSLog

@MainActor
final class ClipboardHistoryStorage {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "Clipboard")

    let storageURL: URL
    let isDefaultStorage: Bool
    private var saveTask: Task<Void, Never>?

    init(storageURL: URL? = nil) {
        let defaultURL = Self.defaultStorageURL()
        let resolved = storageURL ?? defaultURL
        self.storageURL = resolved
        self.isDefaultStorage = resolved == defaultURL
    }

    // MARK: - Load

    /// 读取并解码历史；文件缺失或损坏时返回 nil（调用方按空历史处理）。
    func loadItems() -> [ClipboardItem]? {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return nil
        }
        return decoded
    }

    // MARK: - Save

    /// 300ms 防抖保存，避免复制/粘贴高频路径上的同步磁盘写入。
    func scheduleSave(_ items: [ClipboardItem]) {
        saveTask?.cancel()
        let url = storageURL
        saveTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try Self.persist(items, to: url)
            } catch {
                Self.logger.error("failed to save clipboard history: \(error.localizedDescription)")
            }
        }
    }

    /// 应用终止前同步落盘，避免防抖窗口内的变更丢失。
    func flush(_ items: [ClipboardItem]) {
        saveTask?.cancel()
        saveTask = nil
        do {
            try Self.persist(items, to: storageURL)
        } catch {
            Self.logger.error("failed to flush clipboard history: \(error.localizedDescription)")
        }
    }

    private nonisolated static func persist(_ items: [ClipboardItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Externalization

    /// 把条目里仍内联的大数据（图片、>64KB）替换为磁盘文件引用。
    /// 加载旧版历史与接收新条目共用这一条路径。
    static func externalizeInlineContent(in item: ClipboardItem) -> ClipboardItem {
        var contents = item.contents
        var changed = false
        for index in contents.indices {
            let externalized = ClipboardContentStore.externalized(
                contents[index],
                itemID: item.id,
                index: index
            )
            guard externalized != contents[index] else { continue }
            contents[index] = externalized
            changed = true
        }
        guard changed else { return item }
        var updated = item
        updated.contents = contents
        return updated
    }

    // MARK: - Defaults

    private static func defaultStorageURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ClipboardHistory.json")
    }
}
