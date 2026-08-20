import AppKit
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct ClipboardHistoryTests {
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

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

        await waitUntil {
            let reloaded = makeHistory(url: url)
            return reloaded.allItems.first?.title == "persisted"
        }

        let reloaded = makeHistory(url: url)
        #expect(reloaded.allItems.count == 1)
        #expect(reloaded.allItems.first?.title == "persisted")
    }

    @Test func fileBackedContentIsStoredOnDiskAndResolvesOnDemand() async throws {
        // 图片/大数据应落盘：内容 value 为空，仅保留文件引用；按需读取能还原数据。
        let id = UUID()
        let imageData = Data((0..<16_384).map { UInt8($0 % 251) })  // > 64KB? no, 16KB — 触发外部化需要图片类型
        let content = ClipboardContent(
            type: NSPasteboard.PasteboardType.png.rawValue,
            file: ClipboardContentStore.write(imageData, itemID: id, index: 0),
            size: imageData.count
        )
        defer { ClipboardContentStore.delete(itemID: id) }

        #expect(content.isExternal)
        #expect(content.value == nil)
        let item = ClipboardItem(id: id, contents: [content])
        #expect(item.imageData == imageData)
        #expect(item.image != nil)
    }
}
