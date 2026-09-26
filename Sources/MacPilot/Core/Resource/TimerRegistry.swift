import Foundation

/// Counts the two UI animation timers that remain after background polling
/// moved to BackgroundTask. Registration is paired with invalidation.
@MainActor
enum TimerRegistry {
    private static var active: Set<ObjectIdentifier> = []
    private static var tokens: Set<UUID> = []

    static var activeCount: Int { active.count + tokens.count }

    static func register(_ timer: Timer) {
        active.insert(ObjectIdentifier(timer))
    }

    static func unregister(_ timer: Timer?) {
        guard let timer else { return }
        active.remove(ObjectIdentifier(timer))
    }

    static func register(_ token: UUID) { tokens.insert(token) }
    static func unregister(_ token: UUID) { tokens.remove(token) }
}
