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

    @Test func repeatedRefreshDoesNotOverlapAndReentryRefreshesImmediately() async throws {
        let snapshot = LocalPortSnapshot(activities: [fixtureActivity()])
        let recorder = ScanRecorder(snapshot: snapshot, delay: .milliseconds(25))
        let model = LocalPortsModel(environment: makeEnvironment(scan: { recorder.scan() }))

        model.startVisibleSession()
        model.refreshNow()
        for _ in 0..<100 where model.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorder.calls == 1)
        #expect(recorder.maximumActive == 1)

        model.stopVisibleSession()
        model.startVisibleSession()
        for _ in 0..<100 where model.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorder.calls == 2)
        model.shutdown()
    }

    @Test func successfulCloseClearsPlanAndRefreshesSnapshot() async throws {
        let snapshot = LocalPortSnapshot(activities: [fixtureActivity()])
        let recorder = ScanRecorder(snapshot: snapshot)
        let model = LocalPortsModel(environment: makeEnvironment(scan: { recorder.scan() }))

        model.startVisibleSession()
        try await waitForRefresh(toFinish: model)
        model.prepareClose(for: fixtureActivity())
        for _ in 0..<100 where model.pendingClosePlan == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.pendingClosePlan != nil)

        model.confirmClose()
        for _ in 0..<100 where model.isClosing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.pendingClosePlan == nil)
        #expect(model.lastCloseResult?.portFree == true)
        #expect(recorder.calls >= 4)
        model.shutdown()
    }

    @Test func failedCloseClearsPendingPlanWithoutSendingASecondSignal() async throws {
        let activity = fixtureActivity()
        let sequence = ScanSequence(values: [
            LocalPortSnapshot(activities: [activity]),
            LocalPortSnapshot(activities: [activity]),
            .empty,
        ])
        let model = LocalPortsModel(environment: makeEnvironment(scan: { sequence.next() }))

        model.startVisibleSession()
        try await waitForRefresh(toFinish: model)
        model.prepareClose(for: activity)
        for _ in 0..<100 where model.pendingClosePlan == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.pendingClosePlan != nil)

        model.confirmClose()
        for _ in 0..<100 where model.isClosing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.pendingClosePlan == nil)
        #expect(model.lastCloseError == .processDisappeared(pid: activity.process.pid))
        model.shutdown()
    }

    private func makeEnvironment(
        snapshot: LocalPortSnapshot,
        delay: Duration = .milliseconds(1)
    ) -> LocalPortCloseEnvironment {
        makeEnvironment {
            Thread.sleep(forTimeInterval: delay == .milliseconds(1) ? 0.001 : 0.08)
            return snapshot
        }
    }

    private func makeEnvironment(
        scan: @escaping @Sendable () throws -> LocalPortSnapshot
    ) -> LocalPortCloseEnvironment {
        LocalPortCloseEnvironment(
            scan: scan,
            listenerScan: { [] },
            startTime: { _ in "start" },
            signal: { _, _ in 0 },
            sleep: { duration in try await Task.sleep(for: duration) },
            currentUID: { 501 },
            currentPID: { 999 }
        )
    }

    private func waitForRefresh(toFinish model: LocalPortsModel) async throws {
        for _ in 0..<100 where model.isRefreshing {
            try await Task.sleep(for: .milliseconds(5))
        }
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
            executablePath: CommandLine.arguments.first ?? "/usr/bin/true",
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

    private final class ScanRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let snapshot: LocalPortSnapshot
        private let delay: Duration
        private(set) var calls = 0
        private(set) var active = 0
        private(set) var maximumActive = 0

        init(snapshot: LocalPortSnapshot, delay: Duration = .milliseconds(1)) {
            self.snapshot = snapshot
            self.delay = delay
        }

        func scan() -> LocalPortSnapshot {
            lock.lock()
            calls += 1
            active += 1
            maximumActive = max(maximumActive, active)
            lock.unlock()
            Thread.sleep(forTimeInterval: delay == .milliseconds(1) ? 0.001 : 0.025)
            lock.lock()
            active -= 1
            lock.unlock()
            return snapshot
        }
    }

    private final class ScanSequence: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [LocalPortSnapshot]
        private var index = 0

        init(values: [LocalPortSnapshot]) {
            self.values = values
        }

        func next() -> LocalPortSnapshot {
            lock.lock()
            defer { lock.unlock() }
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}
