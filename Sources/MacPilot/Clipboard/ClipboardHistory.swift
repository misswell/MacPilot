//
//  ClipboardHistory.swift
//  MacPilot
//
//  剪贴板历史内存模型：去重合并、裁剪、搜索排序、选择导航与固定。
//  磁盘职责见 ClipboardHistoryStorage。
//

import AppKit
import Foundation

@MainActor
final class ClipboardHistory: ObservableObject {
    /// 全部历史（未被搜索过滤）。
    @Published private(set) var allItems: [ClipboardItem] = []
    /// 当前可见条目（按搜索过滤 + 排序）。
    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchQuery: String = "" {
        didSet { updateFilteredItems() }
    }
    @Published var selectedIndex: Int = 0
    @Published var pinsAtTop: Bool = true {
        didSet { updateFilteredItems() }
    }

    var storageLimit: Int = 100 {
        didSet {
            guard storageLimit != oldValue else { return }
            trimToLimit()
            updateFilteredItems()
            save()
        }
    }

    var selectedItem: ClipboardItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var pinnedItems: [ClipboardItem] { items.filter(\.isPinned) }
    var unpinnedItems: [ClipboardItem] { items.filter { !$0.isPinned } }

    private let storage: ClipboardHistoryStorage

    init(storageURL: URL? = nil) {
        self.storage = ClipboardHistoryStorage(storageURL: storageURL)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let decoded = storage.loadItems() else {
            allItems = []
            items = []
            return
        }
        allItems = decoded
        // 旧版历史里图片/大数据是内联存进 JSON 的，加载时迁移到磁盘，
        // 之后内存只保留文件引用，彻底释放旧数据占用的内存。
        let migrated = migrateInlineContentToDisk()
        trimToLimit()
        // 仅默认存储位置才回收孤儿文件，避免测试目录误删真实内容文件。
        if storage.isDefaultStorage {
            let referencedFiles = Set(allItems.flatMap { item in
                item.contents.compactMap(\.file)
            })
            ClipboardContentStore.deleteUnreferencedFiles(referencedFileNames: referencedFiles)
        }
        if migrated { save() }
        updateFilteredItems()
    }

    private func migrateInlineContentToDisk() -> Bool {
        var changed = false
        for index in allItems.indices {
            let externalized = ClipboardHistoryStorage.externalizeInlineContent(in: allItems[index])
            guard externalized != allItems[index] else { continue }
            allItems[index] = externalized
            changed = true
        }
        return changed
    }

    func save() {
        storage.scheduleSave(allItems)
    }

    /// Persist the latest snapshot before application termination instead of
    /// losing mutations still inside the normal 300 ms debounce window.
    func flush() {
        storage.flush(allItems)
    }

    // MARK: - Mutations

    /// 新增一条历史记录（自动去重合并、按需裁剪、持久化）。
    @discardableResult
    func add(_ newItem: ClipboardItem) -> ClipboardItem {
        // Keep the published model index-like even when a caller bypasses
        // ClipboardMonitor and supplies inline image/large data.
        var item = ClipboardHistoryStorage.externalizeInlineContent(in: newItem)

        if let existingIndex = allItems.firstIndex(where: { existing in
            existing.id != item.id && existing.supersedes(item)
        }) {
            let existing = allItems[existingIndex]
            item.firstCopiedAt = existing.firstCopiedAt
            item.numberOfCopies += existing.numberOfCopies
            item.pin = existing.pin
            if !item.fromMacPilot {
                item.application = existing.application
            }
            allItems.remove(at: existingIndex)
            // The new item owns its replacement files. Do not leave the
            // discarded duplicate's image data orphaned in the cache.
            ClipboardContentStore.delete(itemID: existing.id)
        }

        allItems.insert(item, at: 0)
        trimToLimit()
        updateFilteredItems()
        save()
        return item
    }

    func delete(_ item: ClipboardItem) {
        allItems.removeAll { $0.id == item.id }
        ClipboardContentStore.delete(itemID: item.id)
        updateFilteredItems()
        save()
    }

    func deleteSelected() {
        guard let selected = selectedItem else { return }
        delete(selected)
    }

    /// 清除未固定的历史（保留固定条目）。
    func clear() {
        let removed = allItems.filter { !$0.isPinned }
        let kept = allItems.filter(\.isPinned)
        allItems = kept
        for item in removed { ClipboardContentStore.delete(itemID: item.id) }
        updateFilteredItems()
        save()
    }

    /// 清空全部历史（含固定条目）。
    func clearAll() {
        allItems = []
        items = []
        searchQuery = ""
        selectedIndex = 0
        ClipboardContentStore.deleteAll()
        save()
    }

    /// 记录一次使用（更新时间与次数，并置顶）。
    func recordUse(of item: ClipboardItem) {
        guard let index = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = allItems[index]
        updated.lastCopiedAt = Date.now
        updated.numberOfCopies += 1
        allItems[index] = updated
        updateFilteredItems()
        save()
    }

    // MARK: - Navigation

    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    func selectFirst() {
        selectedIndex = 0
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// 选择第 index 条未固定条目（数字快捷键 1-9）。
    func selectUnpinnedItem(at index: Int) {
        let unpinned = unpinnedItems
        guard unpinned.indices.contains(index) else { return }
        guard let itemIndex = items.firstIndex(where: { $0.id == unpinned[index].id }) else { return }
        selectedIndex = itemIndex
    }

    /// 选择固定字母为 pin 的条目（字母快捷键）。
    @discardableResult
    func selectPinnedItem(withPin pin: String) -> Bool {
        guard let item = pinnedItems.first(where: { $0.pin?.lowercased() == pin }) else {
            return false
        }
        guard let itemIndex = items.firstIndex(where: { $0.id == item.id }) else { return false }
        selectedIndex = itemIndex
        return true
    }

    // MARK: - Helpers

    private func trimToLimit() {
        let unpinned = allItems.filter { !$0.isPinned }
        let pinned = allItems.filter(\.isPinned)
        if unpinned.count >= storageLimit {
            let kept = pinned + unpinned.prefix(max(0, storageLimit - pinned.count))
            let keptIDs = Set(kept.map(\.id))
            for item in allItems where !keptIDs.contains(item.id) {
                ClipboardContentStore.delete(itemID: item.id)
            }
            allItems = kept
        }
    }

    private func updateFilteredItems() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? allItems
            : allItems.filter { $0.title.localizedCaseInsensitiveContains(query) }

        items = filtered.sorted { lhs, rhs in
            if pinsAtTop {
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            } else {
                if lhs.isPinned != rhs.isPinned { return rhs.isPinned }
            }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }

        if !items.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }
}
