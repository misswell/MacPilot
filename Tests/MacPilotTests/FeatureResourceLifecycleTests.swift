import Foundation
import Testing
@testable import MacPilot

@MainActor
private final class CountedFeature: ManagedFeature, FeatureResourceReporting {
    let identifier = "counted-resource-test"
    private(set) var isRunning = false
    private let loop = BackgroundTask()
    private let observers = ObserverBag()

    var diagnosticTaskCount: Int { loop.isRunning ? 1 : 0 }
    var diagnosticObserverCount: Int { observers.count }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        loop.start(interval: .seconds(60)) {}
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("CountedFeatureProbe"), object: nil, queue: nil
        ) { _ in }
        observers.add(token)
    }

    func stop() {
        guard isRunning else { return }
        loop.stop()
        observers.removeAll()
        isRunning = false
    }
}

@Suite(.serialized)
@MainActor
struct FeatureResourceLifecycleTests {
    @Test func oneHundredStartStopCyclesReleaseTrackedTasksAndObservers() {
        let baselineTasks = BackgroundTask.activeCount
        let baselineObservers = ObserverBag.activeCount
        let manager = FeatureLifecycleManager()
        let feature = CountedFeature()
        manager.register(feature)

        for _ in 0..<100 {
            manager.start(feature.identifier)
            let running = manager.diagnostics().first
            #expect(running?.isRunning == true)
            #expect(running?.startedAt != nil)
            #expect(running?.taskCount == 1)
            #expect(running?.observerCount == 1)

            manager.stop(feature.identifier)
            let stopped = manager.diagnostics().first
            #expect(stopped?.isRunning == false)
            #expect(stopped?.stoppedAt != nil)
            #expect(stopped?.taskCount == 0)
            #expect(stopped?.observerCount == 0)
            #expect(BackgroundTask.activeCount == baselineTasks)
            #expect(ObserverBag.activeCount == baselineObservers)
        }
        manager.unregister(feature.identifier)
        #expect(manager.diagnostics().isEmpty)
    }

    @Test func timerRegistryReturnsToBaselineAfterCancellation() {
        let baseline = TimerRegistry.activeCount
        let token = UUID()
        TimerRegistry.register(token)
        #expect(TimerRegistry.activeCount == baseline + 1)
        TimerRegistry.unregister(token)
        #expect(TimerRegistry.activeCount == baseline)
    }
}
