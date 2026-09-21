// Portions adapted from LeftOpen:
// https://github.com/SonghaiFan/leftopen
//
// Copyright (c) 2026 Songhai Fan
// Licensed under the MIT License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

public enum LocalPortCommandRunner {
    /// Runs a command without invoking a shell.  stdout is drained before
    /// waiting for the child so a verbose command cannot deadlock on a full
    /// pipe.  lsof uses exit status 1 for a valid empty listener result.
    public static func output(
        _ executable: String,
        _ arguments: [String],
        allowEmptyLsof: Bool = false
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw LocalPortScanError.missingTool(path: executable)
        }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw LocalPortScanError.commandFailed(command: executable, status: -1)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 || (allowEmptyLsof && status == 1) else {
            throw LocalPortScanError.commandFailed(command: executable, status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
