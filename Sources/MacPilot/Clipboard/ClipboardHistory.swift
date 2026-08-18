//
//  ClipboardHistory.swift
//  MacPilot
//
//  剪贴板历史模型（记录、去重、固定、搜索、持久化）。
//  改编自 Maccy（MIT License, https://github.com/p0deje/Maccy）：
//  - Maccy/Observables/History.swift
//  - Maccy/Storage.swift
//  - Maccy/Search.swift
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

    private let storageURL: URL
    private var saveTask: Task<Void, Never>?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
    }

    // MARK: - Persistence

    private static func defaultStorageURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ClipboardHistory.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            allItems = []
            items = []
            return
        }
        allItems = decoded
        trimToLimit()
        updateFilteredItems()
    }

    private func save() {
        saveTask?.cancel()
        let itemsToSave = allItems
        let url = storageURL
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(itemsToSave)
                try data.write(to: url, options: .atomic)
            } catch {
                self?.logSaveError(error)
            }
        }
    }

    private func logSaveError(_ error: Error) {
        NSLog("MacPilot clipboard: failed to save history: \(error.localizedDescription)")
    }

    // MARK: - Mutations

    /// 新增一条历史记录（自动去重合并、按需裁剪、持久化）。
    @discardableResult
    func add(_ newItem: ClipboardItem) -> ClipboardItem {
        var item = newItem

        if let existingIndex = allItems.firstIndex(where: { existing in
            existing.id != item.id && existing.supersedes(item)
        }) {
            let existing = allItems[existingIndex]
            item.firstCopiedAt = existing.firstCopiedAt
            item.numberOfCopies += existing.numberOfCopies
            item.pin = existing.pin
            if !item.fromMaccy {
                item.application = existing.application
            }
            allItems.remove(at: existingIndex)
        }

        allItems.insert(item, at: 0)
        trimToLimit()
        updateFilteredItems()
        save()
        return item
    }

    func delete(_ item: ClipboardItem) {
        allItems.removeAll { $0.id == item.id }
        updateFilteredItems()
        save()
    }

    func deleteSelected() {
        guard let selected = selectedItem else { return }
        delete(selected)
    }

    /// 清除未固定的历史（保留固定条目）。
    func clear() {
        let kept = allItems.filter(\.isPinned)
        allItems = kept
        updateFilteredItems()
        save()
    }

    /// 清空全部历史（含固定条目）。
    func clearAll() {
        allItems = []
        items = []
        searchQuery = ""
        selectedIndex = 0
        save()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = allItems[index]
        if updated.pin != nil {
            updated.pin = nil
        } else {
            updated.pin = Self.randomAvailablePin(in: allItems)
        }
        allItems[index] = updated
        updateFilteredItems()
        save()
    }

    func togglePinSelected() {
        guard let selected = selectedItem else { return }
        togglePin(selected)
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
        selectedIndex = items.isEmpty ? 0 : 0
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func selectItem(withId id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
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
            allItems = pinned + unpinned.prefix(max(0, storageLimit - pinned.count))
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
            selectedIndex = items.isEmpty ? 0 : 0
        }
    }

    private static func randomAvailablePin(in items: [ClipboardItem]) -> String {
        let assigned = Set(items.compactMap(\.pin))
        let candidates = "bcdefghijklmnoprstuxy".map(String.init)
        return candidates.first { !assigned.contains($0) } ?? ""
    }
}
