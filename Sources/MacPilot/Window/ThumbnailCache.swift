import AppKit

/// Pixel-cost-aware LRU for the small Window Switcher previews.
@MainActor
final class ThumbnailCache {
    let maximumCount: Int
    let maximumCost: Int

    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private var entries: [String: Entry] = [:]
    private var oldestToNewest: [String] = []
    private(set) var totalCost = 0

    init(maximumCount: Int = 50, maximumCost: Int = 8 * 1_024 * 1_024) {
        self.maximumCount = maximumCount
        self.maximumCost = maximumCost
    }

    var keys: Set<String> { Set(entries.keys) }
    var count: Int { entries.count }

    func image(for id: String) -> NSImage? {
        guard let entry = entries[id] else { return nil }
        touch(id)
        return entry.image
    }

    func contains(_ id: String) -> Bool { entries[id] != nil }

    @discardableResult
    func insert(_ image: NSImage, for id: String) -> Set<String> {
        remove(id)
        let cost = max(1, Int(image.size.width) * Int(image.size.height) * 4)
        guard maximumCount > 0, cost <= maximumCost else { return [id] }
        entries[id] = Entry(image: image, cost: cost)
        totalCost += cost
        oldestToNewest.append(id)
        var evicted = Set<String>()
        while entries.count > maximumCount || totalCost > maximumCost {
            guard let oldest = oldestToNewest.first else { break }
            remove(oldest)
            evicted.insert(oldest)
        }
        return evicted
    }

    @discardableResult
    func retain(_ validIDs: Set<String>) -> Set<String> {
        let removed = keys.subtracting(validIDs)
        for id in removed { remove(id) }
        return removed
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
        oldestToNewest.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    private func touch(_ id: String) {
        oldestToNewest.removeAll { $0 == id }
        oldestToNewest.append(id)
    }

    private func remove(_ id: String) {
        if let entry = entries.removeValue(forKey: id) { totalCost -= entry.cost }
        oldestToNewest.removeAll { $0 == id }
    }
}
