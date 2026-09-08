import Foundation
import SQLite3

/// Only the main app uses SwiftData. Keep its store in Application Support;
/// the extension receives menu configuration over authenticated IPC instead.
enum RightClickStoreMigration {
    static let pendingKey = "rightClickStoreMigrationPendingV2"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/RightClick", isDirectory: true)
    }
    static var destination: URL { directory.appendingPathComponent("RClickDatabase-v2.sqlite") }
    static var legacySources: [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return [
            library.appendingPathComponent("Group Containers/group.com.misswell.macpilot.rightclick/RClickDatabase.sqlite"),
            directory.appendingPathComponent("RClickDatabase.sqlite")
        ]
    }

    /// A denied or interrupted attempt is never retried automatically. Keep
    /// the original database intact and offer an explicit retry in settings.
    static func prepare(
        destination: URL = destination,
        sources: [URL] = legacySources,
        defaults: UserDefaults = .standard,
        retry: Bool = false,
        migrate: (URL, URL) throws -> Bool = copyIfPresent
    ) -> Bool {
        if FileManager.default.fileExists(atPath: destination.path) {
            defaults.set(false, forKey: pendingKey)
            return true
        }
        guard retry || !defaults.bool(forKey: pendingKey) else { return false }
        defaults.set(true, forKey: pendingKey)
        // Persist before entering TCC, including when the process is killed
        // while the consent dialog is open.
        defaults.synchronize()
        do {
            for (index, source) in sources.enumerated() {
                PermissionDiagnostics.record("database.migration.begin sourceIndex=\(index)")
                if try migrate(source, destination) {
                    PermissionDiagnostics.record("database.migration.end copied=true")
                    defaults.set(false, forKey: pendingKey)
                    return true
                }
            }
            PermissionDiagnostics.record("database.migration.end legacyStoreAbsent=true")
            defaults.set(false, forKey: pendingKey)
            return true
        } catch {
            let failure = error as NSError
            PermissionDiagnostics.record("database.migration.deferred domain=\(failure.domain) code=\(failure.code)")
            return false
        }
    }

    static func copyIfPresent(from source: URL, to destination: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return false
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try snapshot(source: source, destination: temporary)
        // The SQLite backup API includes committed WAL transactions. Never
        // copy just the main sqlite file and silently discard newer settings.
        try FileManager.default.moveItem(at: temporary, to: destination)
        return true
    }

    private static func snapshot(source: URL, destination: URL) throws {
        var input: OpaquePointer?
        var output: OpaquePointer?
        defer {
            if let input { sqlite3_close(input) }
            if let output { sqlite3_close(output) }
        }
        try check(sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil))
        try check(sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil))
        sqlite3_busy_timeout(input, 1000)
        sqlite3_busy_timeout(output, 1000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw NSError(domain: "MacPilot.StoreMigration.SQLite", code: Int(sqlite3_errcode(output)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { try check(step); return }
        try check(finish)
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(output, "PRAGMA integrity_check", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0), String(cString: result) == "ok" else {
            throw NSError(domain: "MacPilot.StoreMigration.SQLite", code: Int(SQLITE_CORRUPT))
        }
    }

    private static func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw NSError(domain: "MacPilot.StoreMigration.SQLite", code: Int(result))
        }
    }
}
