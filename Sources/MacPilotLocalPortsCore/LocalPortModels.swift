// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Whether a listener is bound only to loopback or to an address that may be
/// reachable from the local network.  This is an observation about the bind
/// address, not a firewall verdict.
public enum LocalPortScope: String, Codable, Sendable, Equatable {
    case local
    case lan
}

public enum LocalPortOwnerCategory: String, Codable, Sendable, Equatable {
    case project
    case application
    case service
    case systemService
    case unknown
}

public enum LocalPortConfidence: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low
    case none
}

/// Structured evidence for the owner inference.  User-facing wording stays
/// in MacPilot's AppText tables; the core only carries facts.
public enum LocalPortOwnerReason: Sendable, Equatable {
    case project(marker: String, markerPath: String)
    case directApplication(path: String)
    case parentApplication(pid: Int32, path: String)
    case systemExecutable(path: String)
    case nodePackage(name: String, directory: String)
    case pythonModule(name: String)
    case knownService(name: String)
    case userInstalledExecutable(path: String)
    case unknown
}

public struct LocalPortListener: Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let uid: Int32?
    public let user: String?
    public let port: Int
    public var addresses: [String]

    public init(
        pid: Int32,
        command: String,
        uid: Int32?,
        user: String?,
        port: Int,
        addresses: [String]
    ) {
        self.pid = pid
        self.command = command
        self.uid = uid
        self.user = user
        self.port = port
        self.addresses = addresses
    }
}

public struct LocalPortProcess: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32?
    public let command: String
    public let executablePath: String?
    public let uid: Int32?
    public let user: String?
    public let cwd: String?
    public let uptime: String?
    public let rawElapsedTime: String?
    public let arguments: String?
    public let startTime: String?

    public init(
        pid: Int32,
        ppid: Int32?,
        command: String,
        executablePath: String?,
        uid: Int32?,
        user: String?,
        cwd: String?,
        uptime: String? = nil,
        rawElapsedTime: String? = nil,
        arguments: String? = nil,
        startTime: String? = nil
    ) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.executablePath = executablePath
        self.uid = uid
        self.user = user
        self.cwd = cwd
        self.uptime = uptime
        self.rawElapsedTime = rawElapsedTime
        self.arguments = arguments
        self.startTime = startTime
    }

    public var compactUptime: String? {
        guard let rawElapsedTime else { return uptime }
        return LocalPortUptimeFormatter.format(etime: rawElapsedTime, compact: true) ?? uptime
    }
}

public struct LocalPortProject: Sendable, Equatable {
    public let name: String
    public let root: String
    public let marker: String
    public let markerPath: String

    public init(name: String, root: String, marker: String, markerPath: String) {
        self.name = name
        self.root = root
        self.marker = marker
        self.markerPath = markerPath
    }
}

public struct LocalPortApplication: Sendable, Equatable {
    public let name: String
    public let path: String
    public let sourcePID: Int32
    public let direct: Bool

    public init(name: String, path: String, sourcePID: Int32, direct: Bool) {
        self.name = name
        self.path = path
        self.sourcePID = sourcePID
        self.direct = direct
    }
}

public struct LocalPortOwner: Sendable, Equatable {
    public let label: String
    public let category: LocalPortOwnerCategory
    public let confidence: LocalPortConfidence
    public let reason: LocalPortOwnerReason

    public init(
        label: String,
        category: LocalPortOwnerCategory,
        confidence: LocalPortConfidence,
        reason: LocalPortOwnerReason
    ) {
        self.label = label
        self.category = category
        self.confidence = confidence
        self.reason = reason
    }
}

public struct LocalPortActivity: Sendable, Equatable, Identifiable {
    public let listener: LocalPortListener
    public let process: LocalPortProcess
    public let parentChain: [LocalPortProcess]
    public let project: LocalPortProject?
    public let application: LocalPortApplication?
    public let scope: LocalPortScope
    public let owner: LocalPortOwner

    public init(
        listener: LocalPortListener,
        process: LocalPortProcess,
        parentChain: [LocalPortProcess],
        project: LocalPortProject?,
        application: LocalPortApplication?,
        scope: LocalPortScope,
        owner: LocalPortOwner
    ) {
        self.listener = listener
        self.process = process
        self.parentChain = parentChain
        self.project = project
        self.application = application
        self.scope = scope
        self.owner = owner
    }

    public var id: String { "\(listener.port):\(listener.pid)" }
}

public enum LocalPortScanLimitation: String, Codable, Sendable, Equatable {
    case processTableUnavailable
    case cwdUnavailable
    case executableUnavailable
    case argumentsUnavailable
    case startTimeUnavailable
}

public struct LocalPortSnapshot: Sendable, Equatable {
    public let activities: [LocalPortActivity]
    public let limitations: [LocalPortScanLimitation]

    public init(activities: [LocalPortActivity], limitations: [LocalPortScanLimitation] = []) {
        self.activities = activities
        self.limitations = limitations
    }

    public static let empty = LocalPortSnapshot(activities: [])

    public var portCount: Int {
        Set(activities.map(\.listener.port)).count
    }

    public var processCount: Int {
        Set(activities.map(\.process.pid)).count
    }

    public var projectPortCount: Int {
        Set(activities.filter { $0.owner.category == .project }.map(\.listener.port)).count
    }

    public var lanPortCount: Int {
        Set(activities.filter { $0.scope == .lan }.map(\.listener.port)).count
    }

    public var closablePortCount: Int {
        Set(activities.filter { LocalPortCloseService.protectionReason(for: $0) == nil }
            .map(\.listener.port)).count
    }
}

public enum LocalPortProtectionReason: Sendable, Equatable {
    case runningAsRoot
    case protectedPID(Int32)
    case unknownUser(Int32)
    case anotherUser(Int32)
    case unknownExecutable(Int32)
    case systemExecutable(path: String)
    case applicationBundle(path: String)
}

public enum LocalPortScanError: Error, Sendable, Equatable {
    case commandFailed(command: String, status: Int32)
    case missingTool(path: String)
}

public enum LocalPortCloseError: Error, Sendable, Equatable {
    case nothingListening(port: Int)
    case multipleOwners(port: Int, pids: [Int32])
    case processNotListening(pid: Int32, port: Int)
    case protected(LocalPortProtectionReason)
    case missingIdentity(pid: Int32)
    case missingStartTime(pid: Int32)
    case processDisappeared(pid: Int32)
    case newPortOwner(port: Int, pid: Int32)
    case identityChanged(pid: Int32)
    case signalFailed(pid: Int32, errno: Int32)
    case verificationFailed
    case rescanFailed
}

public struct LocalPortClosePlan: Sendable, Equatable, Identifiable {
    public let port: Int
    public let pid: Int32
    public let uid: Int32
    public let executablePath: String
    public let processStartTime: String
    public let activity: LocalPortActivity
    public let otherPorts: [Int]
    public let peerPIDs: [Int32]

    public init(
        port: Int,
        pid: Int32,
        uid: Int32,
        executablePath: String,
        processStartTime: String,
        activity: LocalPortActivity,
        otherPorts: [Int],
        peerPIDs: [Int32]
    ) {
        self.port = port
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.processStartTime = processStartTime
        self.activity = activity
        self.otherPorts = otherPorts
        self.peerPIDs = peerPIDs
    }

    public var id: String { "\(port):\(pid)" }
}

public struct LocalPortCloseResult: Sendable, Equatable {
    public let targetStoppedListening: Bool
    public let portFree: Bool
    public let remainingPIDs: [Int32]

    public init(targetStoppedListening: Bool, portFree: Bool, remainingPIDs: [Int32]) {
        self.targetStoppedListening = targetStoppedListening
        self.portFree = portFree
        self.remainingPIDs = remainingPIDs
    }
}

public struct LocalPortUptimeComponents: Sendable, Equatable {
    public let days: Int
    public let hours: Int
    public let minutes: Int

    public init(days: Int, hours: Int, minutes: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }

    public var isUnderMinute: Bool {
        days == 0 && hours == 0 && minutes == 0
    }
}

public enum LocalPortUptimeFormatter {
    public static func components(etime: String) -> LocalPortUptimeComponents? {
        let trimmed = etime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var days = 0
        var remaining = trimmed
        if let dashIndex = remaining.firstIndex(of: "-") {
            let dayString = remaining[..<dashIndex]
            guard let parsedDays = Int(dayString) else { return nil }
            days = parsedDays
            remaining = String(remaining[remaining.index(after: dashIndex)...])
        }

        let parts = remaining.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let hours = parts.count == 3 ? parts[0] : 0
        let minutes = parts.count == 3 ? parts[1] : parts[0]

        return LocalPortUptimeComponents(days: days, hours: hours, minutes: minutes)
    }

    public static func format(etime: String, compact: Bool = false) -> String? {
        guard let components = components(etime: etime) else { return nil }

        if compact {
            if components.days > 0 { return "\(components.days)d" }
            if components.hours > 0 { return "\(components.hours)h" }
            if components.minutes > 0 { return "\(components.minutes)m" }
            return "< 1m"
        }

        if components.days > 0 {
            return components.hours > 0 ? "\(components.days)d \(components.hours)h" : "\(components.days)d"
        }
        if components.hours > 0 {
            return components.minutes > 0 ? "\(components.hours)h \(components.minutes)m" : "\(components.hours)h"
        }
        if components.minutes > 0 { return "\(components.minutes)m" }
        return "< 1m"
    }
}

public func localPortCompactPath(_ path: String?) -> String {
    guard let path else { return "—" }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
