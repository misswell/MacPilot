import Foundation
import OSLog
import Security

/// Logs before potentially blocking container operations, into this process's
/// own Library directory. Logging must never resolve an App Group itself.
public enum PermissionDiagnostics {
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "PermissionDiagnostics")
    private static let session = UUID().uuidString
    private static let isTesting = Bundle.main.bundleURL.pathExtension == "xctest"
        || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest/") }
    private static let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MacPilot/Permissions", isDirectory: true)
    private static let file = directory.appendingPathComponent("permissions-\(ProcessInfo.processInfo.processIdentifier)-\(session).log")
    private static let startup: Void = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        let selfStatus = SecCodeCopySelf([], &code)
        let staticStatus = code.map { SecCodeCopyStaticCode($0, [], &staticCode) } ?? selfStatus
        let signingStatus = staticCode.map {
            SecCodeCopySigningInformation($0, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        } ?? staticStatus
        let metadata = information as? [String: Any] ?? [:]
        let entitlements = metadata[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        let team = metadata[kSecCodeInfoTeamIdentifier as String] as? String ?? "missing"
        let profile = FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/embedded.provisionprofile").path)
        append("startup version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") signingStatus=\(signingStatus) team=\(team) sandbox=\(entitlements["com.apple.security.app-sandbox"] as? Bool ?? false) groups=\(groups.joined(separator: ",")) embeddedProfile=\(profile)")
    }()

    public static func record(_ event: String) {
        guard !isTesting else { return }
        _ = startup
        append(event)
    }

    static func formattedLine(_ event: String, timestamp: String, bundle: String, pid: Int32, session: String) -> String {
        let singleLine = event.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "[\(timestamp)] bundle=\(bundle) pid=\(pid) session=\(session) \(singleLine)\n"
    }

    private static func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = formattedLine(event, timestamp: formatter.string(from: Date()),
            bundle: Bundle.main.bundleIdentifier ?? "unknown", pid: ProcessInfo.processInfo.processIdentifier, session: session)
        logger.notice("\(line, privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Bounded per-session file; only startup and permission boundaries
            // belong here, never heartbeat payloads or key material.
            if !FileManager.default.fileExists(atPath: file.path) {
                try pruneOldSessions(in: directory, now: Date())
                guard FileManager.default.createFile(atPath: file.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            guard try handle.seekToEnd() < 512 * 1024 else { return }
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            let failure = error as NSError
            logger.error("Permission log write failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        }
    }

    static func pruneOldSessions(in directory: URL, now: Date) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        for file in files where file.lastPathComponent.hasPrefix("permissions-") && file.pathExtension == "log" {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values.isRegularFile == true, let date = values.contentModificationDate,
               date < now.addingTimeInterval(-7 * 24 * 60 * 60) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    static func containerURL(reason: String) -> URL? {
        record("container.resolve.begin reason=\(reason) group=\(RightClickConstants.appGroupIdentifier)")
        let start = ProcessInfo.processInfo.systemUptime
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RightClickConstants.appGroupIdentifier)
        record("container.resolve.end reason=\(reason) resolved=\(url != nil) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
        return url
    }
}
