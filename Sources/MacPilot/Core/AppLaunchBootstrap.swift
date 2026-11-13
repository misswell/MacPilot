import AppKit
import Combine

/// The SwiftUI App initializer precedes AppKit launch registration. Do not
/// construct permission-using feature models there: an early TCC identity
/// failure can be cached for the lifetime of a login-launched process.
@MainActor
final class AppLaunchBootstrap<Value: ObservableObject>: ObservableObject {
    @Published private(set) var value: Value?
    private let makeValue: @MainActor () -> Value
    private let schedule: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var launchObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var changes: AnyCancellable?
    private var isScheduled = false
    private var isStopped = false

    init(
        center: NotificationCenter = .default,
        isLaunched: Bool = NSRunningApplication.current.isFinishedLaunching,
        schedule: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        },
        makeValue: @escaping @MainActor () -> Value
    ) {
        self.makeValue = makeValue
        self.schedule = schedule
        launchObservation = center.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleLaunch() }
            }
        terminationObservation = center.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        if isLaunched { scheduleLaunch() }
    }

    private func scheduleLaunch() {
        guard !isStopped, !isScheduled, value == nil else { return }
        isScheduled = true
        launchObservation = nil
        // Finish the entire launch notification before touching TCC or starting
        // features. A fixed delay is neither a launch boundary nor a repair.
        schedule { [weak self] in
            guard let self, !self.isStopped else { return }
            let value = self.makeValue()
            self.changes = value.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            self.value = value
        }
    }

    func stop() {
        isStopped = true
        launchObservation = nil
        terminationObservation = nil
    }
}
