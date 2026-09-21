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

    @Test func appAndSystemPathProcessesAreClosable() {
        let uid = Int32(getuid())

        // A dev server launched by a browser owns nothing special: same user,
        // so it must be stoppable even though it resolves to an `.app` bundle.
        let app = makeActivity(
            pid: 42,
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            uid: uid,
            application: LocalPortApplication(
                name: "Google Chrome",
                path: "/Applications/Google Chrome.app",
                sourcePID: 42,
                direct: true
            )
        )
        #expect(LocalPortCloseService.protectionReason(for: app, currentUID: uid, currentPID: 99) == nil)

        let system = makeActivity(pid: 42, path: "/usr/bin/python3", uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: system, currentUID: uid, currentPID: 99) == nil)

        // A binary replaced or deleted after launch is the normal state of a
        // watch-mode dev server; it must not lock the port away from the user.
        let rebuilt = makeActivity(pid: 42, path: "/definitely/missing/local-port-executable", uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: rebuilt, currentUID: uid, currentPID: 99) == nil)

        let plan = try? LocalPortCloseService.makePlan(
            activities: [app],
            port: 3000,
            pid: nil,
            currentUID: uid,
            currentPID: 99,
            startTime: { _ in "start" }
        )
        #expect(plan?.executablePath == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    @Test func protectionRulesRejectOnlyProcessesMacPilotCannotSignal() {
        let uid = Int32(getuid())

        let root = makeActivity(pid: 42, uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: root, currentUID: 0, currentPID: 99) == .runningAsRoot)

        let otherUser = makeActivity(pid: 42, uid: uid + 1)
        #expect(LocalPortCloseService.protectionReason(for: otherUser, currentUID: uid, currentPID: 99) == .anotherUser(42))

        let missingExecutable = makeActivity(pid: 42, path: nil, uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: missingExecutable, currentUID: uid, currentPID: 99) == nil)
    }

    @Test func protectionRulesRejectProtectedPIDsAndMissingUsers() {
        let uid = Int32(getuid())
        let initProcess = makeActivity(pid: 1, uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: initProcess, currentUID: uid, currentPID: 99) == .protectedPID(1))

        let ownProcess = makeActivity(pid: 42, uid: uid)
        #expect(LocalPortCloseService.protectionReason(for: ownProcess, currentUID: uid, currentPID: 42) == .protectedPID(42))

        let missingUser = makeActivity(pid: 42, uid: nil)
        #expect(LocalPortCloseService.protectionReason(for: missingUser, currentUID: uid, currentPID: 99) == .unknownUser(42))
    }

    @Test func verifyRejectsPidReuseAndNewPortOwner() throws {
        let uid = Int32(getuid())
        let original = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: original.process.executablePath,
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

        #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [makeActivity(pid: 42, uid: uid + 1)],
                freshStartTime: "start-one",
                currentUID: uid,
                currentPID: 99
            )
        }
        #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [original],
                freshStartTime: "start-two",
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
            executablePath: activity.process.executablePath,
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

    @Test func executeRefusesMissingStartTimeBeforeSendingSignal() async {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: activity.process.executablePath,
            processStartTime: "start",
            activity: activity,
            otherPorts: [],
            peerPIDs: []
        )
        let recorder = SignalRecorder()
        let environment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) },
            listenerScan: { [] },
            startTime: { _ in nil },
            signal: { _, signal in recorder.record(signal); return 0 },
            sleep: { _ in },
            currentUID: { uid },
            currentPID: { 999 }
        )

        await #expect(throws: LocalPortCloseError.missingStartTime(pid: 42)) {
            try await LocalPortCloseService.execute(plan, environment: environment)
        }
        #expect(recorder.value == nil)
    }

    private func makeActivity(
        pid: Int32,
        port: Int = 3000,
        path: String? = CommandLine.arguments.first ?? "/usr/bin/true",
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
