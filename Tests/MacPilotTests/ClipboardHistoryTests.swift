import AppKit
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct ClipboardHistoryTests {
    private func makeItem(_ text: String, date: Date = Date()) -> ClipboardItem {
        var item = ClipboardItem(contents: [
            ClipboardContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
        ])
        item.title = text
        item.lastCopiedAt = date
        item.firstCopiedAt = date
        return item
    }

    @MainActor
    private func makeHistory(url: URL) -> ClipboardHistory {
        ClipboardHistory(storageURL: url)
    }

    @Test func newestCopyIsInsertedFirst() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(url: url)
        let first = makeItem("first", date: Date(timeIntervalSinceNow: -10))
        let second = makeItem("second", date: Date())
        history.add(first)
        history.add(second)

        #expect(history.items.first?.title == "second")
        #expect(history.items.last?.title == "first")
    }

    @Test func duplicateCopyIsMergedIntoOneItem() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(url: url)
        let first = makeItem("hello")
        let second = makeItem("hello")
        history.add(first)
        history.add(second)

        #expect(history.allItems.count == 1)
        #expect(history.allItems[0].numberOfCopies == 2)
    }

    @Test func storageLimitTrimsUnpinnedItemsButKeepsPinned() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(url: url)
        history.storageLimit = 3

        var pinned = makeItem("pinned")
        pinned.pin = "a"
        history.add(pinned)

        for index in 0..<5 {
            history.add(makeItem("item-\(index)"))
        }

        #expect(history.allItems.count == 3)
        #expect(history.allItems.contains { $0.pin == "a" })
    }

    @Test func searchFiltersItemsCaseInsensitively() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(url: url)
        history.add(makeItem("SwiftUI"))
        history.add(makeItem("Swift Testing"))
        history.add(makeItem("AppKit"))

        history.searchQuery = "swift"
        #expect(history.items.count == 2)

        history.searchQuery = "appkit"
        #expect(history.items.count == 1)
        #expect(history.items.first?.title == "AppKit")
    }

    @Test func pinnedItemsSortToTopWhenPinsAtTop() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(url: url)
        history.pinsAtTop = true

        history.add(makeItem("older"))
        var pinned = makeItem("pinned")
        pinned.pin = "x"
        history.add(pinned)

        #expect(history.items.first?.title == "pinned")
        #expect(history.items.last?.title == "older")
    }

    @Test func historyPersistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(url: url)
        history.add(makeItem("persisted"))

        // 等待去抖保存完成。
        try await Task.sleep(for: .milliseconds(600))

        let reloaded = makeHistory(url: url)
        #expect(reloaded.allItems.count == 1)
        #expect(reloaded.allItems.first?.title == "persisted")
    }
}
