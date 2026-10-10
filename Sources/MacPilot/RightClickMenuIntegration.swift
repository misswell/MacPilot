//
//  RightClickMenuIntegration.swift
//  MacPilot
//
//  Finder 右键菜单融合层。
//  MacPilot 主 App 通过 RightClickMenuCoordinator 与内嵌的 FinderSync 扩展通信，
//  让 Finder 右键菜单具备：复制路径、直接删除、隐藏/显示、AirDrop、
//  外部应用打开、新建文件、常用目录快捷访问等能力。
//

import AppKit
import Foundation
import MacPilotRightClickKit
import MacPilotUpdaterSupport

extension MacPilotModel {
    /// Finder 右键菜单协调器（启动时创建）。
    var rightClickMenu: RightClickMenuCoordinator { RightClickMenuCoordinator.shared }

    /// 启动 Finder 右键菜单（应在 applicationDidFinishLaunching 时调用）。
    func startRightClickMenu() {
        rightClickMenu.recoverExtension = {
            let application = Bundle.main.bundleURL
            guard FileManager.default.fileExists(atPath: application
                .appendingPathComponent("Contents/PlugIns/FinderSync.appex").path) else { return }
            do {
                let recovery = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try FinderSyncRegistration.recoverIfEnabled(
                        at: application,
                        journal: .standard,
                        execute: FinderSyncRecoveryRunner.run
                    )
                }
                let recovered = try await withTaskCancellationHandler {
                    try await recovery.value
                } onCancel: {
                    recovery.cancel()
                }
                DiagnosticLog.write("FinderSync", "startup registration recovery completed repaired=\(recovered)")
            } catch is CancellationError {
                DiagnosticLog.write("FinderSync", "startup registration recovery cancelled with feature shutdown")
            } catch {
                DiagnosticLog.write("FinderSync", "startup registration recovery failed error=\(error.localizedDescription)")
            }
        }
        rightClickMenu.start()
    }
}

private enum FinderSyncRecoveryRunner {
    /// Registration runs off the main actor, with a deadline for each command
    /// so an unresponsive system registry cannot hold recovery indefinitely.
    nonisolated static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MacPilot.FinderSyncRegistration", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty
                    ? "pluginkit exited with status \(process.terminationStatus)"
                    : output.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return output
    }
}
