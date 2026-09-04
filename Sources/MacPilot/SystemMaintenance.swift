import SwiftUI
import ServiceManagement
import MacPilotSystemIPC

// MARK: - 系统维护（软重启 macOS）
//
// MacPilot 主程序（普通用户权限）→ XPC → root Helper（SMAppService LaunchDaemon）
// → 固定执行 `/bin/launchctl reboot userspace`。
// UI 只与 SystemMaintenanceService 交互，不直接接触 SMAppService / NSXPCConnection。

/// Helper 守护进程在设置界面中的生命周期状态。
enum SystemHelperState: Equatable {
    case unavailable
    case notRegistered
    case requiresApproval
    case enabled
}

/// 执行软重启前必须通过的安全闸门。
enum RebootGuard: Equatable {
    case screenRecordingActive
    case softwareUpdateActive

    var messageKey: String {
        switch self {
        case .screenRecordingActive: "softRestartRecordingActive"
        case .softwareUpdateActive: "softRestartUpdateActive"
        }
    }
}

/// 失败信息（detail 为技术细节，经 AppText 的 %@ 参数展示）。
enum SystemMaintenanceFailure: Equatable {
    case helperRegistration(String)
    case helperReboot(String)

    var messageKey: String { "systemHelperFailed" }
}

@MainActor
final class SystemMaintenanceService: ObservableObject {
    @Published private(set) var state: SystemHelperState = .unavailable
    @Published private(set) var failure: SystemMaintenanceFailure?

    private let helperService = SMAppService.daemon(plistName: SystemHelperIdentity.plistName)
    private var connection: NSXPCConnection?
    private nonisolated static let xpcTimeout: Duration = .seconds(15)

    // MARK: 状态

    nonisolated static func state(for status: SMAppService.Status) -> SystemHelperState {
        state(for: status, daemonPlistExists: bundledDaemonPlistExists)
    }

    nonisolated static func state(
        for status: SMAppService.Status,
        daemonPlistExists: Bool
    ) -> SystemHelperState {
        switch status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound:
            // 新版 macOS 对「存在于 bundle 但从未注册」的服务一律返回
            // .notFound（注册过再注销才会回到 .notRegistered）。只有当
            // 打包的 LaunchDaemon plist 确实不在 bundle 里时才算「缺失」。
            daemonPlistExists ? .notRegistered : .unavailable
        @unknown default: .unavailable
        }
    }

    nonisolated private static var bundledDaemonPlistExists: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons")
                .appendingPathComponent(SystemHelperIdentity.plistName)
                .path
        )
    }

    func refreshStatus() {
        state = Self.state(for: helperService.status)
    }

    /// 只在用户明确点击「启用系统维护功能」后调用，App 启动时不触发授权弹窗。
    func registerHelper() {
        do {
            try helperService.register()
            failure = nil
        } catch {
            failure = .helperRegistration(error.localizedDescription)
        }
        refreshStatus()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: 安全闸门

    /// 纯函数，便于单测：录屏进行中或软件更新进行中一律禁止软重启。
    nonisolated static func rebootGuard(
        screenRecordingState: ScreenRecordingState,
        isDeviceRecording: Bool,
        isSoftwareUpdateBusy: Bool
    ) -> RebootGuard? {
        if screenRecordingState == .recording
            || screenRecordingState == .paused
            || isDeviceRecording {
            return .screenRecordingActive
        }
        if isSoftwareUpdateBusy {
            return .softwareUpdateActive
        }
        return nil
    }

    // MARK: XPC

    /// 请求 root Helper 执行软重启。Helper 会先回复 accepted，再延迟 0.5 秒
    /// 执行重启；成功的重启会直接销毁本进程，因此不等待"执行完成"。
    func requestUserspaceReboot() async {
        refreshStatus()
        guard state == .enabled else { return }

        let connection = makeConnection()
        self.connection = connection

        let outcome = await requestReboot(connection: connection)
        switch outcome {
        case .accepted:
            failure = nil
        case .refused(let code):
            failure = .helperReboot(code)
            invalidate(connection)
        case .failed(let detail):
            failure = .helperReboot(detail)
            invalidate(connection)
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let serviceName = SystemHelperIdentity.runtimeServiceName
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        // 双向验证的另一半：主程序验证对面的 Helper 身份。
        connection.setCodeSigningRequirement(
            SystemHelperSigning.helperRequirementForCurrentProcess(helperServiceName: serviceName)
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: MacPilotSystemHelperProtocol.self
        )
        connection.resume()
        return connection
    }

    private func invalidate(_ connection: NSXPCConnection) {
        connection.invalidate()
        if self.connection === connection {
            self.connection = nil
        }
    }

    private func requestReboot(connection: NSXPCConnection) async -> XPCOutcome {
        let box = RebootReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.deliver(.failed(error.localizedDescription))
        }
        guard let helper = proxy as? MacPilotSystemHelperProtocol else {
            return .failed("xpcProxyUnavailable")
        }
        let timeoutTask = Task.detached(priority: .utility) { [weak box] in
            try? await Task.sleep(for: Self.xpcTimeout)
            box?.deliver(.failed("xpcTimeout"))
        }
        let outcome: XPCOutcome = await withCheckedContinuation { continuation in
            box.waitForReply(continuation)
            helper.requestUserspaceReboot { accepted, errorCode in
                if accepted {
                    box.deliver(.accepted)
                } else {
                    box.deliver(.refused(errorCode ?? SystemHelperRebootError.unknown.rawValue))
                }
            }
        }
        timeoutTask.cancel()
        return outcome
    }
}

private enum XPCOutcome: Sendable {
    case accepted
    case refused(String)
    case failed(String)
}

/// 保证 reply / errorHandler / 超时三方竞争时，continuation 只恢复一次。
private final class RebootReplyBox: @unchecked Sendable {    private let lock = NSLock()
    private var storedOutcome: XPCOutcome?
    private var continuation: CheckedContinuation<XPCOutcome, Never>?

    func waitForReply(_ continuation: CheckedContinuation<XPCOutcome, Never>) {
        lock.lock()
        if let storedOutcome {
            lock.unlock()
            continuation.resume(returning: storedOutcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func deliver(_ outcome: XPCOutcome) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        storedOutcome = outcome
        lock.unlock()
    }
}

// MARK: - 设置页卡片

struct SystemMaintenanceSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @StateObject private var service = SystemMaintenanceService()
    @State private var showsConfirmAlert = false
    @State private var showsFinalConfirmAlert = false
    @State private var guardMessageKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("systemMaintenance")).font(.headline)
            Text(t("systemMaintenanceDescription"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(t("softRestartWarning"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            statusHints

            HStack {
                Spacer()
                actionButton
            }
        }
        .task { service.refreshStatus() }
        // 软重启会关闭所有应用，执行前必须经过两层确认：
        // 第一层说明影响，第二层为最终确认。
        .alert(t("softRestartConfirmTitle"), isPresented: $showsConfirmAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("softRestartAction"), role: .destructive) {
                showsFinalConfirmAlert = true
            }
        } message: {
            Text(t("softRestartConfirmMessage"))
        }
        .alert(t("softRestartFinalConfirmTitle"), isPresented: $showsFinalConfirmAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("softRestartFinalConfirmAction"), role: .destructive) {
                Task { await service.requestUserspaceReboot() }
            }
        } message: {
            Text(t("softRestartFinalConfirmMessage"))
        }
    }

    /// Helper 生命周期与安全闸门的内联提示。
    @ViewBuilder private var statusHints: some View {
        if let guardMessageKey {
            hintBox(t(guardMessageKey))
        } else if let failure = service.failure {
            hintBox(t(failure.messageKey, failureDetail(failure)), color: .red)
        } else {
            switch service.state {
            case .requiresApproval:
                hintBox(t("systemHelperRequiresApproval"))
            case .unavailable:
                hintBox(t("systemHelperMissing"))
            case .notRegistered, .enabled:
                EmptyView()
            }
        }
    }

    /// Helper 状态对应的操作按钮；仅在 .enabled 时显示破坏性软重启按钮。
    @ViewBuilder private var actionButton: some View {
        switch service.state {
        case .enabled:
            Button(t("softRestartMacOS"), role: .destructive) {
                confirmSoftRestart()
            }
        case .notRegistered:
            Button(t("systemHelperEnable")) {
                service.registerHelper()
            }
        case .requiresApproval:
            Button(t("systemHelperOpenSettings")) {
                service.openSystemSettings()
            }
        case .unavailable:
            EmptyView()
        }
    }

    private func confirmSoftRestart() {
        guardMessageKey = nil
        if let violation = SystemMaintenanceService.rebootGuard(
            screenRecordingState: model.screenRecording.state,
            isDeviceRecording: model.screenRecording.isDeviceRecording,
            isSoftwareUpdateBusy: model.updater.state.isBusy
        ) {
            guardMessageKey = violation.messageKey
            return
        }
        showsConfirmAlert = true
    }

    private func failureDetail(_ failure: SystemMaintenanceFailure) -> String {
        switch failure {
        case .helperRegistration(let detail), .helperReboot(let detail):
            detail
        }
    }

    private func hintBox(_ text: String, color: Color = .orange) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: model.language, arguments: arguments)
    }
}

