import Darwin
import Foundation

private enum UpdaterError: LocalizedError {
    case invalidArguments
    case parentDidNotExit
    case launchFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid updater arguments."
        case .parentDidNotExit: "MacPilot did not exit before the update timeout."
        case .launchFailed(let status): "Could not relaunch MacPilot (open exited with status \(status))."
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

    init() throws {
        let values = CommandLine.arguments
        guard values.count == 7, let parentPID = pid_t(values[1]), parentPID > 0 else {
            throw UpdaterError.invalidArguments
        }
        self.parentPID = parentPID
        sourceApplication = URL(fileURLWithPath: values[2])
        destinationApplication = URL(fileURLWithPath: values[3])
        stagingDirectory = URL(fileURLWithPath: values[4])
        helperDirectory = URL(fileURLWithPath: values[5])
        logURL = URL(fileURLWithPath: values[6])
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

private func launch(_ application: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [application.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UpdaterError.launchFailed(process.terminationStatus)
    }
}

private func install(_ arguments: UpdaterArguments) throws {
    try waitForParent(arguments.parentPID)

    let fileManager = FileManager.default
    let parent = arguments.destinationApplication.deletingLastPathComponent()
    let token = UUID().uuidString
    let incoming = parent.appendingPathComponent(".MacPilot-update-\(token).app")
    let backupName = ".MacPilot-backup-\(token).app"
    let backup = parent.appendingPathComponent(backupName)

    do {
        try fileManager.copyItem(at: arguments.sourceApplication, to: incoming)
        _ = try fileManager.replaceItemAt(
            arguments.destinationApplication,
            withItemAt: incoming,
            backupItemName: backupName,
            options: .withoutDeletingBackupItem
        )
        do {
            try launch(arguments.destinationApplication)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                _ = try? fileManager.replaceItemAt(arguments.destinationApplication, withItemAt: backup)
                try? launch(arguments.destinationApplication)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)
        appendLog("Update installed at \(arguments.destinationApplication.path)", to: arguments.logURL)
    } catch {
        try? fileManager.removeItem(at: incoming)
        if !fileManager.fileExists(atPath: arguments.destinationApplication.path),
           fileManager.fileExists(atPath: backup.path) {
            try? fileManager.moveItem(at: backup, to: arguments.destinationApplication)
        }
        appendLog("Update failed: \(error.localizedDescription)", to: arguments.logURL)
        if fileManager.fileExists(atPath: arguments.destinationApplication.path) {
            try? launch(arguments.destinationApplication)
        }
        throw error
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
