import Foundation
import Darwin
import MacPilotDisplayBridge

public enum DisplayRecoveryPhase: String, Codable, Sendable {
    case prepared
    case creatingVirtual
    case awaitingVirtualConfirmation
    case disablingDisplays
    case active
    case restoringDisplays
    case removingVirtual
    case complete
}

public struct DisplayRecoveryJournal: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var operationID: UUID
    public var generation: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var systemSessionID: String
    public var phase: DisplayRecoveryPhase
    public var policy: DisplayControlPolicy
    public var originalDisplays: [DisplayControlDisplay]
    public var originalMainDisplayUUID: String?
    public var disabledDisplayUUIDs: [String]
    public var pendingRestoreUUIDs: [String]
    public var virtualDisplayUUID: String?
    public var virtualSpec: DisplayVirtualSpec?
    public var remoteSessionID: String?
    public var remoteLeaseExpiresAt: Date?
    public var confirmationDeadline: Date?
    public var virtualSelectionConfirmed: Bool
    public var manualOverride: Bool

    public init(
        generation: UUID,
        policy: DisplayControlPolicy,
        originalDisplays: [DisplayControlDisplay],
        now: Date = Date()
    ) {
        version = Self.currentVersion
        operationID = UUID()
        self.generation = generation
        createdAt = now
        updatedAt = now
        systemSessionID = DisplayRecoverySession.identifier
        phase = .prepared
        self.policy = policy
        self.originalDisplays = originalDisplays
        originalMainDisplayUUID = originalDisplays.first(where: \.isMain)?.uuid
        disabledDisplayUUIDs = []
        pendingRestoreUUIDs = []
        virtualDisplayUUID = nil
        virtualSpec = nil
        remoteSessionID = nil
        remoteLeaseExpiresAt = nil
        confirmationDeadline = nil
        virtualSelectionConfirmed = false
        manualOverride = false
    }

    public var isComplete: Bool { phase == .complete }

    public func validationError(now: Date = Date()) -> String? {
        guard version == Self.currentVersion else { return "Unsupported display recovery journal version." }
        guard !operationID.uuidString.isEmpty, !generation.uuidString.isEmpty else { return "Invalid recovery transaction identity." }
        guard originalDisplays.count <= 32 else { return "Display recovery journal has too many entries." }
        let uuids = originalDisplays.map(\.uuid)
        guard uuids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }), Set(uuids).count == uuids.count else {
            return "Display recovery journal contains invalid or duplicate display identities."
        }
        guard Set(disabledDisplayUUIDs).isSubset(of: Set(uuids)),
              Set(pendingRestoreUUIDs).isSubset(of: Set(disabledDisplayUUIDs)) else {
            return "Display recovery journal contains an unowned display identity."
        }
        guard createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt,
              createdAt.timeIntervalSince(now) <= 60,
              !systemSessionID.isEmpty,
              systemSessionID.utf8.count <= 128 else {
            return "Display recovery journal timestamps are invalid."
        }
        if let virtualSpec, let error = virtualSpec.validationError { return error }
        if policy == .remoteVirtualOnly || policy == .remotePhysical || policy == .remoteVirtualWithPhysical {
            guard let remoteSessionID, !remoteSessionID.isEmpty else { return "Remote virtual display journal lacks a session identity." }
        }
        return nil
    }
}

public struct DisplayRecoveryJournalStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var standard: DisplayRecoveryJournalStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DisplayRecoveryJournalStore(
            fileURL: support.appendingPathComponent("MacPilot", isDirectory: true)
                .appendingPathComponent("DisplayControlRecovery.json")
        )
    }

    public func load() throws -> DisplayRecoveryJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw StoreError.unsafeFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard Self.isPrivate(attributes) else { throw StoreError.unsafeFile }
        if let size = attributes[.size] as? NSNumber, size.intValue > 512 * 1024 {
            throw StoreError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let journal = try JSONDecoder.displayControlDecoder.decode(DisplayRecoveryJournal.self, from: data)
        if let reason = journal.validationError() { throw StoreError.invalidJournal(reason) }
        return journal
    }

    /// Creates private storage and commits one complete journal atomically.
    /// A failed write leaves the previous recoverable record untouched.
    public func save(_ journal: DisplayRecoveryJournal) throws {
        if let reason = journal.validationError() { throw StoreError.invalidJournal(reason) }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let dirValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard dirValues.isSymbolicLink != true else { throw StoreError.unsafeFile }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard Self.isPrivateDirectory(try FileManager.default.attributesOfItem(atPath: directory.path)) else {
            throw StoreError.unsafeFile
        }
        let data = try JSONEncoder.displayControlEncoder.encode(journal)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        // Read back after the write so a truncated or malformed record can
        // never authorize a display operation.
        let saved = try load()
        guard saved == journal else { throw StoreError.writeVerificationFailed }
    }

    public func removeIfComplete() throws {
        guard let journal = try load() else { return }
        guard journal.isComplete, journal.pendingRestoreUUIDs.isEmpty else { throw StoreError.recoveryPending }
        try FileManager.default.removeItem(at: fileURL)
    }

    public enum StoreError: Error, Equatable {
        case unsafeFile
        case fileTooLarge
        case writeVerificationFailed
        case recoveryPending
        case invalidJournal(String)
    }

    private static func isPrivate(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              owner.uint32Value == getuid() else { return false }
        return permissions.intValue & 0o077 == 0
    }

    private static func isPrivateDirectory(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              owner.uint32Value == getuid() else { return false }
        return permissions.intValue & 0o077 == 0
    }
}

public enum DisplayRecoverySession {
    /// Bound to the boot and WindowServer process start; helper restarts retain
    /// the identity while WindowServer restarts fence stale numeric display IDs.
    public static var identifier: String {
        var bootTime = timeval()
        var length = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &bootTime, &length, nil, 0)
        guard result == 0 else { return "display-session-unknown" }
        var serverIdentity = [CChar](repeating: 0, count: 96)
        guard MDCurrentDisplayServerIdentity(&serverIdentity, serverIdentity.count) else { return "display-session-unknown" }
        let end = serverIdentity.firstIndex(of: 0) ?? serverIdentity.endIndex
        let server = String(decoding: serverIdentity[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "boot-\(bootTime.tv_sec)-\(bootTime.tv_usec)-\(server)"
    }
}

public extension JSONEncoder {
    static var displayControlEncoder: JSONEncoder {
        JSONEncoder()
    }
}

public extension JSONDecoder {
    static var displayControlDecoder: JSONDecoder {
        JSONDecoder()
    }
}
