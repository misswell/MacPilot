import Foundation
import Testing
@testable import MacPilot

@MainActor
private final class StubManagedFeature: ManagedFeature {
    let identifier = "stub"
    private(set) var isRunning = false
    private(set) var starts = 0
    private(set) var stops = 0

    func start() {
        isRunning = true
        starts += 1
    }

    func stop() {
        isRunning = false
        stops += 1
    }
}

@Suite(.serialized) @MainActor
struct ResourceLifecycleTests {
    @Test func repeatedStartStopReleasesManagedTasksAndObservers() {
        final class CyclingFeature: ManagedFeature {
            let identifier = "cycling"
            private(set) var isRunning = false
            let observers = ObserverBag()
            let task = BackgroundTask()
            let center = NotificationCenter()

            func start() {
                guard !isRunning else { return }
                isRunning = true
                observers.add(center.addObserver(forName: Notification.Name("tick"), object: nil, queue: nil) { _ in }, center: center)
                task.start(interval: .seconds(60)) {}
            }

            func stop() {
                isRunning = false
                task.stop()
                observers.removeAll()
            }
        }

        let initialTasks = BackgroundTask.activeCount
        let initialObservers = ObserverBag.activeCount
        let manager = FeatureLifecycleManager()
        let feature = CyclingFeature()
        manager.register(feature)
        for _ in 0..<100 {
            manager.start(feature.identifier)
            #expect(BackgroundTask.activeCount == initialTasks + 1)
            #expect(ObserverBag.activeCount == initialObservers + 1)
            manager.stop(feature.identifier)
            #expect(BackgroundTask.activeCount == initialTasks)
            #expect(ObserverBag.activeCount == initialObservers)
        }
        #expect(manager.activeIdentifiers.isEmpty)
    }

    @Test func lifecycleStartsOnceAndStopsOnUnregister() {
        let manager = FeatureLifecycleManager()
        let feature = StubManagedFeature()
        manager.register(feature)

        manager.start(feature.identifier)
        manager.start(feature.identifier)
        #expect(feature.starts == 1)
        #expect(manager.activeIdentifiers == [feature.identifier])

        manager.unregister(feature.identifier)
        #expect(feature.stops == 1)
        #expect(manager.activeIdentifiers.isEmpty)
    }

    @Test func stopAlsoReleasesAFeatureWithoutAnActiveRuntime() {
        let manager = FeatureLifecycleManager()
        let feature = StubManagedFeature()
        manager.register(feature)
        manager.stop(feature.identifier)
        #expect(feature.stops == 1)
    }

    @Test func cancelledBackgroundTaskNeverRunsItsAction() async throws {
        let baseline = BackgroundTask.activeCount
        let polling = BackgroundTask()
        var actions = 0
        polling.start(interval: .milliseconds(50)) { actions += 1 }
        #expect(BackgroundTask.activeCount == baseline + 1)
        polling.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(actions == 0)
        #expect(BackgroundTask.activeCount == baseline)
    }

    @Test func oneShotTaskReleasesItsSlotAfterFiring() async throws {
        let baseline = BackgroundTask.activeCount
        var fired = false
        let timer = BackgroundTask.once(after: 0.01) { fired = true }
        #expect(timer.isRunning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired)
        #expect(!timer.isRunning)
        #expect(BackgroundTask.activeCount == baseline)
    }
}
