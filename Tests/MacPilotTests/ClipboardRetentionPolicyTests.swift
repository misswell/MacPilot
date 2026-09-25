import AppKit
import Foundation
import Testing
@testable import MacPilot

@Suite
struct ClipboardRetentionPolicyTests {
    private func item(ageInDays: Int, size: Int, pinned: Bool = false) -> ClipboardItem {
        var item = ClipboardItem(contents: [
            ClipboardContent(type: NSPasteboard.PasteboardType.png.rawValue, file: "test.bin", size: size)
        ])
        item.lastCopiedAt = Date(timeIntervalSince1970: 1_000_000)
            .addingTimeInterval(TimeInterval(-ageInDays * 24 * 60 * 60))
        item.pin = pinned ? "a" : nil
        return item
    }

    @Test func oldUnpinnedHistoryExpiresButPinsRemain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = item(ageInDays: 31, size: 10)
        let pinned = item(ageInDays: 31, size: 10, pinned: true)
        let recent = item(ageInDays: 1, size: 10)
        let kept = ClipboardRetentionPolicy.retainedIDs(
            from: [old, pinned, recent], countLimit: 10, now: now
        )
        #expect(kept == [pinned.id, recent.id])
    }

    @Test func sizeLimitEvictsOldestUnpinnedFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = item(ageInDays: 2, size: 60)
        let newer = item(ageInDays: 1, size: 60)
        let pinned = item(ageInDays: 1, size: 60, pinned: true)
        let kept = ClipboardRetentionPolicy.retainedIDs(
            from: [newer, older, pinned], countLimit: 10, now: now, maximumBytes: 120
        )
        #expect(kept == [newer.id, pinned.id])
    }
}
