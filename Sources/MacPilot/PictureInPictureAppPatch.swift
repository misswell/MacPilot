// PictureInPictureAppPatch.swift
// Safe, reversible app-bundle patching for custom GPU compositors.

import Foundation

struct PiPCustomPatchApplication: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL
    let isRunning: Bool
    let isEnabled: Bool
    let isPatched: Bool
    let hasBackup: Bool
    let isUserSelected: Bool

    var id: String { bundleIdentifier }
}

struct PiPCustomPatchDescriptor: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
}

enum PiPOcclusionAppPatchService {
    nonisolated static let supportedApplications: [PiPCustomPatchDescriptor] = [
        .init(bundleIdentifier: "org.mozilla.firefox", displayName: "Firefox"),
        .init(bundleIdentifier: "org.mozilla.firefoxdeveloperedition", displayName: "Firefox Developer Edition"),
        .init(bundleIdentifier: "org.mozilla.nightly", displayName: "Firefox Nightly"),
        .init(bundleIdentifier: "org.mozilla.floorp", displayName: "Floorp"),
        .init(bundleIdentifier: "net.kovidgoyal.kitty", displayName: "kitty"),
        .init(bundleIdentifier: "com.mitchellh.ghostty", displayName: "Ghostty"),
        .init(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2")
    ]

    static func isPatched(applicationURL: URL) throws -> Bool {
        let executableURL = try executableURL(for: applicationURL)
        let data = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let libraryURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("libMacPilotOcclusionPatch.dylib")
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return false }
        return try MachODylibInjector.containsLoadCommand(in: data)
    }

    static func applicationIdentity(at applicationURL: URL) -> (bundleIdentifier: String, displayName: String)? {
        guard applicationURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: applicationURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else { return nil }
        let displayName = (try? applicationURL.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return (bundleIdentifier, displayName)
    }

    static func hasBackup(bundleIdentifier: String) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(bundleIdentifier: bundleIdentifier).path)
    }

    static func patch(
        applicationURL: URL,
        expectedBundleIdentifier: String,
        patchLibraryURL: URL,
        backupRootURL: URL? = nil
    ) throws {
        try validateApplication(applicationURL, expectedBundleIdentifier: expectedBundleIdentifier)
        guard FileManager.default.fileExists(atPath: patchLibraryURL.path) else {
            throw PiPOcclusionAppPatchError.missingPatchLibrary
        }
        guard try !isPatched(applicationURL: applicationURL) else {
            throw PiPOcclusionAppPatchError.alreadyPatched
        }
        let fileManager = FileManager.default
        let backup = backupURL(bundleIdentifier: expectedBundleIdentifier, rootURL: backupRootURL)
        try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
        do {
            try fileManager.copyItem(at: applicationURL, to: backup)
        } catch {
            throw PiPOcclusionAppPatchError.backupFailed(error.localizedDescription)
        }

        let requiresAdministrator = requiresAdministratorPrivileges(for: applicationURL)
        let staging = requiresAdministrator
            ? supportTemporaryURL(suffix: "patch", rootURL: backupRootURL)
            : siblingTemporaryURL(for: applicationURL, suffix: "patch")
        let displaced = siblingTemporaryURL(for: applicationURL, suffix: "original")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: displaced)
        }

        do {
            try fileManager.copyItem(at: applicationURL, to: staging)
            let executable = try executableURL(for: staging)
            let originalAttributes = try fileManager.attributesOfItem(atPath: executable.path)
            let originalData = try Data(contentsOf: executable, options: .mappedIfSafe)
            let patchedData = try MachODylibInjector.injectingLoadCommand(into: originalData)
            try patchedData.write(to: executable, options: .atomic)
            if let permissions = originalAttributes[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: executable.path)
            }
            let destinationLibrary = executable.deletingLastPathComponent()
                .appendingPathComponent("libMacPilotOcclusionPatch.dylib")
            if fileManager.fileExists(atPath: destinationLibrary.path) {
                try fileManager.removeItem(at: destinationLibrary)
            }
            try fileManager.copyItem(at: patchLibraryURL, to: destinationLibrary)
            try signApplication(at: staging)
            try replaceApplication(
                at: applicationURL,
                with: staging,
                displacedURL: displaced,
                requiresAdministrator: requiresAdministrator
            )
        } catch let error as PiPOcclusionAppPatchError {
            throw error
        } catch {
            throw PiPOcclusionAppPatchError.patchFailed(error.localizedDescription)
        }
    }

    static func restore(
        applicationURL: URL,
        expectedBundleIdentifier: String,
        backupRootURL: URL? = nil
    ) throws {
        try validateApplication(applicationURL, expectedBundleIdentifier: expectedBundleIdentifier)
        let fileManager = FileManager.default
        let backup = backupURL(bundleIdentifier: expectedBundleIdentifier, rootURL: backupRootURL)
        guard fileManager.fileExists(atPath: backup.path) else {
            throw PiPOcclusionAppPatchError.missingBackup
        }
        let requiresAdministrator = requiresAdministratorPrivileges(for: applicationURL)
        let staging = requiresAdministrator
            ? supportTemporaryURL(suffix: "restore", rootURL: backupRootURL)
            : siblingTemporaryURL(for: applicationURL, suffix: "restore")
        let displaced = siblingTemporaryURL(for: applicationURL, suffix: "patched")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: displaced)
        }
        do {
            try fileManager.copyItem(at: backup, to: staging)
            try replaceApplication(
                at: applicationURL,
                with: staging,
                displacedURL: displaced,
                requiresAdministrator: requiresAdministrator
            )
            try fileManager.removeItem(at: backup)
        } catch {
            throw PiPOcclusionAppPatchError.restoreFailed(error.localizedDescription)
        }
    }

    static func bundledPatchLibraryURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("libMacPilotOcclusionPatch.dylib"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/libMacPilotOcclusionPatch.dylib"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/release/libMacPilotOcclusionPatch.dylib")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func backupURL(bundleIdentifier: String, rootURL: URL? = nil) -> URL {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/OcclusionPatchBackups", isDirectory: true)
        return root.appendingPathComponent(bundleIdentifier + ".app", isDirectory: true)
    }

    private static func validateApplication(_ applicationURL: URL, expectedBundleIdentifier: String) throws {
        guard applicationURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == expectedBundleIdentifier else {
            throw PiPOcclusionAppPatchError.invalidApplication
        }
        _ = try executableURL(for: applicationURL)
    }

    private static func executableURL(for applicationURL: URL) throws -> URL {
        guard let bundle = Bundle(url: applicationURL),
              let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !executable.isEmpty else {
            throw PiPOcclusionAppPatchError.missingExecutable
        }
        let url = applicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PiPOcclusionAppPatchError.missingExecutable
        }
        return url
    }

    private static func siblingTemporaryURL(for applicationURL: URL, suffix: String) -> URL {
        applicationURL.deletingLastPathComponent()
            .appendingPathComponent(".MacPilot-\(suffix)-\(UUID().uuidString).app", isDirectory: true)
    }

    private static func supportTemporaryURL(suffix: String, rootURL: URL?) -> URL {
        backupURL(bundleIdentifier: "staging", rootURL: rootURL)
            .deletingLastPathComponent()
            .appendingPathComponent(".MacPilot-\(suffix)-\(UUID().uuidString).app", isDirectory: true)
    }

    private static func requiresAdministratorPrivileges(for applicationURL: URL) -> Bool {
        let fileManager = FileManager.default
        return !fileManager.isWritableFile(atPath: applicationURL.path)
            || !fileManager.isWritableFile(atPath: applicationURL.deletingLastPathComponent().path)
    }

    private static func replaceApplication(
        at destination: URL,
        with staging: URL,
        displacedURL: URL,
        requiresAdministrator: Bool
    ) throws {
        if requiresAdministrator {
            try replaceApplicationWithAdministratorPrivileges(
                at: destination,
                with: staging,
                displacedURL: displacedURL
            )
            return
        }
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: destination, to: displacedURL)
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.moveItem(at: displacedURL, to: destination)
                throw error
            }
            try fileManager.removeItem(at: displacedURL)
        } catch {
            throw error
        }
    }

    private static func replaceApplicationWithAdministratorPrivileges(
        at destination: URL,
        with staging: URL,
        displacedURL: URL
    ) throws {
        let privilegedStaging = siblingTemporaryURL(for: destination, suffix: "install")
        let command = [
            "/usr/bin/ditto \(shellQuote(staging.path)) \(shellQuote(privilegedStaging.path))",
            "/bin/mv \(shellQuote(destination.path)) \(shellQuote(displacedURL.path))",
            "if /bin/mv \(shellQuote(privilegedStaging.path)) \(shellQuote(destination.path)); then",
            "  /bin/rm -rf \(shellQuote(displacedURL.path)) \(shellQuote(staging.path))",
            "else",
            "  /bin/mv \(shellQuote(displacedURL.path)) \(shellQuote(destination.path))",
            "  /bin/rm -rf \(shellQuote(privilegedStaging.path))",
            "  exit 1",
            "fi"
        ].joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            command
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "authorization failed"
            throw PiPOcclusionAppPatchError.administratorInstallFailed(message)
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func signApplication(at applicationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force", "--deep", "--sign", "-",
            applicationURL.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "codesign failed"
            throw PiPOcclusionAppPatchError.signingFailed(message)
        }
    }
}

enum PiPOcclusionAppPatchError: LocalizedError {
    case invalidApplication
    case missingExecutable
    case missingPatchLibrary
    case alreadyPatched
    case missingBackup
    case administratorPrivilegesRequired
    case administratorInstallFailed(String)
    case backupFailed(String)
    case signingFailed(String)
    case patchFailed(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidApplication: "The selected item is not the expected application."
        case .missingExecutable: "The application has no patchable main executable."
        case .missingPatchLibrary: "MacPilot is missing its bundled off-screen rendering component."
        case .alreadyPatched: "The application is already patched."
        case .missingBackup: "The original application backup is missing."
        case .administratorPrivilegesRequired: "Administrator privileges are required to modify this application."
        case .administratorInstallFailed(let message): "The administrator-authorized install failed: \(message)"
        case .backupFailed(let message): "MacPilot could not back up the application: \(message)"
        case .signingFailed(let message): "Re-signing the patched application failed: \(message)"
        case .patchFailed(let message): "Patching failed and the original application was preserved: \(message)"
        case .restoreFailed(let message): "Restoring the original application failed: \(message)"
        }
    }
}
