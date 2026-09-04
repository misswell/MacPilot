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
        #expect(SystemMaintenanceService.state(for: .notRegistered) == .notRegistered)
        #expect(SystemMaintenanceService.state(for: .requiresApproval) == .requiresApproval)
        #expect(SystemMaintenanceService.state(for: .enabled) == .enabled)
        #expect(SystemMaintenanceService.state(for: .notFound) == .unavailable)
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
