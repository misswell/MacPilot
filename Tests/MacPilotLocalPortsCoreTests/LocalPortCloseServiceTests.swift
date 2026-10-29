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
            identity: { pid in Self.identity(pid: pid, uid: uid) }
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
                identity: { pid in Self.identity(pid: pid, uid: uid) }
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
            identity: { pid in Self.identity(pid: pid, uid: uid, path: app.process.executablePath!) }
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
            processIdentity: Self.identity(uid: uid),
            activity: original,
            otherPorts: [],
            peerPIDs: []
        )

        #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [makeActivity(pid: 42, path: "/opt/local/bin/python", uid: uid)],
                freshIdentity: Self.identity(uid: uid),
                currentUID: uid,
                currentPID: 99
            )
        }
        #expect(throws: LocalPortCloseError.newPortOwner(port: 3000, pid: 43)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [original, makeActivity(pid: 43, uid: uid)],
                freshIdentity: Self.identity(uid: uid),
                currentUID: uid,
                currentPID: 99
            )
        }

        #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [makeActivity(pid: 42, uid: uid + 1)],
                freshIdentity: Self.identity(uid: uid),
                currentUID: uid,
                currentPID: 99
            )
        }
        #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try LocalPortCloseService.verify(
                plan: plan,
                activities: [original],
                freshIdentity: Self.identity(uid: uid, microseconds: 2),
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
            processIdentity: Self.identity(uid: uid),
            activity: activity,
            otherPorts: [],
            peerPIDs: []
        )
        let recorder = SignalRecorder()
        let environment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) },
            listenerScan: { [] },
            identity: { pid in Self.identity(pid: pid, uid: uid) },
            signal: { _, signal in recorder.record(signal); return 0 },
            sleep: { _ in },
            currentUID: { uid },
            currentPID: { 99 }
        )

        let result = try await LocalPortCloseService.execute(plan, environment: environment)
        #expect(recorder.value == Int32(SIGTERM))
        #expect(result.targetStoppedListening)
        #expect(result.portFree)
        #expect(!result.forceKill)
    }

    @Test func executeWithForceKillSendsSigkill() async throws {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: activity.process.executablePath,
            processIdentity: Self.identity(uid: uid),
            activity: activity,
            otherPorts: [],
            peerPIDs: []
        )
        let recorder = SignalRecorder()
        let environment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) },
            listenerScan: { [] },
            identity: { pid in Self.identity(pid: pid, uid: uid) },
            signal: { _, signal in recorder.record(signal); return 0 },
            sleep: { _ in },
            currentUID: { uid },
            currentPID: { 99 }
        )

        let result = try await LocalPortCloseService.execute(
            plan,
            forceKill: true,
            environment: environment
        )
        #expect(recorder.value == Int32(SIGKILL))
        #expect(result.targetStoppedListening)
        #expect(result.portFree)
        #expect(result.forceKill)
    }

    @Test func aFailedForceKillSaysWhichSignalWasRefused() async {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: activity.process.executablePath,
            processIdentity: Self.identity(uid: uid),
            activity: activity,
            otherPorts: [],
            peerPIDs: []
        )
        let environment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) },
            listenerScan: { [] },
            identity: { pid in Self.identity(pid: pid, uid: uid) },
            signal: { _, _ in EPERM },
            sleep: { _ in },
            currentUID: { uid },
            currentPID: { 99 }
        )

        await #expect(throws: LocalPortCloseError.signalFailed(
            pid: 42,
            errno: EPERM,
            forceKill: true
        )) {
            try await LocalPortCloseService.execute(
                plan,
                forceKill: true,
                environment: environment
            )
        }
    }

    @Test func executeRefusesMissingStartTimeBeforeSendingSignal() async {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = LocalPortClosePlan(
            port: 3000,
            pid: 42,
            uid: uid,
            executablePath: activity.process.executablePath,
            processIdentity: Self.identity(uid: uid),
            activity: activity,
            otherPorts: [],
            peerPIDs: []
        )
        let recorder = SignalRecorder()
        let environment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) },
            listenerScan: { [] },
            identity: { _ in nil },
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

    @Test func bothSignalsRefuseReusedPIDsIncompleteIdentityAndNewOwners() async throws {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = try LocalPortCloseService.makePlan(
            activities: [activity], port: 3000, pid: nil, currentUID: uid, currentPID: 99,
            identity: { _ in Self.identity(uid: uid) }
        )
        for force in [false, true] {
            for scenario in 0..<4 {
                let recorder = SignalRecorder()
                let activities = scenario == 2 ? [activity, makeActivity(pid: 43, uid: uid)] : (scenario == 3 ? [] : [activity])
                let environment = LocalPortCloseEnvironment(
                    scan: { LocalPortSnapshot(activities: activities) }, listenerScan: { [] },
                    identity: { _ in scenario == 1 ? nil : Self.identity(uid: uid, microseconds: scenario == 0 ? 2 : 1) },
                    signal: { _, signal in recorder.record(signal); return 0 }, sleep: { _ in },
                    currentUID: { uid }, currentPID: { 99 }
                )
                await #expect(throws: LocalPortCloseError.self) {
                    try await LocalPortCloseService.execute(plan, forceKill: force, environment: environment)
                }
                #expect(recorder.value == nil)
            }
        }
    }

    @Test func timeoutDoesNotEscalateAndLaterForceRequestRevalidates() async throws {
        let uid = Int32(getuid())
        let activity = makeActivity(pid: 42, uid: uid)
        let plan = try LocalPortCloseService.makePlan(
            activities: [activity], port: 3000, pid: nil, currentUID: uid, currentPID: 99,
            identity: { _ in Self.identity(uid: uid) }
        )
        let recorder = SignalRecorder()
        let termEnvironment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) }, listenerScan: { [activity.listener] },
            identity: { _ in Self.identity(uid: uid) },
            signal: { _, signal in recorder.record(signal); return 0 }, sleep: { _ in },
            currentUID: { uid }, currentPID: { 99 }
        )
        let timedOut = try await LocalPortCloseService.execute(plan, environment: termEnvironment)
        #expect(!timedOut.targetStoppedListening)
        #expect(recorder.value == Int32(SIGTERM))
        let forceEnvironment = LocalPortCloseEnvironment(
            scan: { LocalPortSnapshot(activities: [activity]) }, listenerScan: { [] },
            identity: { _ in Self.identity(uid: uid, microseconds: 2) },
            signal: { _, signal in recorder.record(signal); return 0 }, sleep: { _ in },
            currentUID: { uid }, currentPID: { 99 }
        )
        await #expect(throws: LocalPortCloseError.identityChanged(pid: 42)) {
            try await LocalPortCloseService.execute(plan, forceKill: true, environment: forceEnvironment)
        }
        #expect(recorder.value == Int32(SIGTERM))
    }

    @Test func preparationRefusesMissingExecutablePath() {
        let uid = Int32(getuid())
        #expect(throws: LocalPortCloseError.missingStartTime(pid: 42)) {
            try LocalPortCloseService.makePlan(
                activities: [makeActivity(pid: 42, path: nil, uid: uid)], port: 3000, pid: nil,
                currentUID: uid, currentPID: 99, identity: { _ in Self.identity(uid: uid) }
            )
        }
    }

    private static func identity(pid: Int32 = 42, uid: Int32, microseconds: UInt64 = 1, path: String = CommandLine.arguments.first ?? "/usr/bin/true") -> LocalPortProcessIdentity {
        LocalPortProcessIdentity(pid: pid, uid: uid, startSeconds: 100, startMicroseconds: microseconds, executablePath: path)
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
