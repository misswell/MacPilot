import Testing
import ServiceManagement
@testable import MacPilot
import MacPilotSystemIPC

struct SystemMaintenanceTests {
    // MARK: 1. 命令不可改变

    @Test func rebootCommandIsPinnedToUserspaceLaunchctl() {
        #expect(SystemHelperRebootCommand.executablePath == "/bin/launchctl")
        #expect(SystemHelperRebootCommand.arguments == ["reboot", "userspace"])
    }

    @Test func helperServiceNameIsDerivedFromBundleIdentifier() {
        #expect(
            SystemHelperIdentity.serviceName(forBundleIdentifier: "com.misswell.macpilot")
                == "com.misswell.macpilot.system-helper"
        )
        #expect(
            SystemHelperIdentity.serviceName(forBundleIdentifier: "com.misswell.octopilot")
                == "com.misswell.octopilot.system-helper"
        )
        #expect(SystemHelperIdentity.plistName == "MacPilotSystemHelper.plist")
        #expect(SystemHelperIdentity.executableName == "MacPilotSystemHelper")
    }

    // MARK: 2. Helper 状态映射

    @Test func helperDaemonStatusMapsToUIState() {
        #expect(
            SystemMaintenanceService.state(for: .notRegistered, daemonPlistExists: true)
                == .notRegistered
        )
        #expect(
            SystemMaintenanceService.state(for: .requiresApproval, daemonPlistExists: true)
                == .requiresApproval
        )
        #expect(
            SystemMaintenanceService.state(for: .enabled, daemonPlistExists: true) == .enabled
        )
    }

    @Test func notFoundTreatedAsUnregisteredWhileDaemonPlistShipped() {
        // 新版 macOS 对未注册服务返回 .notFound；只要 LaunchDaemon plist
        // 随包存在就按「未注册」处理，引导用户启用而不是提示重装。
        #expect(
            SystemMaintenanceService.state(for: .notFound, daemonPlistExists: true)
                == .notRegistered
        )
        #expect(
            SystemMaintenanceService.state(for: .notFound, daemonPlistExists: false)
                == .unavailable
        )
    }

    // MARK: 3. 录屏保护

    @Test func activeScreenRecordingBlocksReboot() {
        #expect(
            SystemMaintenanceService.rebootGuard(
                screenRecordingState: .recording,
                isDeviceRecording: false,
                isSoftwareUpdateBusy: false
            ) == .screenRecordingActive
        )
        #expect(
            SystemMaintenanceService.rebootGuard(
                screenRecordingState: .paused,
                isDeviceRecording: false,
                isSoftwareUpdateBusy: false
            ) == .screenRecordingActive
        )
        #expect(
            SystemMaintenanceService.rebootGuard(
                screenRecordingState: .idle,
                isDeviceRecording: true,
                isSoftwareUpdateBusy: false
            ) == .screenRecordingActive
        )
    }

    @Test func idleScreenRecordingDoesNotBlockReboot() {
        #expect(
            SystemMaintenanceService.rebootGuard(
                screenRecordingState: .idle,
                isDeviceRecording: false,
                isSoftwareUpdateBusy: false
            ) == nil
        )
    }

    // MARK: 4. Update 保护

    @Test func busySoftwareUpdaterBlocksReboot() {
        #expect(
            SystemMaintenanceService.rebootGuard(
                screenRecordingState: .idle,
                isDeviceRecording: false,
                isSoftwareUpdateBusy: true
            ) == .softwareUpdateActive
        )
    }

    // MARK: 5. 重复请求

    @Test func duplicateRebootRequestsAreRejected() {
        let gate = UserspaceRebootGate()
        #expect(gate.tryScheduleReboot())
        #expect(!gate.tryScheduleReboot())
        #expect(!gate.tryScheduleReboot())
    }
}
