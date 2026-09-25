import AppKit

/// Icons are resolved only by views. NSCache evicts under memory pressure and
/// keeps repeated SwiftUI row renders from asking Launch Services again.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        // NSWorkspace icons are multi-representation; charge conservatively
        // so a large app inventory cannot retain hundreds of full-size icons.
        cache.setObject(image, forKey: key, cost: 128 * 128 * 4)
        return image
    }

    func clear() { cache.removeAllObjects() }
}
