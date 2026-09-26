import Foundation

/// Adapts runtimes owned by MacPilotModel without moving their state into a
/// second object. Closures must capture the model weakly to avoid a cycle.
@MainActor
final class ClosureManagedFeature: ManagedFeature {
    let identifier: String
    private let running: @MainActor () -> Bool
    private let activate: @MainActor () -> Void
    private let deactivate: @MainActor () -> Void

    var isRunning: Bool { running() }

    init(
        identifier: String,
        isRunning: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor () -> Void,
        stop: @escaping @MainActor () -> Void
    ) {
        self.identifier = identifier
        running = isRunning
        activate = start
        deactivate = stop
    }

    func start() { activate() }
    func stop() { deactivate() }
}
