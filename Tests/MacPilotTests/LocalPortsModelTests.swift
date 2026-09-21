import Foundation
import MacPilotLocalPortsCore
import Testing
@testable import MacPilot

@MainActor
struct LocalPortsModelTests {
    @Test func visibleSessionLoadsOnceAndStopsItsPolling() async throws {
        let snapshot = LocalPortSnapshot(activities: [fixtureActivity()])
        let environment = makeEnvironment(snapshot: snapshot)
        let model = LocalPortsModel(environment: environment)

        model.startVisibleSession()
        model.refreshNow()
        #expect(model.isRefreshing)

        for _ in 0..<100 where model.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.snapshot.portCount == 1)

        model.stopVisibleSession()
        #expect(!model.isRefreshing)
        model.shutdown()
        #expect(model.pendingClosePlan == nil)
    }

    @Test func oldScanResultIsIgnoredAfterVisibleSessionStops() async throws {
        let snapshot = LocalPortSnapshot(activities: [fixtureActivity()])
        let environment = makeEnvironment(snapshot: snapshot, delay: .milliseconds(80))
        let model = LocalPortsModel(environment: environment)

        model.startVisibleSession()
        model.stopVisibleSession()
        try await Task.sleep(for: .milliseconds(120))

        #expect(model.snapshot.activities.isEmpty)
        #expect(!model.isRefreshing)
    }

    private func makeEnvironment(
        snapshot: LocalPortSnapshot,
        delay: Duration = .milliseconds(1)
    ) -> LocalPortCloseEnvironment {
        LocalPortCloseEnvironment(
            scan: {
                Thread.sleep(forTimeInterval: delay == .milliseconds(1) ? 0.001 : 0.08)
                return snapshot
            },
            listenerScan: { [] },
            startTime: { _ in "start" },
            signal: { _, _ in 0 },
            sleep: { duration in try await Task.sleep(for: duration) },
            currentUID: { 501 },
            currentPID: { 999 }
        )
    }

    private func fixtureActivity() -> LocalPortActivity {
        let listener = LocalPortListener(
            pid: 42,
            command: "node",
            uid: 501,
            user: "me",
            port: 3000,
            addresses: ["127.0.0.1"]
        )
        let process = LocalPortProcess(
            pid: 42,
            ppid: 1,
            command: "node",
            executablePath: "/opt/local/bin/node",
            uid: 501,
            user: "me",
            cwd: "/tmp/project",
            uptime: "5m",
            rawElapsedTime: "05:30",
            arguments: "node server.js"
        )
        let owner = LocalPortOwner(label: "Project", category: .project, confidence: .high, reason: .unknown)
        return LocalPortActivity(
            listener: listener,
            process: process,
            parentChain: [],
            project: nil,
            application: nil,
            scope: .local,
            owner: owner
        )
    }
}
