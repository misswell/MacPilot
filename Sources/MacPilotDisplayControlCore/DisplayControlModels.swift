import CoreGraphics
import Foundation

public enum DisplayControlCommand: String, Codable, Sendable {
    case status
    case disable
    case keepOnly
    case restore
    case prepareVirtual
    case confirmVirtual
    case confirmChange
    case heartbeat
}

public enum DisplayControlState: String, Codable, Sendable {
    case idle
    case managing
    case awaitingVirtualConfirmation
    case awaitingKeepConfirmation
    case active
    case recovering
    case recoveryRequired
    case unavailable
    case failed
}

public enum DisplayControlPolicy: String, Codable, Sendable {
    case localPhysical
    case remotePhysical
    case remoteVirtualOnly
    case remoteVirtualWithPhysical
}

public struct DisplayVirtualSpec: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let hiDPI: Bool
    public let refreshRate: Double

    public init(width: Int, height: Int, hiDPI: Bool = true, refreshRate: Double = 60) {
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        self.refreshRate = refreshRate
    }

    public var validationError: String? {
        guard (640...8192).contains(width), (480...8192).contains(height) else {
            return "Resolution must be between 640×480 and 8192×8192 pixels."
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            return "Resolution dimensions must be even."
        }
        guard refreshRate.isFinite, (30...120).contains(refreshRate) else {
            return "Refresh rate must be between 30 and 120 Hz."
        }
        return nil
    }
}

public struct DisplayControlRequest: Codable, Sendable {
    public let command: DisplayControlCommand
    public let targetUUID: String?
    public let virtualSpec: DisplayVirtualSpec?
    public let generation: UUID?
    public let remoteSessionID: String?
    public let confirmed: Bool
    public let policy: DisplayControlPolicy?

    public init(
        command: DisplayControlCommand,
        targetUUID: String? = nil,
        virtualSpec: DisplayVirtualSpec? = nil,
        generation: UUID? = nil,
        remoteSessionID: String? = nil,
        confirmed: Bool = false,
        policy: DisplayControlPolicy? = nil
    ) {
        self.command = command
        self.targetUUID = targetUUID
        self.virtualSpec = virtualSpec
        self.generation = generation
        self.remoteSessionID = remoteSessionID
        self.confirmed = confirmed
        self.policy = policy
    }
}

/// A point-in-time display record. Disabled displays remain in responses so the
/// UI can offer a row-level restore action.
public struct DisplayControlDisplay: Codable, Equatable, Identifiable, Sendable {
    public var id: String { uuid }
    public let uuid: String
    public let displayID: UInt32
    public let name: String
    public let isBuiltIn: Bool
    public let isVirtual: Bool
    public let isOnline: Bool
    public let isActive: Bool
    public let isMain: Bool
    public let width: Int
    public let height: Int
    public let isOwned: Bool
    public let isAsleep: Bool
    public let mirrorMasterUUID: String?
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    public let originX: Double
    public let originY: Double

    public init(
        uuid: String,
        displayID: UInt32,
        name: String,
        isBuiltIn: Bool,
        isVirtual: Bool,
        isOnline: Bool,
        isActive: Bool,
        isMain: Bool,
        width: Int,
        height: Int,
        isOwned: Bool = false,
        isAsleep: Bool = false,
        mirrorMasterUUID: String? = nil,
        vendorID: UInt32 = 0,
        productID: UInt32 = 0,
        serialNumber: UInt32 = 0,
        originX: Double = 0,
        originY: Double = 0
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isVirtual = isVirtual
        self.isOnline = isOnline
        self.isActive = isActive
        self.isMain = isMain
        self.width = width
        self.height = height
        self.isOwned = isOwned
        self.isAsleep = isAsleep
        self.mirrorMasterUUID = mirrorMasterUUID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.originX = originX
        self.originY = originY
    }

    public var isUsable: Bool {
        isOnline && isActive && !isAsleep && width > 0 && height > 0
    }
}

public struct DisplayControlResponse: Codable, Sendable {
    public let displays: [DisplayControlDisplay]
    public let state: DisplayControlState
    public let message: String?
    public let generation: UUID?
    public let confirmationDeadline: Date?
    public let helperReady: Bool
    public let virtualDisplayUUID: String?

    public init(
        displays: [DisplayControlDisplay],
        state: DisplayControlState,
        message: String? = nil,
        generation: UUID? = nil,
        confirmationDeadline: Date? = nil,
        helperReady: Bool,
        virtualDisplayUUID: String? = nil
    ) {
        self.displays = displays
        self.state = state
        self.message = message
        self.generation = generation
        self.confirmationDeadline = confirmationDeadline
        self.helperReady = helperReady
        self.virtualDisplayUUID = virtualDisplayUUID
    }
}

public enum DisplayRecoveryService {
    public static let serviceName = "com.misswell.macpilot.display-recovery"
}

/// The XPC boundary transports bounded Codable payloads; the helper validates
/// their schema and sender before dispatching any operation.
@objc public protocol DisplayRecoveryXPC {
    func execute(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum DisplayControlSafety {
    public static func canDisable(
        targetUUID: String,
        displays: [DisplayControlDisplay],
        policy: DisplayControlPolicy,
        remoteSessionIsFresh: Bool,
        virtualSelectionConfirmed: Bool,
        confirmedVirtualUUID: String? = nil
    ) -> Bool {
        guard let target = displays.first(where: { $0.uuid == targetUUID }), target.isUsable else { return false }

        let survivors = displays.filter { candidate in
            guard candidate.uuid != targetUUID, candidate.isUsable else { return false }
            if candidate.mirrorMasterUUID == targetUUID { return false }
            return true
        }
        guard !survivors.isEmpty else { return false }

        let activePhysical = survivors.contains { !$0.isVirtual }
        if activePhysical { return true }

        // A virtual-only topology is allowed only for a live UU session that
        // the user explicitly confirmed on that virtual display.
        guard policy == .remoteVirtualOnly,
              remoteSessionIsFresh,
              virtualSelectionConfirmed,
              let confirmedVirtualUUID,
              survivors.contains(where: { $0.isVirtual && $0.isOwned && $0.uuid == confirmedVirtualUUID }) else { return false }
        return true
    }

    public static func canKeepOnly(
        targetUUID: String,
        displays: [DisplayControlDisplay],
        policy: DisplayControlPolicy,
        remoteSessionIsFresh: Bool,
        virtualSelectionConfirmed: Bool
    ) -> Bool {
        guard let target = displays.first(where: { $0.uuid == targetUUID }), target.isUsable else { return false }
        if !target.isVirtual { return true }
        return policy == .remoteVirtualOnly && remoteSessionIsFresh && virtualSelectionConfirmed
    }
}
