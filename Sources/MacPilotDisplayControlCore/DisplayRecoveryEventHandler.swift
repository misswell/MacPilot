import Foundation

/// Builds DispatchSource callbacks that only enqueue their Sendable operation.
/// The callback itself is constructed without inheriting an actor context.
public enum DisplayRecoveryEventHandler {
    public nonisolated static func enqueue(
        on queue: DispatchQueue,
        operation: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { queue.async(execute: operation) }
    }
}
