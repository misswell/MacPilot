import AppKit
import Testing
@testable import MacPilot

@Suite @MainActor
struct ThumbnailCacheTests {
    @Test func leastRecentlyViewedPreviewIsEvictedFirst() {
        let cache = ThumbnailCache(maximumCount: 2, maximumCost: 1_000)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        cache.insert(image, for: "a")
        cache.insert(image, for: "b")
        _ = cache.image(for: "a")
        let evicted = cache.insert(image, for: "c")
        #expect(evicted == ["b"])
        #expect(cache.keys == ["a", "c"])
    }

    @Test func pixelBudgetEvictsEvenBeforeCountLimit() {
        let cache = ThumbnailCache(maximumCount: 50, maximumCost: 500)
        let image = NSImage(size: NSSize(width: 10, height: 10))
        cache.insert(image, for: "a")
        cache.insert(image, for: "b")
        #expect(cache.keys == ["b"])
        #expect(cache.totalCost <= 500)
    }
}
