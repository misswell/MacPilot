import Darwin
import Foundation
import MacPilotUpdaterSupport

private enum UpdaterError: LocalizedError {
    case invalidArguments
    case parentDidNotExit
    case executableMissing(URL)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid updater arguments."
        case .parentDidNotExit: "MacPilot did not exit before the update timeout."
        case .executableMissing(let url): "MacPilot executable is missing or not executable at \(url.path)."
        case .launchFailed(let detail): "Could not relaunch MacPilot (\(detail))."
        }
    }
}

private struct UpdaterArguments {
    let parentPID: pid_t
    let sourceApplication: URL
    let destinationApplication: URL
    let stagingDirectory: URL
    let helperDirectory: URL
    let logURL: URL
    /// Optional path where this updater records the kept rollback bundle. When
    /// present, the previous app is preserved until the relaunched version
    /// proves it runs (it deletes the backup via the token on next launch).
    let successTokenURL: URL?

    init() throws {
        let values = CommandLine.arguments
        guard values.count == 7 || values.count == 8, let parentPID = pid_t(values[1]), parentPID > 0 else {
            throw UpdaterError.invalidArguments
        }
        self.parentPID = parentPID
        sourceApplication = URL(fileURLWithPath: values[2])
        destinationApplication = URL(fileURLWithPath: values[3])
        stagingDirectory = URL(fileURLWithPath: values[4])
        helperDirectory = URL(fileURLWithPath: values[5])
        logURL = URL(fileURLWithPath: values[6])
        successTokenURL = values.count == 8 ? URL(fileURLWithPath: values[7]) : nil
    }
}

private func appendLog(_ message: String, to url: URL) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data(line.utf8).write(to: url, options: .atomic)
        return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
}

private func waitForParent(_ pid: pid_t) throws {
    for _ in 0..<600 {
        if kill(pid, 0) != 0 { return }
        usleep(100_000)
    }
    throw UpdaterError.parentDidNotExit
}

private func launch(_ application: URL, logURL: URL) throws {
    guard let bundle = Bundle(url: application),
          let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
          !executableName.isEmpty else {
        let executableURL = UpdaterLaunchPlan.directExecutableURL(for: application)
        throw UpdaterError.executableMissing(executableURL)
    }

    let executableURL = UpdaterLaunchPlan.directExecutableURL(
        for: application,
        executableName: executableName
    )
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw UpdaterError.executableMissing(executableURL)
    }

    let process = Process()
    process.executableURL = executableURL
    process.currentDirectoryURL = application.deletingLastPathComponent()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw UpdaterError.launchFailed(error.localizedDescription)
    }
    appendLog("Relaunch request accepted for \(executableURL.path)", to: logURL)
}

private func runPlugInKit(arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let output = String(
        decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "MacPilotUpdater.PlugInKit",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)]
        )
    }
    return output
}

private func refreshFinderSyncRegistration(
    at applicationURL: URL,
    logURL: URL
) throws {
    let inventory = try runPlugInKit(
        arguments: FinderSyncRegistration.queryArguments(includeAllVersions: true)
    )
    let commands = FinderSyncRegistration.registrationArguments(
        for: applicationURL,
        registeredExtensionPaths: FinderSyncRegistration.registeredExtensionPaths(in: inventory),
        restoreEnabledElection: false
    )
    for arguments in commands {
        _ = try runPlugInKit(arguments: arguments)
    }
    appendLog("FinderSync registration refreshed", to: logURL)
}

private func install(_ arguments: UpdaterArguments) throws {
    try waitForParent(arguments.parentPID)

    let fileManager = FileManager.default
    let parent = arguments.destinationApplication.deletingLastPathComponent()
    let token = UUID().uuidString
    let incoming = parent.appendingPathComponent(".MacPilot-update-\(token).app")
    let backupName = ".MacPilot-backup-\(token).app"
    let backup = parent.appendingPathComponent(backupName)
    let journal = FinderSyncRecoveryJournal.standard
    var rollbackFailed = false

    do {
        try FinderSyncRegistration.withSuspendedElection(
            applicationURL: arguments.destinationApplication,
            journal: journal,
            execute: { command in
                _ = try runPlugInKit(arguments: command)
                appendLog("FinderSync election command succeeded: \(command.joined(separator: " "))", to: arguments.logURL)
            },
            query: { try runPlugInKit(arguments: $0) },
            restorationFailed: { error in
                appendLog("FinderSync election restoration failed: \(error.localizedDescription)", to: arguments.logURL)
            },
            operation: {
                do {
                    try fileManager.copyItem(at: arguments.sourceApplication, to: incoming)
                    _ = try fileManager.replaceItemAt(
                        arguments.destinationApplication,
                        withItemAt: incoming,
                        backupItemName: backupName,
                        options: .withoutDeletingBackupItem
                    )
                    try refreshFinderSyncRegistration(
                        at: arguments.destinationApplication,
                        logURL: arguments.logURL
                    )
                } catch {
                    let installationError = error
                    try? fileManager.removeItem(at: incoming)
                    if fileManager.fileExists(atPath: backup.path) {
                        do {
                            if fileManager.fileExists(atPath: arguments.destinationApplication.path) {
                                _ = try fileManager.replaceItemAt(
                                    arguments.destinationApplication,
                                    withItemAt: backup
                                )
                            } else {
                                try fileManager.moveItem(at: backup, to: arguments.destinationApplication)
                            }
                            try refreshFinderSyncRegistration(
                                at: arguments.destinationApplication,
                                logURL: arguments.logURL
                            )
                        } catch {
                            rollbackFailed = true
                            appendLog("FinderSync update rollback failed: \(error.localizedDescription)", to: arguments.logURL)
                            throw error
                        }
                    }
                    throw installationError
                }
            }
        )
    } catch {
        appendLog("Update failed: \(error.localizedDescription)", to: arguments.logURL)
        let recoveryPending = fileManager.fileExists(atPath: journal.fileURL.path)
        if !rollbackFailed,
           fileManager.fileExists(atPath: arguments.destinationApplication.path) {
            if recoveryPending {
                appendLog(
                    "Launching MacPilot with pending FinderSync recovery; extension restoration remains unconfirmed.",
                    to: arguments.logURL
                )
            }
            do {
                try launch(arguments.destinationApplication, logURL: arguments.logURL)
            } catch {
                appendLog("Could not relaunch after update failure: \(error.localizedDescription)", to: arguments.logURL)
            }
        }
        throw error
    }

    do {
        try launch(arguments.destinationApplication, logURL: arguments.logURL)
    } catch {
        let launchError = error
        guard fileManager.fileExists(atPath: backup.path) else { throw launchError }

        try FinderSyncRegistration.withSuspendedElection(
            applicationURL: arguments.destinationApplication,
            journal: journal,
            execute: { _ = try runPlugInKit(arguments: $0) },
            query: { try runPlugInKit(arguments: $0) },
            restorationFailed: { error in
                appendLog("FinderSync rollback restoration failed: \(error.localizedDescription)", to: arguments.logURL)
            },
            operation: {
                if fileManager.fileExists(atPath: arguments.destinationApplication.path) {
                    _ = try fileManager.replaceItemAt(
                        arguments.destinationApplication,
                        withItemAt: backup
                    )
                } else {
                    try fileManager.moveItem(at: backup, to: arguments.destinationApplication)
                }
                try refreshFinderSyncRegistration(
                    at: arguments.destinationApplication,
                    logURL: arguments.logURL
                )
            }
        )
        try launch(arguments.destinationApplication, logURL: arguments.logURL)
        throw launchError
    }

    // "The process started" is not "the new version runs". When a success
    // token path was supplied, keep the backup and record it: the relaunched
    // app deletes the backup only after it has loaded its configuration.
    if let successTokenURL = arguments.successTokenURL {
        UpdateSuccessToken.write(
            to: successTokenURL,
            backupPath: backup.path,
            targetVersion: arguments.sourceApplication.path
        )
        appendLog("Update installed; rollback bundle kept at \(backup.path)", to: arguments.logURL)
    } else {
        try? fileManager.removeItem(at: backup)
        appendLog("Update installed at \(arguments.destinationApplication.path)", to: arguments.logURL)
    }
}

do {
    let arguments = try UpdaterArguments()
    defer {
        try? FileManager.default.removeItem(at: arguments.stagingDirectory)
        try? FileManager.default.removeItem(at: arguments.helperDirectory)
    }
    try install(arguments)
} catch {
    let fallbackLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacPilot/update.log")
    appendLog("Updater terminated: \(error.localizedDescription)", to: fallbackLog)
    exit(1)
}
