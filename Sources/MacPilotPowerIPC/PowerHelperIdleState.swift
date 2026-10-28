import Foundation

/// Serialized admission makes an idle exit mutually exclusive with a newly
/// accepted connection. Owned power state always keeps recovery alive.
public struct PowerHelperIdleState: Sendable {
    private var clients = Set<UUID>()
    public private(set) var isExiting = false
    public init() {}
    public mutating func admit(_ client: UUID) -> Bool {
        guard !isExiting else { return false }
        clients.insert(client)
        return true
    }
    public mutating func remove(_ client: UUID) { clients.remove(client) }
    public mutating func commitIdleExit(ownsPowerState: Bool) -> Bool {
        guard !isExiting, clients.isEmpty, !ownsPowerState else { return false }
        isExiting = true
        return true
    }
}
