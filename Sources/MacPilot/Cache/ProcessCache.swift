import Foundation

/// A process path is stable for one PID/start-time pair. CPU and memory
/// collectors share this cache, avoiding a `proc_pidpath` call on every tick.
final class ProcessCache: @unchecked Sendable {
    static let shared = ProcessCache()

    private struct Entry {
        let startedAt: Date
        let path: String
    }

    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]

    func path(for pid: pid_t, startedAt: Date?, load: () -> String?) -> String? {
        guard let startedAt else { return load() }
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[pid], entry.startedAt == startedAt {
            return entry.path
        }
        guard let path = load() else { return nil }
        entries[pid] = Entry(startedAt: startedAt, path: path)
        return path
    }

    func retain(_ livePIDs: Set<pid_t>) {
        lock.lock()
        entries = entries.filter { livePIDs.contains($0.key) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
