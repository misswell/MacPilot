import AppKit
import Combine

/// Menu tracking notifications describe the native menu session, unlike
/// SwiftUI appearance callbacks which may run during offscreen construction.
@MainActor
final class MonitorMenuActivity: ObservableObject {
    static let shared = MonitorMenuActivity()

    @Published private(set) var isTracking = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private let roots = NSHashTable<NSMenu>.weakObjects()
    private var legacyRootMatches: ((NSMenu) -> Bool)?

    /// The popup controller registers the exact AppKit tree it will display.
    func register(rootMenu: NSMenu) { roots.add(rootMenu) }

    /// macOS 14.0–14.3 owns the MenuBarExtra tree. Identify its root from the
    /// app's complete command signature, then track that exact tree as usual.
    func setLegacyRootMatcher(_ matches: @escaping (NSMenu) -> Bool) {
        legacyRootMatches = matches
    }

    private func owns(_ menu: NSMenu) -> Bool {
        var ancestor: NSMenu? = menu
        while let current = ancestor {
            if roots.contains(current) { return true }
            if legacyRootMatches?(current) == true {
                roots.add(current)
                return true
            }
            ancestor = current.supermenu
        }
        return false
    }
    private var subscriptions: MonitorMenuSubscriptions?

    init(notificationCenter: NotificationCenter = .default) {
        let begin = notificationCenter.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            let event = MonitorMenuEvent(menu: menu)
            MainActor.assumeIsolated {
                guard let self, self.owns(event.menu) else { return }
                self.beginTracking(ObjectIdentifier(event.menu))
            }
        }
        let end = notificationCenter.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            let identifier = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                self?.endTracking(identifier)
            }
        }
        subscriptions = MonitorMenuSubscriptions(center: notificationCenter, tokens: [begin, end])
    }

    private func beginTracking(_ identifier: ObjectIdentifier) {
        trackingMenus.insert(identifier)
        if !isTracking { isTracking = true }
    }

    private func endTracking(_ identifier: ObjectIdentifier) {
        trackingMenus.remove(identifier)
        if trackingMenus.isEmpty, isTracking { isTracking = false }
    }
}

/// NotificationCenter removal is thread safe, including actor teardown.
private final class MonitorMenuSubscriptions: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [NSObjectProtocol]

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}

/// NotificationCenter delivers these observers synchronously on OperationQueue.main.
/// The envelope carries the non-Sendable AppKit value into that isolated body;
/// it is never accessed from another queue.
private struct MonitorMenuEvent: @unchecked Sendable {
    let menu: NSMenu
}
