import Foundation
import Testing
@testable import PilotNest

@MainActor
struct RemotePairingKeyStoreTests {
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: Data] = ["mac": Data([1, 2, 3])]
        private var accesses = 0
        private var touchedMain = false
        private var didEnterLoad = false
        private var loadWaiters: [CheckedContinuation<Void, Never>] = []
        let releaseLoad = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        var blocksLoad = false

        func load() throws -> [String: Data] {
            record()
            lock.lock()
            didEnterLoad = true
            let waiters = loadWaiters
            loadWaiters.removeAll()
            lock.unlock()
            for waiter in waiters { waiter.resume() }
            // Detect the original bug immediately instead of deadlocking a
            // test runner by simulating securityd on its main thread.
            guard !Thread.isMainThread else { throw Failure.ranOnMainThread }
            if blocksLoad { releaseLoad.wait() }
            lock.lock()
            defer { lock.unlock() }
            return keys
        }

        func save(_ id: String, _ key: Data) -> Bool {
            record()
            lock.lock()
            defer { lock.unlock() }
            keys[id] = key
            return true
        }

        func remove(_ id: String) -> Bool {
            record()
            lock.lock()
            keys.removeValue(forKey: id)
            lock.unlock()
            deleteFinished.signal()
            return true
        }

        private func record() {
            lock.lock()
            accesses += 1
            touchedMain = touchedMain || Thread.isMainThread
            lock.unlock()
        }

        func stats() -> (Int, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (accesses, touchedMain)
        }

        func waitForLoad() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didEnterLoad {
                    lock.unlock()
                    continuation.resume()
                } else {
                    loadWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        enum Failure: Error { case unavailable, ranOnMainThread }
    }

    private func store(_ backend: Backend) -> RemotePairingKeyStore {
        RemotePairingKeyStore(load: { try backend.load() },
                              save: { backend.save($0, $1) },
                              remove: { backend.remove($0) })
    }

    @Test func aStalledSecurityReadLeavesTheMainActorResponsiveAndIsCoalesced() async {
        let backend = Backend()
        backend.blocksLoad = true
        let store = store(backend)
        let first = Task { await store.prepare() }
        let second = Task { await store.prepare() }
        // This main-actor continuation must run while the worker is blocked.
        await backend.waitForLoad()
        #expect(!store.isPrepared)
        backend.releaseLoad.signal()
        #expect(await first.value)
        #expect(await second.value)
        #expect(backend.stats().0 == 1)
        #expect(!backend.stats().1)
        #expect(store.key(for: "mac") == Data([1, 2, 3]))
        // Radio callbacks and retry loops must never reach securityd again.
        for _ in 0..<1_000 { _ = store.key(for: "mac") }
        #expect(backend.stats().0 == 1)
    }

    @Test func forgettingDuringLoadCannotResurrectAKey() async {
        let backend = Backend()
        backend.blocksLoad = true
        let store = store(backend)
        let loading = Task { await store.prepare() }
        await backend.waitForLoad()
        store.remove("mac")
        backend.releaseLoad.signal()
        #expect(await loading.value)
        #expect(store.key(for: "mac") == nil)
        #expect(!backend.stats().1)
    }

    @Test func persistenceCompletesOffTheMainActorBeforeAKeyIsUsable() async {
        let backend = Backend()
        let store = store(backend)
        #expect(await store.save(Data([4]), for: "new"))
        #expect(store.key(for: "new") == Data([4]))
        store.remove("new")
        #expect(store.key(for: "new") == nil)
        #expect(!backend.stats().1)
    }

    @Test func anUnavailableKeychainDoesNotBecomeAnEmptySuccessfulSnapshot() async {
        let store = RemotePairingKeyStore(load: { throw Backend.Failure.unavailable },
                                         save: { _, _ in true }, remove: { _ in true })
        #expect(!(await store.prepare()))
        #expect(!store.isPrepared)
        #expect(!(await store.save(Data([1]), for: "mac")))
        #expect(store.key(for: "mac") == nil)
    }

    @Test func forgettingWhileASaveAwaitsStartupCannotRewriteTheForgottenKey() async {
        let backend = Backend()
        backend.blocksLoad = true
        let store = store(backend)
        let saving = Task { await store.save(Data([9]), for: "mac") }
        await backend.waitForLoad()
        let removal = store.remove("mac")
        backend.releaseLoad.signal()
        #expect(!(await saving.value))
        #expect(await removal.value)
        #expect(store.key(for: "mac") == nil)
        // Only the snapshot read and deletion reached persistence, no late save.
        #expect(backend.stats().0 == 2)
    }
}
