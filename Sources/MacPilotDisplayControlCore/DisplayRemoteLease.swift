import Foundation

public struct DisplayRemoteLease: Equatable, Sendable {
    public static let lifetime: TimeInterval = 8
    public private(set) var sessionID: String?
    public private(set) var generation: UUID?
    public private(set) var lastHeartbeat: Date?
    public private(set) var manualOverrideSessionID: String?

    public init() {
        sessionID = nil
        generation = nil
        lastHeartbeat = nil
        manualOverrideSessionID = nil
    }

    @discardableResult
    public mutating func renew(sessionID: String?, generation: UUID?, now: Date = Date()) -> Bool {
        guard let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let generation,
              now.timeIntervalSince1970.isFinite else { return false }
        if let activeSession = self.sessionID, activeSession != sessionID { return false }
        if let activeGeneration = self.generation, activeGeneration != generation { return false }
        if manualOverrideSessionID == sessionID { return false }
        self.sessionID = sessionID
        self.generation = generation
        lastHeartbeat = now
        return true
    }

    public func isFresh(now: Date = Date()) -> Bool {
        guard let lastHeartbeat,
              now >= lastHeartbeat,
              now.timeIntervalSince(lastHeartbeat) <= Self.lifetime,
              sessionID != nil,
              generation != nil else { return false }
        return true
    }

    public mutating func overrideCurrentSession() {
        manualOverrideSessionID = sessionID
        clearLease()
    }

    /// Forgets the override for the current session.
    ///
    /// Only an explicit user re-apply may call this. A confirmation timeout or
    /// an emergency release sets the override on purpose so the automatic UU
    /// rule cannot immediately undo the desktop the user just got back.
    public mutating func clearOverride() {
        manualOverrideSessionID = nil
    }

    /// A newly observed remote session clears an override belonging to the
    /// previous session. Heartbeat cannot override the active session itself.
    @discardableResult
    public mutating func beginNewSession(_ newSessionID: String) -> Bool {
        guard newSessionID != sessionID else { return manualOverrideSessionID != newSessionID }
        sessionID = newSessionID
        generation = nil
        lastHeartbeat = nil
        if manualOverrideSessionID != newSessionID { manualOverrideSessionID = nil }
        return manualOverrideSessionID != newSessionID
    }

    @discardableResult
    public mutating func beginControl(
        sessionID: String,
        expectedGeneration: UUID,
        activeGeneration: UUID,
        now: Date = Date()
    ) -> Bool {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              now.timeIntervalSince1970.isFinite,
              manualOverrideSessionID != sessionID else { return false }
        if let currentSession = self.sessionID, currentSession != sessionID { return false }
        if let currentGeneration = generation, currentGeneration != expectedGeneration { return false }
        self.sessionID = sessionID
        generation = activeGeneration
        lastHeartbeat = now
        return true
    }

    public mutating func clearLease() {
        sessionID = nil
        generation = nil
        lastHeartbeat = nil
    }

    public mutating func restoreOverride(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        manualOverrideSessionID = sessionID
    }
}

public struct DisplaySessionOverrideStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var standard: DisplaySessionOverrideStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DisplaySessionOverrideStore(
            fileURL: support.appendingPathComponent("MacPilot", isDirectory: true)
                .appendingPathComponent("DisplayControlOverride.json")
        )
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw StoreError.unsafeFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1024,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              owner.uint32Value == getuid(), permissions.intValue & 0o077 == 0 else { throw StoreError.unsafeFile }
        let data = try Data(contentsOf: fileURL)
        let value = try JSONDecoder().decode(Value.self, from: data)
        guard !value.sessionID.isEmpty, value.sessionID.utf8.count <= 256 else { throw StoreError.unsafeFile }
        return value.sessionID
    }

    public func save(_ sessionID: String) throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256 else { throw StoreError.unsafeFile }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let directoryOwner = directoryAttributes[.ownerAccountID] as? NSNumber,
              let directoryPermissions = directoryAttributes[.posixPermissions] as? NSNumber,
              directoryOwner.uint32Value == getuid(), directoryPermissions.intValue & 0o077 == 0 else {
            throw StoreError.unsafeFile
        }
        let data = try JSONEncoder().encode(Value(sessionID: sessionID))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        guard try load() == sessionID else { throw StoreError.writeVerificationFailed }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw StoreError.unsafeFile }
        try FileManager.default.removeItem(at: fileURL)
    }

    private struct Value: Codable { let sessionID: String }

    public enum StoreError: Error, Equatable {
        case unsafeFile
        case writeVerificationFailed
    }
}

public enum DisplayControlMessageCode: String, Codable, Sendable {
    case lastPhysicalDisplay
    case staleGeneration
    case helperUnavailable
    case virtualNotReady
    case orphanVirtualDisplay
    case recoveryIncomplete
    case invalidTarget
    case invalidSize
    case uuSessionRequired
    case confirmationExpired
    case permissionDenied
    case displayAPIUnavailable
    case transactionFailed
    case userOverride
    case malformedRequest
    case callerRejected
}
