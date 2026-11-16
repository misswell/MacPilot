import Foundation
import os

/// Bounds concurrent full-image work (crop, composite, output styling,
/// encoding). A burst of captures must not hold several 5K buffers at once,
/// so throughput is deliberately capped instead of scaling with the burst.
/// ScreenCaptureKit keeps its own serial display-capture policy; this gate
/// only covers post-capture work that runs off the main actor.
final class CaptureImageWorkGate: @unchecked Sendable {
    static let shared = CaptureImageWorkGate(limit: 2)

    private struct State {
        var active = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        let acquired = state.withLockUnchecked { state -> Bool in
            guard state.active < limit else { return false }
            state.active += 1
            return true
        }
        guard !acquired else { return }

        await withCheckedContinuation { continuation in
            let acquiredNow = state.withLockUnchecked { state -> Bool in
                guard state.active < limit else {
                    state.waiters.append(continuation)
                    return false
                }
                state.active += 1
                return true
            }
            if acquiredNow { continuation.resume() }
        }
    }

    func release() {
        let next = state.withLockUnchecked { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.active = max(0, state.active - 1)
                return nil
            }
            return state.waiters.removeFirst()
        }
        // The permit transfers to the resumed waiter; `active` is unchanged.
        next?.resume()
    }

    /// Runs synchronous image work while holding a permit. Call from inside a
    /// detached task so the work never lands on the main actor.
    func withPermit<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try work()
    }
}
