import Foundation

enum ClipboardRetentionPolicy {
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let maximumBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    static func retainedIDs(
        from items: [ClipboardItem],
        countLimit: Int,
        now: Date = .now,
        maximumBytes: UInt64 = maximumBytes
    ) -> Set<UUID> {
        let cutoff = now.addingTimeInterval(-maximumAge)
        // Pins survive the age limit, but the overall size limit remains hard.
        let eligible = items.filter { $0.isPinned || $0.lastCopiedAt >= cutoff }
        let pinned = eligible.filter(\.isPinned)
        let unpinned = eligible.filter { !$0.isPinned }
        let countBounded = pinned + unpinned.prefix(max(0, countLimit - pinned.count))
        var retained = Set(countBounded.map(\.id))
        var totalBytes = countBounded.reduce(UInt64.zero) { $0 &+ byteCount(of: $1) }
        guard totalBytes > maximumBytes else { return retained }

        // Discard oldest unpinned data first. A pinned item is evicted only if
        // its bytes alone prevent the configured storage ceiling being met.
        let evictionOrder = countBounded.sorted {
            if $0.isPinned != $1.isPinned { return !$0.isPinned }
            return $0.lastCopiedAt < $1.lastCopiedAt
        }
        for item in evictionOrder where totalBytes > maximumBytes {
            retained.remove(item.id)
            totalBytes -= byteCount(of: item)
        }
        return retained
    }

    private static func byteCount(of item: ClipboardItem) -> UInt64 {
        item.contents.reduce(UInt64.zero) { total, content in
            total &+ UInt64(max(content.size, content.value?.count ?? 0))
        }
    }
}
