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
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

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
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

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
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

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
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

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
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

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
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

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

    @Test func flushPersistsInsideTheDebounceWindow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-flush-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

        let history = makeHistory(url: url)
        history.add(makeItem("latest"))
        history.flush()

        let reloaded = makeHistory(url: url)
        #expect(reloaded.allItems.map(\.title) == ["latest"])
    }

    @Test func fileBackedContentIsStoredOnDiskAndResolvesOnDemand() async throws {
        // 图片/大数据应落盘：内容 value 为空，仅保留文件引用；按需读取能还原数据。
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }
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

    @Test func addingInlineLargeContentExternalizesItBeforePublishing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

        let id = UUID()
        let data = Data(repeating: 0x5A, count: 128 * 1024)
        let item = ClipboardItem(
            id: id,
            contents: [
                ClipboardContent(
                    type: NSPasteboard.PasteboardType.string.rawValue,
                    value: data,
                    size: data.count
                )
            ]
        )
        defer { ClipboardContentStore.delete(itemID: id) }

        let history = makeHistory(url: url)
        let added = history.add(item)
        let content = try #require(added.contents.first)

        #expect(content.value == nil)
        #expect(content.file != nil)
        #expect(content.size == data.count)
        #expect(content.file.flatMap(ClipboardContentStore.read(file:)) == data)
    }

    @Test func mergingDuplicateRemovesDiscardedFileBackedContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }

        let firstID = UUID()
        let secondID = UUID()
        let firstFile = try #require(ClipboardContentStore.write(
            Data(repeating: 0x11, count: 4 * 1024),
            itemID: firstID,
            index: 0
        ))
        let secondFile = try #require(ClipboardContentStore.write(
            Data(repeating: 0x22, count: 4 * 1024),
            itemID: secondID,
            index: 0
        ))
        defer {
            ClipboardContentStore.delete(itemID: firstID)
            ClipboardContentStore.delete(itemID: secondID)
        }

        let first = ClipboardItem(id: firstID, contents: [
            ClipboardContent(
                type: NSPasteboard.PasteboardType.png.rawValue,
                file: firstFile,
                size: 4 * 1024
            )
        ])
        let second = ClipboardItem(id: secondID, contents: [
            ClipboardContent(
                type: NSPasteboard.PasteboardType.png.rawValue,
                file: secondFile,
                size: 4 * 1024
            )
        ])

        let history = makeHistory(url: url)
        history.add(first)
        history.add(second)

        #expect(ClipboardContentStore.read(file: firstFile) == nil)
        #expect(ClipboardContentStore.read(file: secondFile) != nil)
    }

    @Test func fileBackedImageThumbnailIsBoundedWithoutResolvingOriginalData() throws {
        let contentStore = ClipboardContentStoreIsolation.isolate()
        defer { ClipboardContentStoreIsolation.restore(contentStore) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let image = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))

        let id = UUID()
        let file = try #require(ClipboardContentStore.write(data, itemID: id, index: 0))
        defer { ClipboardContentStore.delete(itemID: id) }

        let item = ClipboardItem(id: id, contents: [
            ClipboardContent(
                type: NSPasteboard.PasteboardType.png.rawValue,
                file: file,
                size: data.count
            )
        ])
        let thumbnail = try #require(item.thumbnailImage)

        #expect(item.isImage)
        #expect(thumbnail.pixelSize.width <= 80)
        #expect(thumbnail.pixelSize.height <= 80)
    }
}
