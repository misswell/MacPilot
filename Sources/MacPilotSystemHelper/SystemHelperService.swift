import Foundation
import MacPilotSystemIPC
import OSLog

/// root LaunchDaemon 服务。
///
/// 安全边界：
///  - 只暴露 `MacPilotSystemHelperProtocol` 的两个固定接口，不接受任何
///    动态命令、脚本或参数。
///  - 接受连接前先用 code signing requirement 验证客户端（主程序）。
///  - 唯一执行的操作是固定的 `/bin/launchctl reboot userspace`。
final class SystemHelperService: NSObject, NSXPCListenerDelegate, MacPilotSystemHelperProtocol, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.misswell.macpilot",
        category: "SystemHelper"
    )
    private let rebootQueue = DispatchQueue(
        label: "com.misswell.macpilot.system-helper.reboot",
        qos: .userInitiated
    )
    private let rebootGate = UserspaceRebootGate()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // 必须在 resume() 之前设置：验证连接方的代码签名。
        newConnection.setCodeSigningRequirement(
            SystemHelperSigning.clientRequirementForCurrentProcess()
        )
        newConnection.exportedInterface = NSXPCInterface(
            with: MacPilotSystemHelperProtocol.self
        )
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func requestUserspaceReboot(withReply reply: @escaping (Bool, String?) -> Void) {
        guard geteuid() == 0 else {
            Self.logger.error("Userspace reboot refused: helper is not running as root")
            reply(false, SystemHelperRebootError.notRunningAsRoot.rawValue)
            return
        }
        guard rebootGate.tryScheduleReboot() else {
            Self.logger.notice("Userspace reboot refused: already scheduled")
            reply(false, SystemHelperRebootError.alreadyScheduled.rawValue)
            return
        }
        // 先回复再执行：成功的 userspace reboot 会销毁包括本 XPC 连接在内的
        // 整个 user space，调用方不能等这个命令"执行完成"。
        reply(true, nil)
        Self.logger.notice("Userspace reboot scheduled; executing in 0.5s")
        rebootQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.runUserspaceReboot()
        }
    }

    private func runUserspaceReboot() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SystemHelperRebootCommand.executablePath)
        process.arguments = SystemHelperRebootCommand.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.logger.error(
                "Failed to run \(SystemHelperRebootCommand.executablePath, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
