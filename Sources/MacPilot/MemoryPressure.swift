import AppKit

/// One memory-pressure source for the whole process.
///
/// macOS signals pressure before it starts paging an app's dirty memory out, and
/// the only useful reaction is to hand back caches a later interaction can
/// rebuild. Registering a source per feature would mean one object per toggle
/// for the same kernel signal, so subsystems subscribe here instead.
@MainActor
final class MemoryPressure {
    static let shared = MemoryPressure()

    private var source: DispatchSourceMemoryPressure?
    private var handlers: [UUID: @MainActor () -> Void] = [:]

    /// Live subscriptions. Zero also means the kernel source is torn down, so
    /// a feature that never starts leaves nothing registered behind.
    var subscriberCount: Int { handlers.count }

    /// Subscribes for as long as the returned token is alive and not cancelled.
    /// Handlers must be cheap and non-blocking: they run on the main queue
    /// inside the kernel's pressure notification.
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        startIfNeeded()
        return token
    }

    func cancel(_ token: UUID?) {
        guard let token else { return }
        handlers[token] = nil
        guard handlers.isEmpty else { return }
        source?.cancel()
        source = nil
    }

    private func startIfNeeded() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source is bound to the main queue, so this really is the main
            // thread; `assumeIsolated` is how a dispatch callback tells Swift so.
            MainActor.assumeIsolated {
                guard let self else { return }
                for handler in self.handlers.values { handler() }
            }
        }
        self.source = source
        source.resume()
    }
}
