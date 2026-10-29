import Foundation

/// Security.framework may wait on securityd for seconds. Bluetooth callbacks
/// read this memory snapshot; only the serial worker accesses persisted keys.
@MainActor
final class RemotePairingKeyStore {
    private let queue = DispatchQueue(label: "com.misswell.pilotnest.keychain", qos: .utility)
    private let loadKeys: @Sendable () throws -> [String: Data]
    private let saveKey: @Sendable (String, Data) -> Bool
    private let removeKey: @Sendable (String) -> Bool
    private var keys: [String: Data] = [:]
    private var revisions: [String: UInt64] = [:]
    private var loading: Task<Bool, Never>?
    private var saveSequence: UInt64 = 0
    private var appliedSaves: [String: UInt64] = [:]
    private(set) var isPrepared = false

    init(load: @escaping @Sendable () throws -> [String: Data],
         save: @escaping @Sendable (String, Data) -> Bool,
         remove: @escaping @Sendable (String) -> Bool) {
        loadKeys = load
        saveKey = save
        removeKey = remove
    }

    func key(for id: String) -> Data? { keys[id] }

    /// Failure stays unknown; never mistake a locked/unavailable Keychain for
    /// an absent pairing key and start a replacement pairing exchange.
    func prepare() async -> Bool {
        if isPrepared { return true }
        if let loading { return await loading.value }
        let load = loadKeys
        let queue = queue
        let task = Task { @MainActor in
            let result: [String: Data]? = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: try? load()) }
            }
            guard let result else { return false }
            // A forget action while loading must not be undone by its snapshot.
            self.keys = result.filter { self.revisions[$0.key] == nil }
            self.isPrepared = true
            return true
        }
        loading = task
        let result = await task.value
        loading = nil
        return result
    }

    func save(_ key: Data, for id: String) async -> Bool {
        let revision = revisions[id, default: 0]
        guard await prepare(), revisions[id, default: 0] == revision else { return false }
        saveSequence &+= 1
        let sequence = saveSequence
        let save = saveKey
        let success = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: save(id, key)) }
        }
        // Forget wins over an older save completing on the worker.
        guard success, revisions[id, default: 0] == revision else { return false }
        if sequence > appliedSaves[id, default: 0] {
            keys[id] = key
            appliedSaves[id] = sequence
        }
        return true
    }

    /// Revoke in memory immediately; serialize deletion behind earlier I/O.
    /// No radio callback may continue authenticating with the revoked key.
    @discardableResult
    func remove(_ id: String) -> Task<Bool, Never> {
        revisions[id, default: 0] &+= 1
        keys.removeValue(forKey: id)
        let remove = removeKey
        // Enqueue now, before any newer save; callers may await durability
        // without blocking the main actor or racing queue submission order.
        let results = AsyncStream<Bool> { continuation in
            queue.async {
                continuation.yield(remove(id))
                continuation.finish()
            }
        }
        return Task {
            for await result in results { return result }
            return false
        }
    }
}
