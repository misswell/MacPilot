import Foundation
import Testing

@testable import MacPilot

/// 持久化配置的键集契约（AGENTS.md「Configuration compatibility」不变量）。
///
/// 编码出的键必须永远是历史键集的**超集**：旧版本解码时要求它认识的键都
/// 在，新版本少写一个键，用户一降级，整份配置就会在旧版上解码失败并被
/// 默认值覆盖（v1.1.482-beta.5 事故：删除 `endCalculation` 键清空了全部
/// 配置）。这里在 CI 阶段拦住这类改动。
///
/// 规则：新增键时，把它加进对应的历史键集（只增不减）；废弃字段留在
/// 结构体里继续编码，UI/逻辑停用即可。新持久化类型请照样加一条契约测试。
@MainActor
struct ConfigurationSchemaContractTests {
    @Test func storedConfigurationEncodesEveryHistoricalKey() throws {
        let configuration = MacPilotModel.StoredConfiguration(
            enabledFeatures: [], rules: [], isEnforcing: true, language: .system,
            launchRules: [], isLaunchSchedulingEnabled: true, launchesAtLogin: false,
            lastScheduledBootSession: "scheduled-boot-session", automaticUpdateChecks: true,
            updateChannel: .stable, bleUnlock: BLEUnlockSettings(),
            fileCompression: FolderCompressionSettings(), screenCapture: ScreenCaptureSettings(),
            screenRecording: ScreenRecordingSettings(), pictureInPicture: PictureInPictureSettings(),
            inputSources: InputSourceSettings(), windowSwitcher: WindowSwitcherSettings(),
            smoothScrolling: SmoothScrollSettings(), clipboard: ClipboardSettings(),
            awake: .standard, awakeTriggers: [], awakeProfiles: [],
            remoteControl: RemoteControlSettings(), dockGroups: DockGroupsSettings(),
            quickSearch: QuickSearchSettings()
        )
        try assertEncodedKeys(
            of: configuration,
            supersetOf: [
                "version", "enabledFeatures", "rules", "isEnforcing", "language",
                "launchRules", "isLaunchSchedulingEnabled", "launchesAtLogin",
                "lastScheduledBootSession", "automaticUpdateChecks", "updateChannel",
                "bleUnlock", "fileCompression", "screenCapture", "screenRecording",
                "pictureInPicture", "inputSources", "windowSwitcher", "smoothScrolling",
                "clipboard", "awake", "awakeTriggers", "awakeProfiles", "remoteControl",
                "dockGroups", "quickSearch", "displayControl", "appPresence"
            ]
        )
    }

    @Test func appPresenceEncodesBothSwitchesAndRejectsHidingBoth() throws {
        try assertEncodedKeys(
            of: AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true),
            supersetOf: ["showsDockIcon", "showsMenuBarIcon"]
        )
        // A configuration that asks for neither icon must not strand the app.
        let decoded = try JSONDecoder().decode(
            AppPresenceSettings.self,
            from: Data(#"{"showsDockIcon":false,"showsMenuBarIcon":false}"#.utf8)
        )
        #expect(decoded.showsMenuBarIcon)
        // Missing keys keep the installation default: both icons shown.
        let legacy = try JSONDecoder().decode(AppPresenceSettings.self, from: Data("{}".utf8))
        #expect(legacy == .standard)
    }

    @Test func awakeSessionProfileConfigurationEncodesEveryHistoricalKey() throws {
        // endCalculation 已废弃为纯兼容负载，但必须继续编码（本测试存在的原因）。
        let configuration = AwakeSessionProfileConfiguration(
            durationMinutes: 60,
            endCalculation: .timer,
            endOnForcedSleep: false,
            preventDisplaySleep: false,
            allowSystemSleepWhenDisplayOff: false,
            preventClosedLidSleep: false,
            blockScreenSaver: false,
            screenSaverIdleMinutes: 45,
            lowBatteryProtectionEnabled: true,
            minimumBatteryLevel: 15,
            warnBeforeBatteryTermination: false,
            ignoreBatteryLevelOnExternalPower: true,
            restartOnPowerReconnect: false,
            untilDate: Date(timeIntervalSince1970: 1_000)
        )
        try assertEncodedKeys(
            of: configuration,
            supersetOf: [
                "durationMinutes", "endCalculation", "endOnForcedSleep",
                "preventDisplaySleep", "allowSystemSleepWhenDisplayOff",
                "preventClosedLidSleep", "blockScreenSaver", "screenSaverIdleMinutes",
                "lowBatteryProtectionEnabled", "minimumBatteryLevel",
                "warnBeforeBatteryTermination", "ignoreBatteryLevelOnExternalPower",
                "restartOnPowerReconnect", "autoStartOnLaunch", "autoStartOnWake", "untilDate"
            ]
        )
    }

    @Test func clipboardSettingsEncodeEveryHistoricalKeyIncludingTheSavedPosition() throws {
        let settings = ClipboardSettings(panelPosition: ClipboardPanelPosition(frame: .zero))
        try assertEncodedKeys(
            of: settings,
            supersetOf: [
                "isEnabled", "storageLimit", "pasteByDefault", "showSearch",
                "clearSystemClipboardOnClear", "pinsAtTop", "hotkey", "panelPosition"
            ]
        )
        try assertEncodedKeys(of: settings.panelPosition, supersetOf: ["x", "y"])
    }

    @Test func quickSearchSettingsEncodeEveryHistoricalKeyIncludingPositionSizeAndFavorites() throws {
        var settings = QuickSearchSettings()
        // 可选键在 nil 时不编码，显式赋值才能让它们进入键集（与 AwakeSettings 那条同理）。
        settings.panelPosition = QuickSearchPanelPosition(x: 120, y: 700)
        settings.panelSize = QuickSearchPanelSize(width: 760, height: 520)
        settings.favorites = [
            QuickSearchFavorite(
                identity: "bid:com.test.a", path: "/Applications/A.app", kind: .application,
                title: "A", subtitle: "/Applications", bundleIdentifier: "com.test.a"
            )
        ]
        try assertEncodedKeys(
            of: settings,
            supersetOf: [
                "isEnabled", "hotkey", "fileScope", "customDirectoryPaths",
                "panelPosition", "panelSize", "favorites", "matchScope"
            ]
        )
        try assertEncodedKeys(of: settings.panelPosition, supersetOf: ["x", "y"])
        try assertEncodedKeys(of: settings.panelSize, supersetOf: ["width", "height"])
        try assertEncodedKeys(
            of: settings.favorites.first,
            supersetOf: ["identity", "path", "kind", "title", "subtitle", "bundleIdentifier", "addedAt"]
        )
    }

    @Test func displayControlSettingsEncodesEveryHistoricalKey() throws {
        try assertEncodedKeys(of: DisplayControlSettings(), supersetOf: [
            "isEnabled", "uuPolicy", "targetUUID", "virtualWidth", "virtualHeight", "hiDPI"
        ])
    }

    @Test func sessionPolicyEncodesEveryHistoricalKey() throws {
        try assertEncodedKeys(
            of: SessionPolicy.standard,
            supersetOf: [
                "preventSystemSleep", "preventDisplaySleep", "preventClosedLidSleep",
                "screenSaverPolicy", "lockPolicy", "mouseMovementPolicy",
                "endCalculation", "endOnForcedSleep", "allowSystemSleepWhenDisplayOff",
                "blockScreenSaver", "screenSaverIdleMinutes"
            ]
        )
    }

    @Test func awakeSettingsEncodesEveryHistoricalKey() throws {
        var settings = AwakeSettings.standard
        // 可选键在默认值下不编码，这里显式赋值让它们出现在键集里。
        settings.defaultSession.untilDate = Date(timeIntervalSince1970: 1_000)
        settings.defaultSession.launchProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        try assertEncodedKeys(
            of: settings,
            supersetOf: [
                "isEnabled", "defaultPolicy", "defaultSession", "safetyPolicy"
            ]
        )
        try assertEncodedKeys(
            of: settings.defaultSession,
            supersetOf: [
                "durationMinutes", "usesUntilDate", "untilDate",
                "warnBeforeBatteryTermination", "ignoreBatteryLevelOnExternalPower",
                "restartOnPowerReconnect", "autoStartOnLaunch", "autoStartOnWake",
                "launchProfileEnabled", "launchProfileID"
            ]
        )
    }

    private func assertEncodedKeys(
        of value: some Encodable,
        supersetOf historicalKeys: Set<String>
    ) throws {
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let missing = historicalKeys.subtracting(object.keys)
        #expect(
            missing.isEmpty,
            "持久化键被删除：\(missing.sorted().joined(separator: ", "))。永远不要删除/改名编码键——就地废弃并继续编码（AGENTS.md「Configuration compatibility」）。"
        )
    }
}
