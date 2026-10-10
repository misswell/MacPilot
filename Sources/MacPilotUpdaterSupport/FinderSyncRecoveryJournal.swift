import Darwin
import Foundation

public enum FinderSyncRecoveryJournalError: Error, Equatable, LocalizedError {
    case invalidMarker
    case invalidTarget
    case lockBusy
    case lockFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidMarker:
            "FinderSync recovery marker is invalid; automatic re-enable was refused."
        case .invalidTarget:
            "FinderSync recovery target must be an application with the expected extension path."
        case .lockBusy:
            "Another FinderSync registration recovery is already running."
        case .lockFailure(let code):
            "Could not acquire the FinderSync recovery lock (errno \(code))."
        }
    }
}

public struct FinderSyncRecoveryIntent: Equatable, Sendable {
    public let applicationBundlePath: String
    public let extensionBundlePath: String

    fileprivate init(applicationBundlePath: String, extensionBundlePath: String) {
        self.applicationBundlePath = applicationBundlePath
        self.extensionBundlePath = extensionBundlePath
    }

    public func matches(applicationURL: URL) -> Bool {
        guard let target = FinderSyncRecoveryJournal.normalizedApplicationURL(applicationURL) else {
            return false
        }
        return target.path == applicationBundlePath
            && FinderSyncRecoveryJournal.extensionURL(for: target).path == extensionBundlePath
    }
}

/// A durable, per-user journal for FinderSync registrations temporarily disabled
/// by MacPilot itself. All multi-step registration transactions must hold the
/// nonblocking cross-process lock for their complete duration.
public struct FinderSyncRecoveryJournal {
    public struct Access {
        private let fileURL: URL

        fileprivate init(fileURL: URL) {
            self.fileURL = fileURL
        }

        public func readIntent() throws -> FinderSyncRecoveryIntent? {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let fields = object as? [String: Any],
                  Set(fields.keys) == Set([
                    "schemaVersion", "bundleIdentifier", "applicationBundlePath",
                    "extensionBundlePath", "recoveryID"
                  ]),
                  let schemaVersion = fields["schemaVersion"] as? Int,
                  schemaVersion == 1,
                  let bundleIdentifier = fields["bundleIdentifier"] as? String,
                  bundleIdentifier == FinderSyncRegistration.extensionBundleIdentifier,
                  let applicationPath = fields["applicationBundlePath"] as? String,
                  let extensionPath = fields["extensionBundlePath"] as? String,
                  let recoveryID = fields["recoveryID"] as? String,
                  UUID(uuidString: recoveryID) != nil,
                  let applicationURL = FinderSyncRecoveryJournal.normalizedApplicationURL(
                    URL(fileURLWithPath: applicationPath)
                  ),
                  applicationURL.path == applicationPath,
                  FinderSyncRecoveryJournal.extensionURL(for: applicationURL).path == extensionPath else {
                throw FinderSyncRecoveryJournalError.invalidMarker
            }

            return FinderSyncRecoveryIntent(
                applicationBundlePath: applicationPath,
                extensionBundlePath: extensionPath
            )
        }

        public func writeIntent(for applicationURL: URL) throws {
            guard let target = FinderSyncRecoveryJournal.normalizedApplicationURL(applicationURL) else {
                throw FinderSyncRecoveryJournalError.invalidTarget
            }
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw FinderSyncRecoveryJournalError.invalidMarker
            }

            let marker: [String: Any] = [
                "schemaVersion": 1,
                "bundleIdentifier": FinderSyncRegistration.extensionBundleIdentifier,
                "applicationBundlePath": target.path,
                "extensionBundlePath": FinderSyncRecoveryJournal.extensionURL(for: target).path,
                "recoveryID": UUID().uuidString
            ]
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }

        /// A marker is removed only after callers have independently queried
        /// PlugInKit and confirmed the extension is elected for use.
        public func clearIntent() throws {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            _ = try readIntent()
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public let fileURL: URL
    private var lockURL: URL { fileURL.appendingPathExtension("lock") }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: FinderSyncRecoveryJournal {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return FinderSyncRecoveryJournal(
            fileURL: supportDirectory
                .appendingPathComponent("MacPilot", isDirectory: true)
                .appendingPathComponent("FinderSyncRecovery.json")
        )
    }

    public func withExclusiveLock<T>(_ operation: (Access) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw FinderSyncRecoveryJournalError.lockFailure(errno)
        }
        defer { _ = close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw FinderSyncRecoveryJournalError.lockBusy
            }
            throw FinderSyncRecoveryJournalError.lockFailure(failure)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        return try operation(Access(fileURL: fileURL))
    }

    fileprivate static func normalizedApplicationURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let normalized = url.standardizedFileURL
        guard normalized.path.hasPrefix("/"),
              normalized.lastPathComponent.hasSuffix(".app") else {
            return nil
        }
        return normalized
    }

    fileprivate static func extensionURL(for applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/PlugIns/FinderSync.appex")
    }
}
