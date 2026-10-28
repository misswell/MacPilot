import Combine
import Testing
@testable import MacPilot

@MainActor
struct DockGroupsPerformanceTests {
    @Test func unchangedRunningApplicationsDoNotPublish() {
        var running: Set<String> = ["example.app"]
        let model = DockGroupsModel(runningIdentifiers: { running })
        model.refreshRunningState()
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        model.refreshRunningState()
        #expect(publications == 0)
        running.insert("another.app")
        model.refreshRunningState()
        #expect(publications == 1)
    }
}
