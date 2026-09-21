// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import Darwin
import Foundation

public struct LocalPortCloseEnvironment: Sendable {
    public typealias Scan = @Sendable () throws -> LocalPortSnapshot
    public typealias ListenerScan = @Sendable () throws -> [LocalPortListener]
    public typealias StartTime = @Sendable (Int32) -> String?
    public typealias Signal = @Sendable (Int32, Int32) -> Int32
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias IntValue = @Sendable () -> Int32

    public let scan: Scan
    public let listenerScan: ListenerScan
    public let startTime: StartTime
    public let signal: Signal
    public let sleep: Sleep
    public let currentUID: IntValue
    public let currentPID: IntValue

    public init(
        scan: @escaping Scan,
        listenerScan: @escaping ListenerScan,
        startTime: @escaping StartTime,
        signal: @escaping Signal,
        sleep: @escaping Sleep,
        currentUID: @escaping IntValue,
        currentPID: @escaping IntValue
    ) {
        self.scan = scan
        self.listenerScan = listenerScan
        self.startTime = startTime
        self.signal = signal
        self.sleep = sleep
        self.currentUID = currentUID
        self.currentPID = currentPID
    }

    public static var live: LocalPortCloseEnvironment {
        LocalPortCloseEnvironment(
            scan: { try LocalPortScanner.scan() },
            listenerScan: { try LocalPortScanner.scanListeners() },
            startTime: { LocalPortCloseService.processStartTime(for: $0) },
            signal: { pid, signal in
                Darwin.kill(pid, signal) == 0 ? 0 : errno
            },
            sleep: { duration in try await Task.sleep(for: duration) },
            currentUID: { Int32(getuid()) },
            currentPID: { Int32(getpid()) }
        )
    }
}

public enum LocalPortCloseService {
    public static func protectionReason(for activity: LocalPortActivity) -> LocalPortProtectionReason? {
        protectionReason(
            for: activity,
            currentUID: Int32(getuid()),
            currentPID: Int32(getpid())
        )
    }

    /// What blocks a stop request.  Only a limit that is actually real: MacPilot
    /// must not signal itself or launchd, and `kill` cannot reach another user's
    /// process.  How the process happened to be started — an `.app` bundle, an
    /// interpreter under `/usr/bin`, a binary deleted after launch — says nothing
    /// about whether it may be stopped, so none of that is a reason to refuse.
    public static func protectionReason(
        for activity: LocalPortActivity,
        currentUID: Int32,
        currentPID: Int32
    ) -> LocalPortProtectionReason? {
        let process = activity.process
        guard currentUID != 0 else { return .runningAsRoot }
        guard process.pid > 1, process.pid != currentPID else { return .protectedPID(process.pid) }
        guard let uid = process.uid else { return .unknownUser(process.pid) }
        guard uid == currentUID else { return .anotherUser(process.pid) }
        return nil
    }

    public static func prepare(
        port: Int,
        pid: Int32? = nil,
        environment: LocalPortCloseEnvironment = .live
    ) throws -> LocalPortClosePlan {
        let snapshot = try environment.scan()
        return try makePlan(
            activities: snapshot.activities,
            port: port,
            pid: pid,
            currentUID: environment.currentUID(),
            currentPID: environment.currentPID(),
            startTime: environment.startTime
        )
    }

    public static func makePlan(
        activities: [LocalPortActivity],
        port: Int,
        pid: Int32?,
        currentUID: Int32,
        currentPID: Int32,
        startTime: @escaping @Sendable (Int32) -> String?
    ) throws -> LocalPortClosePlan {
        let matches = activities.filter { $0.listener.port == port }
        guard !matches.isEmpty else { throw LocalPortCloseError.nothingListening(port: port) }

        let pids = Array(Set(matches.map(\.process.pid))).sorted()
        guard pid != nil || pids.count == 1 else {
            throw LocalPortCloseError.multipleOwners(port: port, pids: pids)
        }

        let selectedPID = pid ?? pids[0]
        guard let activity = matches.first(where: { $0.process.pid == selectedPID }) else {
            throw LocalPortCloseError.processNotListening(pid: selectedPID, port: port)
        }

        if let reason = protectionReason(for: activity, currentUID: currentUID, currentPID: currentPID) {
            throw LocalPortCloseError.protected(reason)
        }
        guard let uid = activity.process.uid else {
            throw LocalPortCloseError.missingIdentity(pid: selectedPID)
        }
        guard let processStartTime = startTime(selectedPID) else {
            throw LocalPortCloseError.missingStartTime(pid: selectedPID)
        }

        let otherPorts = Array(Set(activities.filter {
            $0.process.pid == selectedPID && $0.listener.port != port
        }.map(\.listener.port))).sorted()

        return LocalPortClosePlan(
            port: port,
            pid: selectedPID,
            uid: uid,
            executablePath: activity.process.executablePath,
            processStartTime: processStartTime,
            activity: activity,
            otherPorts: otherPorts,
            peerPIDs: pids.filter { $0 != selectedPID }
        )
    }

    public static func verify(
        plan: LocalPortClosePlan,
        activities: [LocalPortActivity],
        freshStartTime: String?,
        currentUID: Int32 = Int32(getuid()),
        currentPID: Int32 = Int32(getpid())
    ) throws {
        let matches = activities.filter { $0.listener.port == plan.port }
        guard let activity = matches.first(where: { $0.process.pid == plan.pid }) else {
            throw LocalPortCloseError.processDisappeared(pid: plan.pid)
        }

        let freshPeers = Set(matches.map(\.process.pid)).subtracting([plan.pid])
        if let newPID = freshPeers.subtracting(plan.peerPIDs).sorted().first {
            throw LocalPortCloseError.newPortOwner(port: plan.port, pid: newPID)
        }

        guard freshStartTime == plan.processStartTime,
              activity.process.uid == plan.uid,
              activity.process.executablePath == plan.executablePath else {
            throw LocalPortCloseError.identityChanged(pid: plan.pid)
        }

        if let reason = protectionReason(for: activity, currentUID: currentUID, currentPID: currentPID) {
            throw LocalPortCloseError.protected(reason)
        }
    }

    public static func execute(
        _ plan: LocalPortClosePlan,
        environment: LocalPortCloseEnvironment = .live
    ) async throws -> LocalPortCloseResult {
        let freshSnapshot: LocalPortSnapshot
        do {
            freshSnapshot = try environment.scan()
        } catch {
            throw LocalPortCloseError.verificationFailed
        }

        guard let freshStartTime = environment.startTime(plan.pid) else {
            throw LocalPortCloseError.missingStartTime(pid: plan.pid)
        }

        try verify(
            plan: plan,
            activities: freshSnapshot.activities,
            freshStartTime: freshStartTime,
            currentUID: environment.currentUID(),
            currentPID: environment.currentPID()
        )

        let signalStatus = environment.signal(plan.pid, Int32(SIGTERM))
        guard signalStatus == 0 else {
            throw LocalPortCloseError.signalFailed(pid: plan.pid, errno: signalStatus)
        }

        var latest: [LocalPortListener] = []
        for _ in 0..<10 {
            try await environment.sleep(.milliseconds(500))
            do {
                latest = try environment.listenerScan().filter { $0.port == plan.port }
            } catch {
                throw LocalPortCloseError.rescanFailed
            }
            if !latest.contains(where: { $0.pid == plan.pid }) { break }
        }

        return LocalPortCloseResult(
            targetStoppedListening: !latest.contains(where: { $0.pid == plan.pid }),
            portFree: latest.isEmpty,
            remainingPIDs: Array(Set(latest.map(\.pid))).sorted()
        )
    }

    public static func processStartTime(for pid: Int32) -> String? {
        guard let output = try? LocalPortCommandRunner.output(
            "/bin/ps",
            ["-p", String(pid), "-o", "lstart="]
        ) else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
