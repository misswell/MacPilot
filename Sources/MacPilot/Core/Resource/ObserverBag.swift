import Foundation

/// Owns block observer tokens and removes each token from the center that
/// created it. Feature stop paths can release the whole set in one call.
@MainActor
final class ObserverBag {
    private struct Entry {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private var entries: [Entry] = []
    private(set) static var activeCount = 0
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    func add(_ token: NSObjectProtocol, center: NotificationCenter = .default) {
        entries.append(Entry(center: center, token: token))
        Self.activeCount += 1
    }

    func removeAll() {
        for entry in entries { entry.center.removeObserver(entry.token) }
        Self.activeCount -= entries.count
        entries.removeAll(keepingCapacity: false)
    }
}
