import Foundation

/// A cancellable, coalescing poll loop. Actions run on the main actor and
/// never run after a cancelled sleep, unlike a `try?` sleep loop.
@MainActor
final class BackgroundTask {
    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) static var activeCount = 0

    func start(interval: Duration, action: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        isRunning = true
        Self.activeCount += 1
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled, self?.isRunning == true else { break }
                action()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        task?.cancel()
        task = nil
        Self.activeCount -= 1
    }

    deinit {
        task?.cancel()
    }
}
