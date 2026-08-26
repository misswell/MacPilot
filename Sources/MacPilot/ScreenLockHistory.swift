import Foundation

/// Identifies who initiated a screen lock or unlock event.
enum ScreenLockHistorySource: String, Codable, Equatable, Sendable {
    case automatic
    case manual
}

/// A paired screen-lock session.  The unlock side remains nil while the Mac
/// is still locked or when the matching unlock notification has not arrived.
struct ScreenLockHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let lockedAt: Date
    var unlockedAt: Date?
    let lockSource: ScreenLockHistorySource
    var unlockSource: ScreenLockHistorySource?

    init(
        id: UUID = UUID(),
        lockedAt: Date,
        lockSource: ScreenLockHistorySource,
        unlockedAt: Date? = nil,
        unlockSource: ScreenLockHistorySource? = nil
    ) {
        self.id = id
        self.lockedAt = lockedAt
        self.unlockedAt = unlockedAt
        self.lockSource = lockSource
        self.unlockSource = unlockedAt == nil ? nil : unlockSource
    }

    var isStillLocked: Bool { unlockedAt == nil }

    var unlockDuration: TimeInterval? {
        guard let unlockedAt else { return nil }
        return max(0, unlockedAt.timeIntervalSince(lockedAt))
    }
}

/// Keeps a small, newest-first record of screen lock sessions.
///
/// The module deliberately accepts event timestamps from its caller instead
/// of reading the clock itself.  This keeps notification delivery and event
/// bookkeeping separate and makes pairing behavior deterministic to test.
struct ScreenLockHistory: Codable, Equatable, Sendable {
    static let maximumEntries = 30
    private static let duplicateEventTolerance: TimeInterval = 2

    private(set) var entries: [ScreenLockHistoryEntry]

    init(entries: [ScreenLockHistoryEntry] = []) {
        self.entries = Self.normalized(entries)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decodeIfPresent([ScreenLockHistoryEntry].self, forKey: .entries) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    /// Adds a lock event unless a previous lock is still open.  macOS can
    /// deliver the distributed notification more than once; treating an open
    /// session as the de-duplication key also handles delayed duplicates.
    @discardableResult
    mutating func recordLock(at date: Date, source: ScreenLockHistorySource) -> Bool {
        guard !entries.contains(where: \.isStillLocked) else { return false }
        if let latestEntry = entries.first {
            let sinceLastLock = date.timeIntervalSince(latestEntry.lockedAt)
            if sinceLastLock >= 0, sinceLastLock <= Self.duplicateEventTolerance {
                return false
            }
            if let unlockedAt = latestEntry.unlockedAt {
                let sinceUnlock = date.timeIntervalSince(unlockedAt)
                if sinceUnlock >= 0, sinceUnlock <= Self.duplicateEventTolerance {
                    return false
                }
            }
        }
        entries.insert(
            ScreenLockHistoryEntry(lockedAt: date, lockSource: source),
            at: 0
        )
        trim()
        return true
    }

    /// Completes the most recent open lock session.  Unlock notifications
    /// without a known lock are ignored so a partial startup state cannot
    /// create a fabricated lock record.
    @discardableResult
    mutating func recordUnlock(at date: Date, source: ScreenLockHistorySource) -> Bool {
        guard let index = entries.firstIndex(where: \.isStillLocked),
              date >= entries[index].lockedAt else {
            return false
        }
        entries[index].unlockedAt = date
        entries[index].unlockSource = source
        return true
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    private mutating func trim() {
        entries = Array(Self.normalized(entries).prefix(Self.maximumEntries))
    }

    private static func normalized(_ entries: [ScreenLockHistoryEntry]) -> [ScreenLockHistoryEntry] {
        entries
            .filter { entry in
                guard let unlockedAt = entry.unlockedAt else { return true }
                return unlockedAt >= entry.lockedAt
            }
            .sorted { $0.lockedAt > $1.lockedAt }
            .prefix(maximumEntries)
            .map { $0 }
    }
}
