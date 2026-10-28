import Foundation

/// All instances address the same launchd job. Keep registration changes and
/// requests in one queue, including across controller shutdown/recreation.
@MainActor
final class PowerHelperLifecycleBarrier {
    static let shared = PowerHelperLifecycleBarrier()
    private var tail: Task<Void, Never>?

    func run<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in _ = try? await work.value }
        return try await work.value
    }
}
