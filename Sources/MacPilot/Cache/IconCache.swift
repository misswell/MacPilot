import AppKit

private final class CachedAppIcon: NSObject {
    let key: String
    let image: NSImage
    let cost: Int
    let identity = UUID()

    init(key: String, image: NSImage, cost: Int) {
        self.key = key
        self.image = image
        self.cost = cost
    }
}

private final class AppIconEvictionTracker: NSObject, NSCacheDelegate {
    private let lock = NSLock()
    private var entries: [String: (identity: UUID, cost: Int)] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var bytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.cost }
    }

    func insert(_ icon: CachedAppIcon) {
        lock.lock()
        entries[icon.key] = (icon.identity, icon.cost)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
        guard let icon = object as? CachedAppIcon else { return }
        lock.lock()
        if entries[icon.key]?.identity == icon.identity { entries.removeValue(forKey: icon.key) }
        lock.unlock()
    }
}

/// Icons are resolved only by views. NSCache evicts under memory pressure and
/// keeps repeated SwiftUI row renders from asking Launch Services again.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private let tracker = AppIconEvictionTracker()

    private lazy var cache: NSCache<NSString, CachedAppIcon> = {
        let cache = NSCache<NSString, CachedAppIcon>()
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.delegate = tracker
        return cache
    }()

    var count: Int { tracker.count }
    var estimatedBytes: Int { tracker.bytes }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let image = NSWorkspace.shared.icon(forFile: path)
        // NSWorkspace icons are multi-representation; charge conservatively
        // so a large app inventory cannot retain hundreds of full-size icons.
        let cost = 128 * 128 * 4
        let icon = CachedAppIcon(key: path, image: image, cost: cost)
        tracker.insert(icon)
        cache.setObject(icon, forKey: key, cost: cost)
        return image
    }

    func clear() {
        cache.removeAllObjects()
        tracker.clear()
    }
}
