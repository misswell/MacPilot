import Foundation

/// The same safe transaction is used for migration and disabled-feature cleanup.
/// A failed/uncertain read leaves the old job installed for recovery.
@MainActor
enum PowerHelperJobRetirement {
    static func run(
        release: () async -> Result<Bool, ClosedLidSleepFailure>,
        read: () async -> Result<Bool, ClosedLidSleepFailure>,
        invalidate: () async -> Void,
        unregister: () async throws -> Void
    ) async throws {
        if case .failure(let error) = await release() { throw error }
        switch await read() {
        case .success(false): break
        case .success(true): throw ClosedLidSleepFailure.requestFailed("The existing power setting has not been safely released.")
        case .failure(let error): throw error
        }
        await invalidate()
        try await unregister()
    }
}
