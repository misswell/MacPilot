import AppKit
import ApplicationServices
import Darwin
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let macPilotDeepLink = Notification.Name("MacPilot.deepLink")
}

@main
struct MacPilotApp: App {
    @StateObject private var model = MacPilotModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MacPilot", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView(
                pictureInPicture: model.pictureInPicture,
                inputSources: model.inputSources,
                windowSwitcher: model.windowSwitcher,
                smoothScrolling: model.smoothScrolling,
                clipboard: model.clipboard
            ).environmentObject(model)
        } label: {
            Image(systemName: model.isEnforcing ? "timer" : "pause.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 登录启动期间为 true，用于隐藏主窗口，避免开机时窗口闪现。
    private var hideWindowDuringLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 尽早判断登录启动：此时 SwiftUI 尚未完成窗口显示，先隐藏已存在的窗口以减少闪现。
        // 手动双击启动时父进程不是 loginwindow，主窗口正常显示。
        hideWindowDuringLaunch = Self.wasLaunchedAtLogin()
        if hideWindowDuringLaunch { hideRegularWindows() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 登录启动时不弹出主窗口，仅保留菜单栏图标，应用在后台运行。
        guard hideWindowDuringLaunch else { return }
        hideRegularWindows()
        // SwiftUI 可能在本回调之后才完成主窗口的显示，
        // 延迟一小段时间再次隐藏以兜底，确保开机时无窗口闪现。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            // 仅当应用仍处于后台（用户尚未主动激活）时隐藏，
            // 避免误隐藏用户从菜单栏主动打开的窗口。
            guard NSApp.isActive == false else { return }
            self?.hideRegularWindows()
        }
        hideWindowDuringLaunch = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .macPilotDeepLink, object: url)
        }
    }

    /// 隐藏所有非面板窗口（菜单栏弹窗等面板不受影响），仅保留菜单栏图标。
    private func hideRegularWindows() {
        for window in NSApp.windows where !window.isKind(of: NSPanel.self) {
            window.orderOut(nil)
        }
    }

    /// 判断本次启动是否由登录项触发：登录启动时父进程是 loginwindow。
    private static func wasLaunchedAtLogin() -> Bool {
        parentProcessName() == "loginwindow"
    }

    private static func parentProcessName() -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getppid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let count = UInt32(mib.count)
        let result = mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
            sysctl(pointer.baseAddress, count, &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
    }
}

struct QuitRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String
    var bundlePath: String?
    var inactiveHideMinutes: Int?
    var inactiveCloseMinutes: Int?
    var inactiveQuitMinutes: Int?
    var hiddenQuitMinutes: Int?
    var isEnabled = true

    var hasAction: Bool { inactiveHideMinutes != nil || inactiveCloseMinutes != nil || inactiveQuitMinutes != nil || hiddenQuitMinutes != nil }
}

struct AppVersionInfo: Equatable {
    let version: String
    let build: String

    static func current(bundle: Bundle = .main) -> AppVersionInfo {
        AppVersionInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        )
    }

    func localizedDescription(language: AppLanguage) -> String {
        AppText.value("versionLabel", language: language, version, build)
    }
}

private struct QuitRuntimeState {
    var lastActiveAt: Date?
    var hiddenAt: Date?
    var didHideSinceActive = false
    var didCloseSinceActive = false
}

private enum WindowCloseResult {
    case noClosableWindows
    case closed
    case failed

    var postLaunchResult: Bool? {
        switch self {
        case .noClosableWindows: nil
        case .closed: true
        case .failed: false
        }
    }
}

struct QuitterImportPreview: Identifiable {
    let id = UUID()
    let rules: [QuitRule]
    let skippedCount: Int
    let isEnforcing: Bool?
}

enum LaunchVisibilityMode: String, CaseIterable, Codable, Identifiable {
    case foreground
    case hidden
    case closeWindows

    var id: String { rawValue }
    var requiresAccessibility: Bool { self == .closeWindows }

    var titleKey: String {
        switch self {
        case .foreground: "launchModeForeground"
        case .hidden: "launchModeHidden"
        case .closeWindows: "launchModeCloseWindows"
        }
    }

    var hintKey: String {
        switch self {
        case .foreground: "launchForegroundHint"
        case .hidden: "launchHiddenHint"
        case .closeWindows: "launchCloseWindowsHint"
        }
    }
}

struct AccessibilityResetCommand: Sendable {
    let bundleIdentifier: String

    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/tccutil") }
    var arguments: [String] { ["reset", "Accessibility", bundleIdentifier] }

    @discardableResult
    func run() throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum AccessibilityResetExecution: Sendable {
    case success(Int32)
    case failure(String)
}

struct AccessibilityRecoveryRequest {
    private static let key = "MacPilot.requestAccessibilityAfterReset"
    private static let legacyKey = "OctoPilot.requestAccessibilityAfterReset"

    static func consume(
        from defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: AppIdentity.legacyBundleIdentifier)
    ) -> Bool {
        if consumeKey(from: defaults) { return true }
        guard let legacyDefaults, legacyDefaults !== defaults else { return false }
        return consumeKey(from: legacyDefaults)
    }

    private static func consumeKey(from defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: key) {
            defaults.removeObject(forKey: key)
            return true
        }
        guard defaults.bool(forKey: legacyKey) else { return false }
        defaults.removeObject(forKey: legacyKey)
        return true
    }
}

struct LaunchRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String
    var bundlePath: String
    var delaySeconds: Int = 30
    var isEnabled = true
    var visibilityMode: LaunchVisibilityMode = .hidden

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        bundlePath: String,
        delaySeconds: Int = 30,
        isEnabled: Bool = true,
        visibilityMode: LaunchVisibilityMode = .hidden
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.delaySeconds = delaySeconds
        self.isEnabled = isEnabled
        self.visibilityMode = visibilityMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, appName, bundleIdentifier, bundlePath, delaySeconds, isEnabled, visibilityMode, activateOnLaunch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        bundlePath = try container.decode(String.self, forKey: .bundlePath)
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 30
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        if let storedMode = try container.decodeIfPresent(LaunchVisibilityMode.self, forKey: .visibilityMode) {
            visibilityMode = storedMode
        } else {
            visibilityMode = try container.decodeIfPresent(Bool.self, forKey: .activateOnLaunch) == true ? .foreground : .hidden
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(bundlePath, forKey: .bundlePath)
        try container.encode(delaySeconds, forKey: .delaySeconds)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(visibilityMode, forKey: .visibilityMode)
        try container.encode(visibilityMode == .foreground, forKey: .activateOnLaunch)
    }
}

enum LaunchRuntimeState: Equatable {
    case pending(Date)
    case launching
    case launched
    case skippedAlreadyRunning
    case cancelled
    case failed(String)
}

private actor LaunchGate {
    private let minimumStartInterval: TimeInterval
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(minimumStartInterval: TimeInterval) {
        self.minimumStartInterval = minimumStartInterval
    }

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        await acquire()
        let startedAt = Date()
        await operation()

        if !Task.isCancelled {
            let remaining = minimumStartInterval - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
        release()
    }

    private func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }
    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }
}

enum AppText {
    private static let chinese: [String: String] = [
        "rules": "退出", "settings": "设置", "addApp": "添加应用", "apps": "应用",
        "versionLabel": "版本 %@（构建 %@）",
        "rulesSubtitle": "在应用闲置一段时间后自动隐藏、关闭窗口或退出。",
        "dropApp": "拖入应用以添加规则", "invalidDrop": "请拖入 macOS 应用（.app）以创建规则。",
        "duplicateRule": "已存在 \"%@\" 的规则。", "selfRule": "MacPilot 不能管理自身。", "enforcing": "规则执行中", "paused": "规则已暂停",
        "enabledChecked": "%d 条已启用 · 检查于 %@", "noApps": "尚未添加应用",
        "noAppsDetail": "添加一个应用，在闲置后自动隐藏、关闭窗口或退出。", "addFirstApp": "添加第一个应用",
        "edit": "编辑", "editRule": "编辑规则", "deleteRule": "删除规则", "remove": "移除",
        "removeConfirmTitle": "确认移除", "removeConfirmMessage": "确定要移除“%@”吗？此操作会删除对应规则。",
        "hideAfter": "闲置 %d 分钟后隐藏", "closeAfter": "闲置 %d 分钟后关闭窗口", "quitAfter": "闲置 %d 分钟后退出", "quitHidden": "隐藏 %d 分钟后退出",
        "addRule": "添加应用规则", "editAppRule": "编辑应用规则", "ruleDetail": "选择一个应用，然后设置一个或多个自动操作。",
        "hideInactive": "闲置后隐藏", "closeInactive": "闲置后关闭窗口", "quitInactive": "闲置后退出", "quitAfterHidden": "隐藏后退出",
        "closeWindowHint": "关闭应用的可关闭窗口，但保留后台进程。MacPilot 会模拟在前台点击关闭按钮，能否移除 Dock 图标取决于该应用是否据此转入菜单栏后台。",
        "accessibilityRequired": "“关闭窗口”需要辅助功能权限。如果升级后已勾选但仍无效，可一键重置权限并退出 MacPilot；重新打开后再允许权限。当前应用：%@",
        "openAccessibilitySettings": "打开辅助功能设置",
        "resetAccessibility": "重置权限并退出",
        "resettingAccessibility": "正在重置…",
        "accessibilityRecoveryHint": "系统仍未确认当前版本的权限。如果列表中已开启但这里仍显示，请直接重置旧授权记录。",
        "accessibilityResetFailed": "无法重置辅助功能权限：%@",
        "accessibilityResetStatus": "tccutil 退出状态：%d",
        "cancel": "取消", "save": "存储", "chooseApp": "选择应用", "chooseRunning": "选择正在运行的应用",
        "browse": "浏览…", "minute": "分钟", "minutes": "分钟", "language": "语言",
        "application": "应用", "selectedApp": "已选应用", "changeApp": "更换应用", "runningApps": "正在运行的应用",
        "browseApplications": "从磁盘选择应用", "noRunningApps": "未检测到可选的运行应用",
        "configFile": "配置文件", "configDescription": "规则和偏好保存在此本机文件中。更新或替换 MacPilot.app 不会影响它。",
        "revealInFinder": "在访达中显示", "configSaveError": "无法保存配置文件：%@",
        "importQuitter": "导入 Quitter 配置", "importQuitterDescription": "直接从 Quitter 的本机偏好文件导入规则；已存在相同应用标识的规则会被跳过。",
        "importQuitterSuccess": "已导入 %d 条规则，跳过 %d 条重复或无效规则。", "importQuitterEmpty": "没有发现可导入的新规则。",
        "importQuitterError": "无法导入配置文件：%@", "importQuitterInvalid": "这不是受支持的 Quitter 偏好文件。",
        "importQuitterNotFound": "未找到 Quitter 配置文件：%@",
        "importQuitterConfirmTitle": "确认导入", "importQuitterConfirmMessage": "找到 %d 条可导入规则，另有 %d 条重复或无效规则将被跳过。是否导入？",
        "import": "导入",
        "languageDescription": "选择 MacPilot 的显示语言。更改会立即生效。", "systemLanguage": "跟随系统",
        "english": "English", "simplifiedChinese": "简体中文", "checkNow": "立即检查", "startAtLogin": "登录时启动",
        "startAtLoginHint": "登录 Mac 后自动在后台启动 MacPilot。",
        "showApp": "显示 MacPilot", "quitApp": "退出 MacPilot", "enabledStatus": "MacPilot：已启用",
        "disabledStatus": "MacPilot：已停用", "disableApp": "停用 MacPilot", "enableApp": "启用 MacPilot",
        "loginError": "无法更新登录启动项：%@", "aboutAutomation": "自动化", "manageRules": "管理应用规则和界面偏好。",
        "quitsIn": "将在 %d 分钟后退出"
        , "launch": "启动", "launchSubtitle": "在登录后按设定延迟启动应用。", "launchApps": "启动应用",
        "addLaunchApp": "添加启动应用", "addLaunchRule": "添加启动规则", "editLaunchRule": "编辑启动规则",
        "launchRuleDetail": "选择一个应用，并设置从 MacPilot 登录启动开始计算的延迟秒数。",
        "launchAfter": "登录后 %d 秒启动", "delaySeconds": "延迟秒数", "launchVisibility": "启动后模式",
        "launchModeForeground": "显示到前台", "launchModeHidden": "隐藏应用", "launchModeCloseWindows": "关闭窗口，保留后台",
        "launchForegroundHint": "应用启动后显示到前台。",
        "launchHiddenHint": "应用启动后自动隐藏，并恢复之前的前台应用。",
        "launchCloseWindowsHint": "应用启动 10 秒后切到前台并模拟点击关闭按钮，保留后台或菜单栏进程。能否移除 Dock 图标取决于该应用。",
        "launchCloseFailed": "应用已启动，但无法关闭其窗口",
        "runNow": "立即执行", "cancelLaunches": "取消待启动任务", "launchEnabled": "启动计划已启用", "launchPaused": "启动计划已暂停",
        "launchIn": "%d 秒后启动", "launching": "正在启动", "launched": "已启动", "alreadyRunning": "已跳过：应用已在运行",
        "launchCancelled": "已取消", "launchFailed": "启动失败：%@", "noLaunchApps": "尚未添加启动应用",
        "noLaunchAppsDetail": "添加应用并设置登录后的启动延迟。", "addFirstLaunchApp": "添加第一个启动应用",
        "loginRequired": "启用“登录时启动”后，启动规则会在每次开机登录时自动执行。", "seconds": "秒",
        "launchDuplicate": "已存在 \"%@\" 的启动规则。", "launchPlanRunning": "%d 个任务正在等待启动",
        "launchPlanIdle": "没有待启动任务", "launchPlanDone": "本次启动计划已完成",
        "bleUnlock": "BLE 解锁", "ble": "BLE", "bleUnlockSubtitle": "根据 BLE 设备（iPhone、Apple Watch 等）的接近程度自动锁定和解锁 Mac。",
        "bleNotConfigured": "尚未选择设备", "bleDeviceNotDetected": "未检测到设备", "bleNoDevice": "尚未选择设备",
        "bleLockNow": "立即锁定屏幕", "bleDevice": "设备", "bleScanning": "正在扫描…", "bleSelectDevice": "选择设备",
        "bleDeviceHint": "打开设备菜单开始扫描附近的 BLE 设备，选择你的 iPhone、Apple Watch 或其他 BLE 设备。需要使用固定 MAC 地址的设备。",
        "bleUnlockRSSI": "解锁 RSSI", "bleLockRSSI": "锁定 RSSI", "bleLockDelay": "锁定延迟", "bleNoSignalTimeout": "无信号超时",
        "bleCloser": "更近", "bleFarther": "更远", "bleDisabled": "禁用",
        "bleUnlockRSSIInfo": "蓝牙信号强度阈值，达到此值时解锁。数值越大，设备需要越靠近才能解锁。选择“禁用”可关闭自动解锁。",
        "bleLockRSSIInfo": "蓝牙信号强度阈值，低于此值时锁定。数值越小，设备需要越远离才会锁定。选择“禁用”可关闭自动锁定。",
        "bleLockDelayInfo": "检测到设备远离后，等待多久再锁定。若在此时间内设备重新靠近，则不会锁定。",
        "bleTimeoutInfo": "距离最后一次收到信号到判定“信号丢失”并锁定的时间。若频繁出现“信号丢失”锁定，请增大此值。",
        "bleWakeOnProximity": "接近时唤醒", "bleWakeWithoutUnlocking": "唤醒但不解锁", "blePauseNowPlaying": "锁定时暂停播放",
        "bleUseScreensaver": "用屏幕保护程序锁定", "bleTurnOffScreen": "锁定时关闭屏幕", "blePassiveMode": "被动模式",
        "blePassiveModeInfo": "默认主动连接设备读取 RSSI，更稳定。若与其他蓝牙设备相互干扰，可开启被动模式仅靠扫描。",
        "bleSetPassword": "设置密码…", "bleEnable": "启用 BLE 解锁", "bleEnabledStatus": "BLE 解锁：已启用", "bleDisabledStatus": "BLE 解锁：已停用",
        "bleBluetoothOff": "蓝牙未打开", "bleEnterPassword": "请输入登录密码", "blePasswordInfo": "密码将安全保存在钥匙串中，仅在屏幕锁定时用于解锁。",
        "blePasswordStored": "密码已保存到钥匙串。", "blePasswordFailed": "无法保存密码：%@", "blePasswordNotSet": "尚未设置登录密码。请使用“设置密码…”。",
        "bleMinRSSI": "设置最小 RSSI…", "bleManage": "管理 BLE 解锁", "bleManageDevices": "在主窗口管理设备…",
        "bleNear": "接近", "bleAway": "离开", "bleLost": "信号丢失", "bleActive": "活动", "bleCurrentDevice": "当前设备", "bleChangeDevice": "更换设备",
        "bleRSSIDBm": "%ddBm", "bleRSSIActive": "%ddBm（活动）", "bleSeconds": "秒",
        "bleSignalStrength": "信号强度", "bleProximityStatus": "接近状态", "bleMonitoring": "正在监控", "bleIdle": "空闲",
        "bleThresholds": "触发阈值", "bleTiming": "时间参数", "bleBehavior": "行为选项", "bleSecurity": "密码与锁定",
        "bleRangeNear": "近", "bleRangeMid": "中", "bleRangeFar": "远", "bleRangeFarFar": "很远",
        "bleUnlockZone": "解锁区", "bleLockZone": "锁定区", "bleCurrent": "当前",
        "bleNoPassword": "未设置密码", "blePasswordSet": "密码已保存",
        "bleAccessRequired": "BLE 解锁需要辅助功能权限来模拟键盘解锁并锁定屏幕。当前应用：%@", "bleBluetoothRequired": "需要蓝牙权限才能扫描 BLE 设备。",
        "bleNoDevicesFound": "未发现附近 BLE 设备。",
        "inputSources": "输入法", "inputSourcesSubtitle": "按应用或浏览器网站自动切换 macOS 输入法，并显示切换提示。",
        "inputSourcesEnable": "启用输入法自动化", "inputSourcesEnabled": "输入法规则正在运行", "inputSourcesDisabled": "输入法规则已停用",
        "inputSourcesEnabledStatus": "输入法：已启用", "inputSourcesDisabledStatus": "输入法：已停用", "inputSourcesCycleNow": "切换到下一个输入法",
        "inputSourcesUnavailable": "没有找到可切换的键盘输入源。", "inputSourcesCurrent": "当前输入法", "inputSourcesNotDetected": "尚未检测到输入法",
        "inputSourcesActiveApp": "当前应用：%@", "refresh": "刷新", "inputSourcesDefault": "默认输入法",
        "inputSourcesDefaultHint": "没有匹配到应用或网站规则时使用此输入法；留空则保留系统当前选择。", "inputSourcesNoDefault": "不自动切换",
        "inputSourcesIndicator": "屏幕提示", "inputSourcesShowIndicator": "切换时显示输入法提示", "inputSourcesIndicatorPosition": "提示位置",
        "inputSourcesNearCursor": "鼠标附近", "inputSourcesScreenCenter": "屏幕中央", "inputSourcesIndicatorDuration": "显示时长",
        "inputSourcesShortcuts": "快捷键", "inputSourcesCycleShortcut": "启用全局切换快捷键",
        "inputSourcesCycleShortcutHint": "按 ⌥⌘I 切换到下一个可用输入法。全局快捷键需要辅助功能权限。",
        "inputSourcesCustomShortcuts": "自定义输入法快捷键", "inputSourcesAddShortcut": "添加快捷键",
        "inputSourcesNoShortcuts": "尚未配置直接切换快捷键。", "inputSourcesShortcutHint": "按下带修饰键的组合键来记录快捷键，例如 ⌥⌘1。相同组合键只保留最后一条。",
        "inputSourcesRecordShortcut": "按下快捷键…",
        "inputSourcesAccessibilityRequired": "需要辅助功能权限才能在其他应用中监听快捷键。", "inputSourcesGrantAccessibility": "授权辅助功能…",
        "inputSourcesAppRules": "应用规则", "inputSourcesAppRulesHint": "为每个应用指定输入法，也可以强制使用英文标点或功能键模式。",
        "inputSourcesNoAppRules": "尚未添加应用规则。", "inputSourcesBrowserRules": "浏览器网站规则",
        "inputSourcesBrowserRulesHint": "在 Safari、Chrome、Firefox 等浏览器中按域名或 URL 自动切换。",
        "inputSourcesNoBrowserRules": "尚未添加浏览器网站规则。", "inputSourcesEnglishPunctuation": "强制英文标点",
        "inputSourcesFunctionKeys": "标准功能键 F1–F12", "inputSourcesMediaKeys": "媒体键（亮度、音量等）",
        "inputSourcesAddAppRule": "添加应用输入法规则", "inputSourcesEditAppRule": "编辑应用输入法规则",
        "inputSourcesChooseApp": "选择应用", "inputSourcesTarget": "目标输入法", "inputSourcesFunctionKeyMode": "功能键模式",
        "inputSourcesUseSystemDefault": "使用系统默认", "inputSourcesAddBrowserRule": "添加浏览器网站规则",
        "inputSourcesEditBrowserRule": "编辑浏览器网站规则", "inputSourcesBrowser": "浏览器",
        "inputSourcesAnyBrowser": "所有支持的浏览器", "inputSourcesRuleType": "匹配类型",
        "inputSourcesDomainSuffix": "域名后缀", "inputSourcesDomain": "精确域名", "inputSourcesURLRegex": "URL 正则",
        "inputSourcesRuleValue": "域名或 URL 模式",
        "bleSortBy": "排序", "bleSortAdded": "加载顺序", "bleSortName": "名称", "bleSortSignal": "信号",
        "softwareUpdate": "软件更新", "updateDescription": "从 GitHub Releases 检查经过签名和 Apple 公证的新版本。",
        "checkForUpdates": "检查更新…", "checkingForUpdates": "正在检查更新…", "upToDate": "已是最新版本。",
        "updateAvailable": "发现新版本 %@。", "downloadAndInstall": "下载并安装", "downloadingUpdate": "正在下载更新…",
        "preparingUpdate": "正在验证并准备安装…", "updateFailed": "更新失败：%@", "currentVersion": "当前版本：%@",
        "releaseNotes": "发布说明", "updateWillRestart": "安装后 MacPilot 将自动重新启动。",
        "updateErrorRelease": "GitHub Release 信息或 macOS 安装包无效。", "updateErrorIntegrity": "下载文件的 SHA-256 校验失败。",
        "updateErrorVerification": "更新包未通过版本、开发者签名或 Gatekeeper 验证。",
        "updateErrorLocation": "无法从当前位置自动更新。请先将 MacPilot 移到可写的“应用程序”文件夹。",
        "updateErrorHelper": "当前 MacPilot 安装中缺少更新 helper。", "updateErrorNetwork": "网络请求失败：%@",
        "updateErrorCommand": "准备更新失败：%@",
        "fileCompression": "存储压缩", "fileCompressionSubtitle": "安全地减少文本类文件的实际磁盘占用，并保留内容、创建时间和修改时间。",
        "compressionFolder": "监控文件夹", "compressionNoFolder": "尚未选择文件夹", "compressionChooseFolder": "选择文件夹…",
        "compressionAddFolders": "添加文件夹…", "compressionRemoveFolder": "移除文件夹", "compressionFolderCount": "已添加 %d 个文件夹",
        "compressionRemoveFolderTitle": "移除监控文件夹？", "compressionRemoveFolderMessage": "移除后将不再扫描此文件夹，但不会删除或恢复其中的文件。\n%@",
        "compressionChoose": "选择", "compressionAutomatic": "定期自动压缩", "compressionAutomaticHint": "按文件变化增量处理；点击说明图标了解扫描方式。",
        "compressionAutomaticInfo": "自动扫描方式", "compressionAutomaticInfoHelp": "查看自动扫描方式",
        "compressionAutomaticInfoBody": "• 使用 macOS 文件事件监控多个文件夹，只检查新增或变化的路径。\n• 重复事件会短暂合并；文件在设定时间内未修改后才处理。\n• 首次启用时扫描全部目录；以后仅扫描新增目录，并每 24 小时校验一次。文件事件异常时扫描受影响的目录。\n• 文件逐个压缩，避免持续占用 CPU 和磁盘。\n\n系统限制：单个文件超过 512 MiB 时，macOS 不提供此类文件系统压缩，应用会在扫描阶段跳过。",
        "compressionRules": "压缩规则", "compressionExtensions": "文件后缀", "compressionRecommended": "使用推荐后缀",
        "compressionApply": "应用", "compressionExtensionsHint": "使用逗号或空格分隔。默认推荐文本、日志与结构化数据文件。",
        "compressionMinimumSize": "最小文件大小", "compressionStableFor": "保持未修改", "compressionMinimumSavings": "最低节省比例",
        "compressionMinutesValue": "%d 分钟", "compressionSafetyHint": "自动跳过正在使用的文件、Resource Fork、符号/硬链接、稀疏文件、云端占位文件、应用包和隐藏目录。替换前会校验内容与元数据。",
        "compressionAnalysis": "空间分析", "compressionScanNow": "立即扫描", "compressionScanPrompt": "选择文件夹并扫描，查看可安全压缩的文件。",
        "compressionCandidates": "待压缩文件", "compressionAlreadyCompressed": "已压缩文件", "compressionSpaceSaved": "已节省空间",
        "compressionViewAllCompressed": "查看全部 %d 个已压缩文件", "compressionCompressedListTitle": "已压缩文件",
        "compressionSearchFiles": "搜索文件路径", "compressionNoMatchingFiles": "没有匹配的文件", "compressionClose": "关闭",
        "compressionSortBy": "排序", "compressionSortLogicalSize": "逻辑大小（从大到小）", "compressionSortActualSize": "实际大小（从大到小）",
        "compressionUses": "实际占用 %@", "compressionLogical": "逻辑大小 %@", "compressionSizeDetail": "逻辑 %@ · 实际 %@", "compressionCompressFiles": "压缩 %d 个文件",
        "compressionRestoreFiles": "恢复 %d 个文件", "compressionCompressResult": "已压缩 %d 个文件，节省 %@；跳过 %d 个，失败 %d 个。",
        "compressionRestoreResult": "已恢复 %d 个文件，失败 %d 个。", "compressionCompressing": "正在压缩文件…", "compressionRestoring": "正在恢复文件…",
        "compressionFailedFile": "未处理：%@", "compressionRecoveryPreserved": "已保留原文件用于恢复：%@",
        "compressionErrorNoFolder": "请先选择文件夹。", "compressionErrorFolderUnavailable": "所选文件夹不可用。", "compressionErrorFileSystem": "所选文件夹使用 %@ 文件系统；透明压缩需要 APFS 或 HFS+。",
        "compressionErrorMonitoringUnavailable": "无法启动文件夹变化监控。请重新启用定期自动压缩。",
        "compressionErrorScan": "无法扫描文件夹：%@", "compressionErrorFileChanged": "文件在扫描后发生了变化。",
        "compressionErrorUnavailable": "macOS 未能压缩此文件。", "compressionErrorVerification": "压缩副本与原文件校验不一致。",
        "compressionErrorCommand": "macOS 压缩命令失败：%@", "compressionErrorCoordination": "无法安全协调文件访问：%@", "compressionErrorFileInUse": "文件正被其他进程使用，已跳过。", "compressionErrorReplacement": "无法原子替换原文件。",
        "compressionFolderIssue": "%@：%@"
        ,
        "screenCapture": "截屏与贴图", "screenCaptureSubtitle": "使用可自定义快捷键智能识别窗口和界面元素边界，支持贴图、OCR、标注与低资源定时截屏。",
        "scScreenshotEnabled": "启用截图功能", "scScreenshotDisabledHint": "关闭后不再监听截图快捷键、不运行定时截屏，也不会在后台占用截图相关资源。", "scScreenshotDisabled": "截图功能已停用，请先在截图设置中重新启用。",
        "scRecording": "屏幕录制", "scRecordingStart": "开始录制", "scRecordingStop": "停止录制", "scRecordingPause": "暂停录制", "scRecordingResume": "继续录制", "scRecordingCancel": "取消录制", "scRecordingOpenFolder": "打开录制文件夹", "scRecordingFormat": "格式", "scRecordingCaptureMode": "录制范围", "scRecordingArea": "框选区域", "scRecordingFullscreen": "全屏", "scRecordingApplication": "应用窗口", "scRecordingFPS": "帧率", "scRecordingFPSValue": "%d 帧/秒", "scRecordingCursor": "包含鼠标光标", "scRecordingSystemAudio": "录制系统声音", "scRecordingIdle": "未录制", "scRecordingPreparing": "准备中…", "scRecordingActive": "录制中 %@", "scRecordingPaused": "已暂停 %@", "scRecordingStopping": "正在保存…", "scRecordingLastFile": "最近录制：%@", "scRecordingExportGIF": "导出 GIF", "scRecordingConvertingGIF": "正在生成 GIF…", "scRecordingActions": "录制快捷操作", "scOpen": "打开",
        "scRecordingPermissionRequired": "需要屏幕录制权限才能录制屏幕。", "scRecordingNoDisplay": "没有可录制的显示器。", "scRecordingAlreadyRunning": "屏幕录制已经在进行中。", "scRecordingNotRunning": "当前没有进行中的屏幕录制。", "scRecordingWriterFailed": "无法创建录制文件。", "scRecordingNoVideoFrames": "没有收到可用的视频帧。", "scRecordingStreamFailed": "屏幕录制失败：%@", "scRecordingUnknownError": "屏幕录制失败，请重试。", "scRecordingGIFSourceUnavailable": "无法读取要转换的录制文件。", "scRecordingGIFNoFrames": "录制文件没有可用于 GIF 的画面。", "scRecordingGIFDestinationUnavailable": "无法创建 GIF 输出文件。", "scRecordingGIFFailed": "无法生成 GIF 文件。",
        "scSmartCapture": "智能截图", "scSmartCaptureHint": "移动鼠标自动识别窗口或界面元素，单击截图，Esc 或右键取消。",
        "scSmartCaptureNow": "开始截图", "scAreaCaptureNow": "区域框选截图", "scApplicationWindowCaptureNow": "应用窗口框选截图", "scFullscreenCaptureNow": "全屏截图", "scActiveWindowCaptureNow": "当前窗口截图", "scAreaAnnotateNow": "区域截图并标注", "scOCRCaptureNow": "区域截图并 OCR", "scScrollingCaptureNow": "滚动长截图", "scObjectCutoutNow": "抠图截图", "scEditShortcuts": "修改截图快捷键", "scEnableSmartCapture": "启用全局快捷键", "scChangeShortcut": "修改快捷键",
        "scShortcutModes": "截图快捷入口", "scStartMode": "开始", "scSmartCaptureShortcut": "智能元素截图快捷键", "scAreaCaptureShortcut": "区域框选截图快捷键", "scRepeatAreaShortcut": "重复上次区域快捷键", "scApplicationWindowShortcut": "应用窗口截图快捷键", "scFullscreenCaptureShortcut": "全屏截图快捷键", "scActiveWindowCaptureShortcut": "当前窗口截图快捷键", "scAreaAnnotateShortcut": "区域截图并标注快捷键", "scOCRShortcut": "OCR 截图快捷键", "scScrollingShortcut": "滚动长截图快捷键", "scObjectCutoutShortcut": "抠图截图快捷键",
        "scRepeatArea": "重复上次区域", "scNoLastArea": "还没有可重复的区域截图。",
        "scSmartCaptureAccessibilityRequired": "智能截图需要辅助功能权限。请在设置中明确点击授权后再试。",
        "scPinAfterSmartCapture": "截图后自动贴图", "scCopyAfterCapture": "截图后复制到剪贴板", "scShowQuickAccess": "截图后显示快捷操作", "scQuickAccessTitle": "截图快捷操作", "scQuickAccessHint": "截图后显示快捷操作，可复制、标注或按需贴图；不会自动贴图。", "scCaptureAreaUnavailable": "上次选择的区域已不可用。", "scCaptureCoordinateUnavailable": "无法定位鼠标所在显示器，请重试。", "scCaptureOutsideDisplay": "所选区域不在显示器范围内。", "scCaptureMultiDisplayAllocationFailed": "无法创建跨显示器截图。", "scCaptureMultiDisplayCompositionFailed": "无法合成跨显示器截图。", "scCaptureTimedOut": "屏幕截图等待画面超时。", "scCaptureCancelled": "屏幕截图已取消。", "scCaptureAlreadyFinished": "屏幕截图会话已结束。", "scCaptureInvalidFrame": "屏幕录制服务返回了无效画面。", "scActiveWindowUnavailable": "没有找到当前应用窗口。",
        "scShortcutHint": "裸键仅支持 F1–F20；字母、数字和其他普通键请至少加 Command、Option、Control 或 Shift。Esc 不能作为截图快捷键。",
        "scShortcutReserved": "Esc 保留用于取消框选，不能设为截图快捷键。",
        "scShortcutModifierRequired": "字母、数字和普通键必须带至少一个修饰键。",
        "scShortcutRegistrationFailed": "快捷键注册失败，可能已被系统或其他应用占用；已保留原快捷键。", "scShortcutDuplicate": "该快捷键已分配给 %@，请换一个组合键。", "scShortcutUsedByScreenshot": "该快捷键已被截图入口使用，请换一个组合键。",
        "scShortcutSystemConflict": "该组合键已被 macOS 截图快捷键占用，请换一个组合键，或在系统设置中关闭冲突项。",
        "scSystemShortcutArea": "与 macOS 的区域截图快捷键冲突",
        "scSystemShortcutFullscreen": "与 macOS 的全屏截图快捷键冲突",
        "scSystemShortcutOptions": "与 macOS 的截图工具快捷键冲突",
        "scOpenKeyboardSettings": "打开系统键盘快捷键设置",
        "scRecordShortcut": "点击后按下快捷键…", "scResetShortcut": "恢复默认（%@）", "scPin": "贴图",
        "scSmartCaptureResources": "空闲时仅监听自定义快捷键，不采集屏幕、不轮询；OCR 与标注仅在使用时加载。智能元素识别需要辅助功能权限。",
        "scPinTitle": "MacPilot 贴图", "scCopy": "复制", "scAnnotate": "标注", "scClose": "关闭", "scReveal": "在访达中显示", "scDelete": "删除", "scOCR": "OCR", "scEditMedia": "编辑", "scMediaEditor": "媒体编辑", "scMediaGIFEditorHint": "GIF 暂不支持裁剪；你可以打开文件或在访达中查看。", "scMediaTrimStart": "开始", "scMediaTrimEnd": "结束", "scMediaExportTrim": "导出裁剪片段", "scMediaExporting": "正在导出…", "scMediaExported": "已导出：%@", "scMediaInvalidTrimRange": "裁剪范围无效，至少保留 0.25 秒。", "scMediaExporterUnavailable": "当前视频格式无法导出。", "scMediaExportFailed": "媒体导出失败。", "scScrollingTitle": "滚动长截图", "scScrollingHint": "在选定区域内滚动页面，MacPilot 会自动采样并拼接；完成后点击“完成”。", "scScrollingFrames": "已采样 %d 帧", "scObjectCutoutFailed": "抠图失败：%@",
        "scHistory": "截图与媒体历史", "scHistoryEmpty": "还没有截图、视频或 GIF 记录。", "scHistoryScreenshot": "截图", "scHistoryVideo": "视频", "scHistoryGIF": "GIF", "scScrollingStitchFailed": "无法拼接滚动截图。请减少滚动幅度后重试。", "scObjectCutoutNoForeground": "没有检测到前景对象。", "scObjectCutoutMaskFailed": "无法生成前景蒙版。",
        "scOCRNoText": "未识别到文字。", "scOCRCopied": "OCR 文字已复制", "scOK": "好",
        "scAnnotateTitle": "MacPilot 标注", "scAnnotationTool": "工具", "scAnnotationRectangle": "矩形",
        "scAnnotationArrow": "箭头", "scAnnotationFilledRectangle": "填充矩形", "scAnnotationEllipse": "椭圆", "scAnnotationLine": "直线", "scAnnotationBlur": "模糊", "scAnnotationSpotlight": "聚光灯", "scAnnotationCounter": "计数器", "scAnnotationHighlighter": "荧光笔", "scAnnotationPencil": "铅笔", "scAnnotationWatermark": "水印", "scAnnotationCrop": "裁剪", "scAnnotationText": "文字", "scUndo": "撤销", "scRedo": "重做", "scClearAnnotations": "清除标注", "scCancel": "取消",
        "scDone": "完成", "scAnnotationTextTitle": "标注文字", "scAnnotationWatermarkTitle": "添加水印", "scText": "文字", "scAdd": "添加",
        "scOutputFolder": "保存文件夹", "scNoFolder": "尚未选择文件夹", "scChooseFolder": "选择文件夹…",
        "scCaptureAllDisplays": "截取所有显示器", "scCaptureAllDisplaysHint": "多显示器时分别保存每块屏幕的画面。",
        "scShowCursor": "包含鼠标光标",
        "scSchedule": "截屏计划", "scEnableCapture": "启用定时截屏", "scCaptureNow": "立即截屏",
        "scBusyHours": "忙时时段", "scStart": "开始", "scEnd": "结束",
        "scBusyHoursHint": "设置忙时（工作时段）的范围。忙时和闲时可分别设置不同截屏间隔。开始等于结束表示无忙时时段。",
        "scBusyInterval": "忙时间隔", "scIdleInterval": "闲时间隔",
        "scCurrentInterval": "当前间隔：%d 分钟", "scMinutesValue": "%d 分钟",
        "scQuality": "画质与压缩", "scFormat": "图片格式",
        "scFormatHEIC": "HEIC", "scFormatJPEG": "JPEG", "scFormatPNG": "PNG",
        "scCompressionQuality": "压缩质量", "scQualityHint": "HEIC 在 60%–80% 时肉眼几乎无损且体积远小于 PNG。数值越低体积越小，越高画质越好。",
        "scRetention": "自动清理", "scRetentionDisabled": "不自动清理", "scRetentionDays": "保留 %d 天",
        "scRetentionHint": "超过设定天数的截屏会自动删除。设为 0 表示永久保留。",
        "scStatus": "状态", "scPermissionRequired": "需要屏幕录制权限才能截屏。",
        "scGrantPermission": "授权屏幕录制…", "scOpenPermissionSettings": "打开屏幕录制设置",
        "scResetPermission": "重置权限并退出", "scResettingPermission": "正在重置…",
        "scPermissionRecoveryHint": "如果系统设置中已经允许但仍无法截屏，请重置旧的屏幕录制授权记录。",
        "scPermissionRestartHint": "授权后请重启 MacPilot；如果仍无法截屏，请重置权限并退出。",
        "scPermissionResetFailed": "无法重置屏幕录制权限：%@", "scPermissionResetStatus": "tccutil 退出状态：%d",
        "scStatusRunning": "运行中", "scCaptureCount": "截屏次数", "scScreenshotCount": "截图数量",
        "scDiskUsage": "磁盘占用", "scLastCapture": "上次截屏", "scLastSize": "上次大小",
        "scNextCapture": "下次截屏：%@", "scYes": "是", "scNo": "否",
        "pictureInPicture": "画中画", "pictureInPictureSubtitle": "将任意窗口或窗口区域变成跨 Space 的实时悬浮面板。",
        "pipEnabledStatus": "画中画：已启用", "pipDisabledStatus": "画中画：已停用", "pipCaptureFocused": "捕获当前窗口", "pipCloseAll": "关闭全部画中画",
        "pipNoSessions": "还没有画中画窗口", "pipNoSessionsDetail": "使用设置中的全局快捷键捕获当前窗口，或使用下方按钮开始。",
        "pipCreate": "创建", "pipShowHide": "显示与隐藏", "pipFocus": "聚焦", "pipZoom": "缩放",
        "pipGeneral": "通用", "pipWindowBehavior": "窗口行为", "pipPanelUI": "面板 UI", "pipCapture": "捕获", "pipMedia": "媒体", "pipDetection": "检测", "pipPatches": "补丁",
        "pipGlobalShortcut": "全局快捷键", "pipGlobalShortcutHint": "当前为 %@；在其他 App 中使用需要辅助功能权限。加 Shift 可选择窗口区域。",
        "pipShortcutModifier": "组合键", "pipShortcutKey": "触发键",
        "pipShortcutCommandOption": "Option + Command", "pipShortcutCommandControl": "Control + Command", "pipShortcutControlOption": "Control + Option", "pipShortcutCommandControlOption": "Control + Option + Command",
        "pipShowMenuBarIcon": "显示菜单栏图标", "pipCheatSheet": "快捷键速查",
        "pipCheatSheetBody": "%@ 捕获窗口 · %@ + Shift 选择区域 · %@ 双击快速区域 · 滚轮缩放 · ⌘+滚轮平移 · Backspace 关闭 · 空格快速查看 · +/- 缩放 · ⌘ 双击重置缩放",
        "pipPosition": "位置", "pipPositionTopLeft": "左上", "pipPositionTopRight": "右上", "pipPositionBottomLeft": "左下", "pipPositionBottomRight": "右下",
        "pipAutoHide": "悬停时自动隐藏", "pipAutoHideHint": "鼠标移到面板上时淡出，让你操作后面的窗口；移开后恢复。",
        "pipClickToFocus": "点击聚焦源窗口", "pipClickToFocusHint": "单击画中画面板将源窗口带到前台。",
        "pipSourceFocused": "源窗口获得焦点时", "pipDoNothing": "不处理", "pipHidePanel": "隐藏面板", "pipClosePanel": "关闭面板",
        "pipFullscreenSpaces": "显示在全屏 Space", "pipMultiWindow": "多窗口模式", "pipMultiWindowHint": "允许同时捕获多个不同窗口，每个窗口拥有自己的画中画面板。",
        "pipShowHoverHints": "显示悬停提示", "pipDimOnHover": "悬停时调暗", "pipBlur": "模糊", "pipCornerRadius": "圆角", "pipQuickLook": "按空格快速查看源窗口",
        "pipFrameRate": "帧率", "pipFrameRateHint": "帧率越低越省 CPU；终端通常 1–5 fps，视频可用 30–60 fps。", "pipEnhanceContrast": "增强对比度", "pipQuickRegion": "启用 %@ 双击快速区域捕获", "pipAspectLimit": "区域宽高比上限",
        "pipMediaControls": "启用媒体控制", "pipSeekBar": "显示进度与方向键控制", "pipSpacePlayPause": "空格播放 / 暂停", "pipYoutubeCaptions": "YouTube 字幕按钮",
        "pipDetectionThreshold": "空闲/变化检测阈值", "pipSensitiveDetection": "敏感检测", "pipDetectionScript": "检测脚本", "pipDetectionScriptHint": "事件触发时运行 shell。环境变量：PIPIRI_EVENT、PIPIRI_APP、PIPIRI_BUNDLE_ID、PIPIRI_WINDOW_ID。", "pipScriptTimeout": "脚本超时",
        "pipPatchesTitle": "离屏渲染修复", "pipPatchesBody": "部分浏览器或 Electron 应用在窗口被遮挡后会暂停渲染。为应用启用修复后，MacPilot 会用后台渲染参数重新启动它；应用包体不会被修改。",
        "pipPatchesNoApps": "没有检测到支持的浏览器或 Electron 应用。", "pipPatchRunning": "正在运行", "pipPatchRelaunch": "使用修复参数重新启动", "pipPatchAutoApply": "自动保持修复生效", "pipPatchAutoApplyHint": "启用的应用正常启动时，MacPilot 会将它重新启动一次并附加离屏渲染参数。关闭开关即可撤销；下次正常启动不会再应用。", "pipPatchFailed": "无法应用离屏渲染修复", "pipPatchDetails": "详细信息", "pipPatchDetailsBody": "此修复使用 Chromium/Electron 官方支持的启动参数。应用当前正在运行时，需要先退出再重新启动，未保存的内容可能丢失，因此只有点击按钮或启用自动应用时才会执行。",
        "pipCustomPatchTitle": "自定义合成器应用", "pipCustomPatchBody": "Firefox、kitty 和 Ghostty 没有后台渲染启动参数。MacPilot 可以在备份原 App 后，为其主程序注入一个独立的轻量组件，使 AppKit 始终报告窗口可见。", "pipCustomPatchNoApps": "没有检测到可补丁的自定义合成器应用。", "pipCustomPatchWarning": "补丁会修改并重新签名第三方 App，可能使它重新请求屏幕录制、辅助功能等权限。操作前必须退出目标 App；原始 App 会保存在 MacPilot 的 Application Support 中并可随时恢复。", "pipPatchInstall": "安装补丁", "pipPatchRestore": "恢复原版", "pipPatchInstalled": "补丁已安装", "pipPatchQuitFirst": "请先退出 App", "pipPatchUpdateDetected": "检测到更新，可重新安装补丁", "pipPatchConfirmTitle": "修改并重新签名这个 App？", "pipPatchConfirmBody": "MacPilot 会先完整备份原 App，再注入离屏渲染组件并使用临时签名重新签名。此操作可能让 macOS 再次询问权限。", "pipRestoreConfirmTitle": "恢复原始 App？", "pipRestoreConfirmBody": "MacPilot 会用安装补丁前保存的完整备份替换当前 App。请确认目标 App 已退出。", "pipPatchAnotherApp": "补丁另一个 App…", "pipPatchRemoveCustom": "从列表移除", "choose": "选择",
        "pipPermissionRequired": "需要屏幕录制权限才能创建画中画。", "pipGrantPermission": "授权屏幕录制…", "pipOpenSettings": "打开设置",
        "pipAccessibilityRequired": "需要辅助功能权限才能在其他 App 中拦截全局快捷键。", "pipGrantAccessibility": "授权辅助功能…", "pipOpenAccessibility": "打开辅助功能设置",
        "windowSwitcher": "窗口切换", "windowSwitcherTitle": "窗口切换器", "windowSwitcherSubtitle": "使用 ⌥Tab 在所有应用窗口之间快速切换。按住 Option 连续切换，松开后聚焦选中的窗口。",
        "windowSwitcherShortcut": "⌥Tab", "windowSwitcherShortcutHint": "默认快捷键为 ⌥Tab；按住 Option 时可连续按 Tab，按住 Shift 可反向切换。",
        "windowSwitcherIncludeMinimized": "显示最小化窗口", "windowSwitcherIncludeHidden": "显示已隐藏应用的窗口",
        "windowSwitcherShowThumbnails": "显示窗口缩略图（需要屏幕录制权限）", "windowSwitcherShowTitles": "显示窗口标题",
        "windowSwitcherShowIconsOnly": "仅显示应用图标", "windowSwitcherPreviewSize": "预览图大小",
        "windowSwitcherPreviewSmall": "小", "windowSwitcherPreviewMedium": "中", "windowSwitcherPreviewLarge": "大",
        "windowSwitcherAccessibilityRequired": "窗口切换需要辅助功能权限，才能读取和聚焦其他应用的窗口。",
        "windowSwitcherGrantAccessibility": "授权辅助功能…", "windowSwitcherAccessibilityReady": "辅助功能权限已就绪",
        "windowSwitcherTestNow": "立即显示窗口切换器", "windowSwitcherNoWindows": "当前没有可切换的窗口。",
        "windowSwitcherEnabledStatus": "窗口切换：已启用", "windowSwitcherDisabledStatus": "窗口切换：已停用",
        "windowSwitcherMerge": "合并窗口",
        "windowSwitcherMergeHint": "把指定应用的多个窗口合并成一个窗口：应用支持时合并为标签页，否则叠放在主窗口位置。需要辅助功能权限。",
        "windowSwitcherAddMergeApp": "添加应用…",
        "windowSwitcherNoMergeApps": "尚未添加合并应用",
        "windowSwitcherMergeNow": "合并窗口",
        "windowSwitcherNotRunning": "未运行",
        "windowSwitcherRemove": "移除",
        "smoothScrolling": "平滑滚动", "smoothScrollingSubtitle": "把鼠标滚轮转换成类似触控板的连续平滑滚动，保留必要的精准控制。",
        "smoothScrollingEnable": "启用平滑滚动", "smoothScrollingEnabledStatus": "平滑滚动：已启用", "smoothScrollingDisabledStatus": "平滑滚动：已停用",
        "smoothScrollingVertical": "垂直平滑", "smoothScrollingHorizontal": "水平平滑", "smoothScrollingReverse": "反转方向",
        "smoothScrollingReverseVertical": "反转垂直方向", "smoothScrollingReverseHorizontal": "反转水平方向",
        "smoothScrollingStep": "最短步长", "smoothScrollingSpeed": "速度增益", "smoothScrollingDuration": "持续时长",
        "smoothScrollingDeadZone": "死区", "smoothScrollingSimulatePhases": "模拟触控板相位",
        "smoothScrollingAdaptiveSpeed": "滚轮越快加速越多", "smoothScrollingAdaptiveSpeedMaximum": "自动加速上限",
        "smoothScrollingBlockWithCommand": "按住 Command 时禁用平滑滚动",
        "smoothScrollingAccessibilityRequired": "平滑滚动需要辅助功能权限来读取并改写其他应用中的滚轮事件。",
        "smoothScrollingGrantAccessibility": "授权辅助功能…", "smoothScrollingOpenAccessibility": "打开辅助功能设置",
        "smoothScrollingAccessibilityReady": "辅助功能权限已就绪",
        "smoothScrollingNotConfiguredHint": "未启用时鼠标滚轮会按系统默认行为传递。",
        "rightClickMenu": "访达右键菜单",
        "clipboard": "剪切板", "clipboardSubtitle": "记录复制历史，随时搜索、固定并重新粘贴，支持文本、图片与文件。",
        "clipboardEnable": "启用剪切板", "clipboardEnabledStatus": "剪切板：已启用", "clipboardDisabledStatus": "剪切板：已停用",
        "clipboardHotkey": "全局快捷键", "clipboardHotkeyRecord": "点击后按下新快捷键…",
        "clipboardStorageLimit": "历史记录数量上限",
        "clipboardPasteByDefault": "点击条目时默认粘贴（关闭则仅复制）",
        "clipboardShowSearch": "打开面板时显示搜索框",
        "clipboardClearSystemClipboard": "清除历史时同时清空系统剪贴板",
        "clipboardPinsAtTop": "固定条目置顶",
        "clipboardOpenNow": "打开剪切板面板",
        "clipboardClearHistory": "清除历史", "clipboardClearAllHistory": "清空全部历史",
        "clipboardClearAllConfirm": "确定要清空全部剪切板历史吗？此操作无法撤销。",
        "clipboardAccessibilityRequired": "粘贴需要辅助功能权限来模拟 ⌘V。",
        "clipboardGrantAccessibility": "授权辅助功能…",
        "clipboardAccessibilityReady": "辅助功能权限已就绪",
        "clipboardNotConfiguredHint": "未启用时不会记录剪贴板内容。",
        "clipboardSearchPlaceholder": "搜索剪贴板历史…",
        "clipboardHistoryEmpty": "剪贴板历史为空",
        "clipboardFooterHint": "%d 条 · ↑↓ 选择 · ⏎ 粘贴 · ⌘⏎ 复制 · ⌫ 删除",
        "clipboardImageLabel": "图片",
        "clipboardHotkeyLabel": "快捷键 %@"
    ]

    static func value(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        value(key, language: language, arguments: arguments)
    }

    static func value(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        let useChinese: Bool
        switch language {
        case .simplifiedChinese: useChinese = true
        case .english: useChinese = false
        case .system: useChinese = Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh"
        }
        let template = useChinese ? (chinese[key] ?? key) : (english[key] ?? key)
        return arguments.isEmpty ? template : String(format: template, locale: language.locale, arguments: arguments)
    }

    private static let english: [String: String] = [
            "rules": "Exit", "settings": "Settings", "addApp": "Add app", "apps": "APPS",
            "versionLabel": "Version %@ (Build %@)",
            "rulesSubtitle": "Hide, close windows, or quit apps after they’ve been inactive.", "dropApp": "Drop an app to add its rule",
            "invalidDrop": "Drop a macOS application (.app) to create a rule.", "duplicateRule": "A rule for \"%@\" already exists.",
            "selfRule": "MacPilot cannot manage itself.",
            "enforcing": "Enforcing rules", "paused": "Rules paused", "enabledChecked": "%d enabled • checked %@",
            "noApps": "No apps yet", "noAppsDetail": "Add an app to automatically hide, close its windows, or quit it after inactivity.",
            "addFirstApp": "Add your first app", "edit": "Edit", "editRule": "Edit rule", "deleteRule": "Delete rule", "remove": "Remove",
            "removeConfirmTitle": "Confirm Removal", "removeConfirmMessage": "Remove “%@”? This will delete its rule.",
            "hideAfter": "Hide after %d min inactive", "closeAfter": "Close windows after %d min inactive", "quitAfter": "Quit after %d min inactive", "quitHidden": "Quit %d min after hiding",
            "addRule": "Add app rule", "editAppRule": "Edit app rule", "ruleDetail": "Choose an application, then choose one or more automatic actions.",
            "hideInactive": "Hide after inactivity", "closeInactive": "Close windows after inactivity", "quitInactive": "Quit after inactivity", "quitAfterHidden": "Quit after being hidden",
            "closeWindowHint": "Closes the app's closable windows while leaving its process running. MacPilot simulates clicking the close button in the foreground; whether the Dock icon disappears depends on whether the app retreats to the menu bar.",
            "accessibilityRequired": "Closing windows requires Accessibility access. If it remains unavailable after an update, reset the permission and quit MacPilot in one step, then reopen it and grant access. Current app: %@",
            "openAccessibilitySettings": "Open Accessibility Settings",
            "resetAccessibility": "Reset Permission and Quit",
            "resettingAccessibility": "Resetting…",
            "accessibilityRecoveryHint": "macOS still does not trust this version. If it is already enabled in the list, reset the stale permission record here.",
            "accessibilityResetFailed": "Couldn’t reset Accessibility access: %@",
            "accessibilityResetStatus": "tccutil exited with status %d",
            "cancel": "Cancel", "save": "Save", "chooseApp": "Choose an app", "chooseRunning": "Choose a running app", "browse": "Browse…",
            "application": "Application", "selectedApp": "Selected application", "changeApp": "Change app", "runningApps": "Running applications",
            "browseApplications": "Choose an app from disk", "noRunningApps": "No eligible running applications found",
            "configFile": "Configuration file", "configDescription": "Rules and preferences are stored in this local file. Updating or replacing MacPilot.app will not affect it.",
            "revealInFinder": "Show in Finder", "configSaveError": "Couldn’t save the configuration file: %@",
            "importQuitter": "Import Quitter Configuration", "importQuitterDescription": "Import rules directly from Quitter’s local preferences file; matching app identifiers already in your rules are skipped.",
            "importQuitterSuccess": "Imported %d rules and skipped %d duplicate or invalid rules.", "importQuitterEmpty": "No new rules were found to import.",
            "importQuitterError": "Couldn’t import the configuration file: %@", "importQuitterInvalid": "This is not a supported Quitter preferences file.",
            "importQuitterNotFound": "Quitter configuration file not found: %@",
            "importQuitterConfirmTitle": "Confirm Import", "importQuitterConfirmMessage": "Found %d rules to import. %d duplicate or invalid rules will be skipped. Import them?",
            "import": "Import",
            "minute": "minute", "minutes": "minutes", "language": "Language", "languageDescription": "Choose MacPilot’s display language. Changes apply immediately.",
            "systemLanguage": "System Language", "english": "English", "simplifiedChinese": "Simplified Chinese", "checkNow": "Check now",
            "startAtLogin": "Start at Login", "startAtLoginHint": "Launch MacPilot automatically in the background when you log in.", "showApp": "Show MacPilot", "quitApp": "Quit MacPilot", "enabledStatus": "MacPilot: Enabled",
            "disabledStatus": "MacPilot: Disabled", "disableApp": "Disable MacPilot", "enableApp": "Enable MacPilot",
            "loginError": "Couldn’t update the login item: %@", "aboutAutomation": "AUTOMATION", "manageRules": "Manage app rules and interface preferences.",
            "quitsIn": "Quits in %d min",
            "launch": "Launch", "launchSubtitle": "Launch apps after their configured delay following login.", "launchApps": "LAUNCH APPS",
            "addLaunchApp": "Add launch app", "addLaunchRule": "Add launch rule", "editLaunchRule": "Edit launch rule",
            "launchRuleDetail": "Choose an app and set its delay in seconds from when MacPilot starts at login.",
            "launchAfter": "Launch %d sec after login", "delaySeconds": "Delay in seconds", "launchVisibility": "After launch",
            "launchModeForeground": "Bring to front", "launchModeHidden": "Hide application", "launchModeCloseWindows": "Close windows, keep running",
            "launchForegroundHint": "Brings the application to the foreground after launch.",
            "launchHiddenHint": "Hides the application after launch and restores the previous foreground app.",
            "launchCloseWindowsHint": "Waits 10 seconds after launch, then brings the app to the foreground and simulates clicking its close button while keeping the background or menu-bar process running. Whether its Dock icon disappears depends on that app.",
            "launchCloseFailed": "The app launched, but its windows could not be closed",
            "runNow": "Run now", "cancelLaunches": "Cancel scheduled launches", "launchEnabled": "Launch plan enabled", "launchPaused": "Launch plan paused",
            "launchIn": "Launches in %d sec", "launching": "Launching", "launched": "Launched", "alreadyRunning": "Skipped: already running",
            "launchCancelled": "Cancelled", "launchFailed": "Launch failed: %@", "noLaunchApps": "No launch apps yet",
            "noLaunchAppsDetail": "Add an app and set its delay after login.", "addFirstLaunchApp": "Add your first launch app",
            "loginRequired": "Enable Start at Login to run launch rules automatically after each boot login.", "seconds": "seconds",
            "launchDuplicate": "A launch rule for \"%@\" already exists.", "launchPlanRunning": "%d launches are waiting",
            "launchPlanIdle": "No scheduled launches", "launchPlanDone": "This launch plan is complete",
            "bleUnlock": "BLE Unlock", "ble": "BLE", "bleUnlockSubtitle": "Automatically lock and unlock your Mac by proximity of a BLE device (iPhone, Apple Watch, etc.).",
            "bleNotConfigured": "No device set", "bleDeviceNotDetected": "Not detected", "bleNoDevice": "No device selected",
            "bleLockNow": "Lock Screen Now", "bleDevice": "Device", "bleScanning": "Scanning…", "bleSelectDevice": "Select Device",
            "bleDeviceHint": "Open the device menu to scan for nearby BLE devices and pick your iPhone, Apple Watch, or other BLE device. The device must use a static MAC address.",
            "bleUnlockRSSI": "Unlock RSSI", "bleLockRSSI": "Lock RSSI", "bleLockDelay": "Delay to Lock", "bleNoSignalTimeout": "No-Signal Timeout",
            "bleCloser": "Closer", "bleFarther": "Farther", "bleDisabled": "Disable",
            "bleUnlockRSSIInfo": "Bluetooth signal strength to unlock. A larger value means the device must be closer to unlock. Choose Disable to turn off auto-unlock.",
            "bleLockRSSIInfo": "Bluetooth signal strength to lock. A smaller value means the device must be farther away to lock. Choose Disable to turn off auto-lock.",
            "bleLockDelayInfo": "How long to wait before locking after the device moves away. If it comes closer within this time, no lock occurs.",
            "bleTimeoutInfo": "Time between last signal reception and locking as “signal lost”. Increase this if you see frequent “signal lost” locking.",
            "bleWakeOnProximity": "Wake on Proximity", "bleWakeWithoutUnlocking": "Wake without Unlocking", "blePauseNowPlaying": "Pause “Now Playing” while Locked",
            "bleUseScreensaver": "Use Screensaver to Lock", "bleTurnOffScreen": "Turn Off Screen on Lock", "blePassiveMode": "Passive Mode",
            "blePassiveModeInfo": "By default it actively connects to the device and reads RSSI, which is more stable. If it interferes with other Bluetooth devices, enable Passive Mode to scan only.",
            "bleSetPassword": "Set Password…", "bleEnable": "Enable BLE Unlock", "bleEnabledStatus": "BLE Unlock: Enabled", "bleDisabledStatus": "BLE Unlock: Disabled",
            "bleBluetoothOff": "Bluetooth is off", "bleEnterPassword": "Enter your login password", "blePasswordInfo": "It will be securely stored in Keychain and used only to unlock the locked screen.",
            "blePasswordStored": "Password saved to Keychain.", "blePasswordFailed": "Couldn’t save password: %@", "blePasswordNotSet": "Login password is not set. Use Set Password….",
            "bleMinRSSI": "Set Minimum RSSI…", "bleManage": "Manage BLE Unlock", "bleManageDevices": "Manage devices in main window…",
            "bleNear": "Near", "bleAway": "Away", "bleLost": "Signal lost", "bleActive": "Active", "bleCurrentDevice": "Current device", "bleChangeDevice": "Change device",
            "bleRSSIDBm": "%ddBm", "bleRSSIActive": "%ddBm (Active)", "bleSeconds": "seconds",
            "bleSignalStrength": "Signal Strength", "bleProximityStatus": "Proximity", "bleMonitoring": "Monitoring", "bleIdle": "Idle",
            "bleThresholds": "Trigger Thresholds", "bleTiming": "Timing", "bleBehavior": "Behavior", "bleSecurity": "Password & Lock",
            "bleRangeNear": "Near", "bleRangeMid": "Mid", "bleRangeFar": "Far", "bleRangeFarFar": "Very far",
            "bleUnlockZone": "Unlock zone", "bleLockZone": "Lock zone", "bleCurrent": "Current",
            "bleNoPassword": "No password set", "blePasswordSet": "Password saved",
            "bleAccessRequired": "BLE Unlock needs Accessibility access to simulate keystrokes for unlocking and to lock the screen. Current app: %@", "bleBluetoothRequired": "Bluetooth permission is required to scan for BLE devices.",
            "bleNoDevicesFound": "No nearby BLE devices found.",
            "inputSources": "Input Sources", "inputSourcesSubtitle": "Automatically switch macOS input sources by app or browser website, with a visual indicator.",
            "inputSourcesEnable": "Enable input source automation", "inputSourcesEnabled": "Input source rules are running", "inputSourcesDisabled": "Input source rules are paused",
            "inputSourcesEnabledStatus": "Input Sources: On", "inputSourcesDisabledStatus": "Input Sources: Off", "inputSourcesCycleNow": "Switch to Next Input Source",
            "inputSourcesUnavailable": "No selectable keyboard input sources were found.", "inputSourcesCurrent": "Current Input Source", "inputSourcesNotDetected": "Input source not detected",
            "inputSourcesActiveApp": "Active app: %@", "refresh": "Refresh", "inputSourcesDefault": "Default Input Source",
            "inputSourcesDefaultHint": "Used when no app or website rule matches. Leave it empty to keep the system selection.", "inputSourcesNoDefault": "Do not switch automatically",
            "inputSourcesIndicator": "On-screen Indicator", "inputSourcesShowIndicator": "Show an indicator when switching", "inputSourcesIndicatorPosition": "Indicator position",
            "inputSourcesNearCursor": "Near cursor", "inputSourcesScreenCenter": "Screen center", "inputSourcesIndicatorDuration": "Display duration",
            "inputSourcesShortcuts": "Shortcuts", "inputSourcesCycleShortcut": "Enable global cycle shortcut",
            "inputSourcesCycleShortcutHint": "Press ⌥⌘I to switch to the next available input source. Accessibility access is required outside MacPilot.",
            "inputSourcesCustomShortcuts": "Custom input source shortcuts", "inputSourcesAddShortcut": "Add Shortcut",
            "inputSourcesNoShortcuts": "No direct-switch shortcuts configured yet.", "inputSourcesShortcutHint": "Press a modified key combination to record it, such as ⌥⌘1. Duplicate combinations keep the last binding.",
            "inputSourcesRecordShortcut": "Press a shortcut…",
            "inputSourcesAccessibilityRequired": "Accessibility access is required to listen for shortcuts in other apps.", "inputSourcesGrantAccessibility": "Grant Accessibility…",
            "inputSourcesAppRules": "Application Rules", "inputSourcesAppRulesHint": "Choose an input source for each app, with optional English punctuation and function-key overrides.",
            "inputSourcesNoAppRules": "No application rules yet.", "inputSourcesBrowserRules": "Browser Website Rules",
            "inputSourcesBrowserRulesHint": "Switch automatically by domain or URL in Safari, Chrome, Firefox, and other supported browsers.",
            "inputSourcesNoBrowserRules": "No browser website rules yet.", "inputSourcesEnglishPunctuation": "Force English punctuation",
            "inputSourcesFunctionKeys": "Standard Function Keys F1–F12", "inputSourcesMediaKeys": "Media Keys (brightness, volume, etc.)",
            "inputSourcesAddAppRule": "Add Application Input Source Rule", "inputSourcesEditAppRule": "Edit Application Input Source Rule",
            "inputSourcesChooseApp": "Choose an application", "inputSourcesTarget": "Target input source", "inputSourcesFunctionKeyMode": "Function-key mode",
            "inputSourcesUseSystemDefault": "Use system default", "inputSourcesAddBrowserRule": "Add Browser Website Rule",
            "inputSourcesEditBrowserRule": "Edit Browser Website Rule", "inputSourcesBrowser": "Browser",
            "inputSourcesAnyBrowser": "All supported browsers", "inputSourcesRuleType": "Match type",
            "inputSourcesDomainSuffix": "Domain suffix", "inputSourcesDomain": "Exact domain", "inputSourcesURLRegex": "URL regex",
            "inputSourcesRuleValue": "Domain or URL pattern",
            "bleSortBy": "Sort", "bleSortAdded": "Added", "bleSortName": "Name", "bleSortSignal": "Signal",
            "softwareUpdate": "Software Update", "updateDescription": "Check GitHub Releases for versions signed and notarized by Apple.",
            "checkForUpdates": "Check for Updates…", "checkingForUpdates": "Checking for updates…", "upToDate": "MacPilot is up to date.",
            "updateAvailable": "Version %@ is available.", "downloadAndInstall": "Download and Install", "downloadingUpdate": "Downloading update…",
            "preparingUpdate": "Verifying and preparing the update…", "updateFailed": "Update failed: %@", "currentVersion": "Current version: %@",
            "releaseNotes": "Release Notes", "updateWillRestart": "MacPilot will restart automatically after installation.",
            "updateErrorRelease": "The GitHub release or macOS archive is invalid.", "updateErrorIntegrity": "The downloaded file failed its SHA-256 integrity check.",
            "updateErrorVerification": "The update failed its version, developer signature, or Gatekeeper verification.",
            "updateErrorLocation": "MacPilot cannot update itself from this location. Move it to a writable Applications folder first.",
            "updateErrorHelper": "The updater helper is missing from this MacPilot installation.", "updateErrorNetwork": "Network request failed: %@",
            "updateErrorCommand": "Couldn’t prepare the update: %@",
            "fileCompression": "Storage Compression", "fileCompressionSubtitle": "Safely reduce the disk space used by text-based files while preserving content and visible dates.",
            "compressionFolder": "Monitored folders", "compressionNoFolder": "No folders selected", "compressionChooseFolder": "Choose Folder…",
            "compressionAddFolders": "Add Folders…", "compressionRemoveFolder": "Remove folder", "compressionFolderCount": "Monitoring %d folders",
            "compressionRemoveFolderTitle": "Remove Monitored Folder?", "compressionRemoveFolderMessage": "This folder will no longer be scanned. No files in it will be deleted or restored.\n%@",
            "compressionChoose": "Choose", "compressionAutomatic": "Compress periodically", "compressionAutomaticHint": "Processes file changes incrementally. Click the info icon to see how scanning works.",
            "compressionAutomaticInfo": "Automatic scanning", "compressionAutomaticInfoHelp": "Show automatic scanning details",
            "compressionAutomaticInfoBody": "• Watches multiple folders through macOS file events and checks only new or changed paths.\n• Briefly coalesces repeated events, then waits until a file has remained unchanged for the configured time.\n• Scans all folders when first enabled, then only newly added folders, with reconciliation every 24 hours. If file events become unreliable, it scans the affected folders.\n• Compresses files one at a time to avoid sustained CPU and disk load.\n\nSystem limit: macOS does not provide this filesystem compression for individual files larger than 512 MiB, so the app excludes them during scanning.",
            "compressionRules": "Compression Rules", "compressionExtensions": "File extensions", "compressionRecommended": "Use Recommended",
            "compressionApply": "Apply", "compressionExtensionsHint": "Separate extensions with commas or spaces. The defaults cover text, logs, and structured data.",
            "compressionMinimumSize": "Minimum file size", "compressionStableFor": "Unmodified for", "compressionMinimumSavings": "Minimum savings",
            "compressionMinutesValue": "%d min", "compressionSafetyHint": "Skips open files, resource forks, symbolic and hard links, sparse files, cloud placeholders, app bundles, and hidden folders. Content and metadata are verified before replacement.",
            "compressionAnalysis": "Space Analysis", "compressionScanNow": "Scan Now", "compressionScanPrompt": "Choose a folder and scan it to find files that are safe to compress.",
            "compressionCandidates": "Ready to compress", "compressionAlreadyCompressed": "Compressed files", "compressionSpaceSaved": "Space saved",
            "compressionViewAllCompressed": "View All %d Compressed Files", "compressionCompressedListTitle": "Compressed Files",
            "compressionSearchFiles": "Search file paths", "compressionNoMatchingFiles": "No matching files", "compressionClose": "Close",
            "compressionSortBy": "Sort", "compressionSortLogicalSize": "Logical Size (Largest First)", "compressionSortActualSize": "Actual Size (Largest First)",
            "compressionUses": "%@ on disk", "compressionLogical": "%@ logical", "compressionSizeDetail": "%@ logical · %@ on disk", "compressionCompressFiles": "Compress %d Files",
            "compressionRestoreFiles": "Restore %d Files", "compressionCompressResult": "Compressed %d files and saved %@; skipped %d, failed %d.",
            "compressionRestoreResult": "Restored %d files; %d failed.", "compressionCompressing": "Compressing files…", "compressionRestoring": "Restoring files…",
            "compressionFailedFile": "Not processed: %@", "compressionRecoveryPreserved": "The original file was preserved for recovery at %@",
            "compressionErrorNoFolder": "Choose a folder first.", "compressionErrorFolderUnavailable": "The selected folder is unavailable.", "compressionErrorFileSystem": "The selected folder uses %@; filesystem compression requires APFS or HFS+.",
            "compressionErrorMonitoringUnavailable": "Folder change monitoring could not be started. Turn periodic compression off and on again.",
            "compressionErrorScan": "Could not scan the folder: %@", "compressionErrorFileChanged": "A file changed after it was scanned.",
            "compressionErrorUnavailable": "macOS could not compress this file.", "compressionErrorVerification": "The compressed copy did not match the original file.",
            "compressionErrorCommand": "The macOS compression command failed: %@", "compressionErrorCoordination": "The file could not be coordinated safely: %@", "compressionErrorFileInUse": "The file is open in another process and was skipped.", "compressionErrorReplacement": "The original file could not be replaced atomically.",
            "compressionFolderIssue": "%@: %@"
            ,
            "screenCapture": "Capture & Pin", "screenCaptureSubtitle": "Use a customizable shortcut to detect window and UI element bounds, then pin, OCR, annotate, or run low-resource scheduled captures.",
            "scScreenshotEnabled": "Enable screenshot capture", "scScreenshotDisabledHint": "Disabling stops screenshot shortcuts, scheduled captures, and screenshot resources in the background.", "scScreenshotDisabled": "Screenshot capture is disabled. Enable it in Screenshot settings first.",
            "scRecording": "Screen Recording", "scRecordingStart": "Start Recording", "scRecordingStop": "Stop Recording", "scRecordingPause": "Pause Recording", "scRecordingResume": "Resume Recording", "scRecordingCancel": "Cancel Recording", "scRecordingOpenFolder": "Open Recording Folder", "scRecordingFormat": "Format", "scRecordingCaptureMode": "Capture area", "scRecordingArea": "Selected area", "scRecordingFullscreen": "Full screen", "scRecordingApplication": "Application window", "scRecordingFPS": "Frame rate", "scRecordingFPSValue": "%d fps", "scRecordingCursor": "Show cursor", "scRecordingSystemAudio": "Record system audio", "scRecordingIdle": "Idle", "scRecordingPreparing": "Preparing…", "scRecordingActive": "Recording %@", "scRecordingPaused": "Paused %@", "scRecordingStopping": "Saving…", "scRecordingLastFile": "Last recording: %@", "scRecordingExportGIF": "Export GIF", "scRecordingConvertingGIF": "Converting to GIF…", "scRecordingActions": "Recording Actions", "scOpen": "Open",
            "scRecordingPermissionRequired": "Screen Recording permission is required to record the screen.", "scRecordingNoDisplay": "No display is available to record.", "scRecordingAlreadyRunning": "A screen recording is already running.", "scRecordingNotRunning": "There is no active screen recording.", "scRecordingWriterFailed": "The recording file could not be created.", "scRecordingNoVideoFrames": "No usable video frames were received.", "scRecordingStreamFailed": "Screen recording failed: %@", "scRecordingUnknownError": "Screen recording failed. Try again.", "scRecordingGIFSourceUnavailable": "The recording file could not be read.", "scRecordingGIFNoFrames": "The recording has no frames that can be used for a GIF.", "scRecordingGIFDestinationUnavailable": "The GIF output file could not be created.", "scRecordingGIFFailed": "The GIF file could not be generated.",
            "scSmartCapture": "Smart Capture", "scSmartCaptureHint": "Move the pointer to detect a window or UI element, click to capture, or press Escape/right-click to cancel.",
            "scSmartCaptureNow": "Start Capture", "scAreaCaptureNow": "Capture Area", "scApplicationWindowCaptureNow": "Capture Application Window", "scFullscreenCaptureNow": "Capture Full Screen", "scActiveWindowCaptureNow": "Capture Current Window", "scAreaAnnotateNow": "Capture and Annotate", "scOCRCaptureNow": "Capture Area and OCR", "scScrollingCaptureNow": "Scrolling Screenshot", "scObjectCutoutNow": "Object Cutout", "scEditShortcuts": "Edit Screenshot Shortcuts", "scEnableSmartCapture": "Enable the global shortcut", "scChangeShortcut": "Change Shortcut",
            "scShortcutModes": "Screenshot shortcuts", "scStartMode": "Start", "scSmartCaptureShortcut": "Smart element shortcut", "scAreaCaptureShortcut": "Area capture shortcut", "scRepeatAreaShortcut": "Repeat last area shortcut", "scApplicationWindowShortcut": "Application window shortcut", "scFullscreenCaptureShortcut": "Fullscreen capture shortcut", "scActiveWindowCaptureShortcut": "Active window shortcut", "scAreaAnnotateShortcut": "Area and annotate shortcut", "scOCRShortcut": "OCR capture shortcut", "scScrollingShortcut": "Scrolling screenshot shortcut", "scObjectCutoutShortcut": "Object cutout shortcut",
            "scRepeatArea": "Repeat Last Area", "scNoLastArea": "There is no previous area to repeat.",
            "scSmartCaptureAccessibilityRequired": "Smart Capture requires Accessibility access. Grant it explicitly in Settings, then try again.",
            "scPinAfterSmartCapture": "Pin after smart capture", "scCopyAfterCapture": "Copy screenshots to the clipboard", "scShowQuickAccess": "Show Quick Access after capture", "scQuickAccessTitle": "Screenshot Actions", "scQuickAccessHint": "After capture, choose to copy, annotate, or pin. Pinning is never automatic.", "scCaptureAreaUnavailable": "The last selected area is no longer available.", "scCaptureCoordinateUnavailable": "The pointer could not be mapped to a display. Try again.", "scCaptureOutsideDisplay": "The selected region is outside the display.", "scCaptureMultiDisplayAllocationFailed": "Unable to allocate a multi-display screenshot.", "scCaptureMultiDisplayCompositionFailed": "Unable to compose the multi-display screenshot.", "scCaptureTimedOut": "The screen capture timed out while waiting for a frame.", "scCaptureCancelled": "The screen capture was cancelled.", "scCaptureAlreadyFinished": "The screen capture session has already finished.", "scCaptureInvalidFrame": "ScreenCaptureKit returned an invalid frame.", "scActiveWindowUnavailable": "No active application window was found.", "scObjectCutoutNoForeground": "No foreground object was detected.", "scObjectCutoutMaskFailed": "The foreground mask could not be rendered.",
            "scShortcutHint": "Bare keys are limited to F1–F20; letters, numbers, and other regular keys need Command, Option, Control, or Shift. Escape is reserved for cancel.",
            "scShortcutReserved": "Escape is reserved for cancelling a selection and cannot be used for capture.",
            "scShortcutModifierRequired": "Letters, numbers, and regular keys require at least one modifier.",
            "scShortcutRegistrationFailed": "The shortcut could not be registered; it may be in use by macOS or another app. The previous shortcut was kept.", "scShortcutDuplicate": "This shortcut is already assigned to %@. Choose another combination.", "scShortcutUsedByScreenshot": "This shortcut is already used by a screenshot entry point. Choose another combination.",
            "scShortcutSystemConflict": "macOS already uses this screenshot shortcut. Choose another combination or disable the conflicting item in System Settings.",
            "scSystemShortcutArea": "Conflicts with macOS area screenshot",
            "scSystemShortcutFullscreen": "Conflicts with macOS full-screen screenshot",
            "scSystemShortcutOptions": "Conflicts with macOS screenshot controls",
            "scOpenKeyboardSettings": "Open Keyboard Shortcuts settings",
            "scRecordShortcut": "Click, then press a shortcut…", "scResetShortcut": "Restore default (%@)", "scPin": "Pin",
            "scSmartCaptureResources": "While idle, MacPilot only listens for your shortcut—no screen stream or polling. OCR and annotation load only when used. Smart elements require Accessibility access.",
            "scPinTitle": "MacPilot Pin", "scCopy": "Copy", "scAnnotate": "Annotate", "scClose": "Close", "scReveal": "Show in Finder", "scDelete": "Delete", "scOCR": "OCR", "scEditMedia": "Edit", "scMediaEditor": "Media Editor", "scMediaGIFEditorHint": "GIF trimming is not supported yet; you can open the file or reveal it in Finder.", "scMediaTrimStart": "Start", "scMediaTrimEnd": "End", "scMediaExportTrim": "Export Trim", "scMediaExporting": "Exporting…", "scMediaExported": "Exported: %@", "scMediaInvalidTrimRange": "Invalid trim range; keep at least 0.25 seconds.", "scMediaExporterUnavailable": "This video format cannot be exported.", "scMediaExportFailed": "Media export failed.", "scScrollingTitle": "Scrolling Screenshot", "scScrollingHint": "Scroll inside the selected area. MacPilot samples and stitches the page; click Done when finished.", "scScrollingFrames": "%d sampled frames", "scObjectCutoutFailed": "Object cutout failed: %@",
            "scHistory": "Screenshot & Media History", "scHistoryEmpty": "No screenshots, videos, or GIFs yet.", "scHistoryScreenshot": "Screenshot", "scHistoryVideo": "Video", "scHistoryGIF": "GIF", "scScrollingStitchFailed": "The scrolling frames could not be stitched. Try smaller scroll steps.",
            "scOCRNoText": "No text was detected.", "scOCRCopied": "OCR copied to clipboard", "scOK": "OK",
            "scAnnotateTitle": "MacPilot Annotate", "scAnnotationTool": "Tool", "scAnnotationRectangle": "Rectangle",
            "scAnnotationArrow": "Arrow", "scAnnotationFilledRectangle": "Filled rectangle", "scAnnotationEllipse": "Ellipse", "scAnnotationLine": "Line", "scAnnotationBlur": "Blur", "scAnnotationSpotlight": "Spotlight", "scAnnotationCounter": "Counter", "scAnnotationHighlighter": "Highlighter", "scAnnotationPencil": "Pencil", "scAnnotationWatermark": "Watermark", "scAnnotationCrop": "Crop", "scAnnotationText": "Text", "scUndo": "Undo", "scRedo": "Redo", "scClearAnnotations": "Clear annotations", "scCancel": "Cancel",
            "scDone": "Done", "scAnnotationTextTitle": "Annotation text", "scAnnotationWatermarkTitle": "Add watermark", "scText": "Text", "scAdd": "Add",
            "scOutputFolder": "Output Folder", "scNoFolder": "No folder selected", "scChooseFolder": "Choose Folder…",
            "scCaptureAllDisplays": "Capture all displays", "scCaptureAllDisplaysHint": "Save each display separately when using multiple monitors.",
            "scShowCursor": "Include mouse cursor",
            "scSchedule": "Schedule", "scEnableCapture": "Enable periodic capture", "scCaptureNow": "Capture Now",
            "scBusyHours": "Busy Hours", "scStart": "Start", "scEnd": "End",
            "scBusyHoursHint": "Set the busy (working) time range. Busy and idle periods can have different capture intervals. Equal start and end means no busy period.",
            "scBusyInterval": "Busy interval", "scIdleInterval": "Idle interval",
            "scCurrentInterval": "Current interval: %d min", "scMinutesValue": "%d min",
            "scQuality": "Quality & Compression", "scFormat": "Image format",
            "scFormatHEIC": "HEIC", "scFormatJPEG": "JPEG", "scFormatPNG": "PNG",
            "scCompressionQuality": "Compression quality", "scQualityHint": "HEIC at 60%–80% is visually lossless and far smaller than PNG. Lower values reduce size; higher values improve quality.",
            "scRetention": "Auto-cleanup", "scRetentionDisabled": "No auto-cleanup", "scRetentionDays": "Keep %d days",
            "scRetentionHint": "Screenshots older than the set number of days are automatically deleted. Set to 0 to keep forever.",
            "scStatus": "Status", "scPermissionRequired": "Screen Recording permission is required to capture the screen.",
            "scGrantPermission": "Grant Screen Recording…", "scOpenPermissionSettings": "Open Screen Recording Settings",
            "scResetPermission": "Reset Permission and Quit", "scResettingPermission": "Resetting…",
            "scPermissionRecoveryHint": "If System Settings already allows access but capture still fails, reset the stale Screen Recording permission record.",
            "scPermissionRestartHint": "Grant access, then restart MacPilot. If capture still fails, reset the permission and quit.",
            "scPermissionResetFailed": "Couldn’t reset Screen Recording access: %@", "scPermissionResetStatus": "tccutil exited with status %d",
            "scStatusRunning": "Running", "scCaptureCount": "Capture runs", "scScreenshotCount": "Screenshots",
            "scDiskUsage": "Disk usage", "scLastCapture": "Last capture", "scLastSize": "Last size",
            "scNextCapture": "Next capture: %@", "scYes": "Yes", "scNo": "No",
            "pictureInPicture": "Picture-in-Picture", "pictureInPictureSubtitle": "Turn any window or region into a live floating panel across Spaces.",
            "pipEnabledStatus": "Picture-in-Picture: On", "pipDisabledStatus": "Picture-in-Picture: Off", "pipCaptureFocused": "Capture Focused Window", "pipCloseAll": "Close All PiP",
            "pipNoSessions": "No Picture-in-Picture windows", "pipNoSessionsDetail": "Use the configured global shortcut to capture the focused window, or use the button below.",
            "pipCreate": "Create", "pipShowHide": "Show & hide", "pipFocus": "Focus", "pipZoom": "Zoom",
            "pipGeneral": "General", "pipWindowBehavior": "Window behavior", "pipPanelUI": "Panel UI", "pipCapture": "Capture", "pipMedia": "Media", "pipDetection": "Detection", "pipPatches": "Patches",
            "pipGlobalShortcut": "Global shortcut", "pipGlobalShortcutHint": "Current shortcut: %@. Accessibility access is required in other apps. Add Shift to select a window region.",
            "pipShortcutModifier": "Modifier", "pipShortcutKey": "Trigger key",
            "pipShortcutCommandOption": "Option + Command", "pipShortcutCommandControl": "Control + Command", "pipShortcutControlOption": "Control + Option", "pipShortcutCommandControlOption": "Control + Option + Command",
            "pipShowMenuBarIcon": "Show menubar icon", "pipCheatSheet": "Cheat sheet",
            "pipCheatSheetBody": "%@ capture window · %@ + Shift select region · %@ double-click quick region · Scroll to zoom · ⌘+scroll to pan · Backspace close · Space QuickLook · +/- zoom · ⌘ double-click reset",
            "pipPosition": "Position", "pipPositionTopLeft": "Top Left", "pipPositionTopRight": "Top Right", "pipPositionBottomLeft": "Bottom Left", "pipPositionBottomRight": "Bottom Right",
            "pipAutoHide": "Auto-hide on hover", "pipAutoHideHint": "Fade the panel while the pointer is over it so you can interact with the window behind it.",
            "pipClickToFocus": "Click to focus", "pipClickToFocusHint": "A single click brings the source window to the front.",
            "pipSourceFocused": "When source window gets focused", "pipDoNothing": "Do nothing", "pipHidePanel": "Hide panel", "pipClosePanel": "Close panel",
            "pipFullscreenSpaces": "Show on fullscreen Spaces", "pipMultiWindow": "Multi-window mode", "pipMultiWindowHint": "Allow multiple different windows to be captured at the same time, each with its own PiP panel.",
            "pipShowHoverHints": "Show hover hints", "pipDimOnHover": "Dim on hover", "pipBlur": "Blur", "pipCornerRadius": "Corner radius", "pipQuickLook": "QuickLook with Space",
            "pipFrameRate": "Frame rate", "pipFrameRateHint": "Lower rates save CPU; terminals often need 1–5 fps while video may need 30–60 fps.", "pipEnhanceContrast": "Enhance contrast", "pipQuickRegion": "Enable %@ double-click quick region capture", "pipAspectLimit": "Aspect ratio limit",
            "pipMediaControls": "Enable media controls", "pipSeekBar": "Seek bar and arrow-key seeking", "pipSpacePlayPause": "Play / pause using Space", "pipYoutubeCaptions": "Captions button for YouTube",
            "pipDetectionThreshold": "Idle/change detection threshold", "pipSensitiveDetection": "Sensitive detection", "pipDetectionScript": "Detection script", "pipDetectionScriptHint": "Run a shell command on events. Environment: PIPIRI_EVENT, PIPIRI_APP, PIPIRI_BUNDLE_ID, PIPIRI_WINDOW_ID.", "pipScriptTimeout": "Script timeout",
            "pipPatchesTitle": "Off-screen rendering fixes", "pipPatchesBody": "Some browsers and Electron apps pause rendering when their windows are covered. When a fix is enabled, MacPilot relaunches that app with a background-rendering argument without modifying its app bundle.",
            "pipPatchesNoApps": "No supported browser or Electron app was found.", "pipPatchRunning": "Running", "pipPatchRelaunch": "Relaunch with fix", "pipPatchAutoApply": "Keep fixes applied automatically", "pipPatchAutoApplyHint": "When an enabled app starts normally, MacPilot relaunches it once with the off-screen rendering argument. Turn its switch off to stop applying the fix.", "pipPatchFailed": "Could not apply the off-screen rendering fix", "pipPatchDetails": "Details", "pipPatchDetailsBody": "This fix uses an officially supported Chromium/Electron launch argument. A running app must quit before relaunching, so unsaved work could be lost; MacPilot only does this when you click the button or enable automatic application.",
            "pipCustomPatchTitle": "Custom compositor apps", "pipCustomPatchBody": "Firefox, kitty, and Ghostty have no background-rendering launch flag. After backing up the original app, MacPilot can inject an independent lightweight component that makes AppKit report its windows as visible.", "pipCustomPatchNoApps": "No patchable custom-compositor app was found.", "pipCustomPatchWarning": "Patching modifies and re-signs a third-party app, which may make it request Screen Recording, Accessibility, or other permissions again. Quit the target app first. Its original bundle is stored in MacPilot's Application Support folder and can be restored.", "pipPatchInstall": "Install patch", "pipPatchRestore": "Restore original", "pipPatchInstalled": "Patch installed", "pipPatchQuitFirst": "Quit the app first", "pipPatchUpdateDetected": "Update detected; patch can be reinstalled", "pipPatchConfirmTitle": "Modify and re-sign this app?", "pipPatchConfirmBody": "MacPilot will fully back up the original app, inject its off-screen rendering component, and apply an ad-hoc signature. macOS may ask for the app's permissions again.", "pipRestoreConfirmTitle": "Restore the original app?", "pipRestoreConfirmBody": "MacPilot will replace the current app with the complete backup saved before patching. Make sure the target app is not running.", "pipPatchAnotherApp": "Patch another app…", "pipPatchRemoveCustom": "Remove from list", "choose": "Choose",
            "pipPermissionRequired": "Screen Recording permission is required to create a Picture-in-Picture window.", "pipGrantPermission": "Grant Screen Recording…", "pipOpenSettings": "Open Settings",
            "pipAccessibilityRequired": "Accessibility permission is required to intercept the global shortcut in other apps.", "pipGrantAccessibility": "Grant Accessibility…", "pipOpenAccessibility": "Open Accessibility Settings",
            "windowSwitcher": "Window Switcher", "windowSwitcherTitle": "Window Switcher", "windowSwitcherSubtitle": "Quickly switch between windows across applications with ⌥Tab. Hold Option to keep cycling, then release it to focus the selected window.",
            "windowSwitcherShortcut": "⌥Tab", "windowSwitcherShortcutHint": "The default shortcut is ⌥Tab. Hold Option and press Tab repeatedly; hold Shift to cycle backwards.",
            "windowSwitcherIncludeMinimized": "Show minimized windows", "windowSwitcherIncludeHidden": "Show windows from hidden applications",
            "windowSwitcherShowThumbnails": "Show window thumbnails (requires Screen Recording)", "windowSwitcherShowTitles": "Show window titles",
            "windowSwitcherShowIconsOnly": "Show app icons only", "windowSwitcherPreviewSize": "Preview size",
            "windowSwitcherPreviewSmall": "Small", "windowSwitcherPreviewMedium": "Medium", "windowSwitcherPreviewLarge": "Large",
            "windowSwitcherAccessibilityRequired": "Accessibility access is required to read and focus windows from other applications.",
            "windowSwitcherGrantAccessibility": "Grant Accessibility…", "windowSwitcherAccessibilityReady": "Accessibility access is ready",
            "windowSwitcherTestNow": "Show Window Switcher Now", "windowSwitcherNoWindows": "There are no switchable windows right now.",
            "windowSwitcherEnabledStatus": "Window Switcher: On", "windowSwitcherDisabledStatus": "Window Switcher: Off",
            "windowSwitcherMerge": "Merge Windows",
            "windowSwitcherMergeHint": "Merge a chosen app's windows into one: as tabs when the app supports it, otherwise stacked over the main window. Requires Accessibility.",
            "windowSwitcherAddMergeApp": "Add App…",
            "windowSwitcherNoMergeApps": "No merge apps yet",
            "windowSwitcherMergeNow": "Merge",
            "windowSwitcherNotRunning": "Not running",
            "windowSwitcherRemove": "Remove",
            "smoothScrolling": "Smooth Scrolling", "smoothScrollingSubtitle": "Turn mouse-wheel deltas into continuous, trackpad-like scrolling while keeping precise control.",
            "smoothScrollingEnable": "Enable smooth scrolling", "smoothScrollingEnabledStatus": "Smooth Scrolling: On", "smoothScrollingDisabledStatus": "Smooth Scrolling: Off",
            "smoothScrollingVertical": "Smooth vertical", "smoothScrollingHorizontal": "Smooth horizontal", "smoothScrollingReverse": "Reverse direction",
            "smoothScrollingReverseVertical": "Reverse vertical", "smoothScrollingReverseHorizontal": "Reverse horizontal",
            "smoothScrollingStep": "Minimum step", "smoothScrollingSpeed": "Speed gain", "smoothScrollingDuration": "Glide duration",
            "smoothScrollingDeadZone": "Dead zone", "smoothScrollingSimulatePhases": "Simulate trackpad phases",
            "smoothScrollingAdaptiveSpeed": "Accelerate more when scrolling faster", "smoothScrollingAdaptiveSpeedMaximum": "Auto-acceleration limit",
            "smoothScrollingBlockWithCommand": "Disable smooth scrolling while Command is held",
            "smoothScrollingAccessibilityRequired": "Smooth scrolling needs Accessibility access to read and rewrite wheel events in other apps.",
            "smoothScrollingGrantAccessibility": "Grant Accessibility…", "smoothScrollingOpenAccessibility": "Open Accessibility Settings",
            "smoothScrollingAccessibilityReady": "Accessibility access is ready",
            "smoothScrollingNotConfiguredHint": "When disabled, mouse-wheel events pass through using the system default behavior.",
            "rightClickMenu": "Finder Context Menu",
            "clipboard": "Clipboard", "clipboardSubtitle": "Keeps your copy history so you can search, pin, and re-paste text, images, and files.",
            "clipboardEnable": "Enable clipboard", "clipboardEnabledStatus": "Clipboard: On", "clipboardDisabledStatus": "Clipboard: Off",
            "clipboardHotkey": "Global hotkey", "clipboardHotkeyRecord": "Click and press a new shortcut…",
            "clipboardStorageLimit": "History size limit",
            "clipboardPasteByDefault": "Paste when clicking an item (otherwise copy only)",
            "clipboardShowSearch": "Show the search field when the panel opens",
            "clipboardClearSystemClipboard": "Also clear the system clipboard when clearing history",
            "clipboardPinsAtTop": "Pinned items on top",
            "clipboardOpenNow": "Open Clipboard Panel",
            "clipboardClearHistory": "Clear History", "clipboardClearAllHistory": "Clear All History",
            "clipboardClearAllConfirm": "Are you sure you want to clear all clipboard history? This cannot be undone.",
            "clipboardAccessibilityRequired": "Pasting requires Accessibility access to simulate ⌘V.",
            "clipboardGrantAccessibility": "Grant Accessibility…",
            "clipboardAccessibilityReady": "Accessibility access is ready",
            "clipboardNotConfiguredHint": "When disabled, clipboard content is not recorded.",
            "clipboardSearchPlaceholder": "Search clipboard history…",
            "clipboardHistoryEmpty": "Clipboard history is empty",
            "clipboardFooterHint": "%d items · ↑↓ select · ⏎ paste · ⌘⏎ copy · ⌫ delete",
            "clipboardImageLabel": "Image",
            "clipboardHotkeyLabel": "Shortcut %@"
        ]
}

@MainActor
final class MacPilotModel: ObservableObject {
    private static let safetyCheckInterval: Duration = .seconds(300)
    private static let closeWindowsLaunchGracePeriod: Duration = .seconds(10)

    private struct StoredConfiguration: Codable {
        var version: Int
        var rules: [QuitRule]
        var isEnforcing: Bool
        var language: AppLanguage
        var launchRules: [LaunchRule]
        var isLaunchSchedulingEnabled: Bool
        var lastScheduledBootSession: String?
        var bleUnlock: BLEUnlockSettings
        var fileCompression: FolderCompressionSettings

        var screenCapture: ScreenCaptureSettings
        var screenRecording: ScreenRecordingSettings
        var pictureInPicture: PictureInPictureSettings
        var inputSources: InputSourceSettings
        var windowSwitcher: WindowSwitcherSettings
        var smoothScrolling: SmoothScrollSettings
        var clipboard: ClipboardSettings

        init(rules: [QuitRule], isEnforcing: Bool, language: AppLanguage, launchRules: [LaunchRule], isLaunchSchedulingEnabled: Bool, lastScheduledBootSession: String?, bleUnlock: BLEUnlockSettings, fileCompression: FolderCompressionSettings, screenCapture: ScreenCaptureSettings, screenRecording: ScreenRecordingSettings, pictureInPicture: PictureInPictureSettings, inputSources: InputSourceSettings, windowSwitcher: WindowSwitcherSettings, smoothScrolling: SmoothScrollSettings, clipboard: ClipboardSettings) {
            version = 14
            self.rules = rules
            self.isEnforcing = isEnforcing
            self.language = language
            self.launchRules = launchRules
            self.isLaunchSchedulingEnabled = isLaunchSchedulingEnabled
            self.lastScheduledBootSession = lastScheduledBootSession
            self.bleUnlock = bleUnlock
            self.fileCompression = fileCompression
            self.screenCapture = screenCapture
            self.screenRecording = screenRecording
            self.pictureInPicture = pictureInPicture
            self.inputSources = inputSources
            self.windowSwitcher = windowSwitcher
            self.smoothScrolling = smoothScrolling
            self.clipboard = clipboard
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            rules = try container.decodeIfPresent([QuitRule].self, forKey: .rules) ?? []
            isEnforcing = try container.decodeIfPresent(Bool.self, forKey: .isEnforcing) ?? true
            language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
            launchRules = try container.decodeIfPresent([LaunchRule].self, forKey: .launchRules) ?? []
            isLaunchSchedulingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLaunchSchedulingEnabled) ?? true
            lastScheduledBootSession = try container.decodeIfPresent(String.self, forKey: .lastScheduledBootSession)
            bleUnlock = try container.decodeIfPresent(BLEUnlockSettings.self, forKey: .bleUnlock) ?? BLEUnlockSettings()
            fileCompression = try container.decodeIfPresent(FolderCompressionSettings.self, forKey: .fileCompression) ?? FolderCompressionSettings()
            screenCapture = try container.decodeIfPresent(ScreenCaptureSettings.self, forKey: .screenCapture) ?? ScreenCaptureSettings()
            screenRecording = try container.decodeIfPresent(ScreenRecordingSettings.self, forKey: .screenRecording) ?? ScreenRecordingSettings()
            pictureInPicture = try container.decodeIfPresent(PictureInPictureSettings.self, forKey: .pictureInPicture) ?? PictureInPictureSettings()
            inputSources = try container.decodeIfPresent(InputSourceSettings.self, forKey: .inputSources) ?? InputSourceSettings()
            windowSwitcher = try container.decodeIfPresent(WindowSwitcherSettings.self, forKey: .windowSwitcher) ?? WindowSwitcherSettings()
            smoothScrolling = try container.decodeIfPresent(SmoothScrollSettings.self, forKey: .smoothScrolling) ?? SmoothScrollSettings()
            clipboard = try container.decodeIfPresent(ClipboardSettings.self, forKey: .clipboard) ?? ClipboardSettings()
        }
    }

    @Published private(set) var rules: [QuitRule] = []
    @Published private(set) var launchRules: [LaunchRule] = []
    @Published var isEnforcing = true { didSet { enforcingChanged() } }
    @Published var isLaunchSchedulingEnabled = true { didSet { launchSchedulingChanged() } }
    @Published private(set) var lastChecked = Date()
    @Published var alertMessage: String?
    @Published private(set) var alertOffersAccessibilitySettings = false
    @Published private(set) var alertOffersAccessibilityReset = false
    @Published private(set) var isResettingAccessibility = false
    @Published private(set) var isResettingScreenCapture = false
    @Published private(set) var launchesAtLogin = false
    @Published var language: AppLanguage = .system { didSet { screenCapture.language = language; screenRecording.language = language; windowSwitcher.language = language; clipboard.language = language; saveIfReady() } }
    let ble = BLEUnlockModel()
    let updater = SoftwareUpdater()
    let fileCompression = FolderCompressionModel()
    let screenCapture = ScreenCaptureModel()
    let screenRecording = ScreenRecordingModel()
    let pictureInPicture = PictureInPictureModel()
    let inputSources = InputSourceModel()
    let windowSwitcher = WindowSwitcherModel()
    let smoothScrolling = SmoothScrollModel()
    let clipboard = ClipboardModel()
    @Published var requestedSection: MainSection?
    /// Set by the menu bar/deep-link shortcut entry so the capture settings
    /// can present the recorder immediately after the main window is opened.
    @Published var requestedCaptureShortcutEditor = false
    private var launchTasks: [UUID: Task<Void, Never>] = [:]
    private let launchGate = LaunchGate(minimumStartInterval: 3)
    @Published private(set) var launchStates: [UUID: LaunchRuntimeState] = [:]
    @Published private(set) var quitDeadlines: [UUID: Date] = [:]
    private var quitRuntimeStates: [UUID: QuitRuntimeState] = [:]
    private var quitTasks: [UUID: Task<Void, Never>] = [:]
    private var quitWakeDeadlines: [UUID: Date] = [:]
    private var safetyCheckTask: Task<Void, Never>?
    private var inputSourceSaveTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastScheduledBootSession: String?
    private var isLoading = false
    private let configurationURL: URL
    private let legacyConfigurationURLs: [URL]
    private let configurationWriteQueue = DispatchQueue(
        label: "com.misswell.macpilot.configuration-write",
        qos: .utility
    )

    private static let legacyUserDefaultsSources: [(suiteName: String, rulesKey: String, enforcementKey: String, languageKey: String)] = [
        ("com.octoqit.app", "OctoQuit.rules.v2", "OctoQuit.enforcing", "OctoQuit.language"),
        ("com.misswell.octopilot", "OctoPilot.rules.v2", "OctoPilot.enforcing", "OctoPilot.language"),
        ("com.misswell.octopilot", "OctoQuit.rules.v2", "OctoQuit.enforcing", "OctoQuit.language")
    ]

    init() {
        configurationURL = Self.defaultConfigurationURL()
        legacyConfigurationURLs = Self.legacyConfigurationURLs()
        isLoading = true
        load()
        isLoading = false
        save()
        refreshLoginItemState()
        startObservingWorkspace()
        startSafetyChecks()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak screenCapture] _ in
            Task { @MainActor in screenCapture?.shutdown() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak screenRecording] _ in
            Task { @MainActor in screenRecording?.shutdown() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak smoothScrolling] _ in
            Task { @MainActor in smoothScrolling?.shutdown() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak clipboard] _ in
            Task { @MainActor in clipboard?.shutdown() }
        }
        NotificationCenter.default.addObserver(
            forName: .macPilotDeepLink,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor in self?.handleDeepLink(url) }
        }
        evaluateRules()
        scheduleLaunchPlanForCurrentBootIfNeeded()
        clearLegacyAccessibilityRecoveryRequest()
        ble.persist = { [weak self] in self?.saveIfReady() }
        fileCompression.persist = { [weak self] in self?.saveIfReady() }
        screenCapture.persist = { [weak self] in self?.saveIfReady() }
        screenRecording.persist = { [weak self] in self?.saveIfReady() }
        screenRecording.isShortcutInUse = { [weak screenCapture] binding in
            guard let screenCapture else { return false }
            return ScreenCaptureShortcutKind.allCases.contains {
                screenCapture.shortcutBinding(for: $0) == binding
            }
        }
        screenRecording.onRequestSelection = { [weak self] mode in
            self?.screenCapture.startRecordingSelection(mode: mode)
        }
        screenCapture.onRecordingSelection = { [weak self] rect, _ in
            self?.screenRecording.start(captureRect: rect)
        }
        screenRecording.onCompleted = { [weak self] url in
            self?.screenCapture.showRecordingQuickAccess(url: url)
        }
        pictureInPicture.persist = { [weak self] in self?.saveIfReady() }
        inputSources.persist = { [weak self] in self?.scheduleInputSourceSave() }
        windowSwitcher.persist = { [weak self] in self?.saveIfReady() }
        smoothScrolling.persist = { [weak self] in self?.saveIfReady() }
        clipboard.persist = { [weak self] in self?.saveIfReady() }
        windowSwitcher.language = language
        clipboard.language = language
        ble.startObservingSystemState()
        ble.activateFromConfiguration()
        fileCompression.activateFromConfiguration()
        screenCapture.activateFromConfiguration()
        screenRecording.language = language
        screenRecording.activateFromConfiguration()
        pictureInPicture.activateFromConfiguration()
        inputSources.activateFromConfiguration()
        windowSwitcher.activateFromConfiguration()
        smoothScrolling.activateFromConfiguration()
        clipboard.activateFromConfiguration()
        // Finder 右键菜单（融合 RClick FinderSync 扩展）。
        startRightClickMenu()
        Task { [weak updater] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await updater?.checkForUpdates()
        }
    }

    var enabledCount: Int { rules.filter(\.isEnabled).count }
    var enabledLaunchCount: Int { launchRules.filter(\.isEnabled).count }
    var pendingLaunchCount: Int { launchStates.values.reduce(into: 0) { if case .pending = $1 { $0 += 1 } } }
    var configurationFilePath: String { configurationURL.path }

    /// Handles the Snapzy-compatible automation routes used by scripts and
    /// other tools. Unknown routes are intentionally ignored so opening an
    /// unrelated URL never changes the app state.
    func handleDeepLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "snapzy" || scheme == "macpilot" else { return }
        var route = url.host.map { [$0.lowercased()] } ?? []
        route.append(contentsOf: url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() })
        guard !route.isEmpty else { return }
        switch route {
        case ["capture", "fullscreen"], ["capture", "full-screen"], ["screenshot", "fullscreen"]:
            screenCapture.captureFullscreen()
        case ["capture", "area"], ["screenshot", "area"], ["area"]:
            screenCapture.startAreaCapture()
        case ["capture", "repeat-area"], ["screenshot", "repeat-area"], ["repeat-area"]:
            screenCapture.repeatSmartCapture()
        case ["capture", "application"], ["capture", "window"], ["screenshot", "application"]:
            screenCapture.startApplicationWindowCapture()
        case ["capture", "active-window"], ["capture", "focused-window"], ["screenshot", "active-window"]:
            screenCapture.captureActiveWindow()
        case ["capture", "area-annotate"], ["screenshot", "area-annotate"]:
            screenCapture.startAreaAnnotateCapture()
        case ["capture", "scrolling"], ["screenshot", "scrolling"]:
            screenCapture.startScrollingCapture()
        case ["capture", "ocr"], ["screenshot", "ocr"], ["ocr"]:
            screenCapture.startOCRCapture()
        case ["capture", "smart-element"], ["screenshot", "smart-element"]:
            screenCapture.startSmartCapture()
        case ["capture", "object-cutout"], ["screenshot", "object-cutout"]:
            screenCapture.startObjectCutoutCapture()
        case ["record", "screen"], ["record", "fullscreen"]:
            screenRecording.start()
        case ["record", "application"], ["record", "window"]:
            screenRecording.setCaptureMode(.application)
            screenRecording.start()
        case ["record", "stop"]:
            screenRecording.stop()
        case ["right-click"], ["rightclick"], ["finder", "menu"]:
            requestedSection = .rightClick
        case ["settings"], ["preferences"]:
            requestedSection = .settings
        case ["settings", "capture"], ["settings", "screenshots"]:
            requestedSection = .capture
        case ["show", "shortcuts"], ["open", "shortcuts"]:
            requestedSection = .capture
            requestedCaptureShortcutEditor = true
        case ["open", "history"], ["history"]:
            requestedSection = .capture
        default:
            break
        }
    }

    @discardableResult
    func requestWindowControlAccess(presentRecoveryGuidance: Bool = true) -> Bool {
        // Feature toggles and startup paths must never trigger a TCC prompt.
        // Permission requests are reserved for explicit Grant buttons.
        let trusted = AXIsProcessTrusted()
        if !trusted && presentRecoveryGuidance { showWindowControlGuidance() }
        return trusted
    }

    func hasWindowControlAccess() -> Bool {
        AXIsProcessTrusted()
    }

    private func showWindowControlGuidance() {
        alertOffersAccessibilitySettings = true
        alertOffersAccessibilityReset = true
        alertMessage = t("accessibilityRequired", Bundle.main.bundleURL.path)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func resetAccessibility(presentFailureAlert: Bool = true) async -> String? {
        guard !isResettingAccessibility else { return t("resettingAccessibility") }
        isResettingAccessibility = true
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
        let command = AccessibilityResetCommand(bundleIdentifier: bundleIdentifier)
        let execution = await Task.detached(priority: .userInitiated) {
            do {
                return AccessibilityResetExecution.success(try command.run())
            } catch {
                return AccessibilityResetExecution.failure(error.localizedDescription)
            }
        }.value

        switch execution {
        case .success(let status):
            guard status == 0 else {
                let message = t("accessibilityResetFailed", t("accessibilityResetStatus", status))
                isResettingAccessibility = false
                if presentFailureAlert { showAlert(message) }
                return message
            }
            return nil
        case .failure(let description):
            let message = t("accessibilityResetFailed", description)
            isResettingAccessibility = false
            if presentFailureAlert { showAlert(message) }
            return message
        }
    }

    @discardableResult
    func resetScreenCapturePermission(presentFailureAlert: Bool = true) async -> String? {
        guard !isResettingScreenCapture else { return t("scResettingPermission") }
        isResettingScreenCapture = true
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
        let command = ScreenCaptureResetCommand(bundleIdentifier: bundleIdentifier)
        let execution = await Task.detached(priority: .userInitiated) {
            do {
                return ScreenCaptureResetExecution.success(try command.run())
            } catch {
                return ScreenCaptureResetExecution.failure(error.localizedDescription)
            }
        }.value

        switch execution {
        case .success(let status):
            guard status == 0 else {
                let message = t("scPermissionResetFailed", t("scPermissionResetStatus", status))
                isResettingScreenCapture = false
                if presentFailureAlert { showAlert(message) }
                return message
            }
            return nil
        case .failure(let description):
            let message = t("scPermissionResetFailed", description)
            isResettingScreenCapture = false
            if presentFailureAlert { showAlert(message) }
            return message
        }
    }

    func terminateAfterSheetsClose() {
        guard NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.terminateAfterSheetsClose()
            }
            return
        }
        NSApp.terminate(nil)
    }

    private func clearLegacyAccessibilityRecoveryRequest() {
        // Older builds persisted a one-shot flag that prompted again on the
        // next launch. Consume it without requesting access.
        _ = AccessibilityRecoveryRequest.consume()
    }

    func dismissAlert() {
        alertMessage = nil
        alertOffersAccessibilitySettings = false
        alertOffersAccessibilityReset = false
    }

    func showAlert(_ message: String) {
        alertOffersAccessibilitySettings = false
        alertOffersAccessibilityReset = false
        alertMessage = message
    }

    @discardableResult
    func addRule(_ rule: QuitRule) -> Bool {
        guard !isOwnApplication(rule.bundleIdentifier) else {
            showAlert(t("selfRule"))
            return false
        }
        guard !rules.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) else {
            showAlert(t("duplicateRule", rule.appName))
            return false
        }
        rules.append(rule)
        save()
        rebuildQuitSchedule()
        return true
    }

    func updateRule(_ rule: QuitRule) {
        guard !isOwnApplication(rule.bundleIdentifier) else {
            showAlert(t("selfRule"))
            return
        }
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
        rebuildQuitSchedule()
    }

    @discardableResult
    func addLaunchRule(_ rule: LaunchRule) -> Bool {
        guard !launchRules.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) else {
            showAlert(t("launchDuplicate", rule.appName))
            return false
        }
        launchRules.append(rule)
        save()
        return true
    }

    func updateLaunchRule(_ rule: LaunchRule) {
        guard let index = launchRules.firstIndex(where: { $0.id == rule.id }) else { return }
        cancelLaunchTask(for: rule.id, markCancelled: false)
        launchRules[index] = rule
        save()
    }

    func removeLaunchRule(_ rule: LaunchRule) {
        cancelLaunchTask(for: rule.id, markCancelled: false)
        launchRules.removeAll { $0.id == rule.id }
        launchStates[rule.id] = nil
        save()
    }

    func toggleLaunchRule(_ rule: LaunchRule) {
        guard let index = launchRules.firstIndex(where: { $0.id == rule.id }) else { return }
        launchRules[index].isEnabled.toggle()
        if !launchRules[index].isEnabled { cancelLaunchTask(for: rule.id, markCancelled: true) }
        save()
    }

    func runLaunchPlanNow() {
        guard isLaunchSchedulingEnabled else { return }
        scheduleLaunchPlan()
    }

    func cancelScheduledLaunches() {
        for id in Array(launchTasks.keys) { cancelLaunchTask(for: id, markCancelled: true) }
    }

    func remove(_ rule: QuitRule) {
        cancelQuitTask(for: rule.id)
        rules.removeAll { $0.id == rule.id }
        quitRuntimeStates[rule.id] = nil
        quitDeadlines[rule.id] = nil
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        rules.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func toggleRule(_ rule: QuitRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled.toggle()
        save()
        rebuildQuitSchedule()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginItemState()
        } catch {
            showAlert(t("loginError", error.localizedDescription))
            refreshLoginItemState()
        }
    }

    func refreshLoginItemState() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func revealConfigurationFile() {
        save()
        NSWorkspace.shared.activateFileViewerSelecting([configurationURL])
    }

    func prepareQuitterImportFromDefaultLocation() -> QuitterImportPreview? {
        let url = Self.defaultQuitterConfigurationURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(t("importQuitterNotFound", url.path))
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = propertyList as? [String: Any],
                  let sourceRules = root["rules"] as? [[String: Any]] else {
                throw ImportError.invalidFormat
            }

            let existingIdentifiers = Set(rules.map(\.bundleIdentifier))
            var imported: [QuitRule] = []
            var skipped = 0
            for sourceRule in sourceRules {
                guard let bundleIdentifier = sourceRule["bundleIdentifier"] as? String,
                      let bundlePath = sourceRule["bundlePath"] as? String,
                      !bundleIdentifier.isEmpty,
                      !isOwnApplication(bundleIdentifier),
                      !existingIdentifiers.contains(bundleIdentifier),
                      !imported.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                    skipped += 1
                    continue
                }

                let hide = minutes(fromQuitterInterval: sourceRule["inactiveHideInterval"])
                let quit = minutes(fromQuitterInterval: sourceRule["inactiveQuitInterval"])
                let hiddenQuit = minutes(fromQuitterInterval: sourceRule["quitIfHiddenInterval"])
                guard hide != nil || quit != nil || hiddenQuit != nil else {
                    skipped += 1
                    continue
                }

                imported.append(QuitRule(
                    appName: appName(forBundlePath: bundlePath),
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: bundlePath,
                    inactiveHideMinutes: hide,
                    inactiveQuitMinutes: quit,
                    hiddenQuitMinutes: hiddenQuit
                ))
            }

            guard !imported.isEmpty else {
                showAlert(t("importQuitterEmpty"))
                return nil
            }
            let importedEnforcementState = (root["active"] as? NSNumber)?.boolValue
            return QuitterImportPreview(rules: imported, skippedCount: skipped, isEnforcing: importedEnforcementState)
        } catch ImportError.invalidFormat {
            showAlert(t("importQuitterInvalid"))
        } catch {
            showAlert(t("importQuitterError", error.localizedDescription))
        }
        return nil
    }

    func importQuitterConfiguration(_ preview: QuitterImportPreview) {
        rules.append(contentsOf: preview.rules)
        if let isEnforcing = preview.isEnforcing {
            isLoading = true
            self.isEnforcing = isEnforcing
            isLoading = false
        }
        save()
        showAlert(t("importQuitterSuccess", preview.rules.count, preview.skippedCount))
    }

    func evaluateRules() {
        rebuildQuitSchedule()
    }

    private func startObservingWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    self?.handleWorkspaceNotification(name: name, application: application)
                }
            }
        }
    }

    private func handleWorkspaceNotification(name: Notification.Name, application: NSRunningApplication?) {
        let now = Date()
        if name == NSWorkspace.didWakeNotification {
            rebuildQuitSchedule(now: now)
            return
        }
        guard let bundleIdentifier = application?.bundleIdentifier else { return }
        let matchingRules = rules.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !matchingRules.isEmpty else { return }
        for rule in matchingRules {
            var state = quitRuntimeStates[rule.id] ?? QuitRuntimeState()
            switch name {
            case NSWorkspace.didActivateApplicationNotification:
                state.lastActiveAt = now
                state.hiddenAt = nil
                state.didHideSinceActive = false
            case NSWorkspace.didDeactivateApplicationNotification:
                state.lastActiveAt = now
            case NSWorkspace.didHideApplicationNotification:
                state.hiddenAt = now
            case NSWorkspace.didUnhideApplicationNotification:
                state.hiddenAt = nil
            case NSWorkspace.didLaunchApplicationNotification:
                state.lastActiveAt = now
            case NSWorkspace.didTerminateApplicationNotification:
                state = QuitRuntimeState()
            default:
                break
            }
            quitRuntimeStates[rule.id] = state
            if isEnforcing, rule.isEnabled, !isOwnApplication(rule.bundleIdentifier) {
                evaluateQuitRule(
                    rule,
                    app: name == NSWorkspace.didTerminateApplicationNotification ? nil : application,
                    now: now
                )
            }
        }
        if isEnforcing { lastChecked = now }
    }

    private func rebuildQuitSchedule(now: Date = Date()) {
        guard isEnforcing else {
            cancelAllQuitTasks()
            return
        }
        var runningApps = [String: NSRunningApplication]()
        for app in NSWorkspace.shared.runningApplications {
            if let identifier = app.bundleIdentifier { runningApps[identifier] = app }
        }
        let enforceableRules = rules.filter { $0.isEnabled && !isOwnApplication($0.bundleIdentifier) }
        let validRuleIDs = Set(enforceableRules.map(\.id))
        for id in Array(quitTasks.keys) where !validRuleIDs.contains(id) { cancelQuitTask(for: id) }
        for id in Array(quitDeadlines.keys) where !validRuleIDs.contains(id) { quitDeadlines[id] = nil }

        for rule in enforceableRules {
            evaluateQuitRule(rule, app: runningApps[rule.bundleIdentifier], now: now)
        }
        lastChecked = now
    }

    private func evaluateQuitRule(_ rule: QuitRule, app: NSRunningApplication?, now: Date) {
        guard let app else {
            cancelQuitTask(for: rule.id)
            quitRuntimeStates[rule.id] = nil
            quitDeadlines[rule.id] = nil
            return
        }

        var state = quitRuntimeStates[rule.id] ?? QuitRuntimeState()
        if app.isActive {
            cancelQuitTask(for: rule.id)
            state.lastActiveAt = now
            state.hiddenAt = nil
            state.didHideSinceActive = false
            state.didCloseSinceActive = false
            quitRuntimeStates[rule.id] = state
            quitDeadlines[rule.id] = nil
            return
        }
        if state.lastActiveAt == nil { state.lastActiveAt = now }
        if app.isHidden {
            if state.hiddenAt == nil { state.hiddenAt = now }
        } else {
            state.hiddenAt = nil
        }

        let hideDeadline = state.didHideSinceActive ? nil : deadline(minutes: rule.inactiveHideMinutes, since: state.lastActiveAt)
        let closeDeadline = state.didCloseSinceActive ? nil : deadline(minutes: rule.inactiveCloseMinutes, since: state.lastActiveAt)
        let initialQuitDeadline = [
            deadline(minutes: rule.inactiveQuitMinutes, since: state.lastActiveAt),
            deadline(minutes: rule.hiddenQuitMinutes, since: state.hiddenAt)
        ].compactMap { $0 }.min()

        if let initialQuitDeadline, initialQuitDeadline <= now {
            app.terminate()
            quitRuntimeStates[rule.id] = state
            quitDeadlines[rule.id] = nil
            scheduleQuitWake(for: rule.id, at: now.addingTimeInterval(60), now: now)
            return
        }

        var nextDeadlines = [Date]()
        if let closeDeadline, closeDeadline <= now {
            if closeWindows(of: app) != .failed {
                state.didCloseSinceActive = true
            } else {
                nextDeadlines.append(now.addingTimeInterval(60))
            }
        } else if let closeDeadline {
            nextDeadlines.append(closeDeadline)
        }

        if let hideDeadline, hideDeadline <= now {
            app.hide()
            state.didHideSinceActive = true
            state.hiddenAt = now
        } else if let hideDeadline {
            nextDeadlines.append(hideDeadline)
        }

        let inactiveQuitDeadline = deadline(minutes: rule.inactiveQuitMinutes, since: state.lastActiveAt)
        let hiddenQuitDeadline = deadline(minutes: rule.hiddenQuitMinutes, since: state.hiddenAt)
        let quitDeadline = [inactiveQuitDeadline, hiddenQuitDeadline].compactMap { $0 }.min()
        if let inactiveQuitDeadline { nextDeadlines.append(inactiveQuitDeadline) }
        if let hiddenQuitDeadline { nextDeadlines.append(hiddenQuitDeadline) }

        quitRuntimeStates[rule.id] = state
        if let quitDeadline { setQuitDeadline(quitDeadline, for: rule.id) }
        else { quitDeadlines[rule.id] = nil }

        guard let nextDeadline = nextDeadlines.filter({ $0 > now }).min() else {
            cancelQuitTask(for: rule.id)
            return
        }
        scheduleQuitWake(for: rule.id, at: nextDeadline, now: now)
    }

    private func closeWindows(of application: NSRunningApplication) -> WindowCloseResult {
        guard hasWindowControlAccess() else { return .failed }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success else {
            return result == .noValue || result == .attributeUnsupported ? .noClosableWindows : .failed
        }
        guard let windows = windowsValue as? [AXUIElement] else { return .noClosableWindows }

        var didAttemptClose = false
        var actionFailed = false
        for window in windows {
            var closeButtonValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
                  let closeButtonValue else { continue }
            didAttemptClose = true
            let closeButton = unsafeDowncast(closeButtonValue, to: AXUIElement.self)
            if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) != .success {
                actionFailed = true
            }
        }
        if actionFailed { return .failed }
        return didAttemptClose ? .closed : .noClosableWindows
    }

    private func scheduleQuitWake(for id: UUID, at deadline: Date, now: Date) {
        if quitTasks[id] != nil, quitWakeDeadlines[id] == deadline { return }
        cancelQuitTask(for: id)
        let delay = max(0, deadline.timeIntervalSince(now))
        quitWakeDeadlines[id] = deadline
        quitTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.wakeQuitRule(id)
        }
    }

    private func startSafetyChecks() {
        guard isEnforcing, safetyCheckTask == nil else { return }
        safetyCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Workspace notifications and per-rule deadline tasks handle normal operation.
                    // This slower sweep only recovers from a missed system notification.
                    try await Task.sleep(for: Self.safetyCheckInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.rebuildQuitSchedule()
            }
        }
    }

    private func stopSafetyChecks() {
        safetyCheckTask?.cancel()
        safetyCheckTask = nil
    }

    private func wakeQuitRule(_ id: UUID) {
        quitTasks[id] = nil
        quitWakeDeadlines[id] = nil
        guard isEnforcing,
              let rule = rules.first(where: { $0.id == id }),
              rule.isEnabled,
              !isOwnApplication(rule.bundleIdentifier) else { return }
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == rule.bundleIdentifier }
        let now = Date()
        evaluateQuitRule(rule, app: app, now: now)
        lastChecked = now
    }

    private func deadline(minutes: Int?, since date: Date?) -> Date? {
        guard let minutes, let date else { return nil }
        return date.addingTimeInterval(Double(minutes * 60))
    }

    private func isOwnApplication(_ bundleIdentifier: String) -> Bool {
        guard let ownIdentifier = Bundle.main.bundleIdentifier else { return false }
        return bundleIdentifier.caseInsensitiveCompare(ownIdentifier) == .orderedSame
    }

    private func setQuitDeadline(_ deadline: Date, for id: UUID) {
        if quitDeadlines[id] != deadline { quitDeadlines[id] = deadline }
    }

    private func cancelQuitTask(for id: UUID) {
        quitTasks[id]?.cancel()
        quitTasks[id] = nil
        quitWakeDeadlines[id] = nil
    }

    private func cancelAllQuitTasks(resetRuntime: Bool = false) {
        for id in Array(quitTasks.keys) { cancelQuitTask(for: id) }
        if !quitDeadlines.isEmpty { quitDeadlines.removeAll() }
        if resetRuntime { quitRuntimeStates.removeAll() }
    }

    private func load() {
        if let data = try? Data(contentsOf: configurationURL),
           let configuration = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
            apply(configuration)
            return
        }

        for url in legacyConfigurationURLs {
            if let data = try? Data(contentsOf: url),
               let configuration = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
                apply(configuration)
                return
            }
        }

        // One-time migration from versions that used UserDefaults.
        for source in Self.legacyUserDefaultsSources {
            let defaults = UserDefaults(suiteName: source.suiteName) ?? .standard
            var didLoad = false
            if let enforcing = defaults.object(forKey: source.enforcementKey) as? Bool {
                isEnforcing = enforcing
                didLoad = true
            }
            if let storedLanguage = defaults.string(forKey: source.languageKey),
               let decodedLanguage = AppLanguage(rawValue: storedLanguage) {
                language = decodedLanguage
                didLoad = true
            }
            if let data = defaults.data(forKey: source.rulesKey),
               let saved = try? JSONDecoder().decode([QuitRule].self, from: data) {
                rules = saved
                didLoad = true
            }
            if didLoad { return }
        }
    }

    private func apply(_ configuration: StoredConfiguration) {
        isEnforcing = configuration.isEnforcing
        language = configuration.language
        rules = configuration.rules
        launchRules = configuration.launchRules
        isLaunchSchedulingEnabled = configuration.isLaunchSchedulingEnabled
        lastScheduledBootSession = configuration.lastScheduledBootSession
        ble.applyLoadedSettings(configuration.bleUnlock)
        fileCompression.applyLoadedSettings(configuration.fileCompression)
        screenCapture.applyLoadedSettings(configuration.screenCapture)
        screenRecording.applyLoadedSettings(configuration.screenRecording)
        pictureInPicture.applyLoadedSettings(configuration.pictureInPicture)
        inputSources.applyLoadedSettings(configuration.inputSources)
        windowSwitcher.applyLoadedSettings(configuration.windowSwitcher)
        smoothScrolling.applyLoadedSettings(configuration.smoothScrolling)
        clipboard.applyLoadedSettings(configuration.clipboard)
    }

    private func scheduleInputSourceSave() {
        guard !isLoading else { return }
        inputSourceSaveTask?.cancel()
        inputSourceSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.inputSourceSaveTask = nil
            self.save()
        }
    }

    private func save() {
        let configuration = StoredConfiguration(
            rules: rules,
            isEnforcing: isEnforcing,
            language: language,
            launchRules: launchRules,
            isLaunchSchedulingEnabled: isLaunchSchedulingEnabled,
            lastScheduledBootSession: lastScheduledBootSession,
            bleUnlock: ble.settings,
            fileCompression: fileCompression.settings,
            screenCapture: screenCapture.settings,
            screenRecording: screenRecording.settings,
            pictureInPicture: pictureInPicture.settings,
            inputSources: inputSources.settings,
            windowSwitcher: windowSwitcher.settings,
            smoothScrolling: smoothScrolling.settings,
            clipboard: clipboard.settings
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(configuration)
        } catch {
            showAlert(t("configSaveError", error.localizedDescription))
            return
        }

        let configurationURL = self.configurationURL
        configurationWriteQueue.async { [weak self] in
            do {
                let directory = configurationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: configurationURL, options: .atomic)
            } catch {
                let errorDescription = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.showAlert(self.t("configSaveError", errorDescription))
                }
            }
        }
    }

    private func saveIfReady() {
        guard !isLoading else { return }
        save()
    }

    private func enforcingChanged() {
        guard !isLoading else { return }
        if isEnforcing {
            startSafetyChecks()
            rebuildQuitSchedule()
        } else {
            stopSafetyChecks()
            cancelAllQuitTasks(resetRuntime: true)
        }
        save()
    }

    private func launchSchedulingChanged() {
        guard !isLoading else { return }
        if !isLaunchSchedulingEnabled { cancelScheduledLaunches() }
        save()
    }

    private func scheduleLaunchPlanForCurrentBootIfNeeded() {
        guard isLaunchSchedulingEnabled, launchesAtLogin else { return }
        let bootSession = Self.bootSessionIdentifier()
        guard lastScheduledBootSession != bootSession else { return }
        lastScheduledBootSession = bootSession
        save()
        scheduleLaunchPlan()
    }

    private func scheduleLaunchPlan() {
        cancelScheduledLaunches()
        let now = Date()
        for rule in launchRules where rule.isEnabled {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
                launchStates[rule.id] = .skippedAlreadyRunning
                continue
            }
            let dueDate = now.addingTimeInterval(Double(rule.delaySeconds))
            launchStates[rule.id] = .pending(dueDate)
            launchTasks[rule.id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(rule.delaySeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.launch(ruleID: rule.id)
            }
        }
    }

    private func launch(ruleID: UUID) async {
        launchTasks[ruleID] = nil
        await launchGate.run { [weak self] in
            await self?.performLaunch(ruleID: ruleID)
        }
    }

    private func performLaunch(ruleID: UUID) async {
        guard !Task.isCancelled else {
            launchStates[ruleID] = .cancelled
            return
        }
        guard isLaunchSchedulingEnabled,
              let rule = launchRules.first(where: { $0.id == ruleID }), rule.isEnabled else {
            launchStates[ruleID] = .cancelled
            return
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
            launchStates[ruleID] = .skippedAlreadyRunning
            return
        }
        let url = URL(fileURLWithPath: rule.bundlePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            launchStates[ruleID] = .failed("App not found")
            return
        }
        launchStates[ruleID] = .launching
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = rule.visibilityMode == .foreground
        let previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
        do {
            let launchedApplication = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            switch rule.visibilityMode {
            case .foreground:
                break
            case .hidden:
                await hideAfterLaunch(launchedApplication, restoring: previousFrontmostApplication)
            case .closeWindows:
                guard await closeWindowsAfterLaunch(launchedApplication, restoring: previousFrontmostApplication) else {
                    launchStates[ruleID] = .failed(t("launchCloseFailed"))
                    return
                }
            }
            launchStates[ruleID] = .launched
        } catch {
            launchStates[ruleID] = .failed(error.localizedDescription)
        }
    }

    private func hideAfterLaunch(_ application: NSRunningApplication, restoring previousApplication: NSRunningApplication?) async {
        _ = await retryPostLaunchAction(application, restoring: previousApplication) {
            application.hide()
        }
    }

    private func closeWindowsAfterLaunch(_ application: NSRunningApplication, restoring previousApplication: NSRunningApplication?) async -> Bool {
        do {
            try await Task.sleep(for: Self.closeWindowsLaunchGracePeriod)
        } catch {
            return false
        }
        guard !application.isTerminated else { return false }
        // 先把目标应用切到前台再模拟点击关闭按钮，使其更接近"用户在前台手动关闭"，
        // 从而让"关闭即缩到菜单栏、移除 Dock 图标"的应用（如 OpenVPN）更可能触发自身逻辑。
        application.activate(options: [])
        return await retryPostLaunchAction(application, restoring: previousApplication) {
            self.closeWindows(of: application).postLaunchResult
        }
    }

    private func retryPostLaunchAction(
        _ application: NSRunningApplication,
        restoring previousApplication: NSRunningApplication?,
        action: () -> Bool?
    ) async -> Bool {
        var completed = true
        // Some apps create or reactivate their first window after the workspace
        // launch callback returns, so retry briefly without keeping a poller alive.
        for delayMilliseconds in [0, 250, 750, 1_500] {
            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return completed
                }
            }
            guard !application.isTerminated else { return false }
            let stoleFocus = application.isActive
            if let result = action() { completed = result }
            if stoleFocus,
               let previousApplication,
               !previousApplication.isTerminated,
               previousApplication.processIdentifier != application.processIdentifier {
                previousApplication.activate(options: [])
            }
        }
        return !application.isTerminated && completed
    }

    private func cancelLaunchTask(for id: UUID, markCancelled: Bool) {
        launchTasks[id]?.cancel()
        launchTasks[id] = nil
        if markCancelled { launchStates[id] = .cancelled }
    }

    private static func defaultConfigurationURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent(AppIdentity.configurationDirectoryName, isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func legacyConfigurationURLs() -> [URL] {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppIdentity.legacyConfigurationDirectoryNames.map {
            applicationSupport.appendingPathComponent($0, isDirectory: true).appendingPathComponent("config.json")
        }
    }

    private static func bootSessionIdentifier() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return "uptime-\(Int(ProcessInfo.processInfo.systemUptime))"
        }
        return "boot-\(bootTime.tv_sec)"
    }

    private static func defaultQuitterConfigurationURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/com.marcoarment.quitter.plist")
    }

    private func minutes(fromQuitterInterval value: Any?) -> Int? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return max(1, Int((seconds / 60).rounded()))
    }

    private func appName(forBundlePath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private enum ImportError: LocalizedError {
        case invalidFormat
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String { AppText.value(key, language: language, arguments: arguments) }
    var timeString: String { lastChecked.formatted(.dateTime.hour().minute().locale(language.locale)) }
}

enum MainSection { case exit, launch, ble, inputSources, compression, capture, pictureInPicture, windowSwitcher, smoothScrolling, clipboard, rightClick, settings }

struct ContentView: View {
    @EnvironmentObject private var model: MacPilotModel
    @State private var showingAdd = false
    @State private var editingRule: QuitRule?
    @State private var showingLaunchAdd = false
    @State private var editingLaunchRule: LaunchRule?
    @State private var isDropTarget = false
    @State private var section: MainSection = .exit

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if section == .exit {
                    header
                    if model.rules.isEmpty { EmptyRulesView(addRule: { showingAdd = true }) }
                    else { rulesList }
                } else if section == .launch {
                    LaunchRulesView(showingAdd: $showingLaunchAdd, editingRule: $editingLaunchRule)
                } else if section == .ble {
                    BLEUnlockView(ble: model.ble)
                } else if section == .inputSources {
                    InputSourcesView(inputSources: model.inputSources)
                } else if section == .compression {
                    FileCompressionView(compression: model.fileCompression)
                } else if section == .capture {
                    ScreenCaptureView(
                        capture: model.screenCapture,
                        recording: model.screenRecording,
                        openShortcutEditor: Binding(
                            get: { model.requestedCaptureShortcutEditor },
                            set: { model.requestedCaptureShortcutEditor = $0 }
                        )
                    )
                } else if section == .pictureInPicture {
                    PictureInPictureView(pictureInPicture: model.pictureInPicture)
                } else if section == .windowSwitcher {
                    WindowSwitcherSettingsView(windowSwitcher: model.windowSwitcher)
                } else if section == .smoothScrolling {
                    SmoothScrollSettingsView(smoothScrolling: model.smoothScrolling)
                } else if section == .clipboard {
                    ClipboardSettingsView(clipboard: model.clipboard)
                } else if section == .rightClick {
                    RightClickMenuSettingsView()
                } else {
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $showingAdd) { RuleEditor(rule: nil).environmentObject(model) }
        .sheet(item: $editingRule) { rule in RuleEditor(rule: rule).environmentObject(model) }
        .sheet(isPresented: $showingLaunchAdd) { LaunchRuleEditor(rule: nil).environmentObject(model) }
        .sheet(item: $editingLaunchRule) { rule in LaunchRuleEditor(rule: rule).environmentObject(model) }
        .alert("MacPilot", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.dismissAlert() } })) {
            if model.alertOffersAccessibilityReset {
                Button(model.isResettingAccessibility ? model.t("resettingAccessibility") : model.t("resetAccessibility"), role: .destructive) {
                    Task {
                        if await model.resetAccessibility() == nil {
                            model.terminateAfterSheetsClose()
                        }
                    }
                }
                .disabled(model.isResettingAccessibility)
            }
            if model.alertOffersAccessibilitySettings {
                Button(model.t("openAccessibilitySettings")) {
                    model.openAccessibilitySettings()
                    model.dismissAlert()
                }
            }
            Button("OK", role: .cancel) { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: acceptDrop)
        .onChange(of: model.requestedSection) { _, newValue in
            if let s = newValue { section = s; model.requestedSection = nil }
        }
        .onAppear { if let s = model.requestedSection { section = s } }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .overlay(Text(model.t("dropApp")).font(.headline).padding(16).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t("rules")).font(.system(size: 30, weight: .bold))
                Text(model.t("rulesSubtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingAdd = true } label: { Label(model.t("addApp"), systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 28)
    }

    private var rulesList: some View {
        List {
            Section(model.t("apps")) {
                ForEach(model.rules) { rule in
                    RuleRow(
                        rule: rule,
                        edit: { editingRule = rule },
                        toggle: { model.toggleRule(rule) },
                        remove: { model.remove(rule) }
                    )
                        .contextMenu {
                            Button(model.t("editRule")) { editingRule = rule }
                            Divider()
                            Button(model.t("deleteRule"), role: .destructive) { model.remove(rule) }
                        }
                }
                .onMove(perform: model.move)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            guard let url else { return }
            Task { @MainActor in addApp(at: url) }
        }
        return true
    }

    private func addApp(at url: URL) {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            model.showAlert(model.t("invalidDrop"))
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        model.addRule(QuitRule(appName: name, bundleIdentifier: identifier, bundlePath: url.path, inactiveQuitMinutes: 10))
    }
}

/// 侧边栏 Label 样式：图标固定宽度，保证文字起点一致。
private struct SidebarLabelStyle: LabelStyle {
    var iconWidth: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: iconWidth)
            configuration.title
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: MacPilotModel
    @Binding var section: MainSection
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.title2.bold()).foregroundStyle(.blue)
                Text("MacPilot").font(.headline)
            }
            .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 34)
            Button { section = .exit } label: {
                Label(model.t("rules"), systemImage: "list.bullet.rectangle")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .exit ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .launch } label: {
                Label(model.t("launch"), systemImage: "play.circle")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .launch ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .ble } label: {
                Label(model.t("bleUnlock"), systemImage: "antenna.radiowaves.left.and.right")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .ble ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .inputSources } label: {
                Label(model.t("inputSources"), systemImage: "keyboard")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .inputSources ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .compression } label: {
                Label(model.t("fileCompression"), systemImage: "archivebox")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .compression ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .capture } label: {
                Label(model.t("screenCapture"), systemImage: "camera.viewfinder")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .capture ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .pictureInPicture } label: {
                Label(model.t("pictureInPicture"), systemImage: "pip.enter")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .pictureInPicture ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .windowSwitcher } label: {
                Label(model.t("windowSwitcher"), systemImage: "rectangle.on.rectangle")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .windowSwitcher ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .smoothScrolling } label: {
                Label(model.t("smoothScrolling"), systemImage: "scroll")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .smoothScrolling ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .clipboard } label: {
                Label(model.t("clipboard"), systemImage: "clipboard")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .clipboard ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .rightClick } label: {
                Label(model.t("rightClickMenu"), systemImage: "contextualmenu.and.cursorarrow")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .rightClick ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .settings } label: {
                Label(model.t("settings"), systemImage: "gearshape")
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .settings ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Circle().fill(model.isEnforcing ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.isEnforcing ? model.t("enforcing") : model.t("paused")).font(.subheadline.weight(.medium))
                    Spacer()
                    Toggle("", isOn: $model.isEnforcing).labelsHidden().controlSize(.mini)
                }
                Text(model.t("enabledChecked", model.enabledCount, model.timeString))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(15).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).padding(16)
        }
        .frame(width: 230).background(Color(nsColor: .controlBackgroundColor))
    }
}

struct EmptyRulesView: View {
    @EnvironmentObject private var model: MacPilotModel
    let addRule: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz").font(.system(size: 46)).foregroundStyle(.blue)
            Text(model.t("noApps")).font(.title2.bold())
            Text(model.t("noAppsDetail")).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(model.t("addFirstApp"), action: addRule).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 70)
    }
}

struct RuleRow: View {
    @EnvironmentObject private var model: MacPilotModel
    @State private var showingRemoveConfirmation = false
    let rule: QuitRule
    let edit: () -> Void
    let toggle: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(path: rule.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.appName).font(.body.weight(.semibold))
                Text(ruleSummary(rule)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let deadline = model.quitDeadlines[rule.id] {
                QuitCountdownBadge(deadline: deadline)
            }
            Button(model.t("edit"), action: edit).buttonStyle(.borderless)
            Button { showingRemoveConfirmation = true } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(model.t("remove"))
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in toggle() })).labelsHidden()
        }
        .padding(.vertical, 5)
        .alert(model.t("removeConfirmTitle"), isPresented: $showingRemoveConfirmation) {
            Button(model.t("remove"), role: .destructive, action: remove)
            Button(model.t("cancel"), role: .cancel) {}
        } message: {
            Text(model.t("removeConfirmMessage", rule.appName))
        }
    }

    private func ruleSummary(_ rule: QuitRule) -> String {
        var items: [String] = []
        if let m = rule.inactiveHideMinutes { items.append(model.t("hideAfter", m)) }
        if let m = rule.inactiveCloseMinutes { items.append(model.t("closeAfter", m)) }
        if let m = rule.inactiveQuitMinutes { items.append(model.t("quitAfter", m)) }
        if let m = rule.hiddenQuitMinutes { items.append(model.t("quitHidden", m)) }
        return items.joined(separator: " • ")
    }
}

struct QuitCountdownBadge: View {
    @EnvironmentObject private var model: MacPilotModel
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date) / 60)))
            Text(model.t("quitsIn", remaining))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.orange.opacity(0.12), in: Capsule())
        }
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct AppIcon: View {
    var path: String?
    var body: some View {
        Group {
            if let path {
                Image(nsImage: AppIconCache.shared.icon(for: path)).resizable().interpolation(.high)
            } else { Image(systemName: "app.fill").resizable().scaledToFit().padding(9).foregroundStyle(.blue) }
        }
        .frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct AccessibilityRecoveryView: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @State private var resetFailureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.t("accessibilityRecoveryHint"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            HStack {
                Button(model.t("openAccessibilitySettings")) {
                    model.openAccessibilitySettings()
                }
                Button(model.isResettingAccessibility ? model.t("resettingAccessibility") : model.t("resetAccessibility"), role: .destructive) {
                    Task {
                        resetFailureMessage = await model.resetAccessibility(presentFailureAlert: false)
                        guard resetFailureMessage == nil else { return }
                        dismiss()
                        model.terminateAfterSheetsClose()
                    }
                }
                .disabled(model.isResettingAccessibility)
            }
            if let resetFailureMessage {
                Text(resetFailureMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.35)))
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    private let original: QuitRule?
    @State private var appName = ""
    @State private var bundleIdentifier = ""
    @State private var bundlePath: String?
    @State private var hideEnabled = false
    @State private var hideMinutes = 10
    @State private var closeEnabled = false
    @State private var closeMinutes = 10
    @State private var inactiveQuitEnabled = true
    @State private var inactiveQuitMinutes = 10
    @State private var hiddenQuitEnabled = false
    @State private var hiddenQuitMinutes = 10
    @State private var runningApps: [NSRunningApplication] = []
    @State private var needsAccessibilityRecovery = false

    init(rule: QuitRule?) {
        original = rule
        _appName = State(initialValue: rule?.appName ?? "")
        _bundleIdentifier = State(initialValue: rule?.bundleIdentifier ?? "")
        _bundlePath = State(initialValue: rule?.bundlePath)
        _hideEnabled = State(initialValue: rule?.inactiveHideMinutes != nil)
        _hideMinutes = State(initialValue: rule?.inactiveHideMinutes ?? 10)
        _closeEnabled = State(initialValue: rule?.inactiveCloseMinutes != nil)
        _closeMinutes = State(initialValue: rule?.inactiveCloseMinutes ?? 10)
        _inactiveQuitEnabled = State(initialValue: rule?.inactiveQuitMinutes != nil || rule == nil)
        _inactiveQuitMinutes = State(initialValue: rule?.inactiveQuitMinutes ?? 10)
        _hiddenQuitEnabled = State(initialValue: rule?.hiddenQuitMinutes != nil)
        _hiddenQuitMinutes = State(initialValue: rule?.hiddenQuitMinutes ?? 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? model.t("addRule") : model.t("editAppRule")).font(.title2.bold())
            Text(model.t("ruleDetail")).foregroundStyle(.secondary)
            appPicker
            Divider()
            ActionSetting(title: model.t("hideInactive"), enabled: $hideEnabled, minutes: $hideMinutes)
            ActionSetting(title: model.t("closeInactive"), enabled: $closeEnabled, minutes: $closeMinutes)
            Text(model.t("closeWindowHint")).font(.caption).foregroundStyle(.secondary)
            if closeEnabled && needsAccessibilityRecovery {
                AccessibilityRecoveryView()
            }
            ActionSetting(title: model.t("quitInactive"), enabled: $inactiveQuitEnabled, minutes: $inactiveQuitMinutes)
            ActionSetting(title: model.t("quitAfterHidden"), enabled: $hiddenQuitEnabled, minutes: $hiddenQuitMinutes)
            Spacer()
            HStack { Spacer(); Button(model.t("cancel")) { dismiss() }; Button(original == nil ? model.t("addApp") : model.t("save")) { save() }.buttonStyle(.borderedProminent).disabled(bundleIdentifier.isEmpty || !(hideEnabled || closeEnabled || inactiveQuitEnabled || hiddenQuitEnabled)) }
        }
        .padding(28).frame(width: 520, height: needsAccessibilityRecovery ? 700 : 625)
        .onAppear {
            runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            needsAccessibilityRecovery = closeEnabled && !model.hasWindowControlAccess()
        }
        .onChange(of: closeEnabled) { _, enabled in
            needsAccessibilityRecovery = enabled && !model.requestWindowControlAccess(presentRecoveryGuidance: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if closeEnabled { needsAccessibilityRecovery = !model.hasWindowControlAccess() }
        }
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("application")).font(.headline)
            HStack(spacing: 12) {
                AppIcon(path: bundlePath)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appName.isEmpty ? model.t("chooseApp") : appName).font(.body.weight(.medium)).lineLimit(1)
                    Text(bundleIdentifier.isEmpty ? model.t("selectedApp") : bundleIdentifier)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Menu {
                    if runningApps.isEmpty {
                        Text(model.t("noRunningApps"))
                    } else {
                        Section(model.t("runningApps")) {
                            ForEach(runningApps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
                                    selectRunningApp(app.bundleIdentifier ?? "")
                                }
                            }
                        }
                    }
                    Divider()
                    Button(model.t("browseApplications"), action: browseForApp)
                } label: {
                    Label(appName.isEmpty ? model.t("chooseApp") : model.t("changeApp"), systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
    }

    private func selectRunningApp(_ identifier: String) {
        guard let app = runningApps.first(where: { $0.bundleIdentifier == identifier }) else { return }
        appName = app.localizedName ?? identifier
        bundleIdentifier = identifier
        bundlePath = app.bundleURL?.path
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = model.t("chooseApp")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        bundleIdentifier = identifier
        bundlePath = url.path
    }

    private func save() {
        let rule = QuitRule(
            id: original?.id ?? UUID(), appName: appName, bundleIdentifier: bundleIdentifier, bundlePath: bundlePath,
            inactiveHideMinutes: hideEnabled ? hideMinutes : nil,
            inactiveCloseMinutes: closeEnabled ? closeMinutes : nil,
            inactiveQuitMinutes: inactiveQuitEnabled ? inactiveQuitMinutes : nil,
            hiddenQuitMinutes: hiddenQuitEnabled ? hiddenQuitMinutes : nil,
            isEnabled: original?.isEnabled ?? true
        )
        if original == nil {
            if model.addRule(rule) { dismiss() }
        } else {
            model.updateRule(rule)
            dismiss()
        }
    }
}

struct LaunchRulesView: View {
    @EnvironmentObject private var model: MacPilotModel
    @Binding var showingAdd: Bool
    @Binding var editingRule: LaunchRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("launch")).font(.system(size: 30, weight: .bold))
                    Text(model.t("launchSubtitle")).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingAdd = true } label: { Label(model.t("addLaunchApp"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 22)

            launchControls

            if model.launchRules.isEmpty {
                EmptyLaunchRulesView(addRule: { showingAdd = true })
            } else {
                List {
                    Section(model.t("launchApps")) {
                        ForEach(model.launchRules) { rule in
                            LaunchRuleRow(
                                rule: rule,
                                edit: { editingRule = rule },
                                toggle: { model.toggleLaunchRule(rule) },
                                remove: { model.removeLaunchRule(rule) }
                            )
                                .contextMenu {
                                    Button(model.t("edit")) { editingRule = rule }
                                    Divider()
                                    Button(model.t("deleteRule"), role: .destructive) { model.removeLaunchRule(rule) }
                                }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
        }
    }

    private var launchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(model.t("launchEnabled"), isOn: $model.isLaunchSchedulingEnabled).toggleStyle(.switch)
                Spacer()
                Button(model.t("cancelLaunches")) { model.cancelScheduledLaunches() }
                    .disabled(model.pendingLaunchCount == 0)
                Button(model.t("runNow")) { model.runLaunchPlanNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isLaunchSchedulingEnabled || model.enabledLaunchCount == 0)
            }
            Text(model.launchesAtLogin ? launchPlanMessage : model.t("loginRequired"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        )
        .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
        .padding(.horizontal, 36).padding(.bottom, 16)
    }

    private var launchPlanMessage: String {
        if model.pendingLaunchCount > 0 { return model.t("launchPlanRunning", model.pendingLaunchCount) }
        if model.launchRules.isEmpty { return model.t("launchPlanIdle") }
        return model.t("launchPlanDone")
    }
}

struct EmptyLaunchRulesView: View {
    @EnvironmentObject private var model: MacPilotModel
    let addRule: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle").font(.system(size: 46)).foregroundStyle(.blue)
            Text(model.t("noLaunchApps")).font(.title2.bold())
            Text(model.t("noLaunchAppsDetail")).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(model.t("addFirstLaunchApp"), action: addRule).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 70)
    }
}

struct LaunchRuleRow: View {
    @EnvironmentObject private var model: MacPilotModel
    @State private var showingRemoveConfirmation = false
    let rule: LaunchRule
    let edit: () -> Void
    let toggle: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(path: rule.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.appName).font(.body.weight(.semibold))
                Text(model.t("launchAfter", rule.delaySeconds) + " • " + model.t(rule.visibilityMode.titleKey))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let state = model.launchStates[rule.id] {
                LaunchStatusBadge(state: state)
            }
            Button(model.t("edit"), action: edit).buttonStyle(.borderless)
            Button { showingRemoveConfirmation = true } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(model.t("remove"))
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in toggle() })).labelsHidden()
        }
        .padding(.vertical, 5)
        .alert(model.t("removeConfirmTitle"), isPresented: $showingRemoveConfirmation) {
            Button(model.t("remove"), role: .destructive, action: remove)
            Button(model.t("cancel"), role: .cancel) {}
        } message: {
            Text(model.t("removeConfirmMessage", rule.appName))
        }
    }

}

struct LaunchStatusBadge: View {
    @EnvironmentObject private var model: MacPilotModel
    let state: LaunchRuntimeState

    @ViewBuilder
    var body: some View {
        switch state {
        case .pending(let deadline):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                badge(model.t("launchIn", max(0, Int(ceil(deadline.timeIntervalSince(context.date))))), color: .blue)
            }
        case .launching:
            badge(model.t("launching"), color: .orange)
        case .launched:
            badge(model.t("launched"), color: .green)
        case .skippedAlreadyRunning:
            badge(model.t("alreadyRunning"), color: .secondary)
        case .cancelled:
            badge(model.t("launchCancelled"), color: .secondary)
        case .failed(let message):
            badge(model.t("launchFailed", message), color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct LaunchRuleEditor: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    private let original: LaunchRule?
    @State private var appName = ""
    @State private var bundleIdentifier = ""
    @State private var bundlePath = ""
    @State private var delaySeconds = 30
    @State private var visibilityMode: LaunchVisibilityMode = .hidden
    @State private var runningApps: [NSRunningApplication] = []
    @State private var needsAccessibilityRecovery = false

    init(rule: LaunchRule?) {
        original = rule
        _appName = State(initialValue: rule?.appName ?? "")
        _bundleIdentifier = State(initialValue: rule?.bundleIdentifier ?? "")
        _bundlePath = State(initialValue: rule?.bundlePath ?? "")
        _delaySeconds = State(initialValue: rule?.delaySeconds ?? 30)
        _visibilityMode = State(initialValue: rule?.visibilityMode ?? .hidden)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? model.t("addLaunchRule") : model.t("editLaunchRule")).font(.title2.bold())
            Text(model.t("launchRuleDetail")).foregroundStyle(.secondary)
            appPicker
            Divider()
            HStack {
                Text(model.t("delaySeconds"))
                Spacer()
                TextField(model.t("seconds"), value: $delaySeconds, format: .number)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 68)
                Stepper("", value: $delaySeconds, in: 0...86_400).labelsHidden()
                Text(model.t("seconds")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("launchVisibility")).font(.headline)
                Picker(model.t("launchVisibility"), selection: $visibilityMode) {
                    ForEach(LaunchVisibilityMode.allCases) { mode in
                        Text(model.t(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            Text(model.t(visibilityMode.hintKey))
                .font(.caption)
                .foregroundStyle(.secondary)
            if visibilityMode.requiresAccessibility && needsAccessibilityRecovery {
                AccessibilityRecoveryView()
            }
            Spacer()
            HStack {
                Spacer()
                Button(model.t("cancel")) { dismiss() }
                Button(original == nil ? model.t("addLaunchApp") : model.t("save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(bundleIdentifier.isEmpty || bundlePath.isEmpty)
            }
        }
        .padding(28).frame(width: 560, height: needsAccessibilityRecovery ? 590 : 500)
        .onAppear {
            refreshRunningApps()
            needsAccessibilityRecovery = visibilityMode.requiresAccessibility && !model.hasWindowControlAccess()
        }
        .onChange(of: delaySeconds) { _, value in delaySeconds = min(max(value, 0), 86_400) }
        .onChange(of: visibilityMode) { _, mode in
            needsAccessibilityRecovery = mode.requiresAccessibility && !model.requestWindowControlAccess(presentRecoveryGuidance: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if visibilityMode.requiresAccessibility { needsAccessibilityRecovery = !model.hasWindowControlAccess() }
        }
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("application")).font(.headline)
            HStack(spacing: 12) {
                AppIcon(path: bundlePath.isEmpty ? nil : bundlePath).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appName.isEmpty ? model.t("chooseApp") : appName).font(.body.weight(.medium)).lineLimit(1)
                    Text(bundleIdentifier.isEmpty ? model.t("selectedApp") : bundleIdentifier)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Menu {
                    if runningApps.isEmpty {
                        Text(model.t("noRunningApps"))
                    } else {
                        Section(model.t("runningApps")) {
                            ForEach(runningApps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
                                    selectRunningApp(app)
                                }
                            }
                        }
                    }
                    Divider()
                    Button(model.t("browseApplications"), action: browseForApp)
                } label: {
                    Label(appName.isEmpty ? model.t("chooseApp") : model.t("changeApp"), systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
    }

    private func refreshRunningApps() {
        var seenIdentifiers = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      let identifier = app.bundleIdentifier,
                      identifier != Bundle.main.bundleIdentifier,
                      app.bundleURL != nil else { return false }
                return seenIdentifiers.insert(identifier).inserted
            }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func selectRunningApp(_ app: NSRunningApplication) {
        guard let identifier = app.bundleIdentifier, let url = app.bundleURL else { return }
        appName = app.localizedName ?? identifier
        bundleIdentifier = identifier
        bundlePath = url.path
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = model.t("chooseApp")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        bundleIdentifier = identifier
        bundlePath = url.path
    }

    private func save() {
        let rule = LaunchRule(
            id: original?.id ?? UUID(),
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            delaySeconds: delaySeconds,
            isEnabled: original?.isEnabled ?? true,
            visibilityMode: visibilityMode
        )
        if original == nil {
            if model.addLaunchRule(rule) { dismiss() }
        } else {
            model.updateLaunchRule(rule)
            dismiss()
        }
    }
}

struct ActionSetting: View {
    @EnvironmentObject private var model: MacPilotModel
    let title: String
    @Binding var enabled: Bool
    @Binding var minutes: Int
    var body: some View {
        HStack(spacing: 12) {
            Toggle(title, isOn: $enabled).toggleStyle(.checkbox)
            Spacer()
            HStack(spacing: 6) {
                TextField(model.t("minutes"), value: $minutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: $minutes, in: 1...720).labelsHidden()
                Text(minutes == 1 ? model.t("minute") : model.t("minutes"))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            }
            .disabled(!enabled)
        }
        .onChange(of: minutes) { _, newValue in minutes = min(max(newValue, 1), 720) }
    }
}

private enum DeviceSortMode { case added, name, signal }

struct BLEUnlockView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var ble: BLEUnlockModel
    @State private var showPicker = false
    @State private var showingPassword = false
    @State private var passwordEntry = ""
    @State private var showingMinRSSI = false
    @State private var minRSSIEntry = ""
    @State private var passwordMessage: String?
    @State private var resetFailureMessage: String?
    @State private var sortMode: DeviceSortMode = .added

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                enableSection
                if ble.settings.isEnabled {
                    deviceSection
                    thresholdSection
                    optionsSection
                    actionsSection
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingPassword) { passwordSheet }
        .sheet(isPresented: $showingMinRSSI) { minRSSISheet }
        .alert("MacPilot", isPresented: Binding(get: { passwordMessage != nil }, set: { if !$0 { passwordMessage = nil } })) {
            Button("OK", role: .cancel) { passwordMessage = nil }
        } message: { Text(passwordMessage ?? "") }
        .onDisappear { if showPicker { showPicker = false; ble.stopScanning() } }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t("bleUnlock")).font(.system(size: 30, weight: .bold))
                Text(model.t("bleUnlockSubtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            signalGauge
        }
    }

    private var signalGauge: some View {
        let rssi = ble.lastRSSI ?? -100
        let progress = max(0, min(1, Double(rssi + 100) / 70))
        let color: Color = rssi >= -60 ? .green : (rssi >= -80 ? .yellow : .red)
        return ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10)
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(ble.lastRSSI.map { model.t("bleRSSIDBm", $0) } ?? "—").font(.system(.title3, design: .rounded).bold())
                Text(proximityLabel).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 88)
    }

    private var proximityLabel: String {
        if !ble.bluetoothPoweredOn { return model.t("bleBluetoothOff") }
        if ble.lastRSSI == nil { return model.t("bleLost") }
        return ble.presence ? model.t("bleNear") : model.t("bleAway")
    }

    private var enableSection: some View {
        SettingsCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("bleEnable")).font(.headline)
                    statusLine
                }
                Spacer()
                Toggle("", isOn: Binding(get: { ble.settings.isEnabled }, set: { enabled in
                    if enabled { model.requestWindowControlAccess(presentRecoveryGuidance: false) }
                    ble.setEnabled(enabled)
                })).labelsHidden().toggleStyle(.switch).controlSize(.large)
            }
            if ble.settings.isEnabled, !model.hasWindowControlAccess() {
                accessibilityHint
            }
        }
    }

    @ViewBuilder private var accessibilityHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.t("bleAccessRequired", Bundle.main.bundleURL.path), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
            HStack {
                Button(model.t("openAccessibilitySettings")) { model.openAccessibilitySettings() }
                Button(model.isResettingAccessibility ? model.t("resettingAccessibility") : model.t("resetAccessibility"), role: .destructive) {
                    Task {
                        resetFailureMessage = await model.resetAccessibility(presentFailureAlert: false)
                        guard resetFailureMessage == nil else { return }
                        model.terminateAfterSheetsClose()
                    }
                }
                .disabled(model.isResettingAccessibility)
            }
            if let resetFailureMessage {
                Text(resetFailureMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.35)))
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if !ble.bluetoothPoweredOn { return .orange }
        if ble.lastRSSI == nil { return .secondary }
        return ble.presence ? .green : .red
    }

    private var statusText: String {
        if !ble.bluetoothPoweredOn { return model.t("bleBluetoothOff") }
        if ble.lastRSSI == nil { return ble.settings.monitoredDeviceUUID == nil ? model.t("bleNoDevice") : model.t("bleDeviceNotDetected") }
        return ble.presence ? model.t("bleNear") : model.t("bleAway")
    }

    private var deviceSection: some View {
        SettingsCard {
            sectionTitle(model.t("bleDevice"))
            Text(model.t("bleDeviceHint")).font(.subheadline).foregroundStyle(.secondary)
            if let name = ble.settings.monitoredDeviceName, !name.isEmpty {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.blue.opacity(0.12)).frame(width: 42, height: 42)
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue).font(.title3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.body.weight(.medium))
                        if let uuid = ble.settings.monitoredDeviceUUID { Text(uuid).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(model.t("bleChangeDevice")) { showPicker = true; ble.startScanning() }
                }
            }
            if showPicker { deviceScanList }
            else if ble.settings.monitoredDeviceUUID == nil {
                Button { showPicker = true; ble.startScanning() } label: {
                    Label(model.t("bleSelectDevice"), systemImage: "viewfinder").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var deviceScanList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.t("bleScanning")).foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                Button(model.t("cancel")) { showPicker = false; ble.stopScanning() }
            }
            if !ble.devices.isEmpty {
                Picker(model.t("bleSortBy"), selection: $sortMode) {
                    Text(model.t("bleSortAdded")).tag(DeviceSortMode.added)
                    Text(model.t("bleSortName")).tag(DeviceSortMode.name)
                    Text(model.t("bleSortSignal")).tag(DeviceSortMode.signal)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if ble.devices.isEmpty {
                Text(model.t("bleNoDevicesFound")).foregroundStyle(.secondary).font(.subheadline)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(sortedDevices()) { device in deviceRow(device) }
                }
            }
        }
    }

    private func sortedDevices() -> [BLEUnlockDevice] {
        switch sortMode {
        case .added: return ble.devices
        case .name: return ble.devices.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .signal: return ble.devices.sorted { $0.rssi > $1.rssi }
        }
    }

    @ViewBuilder private func deviceRow(_ device: BLEUnlockDevice) -> some View {
        HStack(spacing: 12) {
            signalBars(device.rssi)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body).lineLimit(1)
                if let mac = device.prettifiedMAC { Text(mac).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text("\(device.rssi)dBm").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Button(model.t("bleSelectDevice")) { showPicker = false; ble.selectDevice(device.uuid) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func signalBars(_ rssi: Int) -> some View {
        let level = rssi >= -55 ? 4 : (rssi >= -65 ? 3 : (rssi >= -75 ? 2 : 1))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                Capsule().fill(index <= level ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(5 + index * 4))
            }
        }.frame(width: 24, height: 22)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private var thresholdSection: some View {
        SettingsCard {
            sectionTitle(model.t("bleThresholds"))
            rssiRangeBar
            rssiPickerRow(model.t("bleUnlockRSSI"), selection: Binding(get: { ble.settings.unlockRSSI }, set: { ble.setUnlockRSSI($0) }), options: [BLEUnlockModel.unlockDisabled] + BLEUnlockModel.rssiOptions, info: model.t("bleUnlockRSSIInfo"))
            rssiPickerRow(model.t("bleLockRSSI"), selection: Binding(get: { ble.settings.lockRSSI }, set: { ble.setLockRSSI($0) }), options: BLEUnlockModel.rssiOptions + [BLEUnlockModel.lockDisabled], info: model.t("bleLockRSSIInfo"))
        }
    }

    private var rssiRangeBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let position: (Int) -> CGFloat = { rssi in width * max(0, min(1, CGFloat(rssi + 100) / 70)) }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 12)
                if ble.settings.unlockRSSI != BLEUnlockModel.unlockDisabled {
                    Rectangle().fill(Color.green.opacity(0.5))
                        .frame(width: max(0, width - position(ble.settings.unlockRSSI)), height: 12)
                        .offset(x: position(ble.settings.unlockRSSI)).clipShape(Capsule())
                }
                if ble.settings.lockRSSI != BLEUnlockModel.lockDisabled {
                    Rectangle().fill(Color.red.opacity(0.5))
                        .frame(width: position(ble.settings.lockRSSI), height: 12).clipShape(Capsule())
                }
                if let rssi = ble.lastRSSI {
                    Rectangle().fill(Color.primary).frame(width: 2).offset(x: position(rssi) - 1)
                }
            }
        }.frame(height: 12)
    }

    private func rssiPickerRow(_ title: String, selection: Binding<Int>, options: [Int], info: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { value in
                        Text(value == BLEUnlockModel.unlockDisabled || value == BLEUnlockModel.lockDisabled ? model.t("bleDisabled") : "\(value)dBm").tag(value)
                    }
                }.labelsHidden().pickerStyle(.menu).frame(width: 140).controlSize(.small)
            }
            Text(info).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        SettingsCard {
            sectionTitle(model.t("bleTiming"))
            timingRow(model.t("bleLockDelay"), selection: Binding(get: { ble.settings.proximityTimeout }, set: { ble.setProximityTimeout($0) }), options: BLEUnlockModel.lockDelayOptions, info: model.t("bleLockDelayInfo"))
            timingRow(model.t("bleNoSignalTimeout"), selection: Binding(get: { ble.settings.signalTimeout }, set: { ble.setSignalTimeout($0) }), options: BLEUnlockModel.timeoutOptions, info: model.t("bleTimeoutInfo"))
        }
    }

    private func timingRow(_ title: String, selection: Binding<Int>, options: [Int], info: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { value in Text(durationLabel(value)).tag(value) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 140).controlSize(.small)
            }
            Text(info).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        SettingsCard {
            sectionTitle(model.t("bleBehavior"))
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(model.t("bleWakeOnProximity"), isOn: Binding(get: { ble.settings.wakeOnProximity }, set: { ble.setWakeOnProximity($0) }))
                toggleRow(model.t("bleWakeWithoutUnlocking"), isOn: Binding(get: { ble.settings.wakeWithoutUnlocking }, set: { ble.setWakeWithoutUnlocking($0) }))
                toggleRow(model.t("blePauseNowPlaying"), isOn: Binding(get: { ble.settings.pauseNowPlaying }, set: { ble.setPauseNowPlaying($0) }))
                toggleRow(model.t("bleUseScreensaver"), isOn: Binding(get: { ble.settings.useScreensaver }, set: { ble.setUseScreensaver($0) }))
                toggleRow(model.t("bleTurnOffScreen"), isOn: Binding(get: { ble.settings.turnOffScreen }, set: { ble.setTurnOffScreen($0) }))
                toggleRow(model.t("blePassiveMode"), isOn: Binding(get: { ble.settings.passiveMode }, set: { ble.setPassiveMode($0) }))
                Text(model.t("blePassiveModeInfo")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            sectionTitle(model.t("bleSecurity"))
            HStack(spacing: 12) {
                Label(ble.hasPassword ? model.t("blePasswordSet") : model.t("bleNoPassword"), systemImage: ble.hasPassword ? "checkmark.seal.fill" : "key.fill")
                    .font(.subheadline).foregroundStyle(ble.hasPassword ? .green : .secondary)
                Button(model.t("bleSetPassword")) { showingPassword = true; passwordEntry = "" }
                Button(model.t("bleMinRSSI")) { showingMinRSSI = true; minRSSIEntry = String(ble.settings.thresholdRSSI) }
                Spacer()
                Button(model.t("bleLockNow")) { ble.lockNow() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small)
    }

    private func durationLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) \(model.t("bleSeconds"))" : "\(seconds / 60) \(model.t(seconds / 60 == 1 ? "minute" : "minutes"))"
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("bleEnterPassword")).font(.headline)
            Text(model.t("blePasswordInfo")).font(.subheadline).foregroundStyle(.secondary)
            SecureField(model.t("bleEnterPassword"), text: $passwordEntry)
            HStack {
                Spacer()
                Button(model.t("cancel")) { showingPassword = false }.keyboardShortcut(.cancelAction)
                Button(model.t("save")) {
                    if ble.storePassword(passwordEntry) { passwordMessage = model.t("blePasswordStored") }
                    else { passwordMessage = model.t("blePasswordFailed", "Keychain") }
                    showingPassword = false
                }.keyboardShortcut(.defaultAction).disabled(passwordEntry.isEmpty)
            }
        }.padding(20).frame(width: 360)
    }

    private var minRSSISheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("bleMinRSSI")).font(.headline)
            TextField(model.t("bleMinRSSI"), text: $minRSSIEntry)
            HStack {
                Spacer()
                Button(model.t("cancel")) { showingMinRSSI = false }.keyboardShortcut(.cancelAction)
                Button(model.t("save")) {
                    if let value = Int(minRSSIEntry) { ble.setThresholdRSSI(value) }
                    showingMinRSSI = false
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var pictureInPicture: PictureInPictureModel
    @ObservedObject var inputSources: InputSourceModel
    @ObservedObject var windowSwitcher: WindowSwitcherModel
    @ObservedObject var smoothScrolling: SmoothScrollModel
    @ObservedObject var clipboard: ClipboardModel

    init(
        pictureInPicture: PictureInPictureModel,
        inputSources: InputSourceModel = InputSourceModel(),
        windowSwitcher: WindowSwitcherModel = WindowSwitcherModel(),
        smoothScrolling: SmoothScrollModel = SmoothScrollModel(),
        clipboard: ClipboardModel = ClipboardModel()
    ) {
        self._pictureInPicture = ObservedObject(wrappedValue: pictureInPicture)
        self._inputSources = ObservedObject(wrappedValue: inputSources)
        self._windowSwitcher = ObservedObject(wrappedValue: windowSwitcher)
        self._smoothScrolling = ObservedObject(wrappedValue: smoothScrolling)
        self._clipboard = ObservedObject(wrappedValue: clipboard)
    }

    var body: some View {
        Text(model.isEnforcing ? model.t("enabledStatus") : model.t("disabledStatus"))
        Divider()
        Button(model.isEnforcing ? model.t("disableApp") : model.t("enableApp")) { model.isEnforcing.toggle() }
        Button(model.t("checkNow")) { model.evaluateRules() }
        Divider()
        Button(model.t("runNow")) { model.runLaunchPlanNow() }
            .disabled(!model.isLaunchSchedulingEnabled || model.enabledLaunchCount == 0)
        Button(model.t("cancelLaunches")) { model.cancelScheduledLaunches() }
            .disabled(model.pendingLaunchCount == 0)
        Divider()
        Toggle(model.t("startAtLogin"), isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button(model.t("showApp"), action: showMainWindow)
        if model.ble.settings.isEnabled {
            Divider()
            Toggle(model.t("bleEnabledStatus"),
                   isOn: Binding(get: { model.ble.settings.isEnabled }, set: { model.ble.setEnabled($0) }))
            Button(model.t("bleLockNow")) { model.ble.lockNow() }
            if let name = model.ble.settings.monitoredDeviceName, !name.isEmpty {
                Button(name) { model.requestedSection = .ble; showMainWindow() }
            } else {
                Button(model.t("bleSelectDevice")) { model.requestedSection = .ble; showMainWindow() }
            }
        }
        if inputSources.settings.isEnabled {
            Divider()
            Toggle(model.t("inputSourcesEnabledStatus"),
                   isOn: Binding(get: { inputSources.settings.isEnabled }, set: { inputSources.setEnabled($0) }))
            Button(model.t("inputSourcesCycleNow")) { inputSources.cycleInputSource() }
                .disabled(inputSources.availableSources.count < 2)
            Button(model.t("inputSources")) { model.requestedSection = .inputSources; showMainWindow() }
        }
        if windowSwitcher.settings.isEnabled {
            Divider()
            Toggle(model.t("windowSwitcherEnabledStatus"),
                   isOn: Binding(get: { windowSwitcher.settings.isEnabled }, set: { windowSwitcher.setEnabled($0) }))
            Button(model.t("windowSwitcherTestNow")) { windowSwitcher.showSwitcherNow() }
                .disabled(!windowSwitcher.hasAccessibilityPermission)
            Button(model.t("windowSwitcher")) { model.requestedSection = .windowSwitcher; showMainWindow() }
        }
        if smoothScrolling.settings.isEnabled {
            Divider()
            Toggle(model.t("smoothScrollingEnabledStatus"),
                   isOn: Binding(get: { smoothScrolling.settings.isEnabled }, set: { smoothScrolling.setEnabled($0) }))
            Button(model.t("smoothScrolling")) { model.requestedSection = .smoothScrolling; showMainWindow() }
        }
        if clipboard.settings.isEnabled {
            Divider()
            Toggle(model.t("clipboardEnabledStatus"),
                   isOn: Binding(get: { clipboard.settings.isEnabled }, set: { clipboard.setEnabled($0) }))
            Button(model.t("clipboardOpenNow")) {
                deferCaptureAction { clipboard.openPanel() }
            }
            Button(model.t("clipboard")) { model.requestedSection = .clipboard; showMainWindow() }
        }
        if model.screenCapture.settings.screenshotEnabled {
            Divider()
            Button(model.t("scSmartCaptureNow")) { deferCaptureAction { model.screenCapture.startSmartCapture() } }
            Divider()
        }
        UpdateMenuItems(updater: model.updater) {
            model.requestedSection = .settings
            showMainWindow()
        }
        Divider()
        Text(AppVersionInfo.current().localizedDescription(language: model.language))
        Button(model.t("quitApp")) { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        if let window = mainWindow {
            present(window)
            return
        }

        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = mainWindow { present(window) }
        }
    }

    /// NSMenu remains in its tracking loop while a menu item action runs. Let
    /// it close before creating the screen-level overlay, otherwise AppKit can
    /// immediately order the new panel out or keep the menu as the key window.
    private func deferCaptureAction(_ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "MacPilot" && $0.canBecomeMain }
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateMenuItems: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var updater: SoftwareUpdater
    let showSettings: () -> Void

    var body: some View {
        if let release = updater.state.availableRelease {
            Button(model.t("updateAvailable", release.version.description), action: showSettings)
        } else if let activity = updater.state.activity {
            Text(model.t(activity.rawValue))
        } else {
            Button(model.t("checkForUpdates")) {
                showSettings()
                Task { await updater.checkForUpdates() }
            }
        }
    }

}

struct SettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @State private var quitterImportPreview: QuitterImportPreview?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("settings")).font(.system(size: 30, weight: .bold))
                    Text(model.t("manageRules")).foregroundStyle(.secondary)
                    Text(AppVersionInfo.current().localizedDescription(language: model.language))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                SettingsCard {
                    Toggle(model.t("startAtLogin"), isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    Text(model.t("startAtLoginHint")).font(.subheadline).foregroundStyle(.secondary)
                }
                SettingsCard {
                    SoftwareUpdateSettingsView(updater: model.updater, language: model.language)
                }
                SettingsCard {
                    Text(model.t("language")).font(.headline)
                    Text(model.t("languageDescription")).font(.subheadline).foregroundStyle(.secondary)
                    Picker(model.t("language"), selection: $model.language) {
                        Text(model.t("systemLanguage")).tag(AppLanguage.system)
                        Text(model.t("english")).tag(AppLanguage.english)
                        Text(model.t("simplifiedChinese")).tag(AppLanguage.simplifiedChinese)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 390)
                }
                SettingsCard {
                    Text(model.t("configFile")).font(.headline)
                    Text(model.t("configDescription")).font(.subheadline).foregroundStyle(.secondary)
                    Text(model.configurationFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(model.t("revealInFinder")) { model.revealConfigurationFile() }
                }
                SettingsCard {
                    Text(model.t("importQuitter")).font(.headline)
                    Text(model.t("importQuitterDescription")).font(.subheadline).foregroundStyle(.secondary)
                    Button(model.t("importQuitter")) { quitterImportPreview = model.prepareQuitterImportFromDefaultLocation() }
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .alert(model.t("importQuitterConfirmTitle"), isPresented: Binding(get: { quitterImportPreview != nil }, set: { if !$0 { quitterImportPreview = nil } })) {
            Button(model.t("cancel"), role: .cancel) { quitterImportPreview = nil }
            Button(model.t("import")) {
                if let preview = quitterImportPreview { model.importQuitterConfiguration(preview) }
                quitterImportPreview = nil
            }
        } message: {
            if let preview = quitterImportPreview {
                Text(model.t("importQuitterConfirmMessage", preview.rules.count, preview.skippedCount))
            }
        }
    }

}

private struct SoftwareUpdateSettingsView: View {
    @ObservedObject var updater: SoftwareUpdater
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("softwareUpdate")).font(.headline)
            Text(t("updateDescription")).font(.subheadline).foregroundStyle(.secondary)
            Text(t("currentVersion", updater.currentVersion)).font(.caption).foregroundStyle(.tertiary)

            switch updater.state {
            case .idle:
                checkButton
            case .checking:
                progress(t("checkingForUpdates"))
            case .upToDate:
                Label(t("upToDate"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                checkButton
            case .available(let release):
                Label(t("updateAvailable", release.version.description), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                if !release.releaseNotes.isEmpty {
                    Text(t("releaseNotes")).font(.subheadline.weight(.semibold))
                    Text(release.releaseNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(t("updateWillRestart")).font(.caption).foregroundStyle(.secondary)
                Button(t("downloadAndInstall")) {
                    Task { await updater.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
            case .downloading:
                progress(t("downloadingUpdate"))
            case .installing:
                progress(t("preparingUpdate"))
            case .failed(let failure):
                Label(t("updateFailed", localized(failure)), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button(t("checkForUpdates")) { Task { await updater.checkForUpdates() } }
            .disabled(updater.state.isBusy)
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(.secondary)
        }
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    private func localized(_ failure: SoftwareUpdateFailure) -> String {
        if let detail = failure.detail { return t(failure.message.rawValue, detail) }
        return t(failure.message.rawValue)
    }
}
