import Darwin
import Foundation
import Testing
@testable import MacPilotLocalPortsCore

struct LocalPortCloseServiceTests {
    @Test func makePlanReportsOtherPortsAndRejectsAmbiguousOwners() throws {
        let uid = Int32(getuid())
        let sameProcess = makeActivity(pid: 42, port: 3000, uid: uid)
        let otherPort = makeActivity(pid: 42, port: 3001, uid: uid)
        let peer = makeActivity(pid: 43, port: 3000, uid: uid)

        let plan = try LocalPortCloseService.makePlan(
            activities: [sameProcess, otherPort],
            port: 3000,
            pid: nil,
            currentUID: uid,
            currentPID: 99,
            startTime: { _ in "start" }
        )
        #expect(plan.otherPorts == [3001])
        #expect(plan.peerPIDs.isEmpty)

        #expect(throws: LocalPortCloseError.multipleOwners(port: 3000, pids: [42, 43])) {
            try LocalPortCloseService.makePlan(
                activities: [sameProcess, peer],
                port: 3000,
                pid: nil,
                currentUID: uid,
                currentPID: 99,
                startTime: { _ in "start" }
            )
        }
    }

    @Test func protectionRulesRejectRootSystemAppAndOtherUser() {
        let uid = Int32(getuid())
        let safe = makeActivity(pid: 42, uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: safe, currentUID: uid, currentPID: 99) == nil)

        let root = makeActivity(pid: 42, uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: root, currentUID: 0, currentPID: 99) == .runningAsRoot)

        let system = makeActivity(pid: 42, path: "/usr/bin/python3", uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: system, currentUID: uid, currentPID: 99) == .systemExecutable(path: "/usr/bin/python3"))

        let otherUser = makeActivity(pid: 42, uid: uid + 1)
        #expect(LocalPortCloseService.protectionReason(for: otherUser, currentUID: uid, currentPID: 99) == .anotherUser(42))

        let app = makeActivity(pid: 42, uid: uid, application: LocalPortApplication(name: "Test", path: "/Applications/Test.app", sourcePID: 42, direct: true))
        #expect(LocalPortCloseService.protectionReason(for: app, currentUID: uid, currentPID: 99) == .applicationBundle(path: "/Applications/Test.app"))
    }

    @Test func verifyRejectsPidReuseAndNewPortOwner() throws {
        let uid = Int32(getuid())
        let original = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: "/opt/local/bin/node",
            processStartTime: "start-one",
            activity: original,
            otherPorts: [],
            peerPIDs: []
        )

        #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [makeActivity(pid: 42, path: "/opt/local/bin/python", uid: uid)],
                freshStartTime: "start-one",
                currentUID: uid,
                currentPID: 99
            )
        }
        #expect(throws: LocalPortCloseError.newPortOwner(port: 3000, pid: 43)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [original, makeActivity(pid: 43, uid: uid)],
                freshStartTime: "start-one",
                currentUID: uid,
                currentPID: 99
            )
        }
    }

    @Test func executeSendsOnlySigtermAndReportsReleasedPort() async throws {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: "/opt/local/bin/node",
            processStartTime: "start",
            activity: activity,
            otherPorts: [],
            peerPIDs: []
        )
        let recorder = SignalRecorder()
        let environment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) },
            listenerScan: { [] },
            startTime: { _ in "start" },
            signal: { _, signal in recorder.record(signal); return 0 },
            sleep: { _ in },
            currentUID: { uid },
            currentPID: { 99 }
        )

        let result = try await LocalPortCloseService.execute(plan, environment: environment)
        #expect(recorder.value == Int32(SIGTERM))
        #expect(result.targetStoppedListening)
        #expect(result.portFree)
    }

    private func makeActivity(
        pid: Int32,
        port: Int = 3000,
        path: String = "/opt/local/bin/node",
        uid: Int32?,
        application: LocalPortApplication? = nil
    ) -> LocalPortActivity {
        let listener = LocalPortListener(
            pid: pid,
            command: "node",
            uid: uid,
            user: "me",
            port: port,
            addresses: ["127.0.0.1"]
        )
        let process = LocalPortProcess(
            pid: pid,
            ppid: nil,
            command: "node",
            executablePath: path,
            uid: uid,
            user: "me",
            cwd: "/tmp/project"
        )
        let owner = LocalPortOwner(label: "Project", category: .project, confidence: .high, reason: .unknown)
        return LocalPortActivity(
            listener: listener,
            process: process,
            parentChain: [],
            project: nil,
            application: application,
            scope: .local,
            owner: owner
        )
    }

    private final class SignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value: Int32?

        func record(_ signal: Int32) {
            lock.lock()
            value = signal
            lock.unlock()
        }
    }
}
