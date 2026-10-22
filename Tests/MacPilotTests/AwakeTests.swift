import Foundation
import Testing
@testable import MacPilot

@MainActor
struct AwakeTests {
    @Test func menuBarIconReflectsAwakeSessionState() {
        #expect(MenuBarIcon.systemImage(awakeActive: true, enforcing: false) == "sun.max.fill")
        #expect(MenuBarIcon.systemImage(awakeActive: false, enforcing: true) == "timer")
        #expect(MenuBarIcon.systemImage(awakeActive: false, enforcing: false) == "pause.circle")
    }

    @Test func standardPolicyAllowsDisplaySleepWhileBlockingSystemSleep() {
        #expect(SessionPolicy.standard.preventSystemSleep)
        #expect(!SessionPolicy.standard.preventDisplaySleep)
        #expect(!SessionPolicy.standard.preventClosedLidSleep)
    }

    @Test func screenOnQuickActionKeepsTheDisplayAwakeWithoutChangingTheDefaultPolicy() {
        let assertionController = TestAssertionController()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        // The saved default allows display sleep; the quick action must not.
        #expect(!manager.settings.defaultPolicy.preventDisplaySleep)

        let id = manager.startScreenOnSession(duration: 30 * 60)
        let session = manager.activeSessions.first { $0.id == id }

        #expect(session?.policy.preventDisplaySleep == true)
        #expect(session?.policy.preventSystemSleep == true)
        #expect(session?.endCondition == .duration(30 * 60))
        #expect(assertionController.lastState.preventDisplaySleep)
        #expect(assertionController.lastState.preventSystemSleep)
        #expect(!manager.settings.defaultPolicy.preventDisplaySleep)

        let unlimited = manager.startScreenOnSession(duration: nil)
        #expect(manager.activeSessions.first { $0.id == unlimited }?.endCondition == .manual)
    }

    @Test func sessionModelsRoundTripAllP0EndConditions() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let sessions = [
            AwakeSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                source: .manual,
                startedAt: startedAt,
                endCondition: .duration(60),
                policy: .standard,
                state: .active
            ),
            AwakeSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                source: .manual,
                startedAt: startedAt,
                endCondition: .date(startedAt.addingTimeInterval(3_600)),
                policy: SessionPolicy(preventDisplaySleep: true),
                state: .ended
            )
        ]

        let data = try JSONEncoder().encode(sessions)
        let decoded = try JSONDecoder().decode([AwakeSession].self, from: data)

        #expect(decoded == sessions)
        #expect(sessions[0].expectedEndAt == startedAt.addingTimeInterval(60))
        #expect(sessions[1].expectedEndAt == startedAt.addingTimeInterval(3_600))
    }

    @Test func multipleSessionsAggregatePoliciesAndReleaseOnlyAfterTheLastSessionEnds() {
        let assertionController = TestAssertionController()
        let powerProvider = TestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: powerProvider
        )
        defer { manager.shutdown() }

        let first = manager.startManualSession()
        let second = manager.startManualSession(endCondition: .date(Date().addingTimeInterval(3_600)))

        #expect(manager.activeSessionCount == 2)
        #expect(assertionController.lastState.preventSystemSleep)
        #expect(assertionController.lastState.preventDisplaySleep == false)

        manager.endSession(first)
        #expect(manager.activeSessionCount == 1)
        #expect(assertionController.lastState.preventSystemSleep)

        manager.endSession(second)
        #expect(manager.activeSessionCount == 0)
        #expect(assertionController.lastState == .inactive)
    }

    @Test func durationSessionEndsAfterTheExpectedEndDate() {
        var currentDate = Date(timeIntervalSince1970: 10_000)
        let assertionController = TestAssertionController()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: TestPowerStateProvider(),
            now: { currentDate }
        )
        defer { manager.shutdown() }

        let id = manager.startManualSession(duration: 60)
        #expect(manager.activeSessions.contains { $0.id == id })

        currentDate = currentDate.addingTimeInterval(61)
        manager.refreshDesiredState()

        #expect(manager.activeSessions.isEmpty)
        #expect(manager.sessions.first(where: { $0.id == id })?.state == .ended)
        #expect(assertionController.lastState == .inactive)
    }

    @Test func untilSessionEndsAfterItsAbsoluteEndDate() {
        var currentDate = Date(timeIntervalSince1970: 20_000)
        let assertionController = TestAssertionController()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: TestPowerStateProvider(),
            now: { currentDate }
        )
        defer { manager.shutdown() }

        let endDate = currentDate.addingTimeInterval(3_600)
        let id = manager.startManualSession(until: endDate)
        #expect(manager.sessions.first(where: { $0.id == id })?.expectedEndAt == endDate)

        currentDate = endDate.addingTimeInterval(1)
        manager.refreshDesiredState()

        #expect(manager.activeSessions.isEmpty)
        #expect(manager.sessions.first(where: { $0.id == id })?.state == .ended)
        #expect(assertionController.lastState == .inactive)
    }

    @Test func lowBatteryProtectionEndsAllActiveSessions() {
        let assertionController = TestAssertionController()
        let powerProvider = TestPowerStateProvider(
            state: PowerState(batteryLevel: 50, charging: false, onExternalPower: false)
        )
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: powerProvider
        )
        defer { manager.shutdown() }

        _ = manager.startManualSession()
        #expect(manager.isActive)

        powerProvider.state = PowerState(batteryLevel: 8, charging: false, onExternalPower: false)
        manager.refreshPowerState()

        #expect(!manager.isActive)
        #expect(manager.safetyProtectionActive)
        #expect(assertionController.lastState == .inactive)
    }

    @Test func batterySafetyPolicyClampsToTheDocumentedRange() {
        let low = AwakeSafetyPolicy(minimumBatteryLevel: 0)
        let high = AwakeSafetyPolicy(minimumBatteryLevel: 100)

        #expect(low.minimumBatteryLevel == 10)
        #expect(high.minimumBatteryLevel == 50)
    }

    @Test func appTextLocalizesAwakeP0Labels() {
        #expect(AppText.value("awake", language: .simplifiedChinese) == "保持唤醒")
        #expect(AppText.value("awake", language: .english) == "Awake")
        #expect(AppText.value("awakeDisplaySleepAllowed", language: .simplifiedChinese) == "允许显示器休眠")
        #expect(AppText.value("awakeDisplaySleepAllowed", language: .english) == "Allow display sleep")
        #expect(AppText.value("awakeDuration", language: .simplifiedChinese) == "亮屏时长")
        #expect(AppText.value("awakeDuration", language: .english) == "Screen-On Duration")
        #expect(AppText.value("awakeStopSession", language: .simplifiedChinese) == "停止此 Session")
        #expect(AppText.value("awakeStopSession", language: .english) == "Stop this session")
        #expect(AppText.value("awakeActiveSessions", language: .simplifiedChinese) == "活跃 Session")
        #expect(AppText.value("awakeActiveSessions", language: .english) == "Active sessions")
        #expect(AppText.value("awakeStopSessionMenuItem", language: .simplifiedChinese, 2, "手动", "10:20:30") == "停止第 2 个 Session：手动 · 开始时间 10:20:30")
        #expect(AppText.value("awakeStopSessionMenuItem", language: .english, 2, "Manual", "10:20:30") == "Stop session 2: Manual · Started 10:20:30")
        #expect(AppText.value("awakeSessionStopped", language: .simplifiedChinese) == "已手动停止")
        #expect(AppText.value("awakeSessionStopped", language: .english) == "Stopped manually")
    }

    @Test func settingsRoundTripPreservesBatteryProtectionAndDefaultPolicy() throws {
        let settings = AwakeSettings(
            defaultPolicy: SessionPolicy(preventDisplaySleep: true),
            safetyPolicy: AwakeSafetyPolicy(lowBatteryProtectionEnabled: false, minimumBatteryLevel: 22)
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AwakeSettings.self, from: data)

        #expect(decoded == settings)
    }

    @Test func defaultSessionSettingsDecodeWithBackwardCompatibleDefaults() throws {
        let decoded = try JSONDecoder().decode(AwakeDefaultSessionSettings.self, from: Data("{}".utf8))
        #expect(decoded == .standard)

        let settings = AwakeSettings(
            defaultSession: AwakeDefaultSessionSettings(durationMinutes: 0, autoStartOnLaunch: true, autoStartOnWake: true)
        )
        let roundTrip = try JSONDecoder().decode(AwakeSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }

    @Test func defaultSessionUsesConfiguredDurationOrRunsUntilManuallyEnded() {
        var currentDate = Date(timeIntervalSince1970: 30_000)
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider(),
            now: { currentDate }
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultSession.durationMinutes = 30
        manager.applyLoadedSettings(settings)

        let timedID = manager.startDefaultSession()
        #expect(manager.sessions.first(where: { $0.id == timedID })?.expectedEndAt == currentDate.addingTimeInterval(1_800))

        settings.defaultSession.durationMinutes = 0
        manager.applyLoadedSettings(settings)
        let unlimitedID = manager.startDefaultSession()
        #expect(manager.sessions.first(where: { $0.id == unlimitedID })?.expectedEndAt == nil)
    }

    @Test func defaultSessionHonorsUntilDatePreset() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        let endDate = Date().addingTimeInterval(600)
        var settings = manager.settings
        settings.defaultSession.usesUntilDate = true
        settings.defaultSession.untilDate = endDate
        manager.applyLoadedSettings(settings)

        let id = manager.startDefaultSession()
        #expect(manager.sessions.first(where: { $0.id == id })?.expectedEndAt == endDate)
    }

    @Test func expiredUntilDateFallsBackToManualEnd() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultSession.usesUntilDate = true
        settings.defaultSession.untilDate = Date().addingTimeInterval(-60)
        manager.applyLoadedSettings(settings)

        let id = manager.startDefaultSession()
        let session = manager.sessions.first(where: { $0.id == id })
        #expect(session?.endCondition == .manual)
        #expect(session?.expectedEndAt == nil)
    }

    @Test func launchAutoStartStartsOneDefaultSessionOnlyWhenEnabled() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        #expect(manager.startDefaultSessionOnLaunchIfEnabled() == nil)

        var settings = manager.settings
        settings.defaultSession.autoStartOnLaunch = true
        settings.defaultSession.durationMinutes = 45
        manager.applyLoadedSettings(settings)

        #expect(manager.startDefaultSessionOnLaunchIfEnabled() != nil)
        #expect(manager.activeSessionCount == 1)
        #expect(manager.startDefaultSessionOnLaunchIfEnabled() == nil)
        #expect(manager.activeSessionCount == 1)
    }

    @Test func wakeAutoStartsDefaultSessionOnlyWhenIdleAndEnabled() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultSession.autoStartOnWake = true
        settings.defaultSession.durationMinutes = 30
        manager.applyLoadedSettings(settings)

        manager.handleSystemWake()
        #expect(manager.activeSessionCount == 1)

        manager.handleSystemWake()
        #expect(manager.activeSessionCount == 1)

        settings.defaultSession.autoStartOnWake = false
        manager.endAllSessions()
        manager.applyLoadedSettings(settings)
        manager.handleSystemWake()
        #expect(manager.activeSessionCount == 0)
    }

    @Test func wakeExpiresStaleSessionsBeforeAutoStartingTheDefaultSession() {
        var currentDate = Date(timeIntervalSince1970: 40_000)
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider(),
            now: { currentDate }
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultSession.autoStartOnWake = true
        settings.defaultSession.durationMinutes = 60
        manager.applyLoadedSettings(settings)

        _ = manager.startManualSession(duration: 30 * 60)
        currentDate = currentDate.addingTimeInterval(31 * 60)
        manager.handleSystemWake()

        #expect(manager.activeSessionCount == 1)
        #expect(manager.activeSessions.first?.endCondition == .duration(60 * 60))
    }

    @Test func appTextLocalizesDefaultSessionLabels() {
        #expect(AppText.value("awakeDefaultSession", language: .simplifiedChinese) == "默认会话")
        #expect(AppText.value("awakeDefaultSession", language: .english) == "Default Session")
        #expect(AppText.value("awakeDefaultDuration", language: .simplifiedChinese) == "默认时长")
        #expect(AppText.value("awakeDefaultDuration", language: .english) == "Default duration")
        #expect(AppText.value("awakeAutoStartOnLaunch", language: .simplifiedChinese) == "启动 MacPilot 时自动开启")
        #expect(AppText.value("awakeAutoStartOnLaunch", language: .english) == "Start automatically when MacPilot launches")
        #expect(AppText.value("awakeAutoStartOnWake", language: .simplifiedChinese) == "从睡眠唤醒时自动开启")
        #expect(AppText.value("awakeAutoStartOnWake", language: .english) == "Start automatically when waking from sleep")
        #expect(AppText.value("awakeSessionConfig", language: .simplifiedChinese) == "Session 配置")
        #expect(AppText.value("awakeSessionConfig", language: .english) == "Session Setup")
        #expect(AppText.value("awakeSessionProtectionTitle", language: .simplifiedChinese) == "第 2 步：Session 保护")
        #expect(AppText.value("awakeSessionProtectionTitle", language: .english) == "Step 2: Session Protection")
        #expect(AppText.value("awakeSessionProtectionConfirm", language: .simplifiedChinese) == "确认并开始 Session")
        #expect(AppText.value("awakeSessionProtectionConfirm", language: .english) == "Confirm and Start Session")
        #expect(AppText.value("awakeAdvancedSettings", language: .simplifiedChinese) == "高级设置")
        #expect(AppText.value("awakeAdvancedSettings", language: .english) == "Advanced Settings")
        #expect(AppText.value("awakeForceSleep", language: .simplifiedChinese) == "强制睡眠")
        #expect(AppText.value("awakeForceSleep", language: .english) == "Forced Sleep")
        #expect(AppText.value("awakeEndSessionBelowBattery", language: .simplifiedChinese, 15) == "当电量低于 15% 时结束会话")
        #expect(AppText.value("awakeEndSessionBelowBattery", language: .english, 15) == "End the session below 15% battery")
        #expect(AppText.value("awakePowerAdapterSection", language: .simplifiedChinese) == "电源适配器")
        #expect(AppText.value("awakePowerAdapterSection", language: .english) == "Power Adapter")
    }

    @Test func sessionProtectionDraftStartsWithStandardDefaults() {
        var previousDraft = AwakeSessionProtectionDraft()
        previousDraft.endOnForcedSleep = true
        previousDraft.allowSystemSleepWhenDisplayOff = true
        previousDraft.blockScreenSaver = true
        previousDraft.screenSaverIdleMinutes = 90
        previousDraft.safetyPolicy.lowBatteryProtectionEnabled = false
        previousDraft.safetyPolicy.minimumBatteryLevel = 35
        previousDraft.warnBeforeBatteryTermination = true
        previousDraft.ignoreBatteryLevelOnExternalPower = false
        previousDraft.restartOnPowerReconnect = true
        previousDraft.autoStartOnLaunch = true
        previousDraft.autoStartOnWake = true

        let nextDraft = AwakeSessionProtectionDraft()
        #expect(!nextDraft.endOnForcedSleep)
        #expect(!nextDraft.allowSystemSleepWhenDisplayOff)
        #expect(!nextDraft.blockScreenSaver)
        #expect(nextDraft.screenSaverIdleMinutes == 45)
        #expect(nextDraft.safetyPolicy.lowBatteryProtectionEnabled)
        #expect(nextDraft.safetyPolicy.minimumBatteryLevel == 15)
        #expect(!nextDraft.warnBeforeBatteryTermination)
        #expect(nextDraft.ignoreBatteryLevelOnExternalPower)
        #expect(!nextDraft.restartOnPowerReconnect)
        #expect(!nextDraft.autoStartOnLaunch)
        #expect(!nextDraft.autoStartOnWake)
    }

    @Test func timedDefaultSessionsKeepCountingThroughSystemSleep() {
        var currentDate = Date(timeIntervalSince1970: 50_000)
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider(),
            now: { currentDate }
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultSession.durationMinutes = 60
        // 旧配置里可能残留「睡眠期间暂停计时」；加载时统一归一为计时器，
        // 倒计时始终按墙钟时间走。
        settings.defaultPolicy.endCalculation = .pausesDuringSleep
        manager.applyLoadedSettings(settings)

        let sessionID = manager.startDefaultSession()
        #expect(
            manager.sessions.first { $0.id == sessionID }?.policy.endCalculation == .timer
        )

        currentDate = currentDate.addingTimeInterval(30 * 60)
        manager.handleSystemSleep()
        currentDate = currentDate.addingTimeInterval(45 * 60)
        manager.handleSystemWake()
        #expect(manager.activeSessions.isEmpty)
    }

    @Test func forcedSleepEndsOnlyTheSessionsOptedIn() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        _ = manager.startManualSession(endCondition: .duration(3_600))
        manager.handleSystemSleep()
        #expect(manager.activeSessionCount == 1)

        // Only the session whose policy opted into forced sleep ends.
        _ = manager.startSession(
            source: .manual,
            endCondition: .duration(3_600),
            policy: SessionPolicy(endOnForcedSleep: true)
        )
        #expect(manager.activeSessionCount == 2)
        manager.handleSystemSleep()
        #expect(manager.activeSessionCount == 1)
        #expect(manager.activeSessions.allSatisfy { !$0.policy.endOnForcedSleep })
    }

    @Test func externalPowerCanSuppressLowBatteryTermination() {
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: powerProvider
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.safetyPolicy.lowBatteryProtectionEnabled = true
        settings.safetyPolicy.minimumBatteryLevel = 30
        manager.applyLoadedSettings(settings)

        powerProvider.state = PowerState(batteryLevel: 10, charging: false, onExternalPower: true)
        _ = manager.startManualSession()
        manager.refreshPowerState()
        #expect(manager.isActive)
        #expect(!manager.safetyProtectionActive)

        settings.defaultSession.ignoreBatteryLevelOnExternalPower = false
        manager.applyLoadedSettings(settings)
        #expect(!manager.isActive)
        #expect(manager.safetyProtectionActive)
    }

    @Test func batteryWarningIsDueNearTheThreshold() {
        let powerProvider = TriggerTestPowerStateProvider()
        powerProvider.state = PowerState(batteryLevel: 18, charging: false, onExternalPower: false)
        var warnings: [Int] = []
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: powerProvider,
            notifyBatteryWarning: { warnings.append($0) }
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.safetyPolicy.lowBatteryProtectionEnabled = true
        settings.safetyPolicy.minimumBatteryLevel = 15
        settings.defaultSession.warnBeforeBatteryTermination = true
        manager.applyLoadedSettings(settings)

        _ = manager.startManualSession()
        #expect(warnings == [15])
        #expect(!manager.isBatteryWarningDue)
        manager.refreshPowerState()
        #expect(warnings == [15])

        powerProvider.state = PowerState(batteryLevel: 18, charging: false, onExternalPower: true)
        manager.refreshPowerState()
        #expect(!manager.isBatteryWarningDue)
        #expect(warnings == [15])

        powerProvider.state = PowerState(batteryLevel: 18, charging: false, onExternalPower: false)
        settings.defaultSession.warnBeforeBatteryTermination = false
        manager.applyLoadedSettings(settings)
        #expect(!manager.isBatteryWarningDue)
        #expect(warnings == [15])
    }

    @Test func powerReconnectStartsDefaultSessionFromDisconnectedState() {
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: powerProvider
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultSession.restartOnPowerReconnect = true
        settings.defaultSession.durationMinutes = 30
        manager.applyLoadedSettings(settings)

        powerProvider.setState(PowerState(batteryLevel: 80, charging: true, onExternalPower: true))
        #expect(manager.activeSessionCount == 1)
        #expect(manager.activeSessions.first?.endCondition == .duration(30 * 60))

        manager.endAllSessions()
        powerProvider.setState(PowerState(batteryLevel: 80, charging: true, onExternalPower: true))
        #expect(manager.activeSessionCount == 0)

        powerProvider.setState(PowerState(batteryLevel: 80, charging: false, onExternalPower: false))
        powerProvider.setState(PowerState(batteryLevel: 80, charging: true, onExternalPower: true))
        #expect(manager.activeSessionCount == 1)
    }

    @Test func displayOffReleasesSystemSleepPreventionOnlyWhenAllowed() {
        let assertionController = TestAssertionController()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        var settings = manager.settings
        settings.defaultPolicy.allowSystemSleepWhenDisplayOff = true
        manager.applyLoadedSettings(settings)
        _ = manager.startManualSession()
        #expect(assertionController.lastState.preventSystemSleep)

        manager.handleDisplaysDidSleep()
        #expect(!assertionController.lastState.preventSystemSleep)

        manager.handleDisplaysDidWake()
        #expect(assertionController.lastState.preventSystemSleep)

        // A running session keeps the policy it was started with, so the
        // strict behavior applies only to sessions started afterwards.
        settings.defaultPolicy.allowSystemSleepWhenDisplayOff = false
        manager.applyLoadedSettings(settings)
        manager.handleDisplaysDidSleep()
        #expect(!assertionController.lastState.preventSystemSleep)

        manager.handleDisplaysDidWake()
        manager.endAllSessions()
        _ = manager.startManualSession()
        manager.handleDisplaysDidSleep()
        #expect(assertionController.lastState.preventSystemSleep)
    }

    @Test func displayOffReleasesSleepPreventionOnlyWhenEverySessionAllowsIt() throws {
        let assertionController = TestAssertionController()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }

        // One session allows sleep with the display off, one does not.
        _ = manager.startSession(
            source: .manual,
            endCondition: .duration(3_600),
            policy: SessionPolicy(allowSystemSleepWhenDisplayOff: true)
        )
        _ = manager.startSession(
            source: .manual,
            endCondition: .duration(3_600),
            policy: SessionPolicy()
        )

        manager.handleDisplaysDidSleep()
        #expect(assertionController.lastState.preventSystemSleep)

        // Once the strict session ends, the remaining session may sleep.
        let strictID = try #require(manager.activeSessions.first(where: { !$0.policy.allowSystemSleepWhenDisplayOff })?.id)
        manager.endSession(strictID)
        manager.handleDisplaysDidSleep()
        #expect(!assertionController.lastState.preventSystemSleep)
    }

    @Test func screenSaverDeferralStopsAtTheAllowedIdleWindow() {
        // Near the system idle limit and inside the allowed window: defer.
        #expect(AwakeIdleInput.shouldDeferScreenSaver(
            idleSeconds: 20 * 60 - 10,
            allowedAfterMinutes: 45,
            systemIdleLimitSeconds: 20 * 60
        ))
        // The allowed idle window elapsed: the screen saver may run.
        #expect(!AwakeIdleInput.shouldDeferScreenSaver(
            idleSeconds: 46 * 60,
            allowedAfterMinutes: 45,
            systemIdleLimitSeconds: 20 * 60
        ))
        // The screen saver is disabled or its limit is unknown/too short.
        #expect(!AwakeIdleInput.shouldDeferScreenSaver(
            idleSeconds: 10 * 60,
            allowedAfterMinutes: 45,
            systemIdleLimitSeconds: nil
        ))
        #expect(!AwakeIdleInput.shouldDeferScreenSaver(
            idleSeconds: 10 * 60,
            allowedAfterMinutes: 45,
            systemIdleLimitSeconds: 30
        ))
    }
}

@MainActor
private final class TestAssertionController: AwakeAssertionControlling {
    private(set) var appliedStates: [DesiredAwakeState] = []

    var isSystemAssertionActive: Bool { lastState.preventSystemSleep }
    var isDisplayAssertionActive: Bool { lastState.preventDisplaySleep }
    var lastState = DesiredAwakeState.inactive

    @discardableResult
    func apply(_ desiredState: DesiredAwakeState) -> Result<Void, AwakeAssertionFailure> {
        lastState = desiredState
        appliedStates.append(desiredState)
        return .success(())
    }

    @discardableResult
    func releaseAll() -> Result<Void, AwakeAssertionFailure> {
        lastState = .inactive
        return .success(())
    }
}

private final class TestPowerStateProvider: AwakePowerStateProviding {
    var state: PowerState

    init(state: PowerState = PowerState(batteryLevel: 80, charging: true, onExternalPower: true)) {
        self.state = state
    }

    func currentPowerState() -> PowerState { state }
}

@MainActor
struct AwakeTriggerTests {
    @Test func triggerConditionsRoundTripAndEvaluateAllAndAny() throws {
        let state = AwakeTriggerSystemState(
            application: ApplicationState(
                runningBundleIDs: ["com.example.editor"],
                frontmostBundleID: "com.example.editor"
            ),
            process: ProcessState(runningNames: ["claude"], runningExecutablePaths: []),
            power: PowerState(batteryLevel: 80, charging: true, onExternalPower: true),
            display: DisplayState(
                onlineDisplays: [DisplayInfo(id: 1, isBuiltIn: true), DisplayInfo(id: 2, isBuiltIn: false)],
                externalDisplayCount: 1,
                mirroringActive: false
            )
        )
        let trigger = AwakeTrigger(
            name: "Coding",
            operatorType: .all,
            conditions: [
                .applicationFrontmost(bundleID: "com.example.editor"),
                .processRunning(name: "claude"),
                .externalDisplay(minimumCount: 1)
            ],
            timingPolicy: TriggerTimingPolicy(activationDelay: 2, deactivationDelay: 3)
        )

        #expect(trigger.matches(state))
        #expect(AwakeTrigger(name: "Any", operatorType: .any, conditions: [.powerAdapter(connected: false), .processRunning(name: "claude")]).matches(state))

        let decoded = try JSONDecoder().decode(AwakeTrigger.self, from: JSONEncoder().encode(trigger))
        #expect(decoded == trigger)
    }

    @Test func processTriggerCreatesOneSessionAndEndsWhenProcessStops() {
        let assertionController = TestAssertionController()
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(assertionController: assertionController, powerStateProvider: powerProvider)
        let processProvider = TriggerTestProcessStateProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: TriggerTestApplicationStateProvider(),
            processStateProvider: processProvider,
            displayStateProvider: TriggerTestDisplayStateProvider()
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        let trigger = AwakeTrigger(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Claude",
            conditions: [.processRunning(name: "claude")]
        )
        engine.applyLoadedTriggers([trigger])
        #expect(processProvider.isPolling)

        processProvider.setState(ProcessState(runningNames: ["claude"], runningExecutablePaths: []))
        #expect(manager.activeSessionCount == 1)
        processProvider.setState(ProcessState(runningNames: ["claude"], runningExecutablePaths: []))
        #expect(manager.activeSessionCount == 1)
        #expect(manager.activeSessions.first?.source == .trigger(trigger.id))

        processProvider.setState(.unknown)
        #expect(manager.activeSessionCount == 0)
        #expect(assertionController.lastState == .inactive)
    }

    @Test func stoppingTriggerSessionKeepsItStoppedUntilConditionChanges() throws {
        let assertionController = TestAssertionController()
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(assertionController: assertionController, powerStateProvider: powerProvider)
        let processProvider = TriggerTestProcessStateProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: TriggerTestApplicationStateProvider(),
            processStateProvider: processProvider,
            displayStateProvider: TriggerTestDisplayStateProvider()
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        let trigger = AwakeTrigger(name: "Claude", conditions: [.processRunning(name: "claude")])
        let runningState = ProcessState(runningNames: ["claude"], runningExecutablePaths: [])
        engine.applyLoadedTriggers([trigger])
        processProvider.setState(runningState)
        let sessionID = try #require(manager.activeSessions.first?.id)

        engine.stopSession(sessionID)
        #expect(manager.activeSessionCount == 0)
        #expect(!engine.runtimeState(for: trigger.id).sessionActive)
        #expect(engine.runtimeState(for: trigger.id).sessionStoppedByUser)
        #expect(assertionController.lastState == .inactive)

        processProvider.setState(runningState)
        #expect(manager.activeSessionCount == 0)

        processProvider.setState(.unknown)
        #expect(!engine.runtimeState(for: trigger.id).sessionStoppedByUser)
        processProvider.setState(runningState)
        #expect(manager.activeSessionCount == 1)
    }

    @Test func triggerSessionsCarryTheirConfiguredPolicy() {
        let assertionController = TestAssertionController()
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: assertionController,
            powerStateProvider: powerProvider
        )
        let processProvider = TriggerTestProcessStateProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: TriggerTestApplicationStateProvider(),
            processStateProvider: processProvider,
            displayStateProvider: TriggerTestDisplayStateProvider()
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        let policy = SessionPolicy(preventDisplaySleep: true)
        let trigger = AwakeTrigger(
            name: "Claude",
            conditions: [.processRunning(name: "claude")],
            sessionPolicy: policy
        )
        engine.applyLoadedTriggers([trigger])
        processProvider.setState(ProcessState(runningNames: ["claude"], runningExecutablePaths: []))

        #expect(manager.activeSessions.first?.policy == policy)
        #expect(assertionController.lastState.preventDisplaySleep)
    }

    @Test func powerAndDisplayTriggersUseSharedStateProviders() {
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: powerProvider
        )
        let displayProvider = TriggerTestDisplayStateProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: TriggerTestApplicationStateProvider(),
            processStateProvider: TriggerTestProcessStateProvider(),
            displayStateProvider: displayProvider
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        let powerTrigger = AwakeTrigger(
            name: "Power",
            conditions: [.powerAdapter(connected: true)]
        )
        let displayTrigger = AwakeTrigger(
            name: "Display",
            conditions: [.externalDisplay(minimumCount: 1)]
        )
        engine.applyLoadedTriggers([powerTrigger, displayTrigger])
        #expect(powerProvider.isMonitoring)
        #expect(displayProvider.isMonitoring)

        powerProvider.setState(PowerState(batteryLevel: 80, charging: true, onExternalPower: true))
        #expect(manager.activeSessionCount == 1)
        displayProvider.setState(DisplayState(
            onlineDisplays: [DisplayInfo(id: 1, isBuiltIn: true), DisplayInfo(id: 2, isBuiltIn: false)],
            externalDisplayCount: 1,
            mirroringActive: false
        ))
        #expect(manager.activeSessionCount == 2)

        powerProvider.setState(PowerState(batteryLevel: 80, charging: false, onExternalPower: false))
        #expect(manager.activeSessionCount == 1)
        displayProvider.setState(.unknown)
        #expect(manager.activeSessionCount == 0)
    }

    @Test func triggerDelaysActivationAndDeactivation() async throws {
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: powerProvider
        )
        let processProvider = TriggerTestProcessStateProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: TriggerTestApplicationStateProvider(),
            processStateProvider: processProvider,
            displayStateProvider: TriggerTestDisplayStateProvider()
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        let trigger = AwakeTrigger(
            name: "Delayed Claude",
            conditions: [.processRunning(name: "claude")],
            timingPolicy: TriggerTimingPolicy(activationDelay: 0.05, deactivationDelay: 0.05)
        )
        engine.applyLoadedTriggers([trigger])
        processProvider.setState(ProcessState(runningNames: ["claude"], runningExecutablePaths: []))
        #expect(manager.activeSessionCount == 0)
        for _ in 0..<20 where manager.activeSessionCount == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(manager.activeSessionCount == 1)

        processProvider.setState(.unknown)
        #expect(manager.activeSessionCount == 1)
        for _ in 0..<20 where manager.activeSessionCount == 1 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(manager.activeSessionCount == 0)
    }

    @Test func disablingLastTriggerStopsItsMonitor() {
        let powerProvider = TriggerTestPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: powerProvider
        )
        let processProvider = TriggerTestProcessStateProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: TriggerTestApplicationStateProvider(),
            processStateProvider: processProvider,
            displayStateProvider: TriggerTestDisplayStateProvider()
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        let trigger = AwakeTrigger(name: "Claude", conditions: [.processRunning(name: "claude")])
        engine.applyLoadedTriggers([trigger])
        #expect(processProvider.isPolling)
        engine.setTriggerEnabled(trigger.id, enabled: false)
        #expect(!processProvider.isPolling)
        #expect(!engine.runtimeState(for: trigger.id).sessionActive)
    }
}

@MainActor
private final class TriggerTestApplicationStateProvider: AwakeApplicationStateProviding {
    var currentState = ApplicationState.unknown
    var isMonitoring = false
    private var handler: (@MainActor () -> Void)?

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        isMonitoring = true
        self.handler = handler
        handler()
    }

    func stopMonitoring() {
        isMonitoring = false
        handler = nil
    }

    func setState(_ state: ApplicationState) {
        currentState = state
        handler?()
    }
}

@MainActor
private final class TriggerTestProcessStateProvider: AwakeProcessStateProviding {
    var currentState = ProcessState.unknown
    var isPolling = false
    private var handler: (@MainActor () -> Void)?

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        isPolling = true
        self.handler = handler
        handler()
    }

    func stopMonitoring() {
        isPolling = false
        handler = nil
    }

    func setState(_ state: ProcessState) {
        currentState = state
        handler?()
    }
}

@MainActor
private final class TriggerTestDisplayStateProvider: AwakeDisplayStateProviding {
    var currentState = DisplayState.unknown
    var isMonitoring = false
    private var handler: (@MainActor () -> Void)?

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        isMonitoring = true
        self.handler = handler
        handler()
    }

    func stopMonitoring() {
        isMonitoring = false
        handler = nil
    }

    func setState(_ state: DisplayState) {
        currentState = state
        handler?()
    }
}

@MainActor
private final class TriggerTestPowerStateProvider: @MainActor AwakePowerStateProviding {
    var state = PowerState(batteryLevel: 80, charging: false, onExternalPower: false)
    private var observers: [UUID: @MainActor () -> Void] = [:]

    var isMonitoring: Bool { !observers.isEmpty }

    func currentPowerState() -> PowerState { state }

    func addMonitoringObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeMonitoringObserver(_ id: UUID) {
        observers[id] = nil
    }

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        _ = addMonitoringObserver(handler)
    }

    func stopMonitoring() {
        observers.removeAll()
    }

    func setState(_ state: PowerState) {
        self.state = state
        observers.values.forEach { $0() }
    }
}

// MARK: - 会话方案（Session Profiles）

@MainActor
struct AwakeProfileTests {
    private var fullConfiguration: AwakeSessionProfileConfiguration {
        AwakeSessionProfileConfiguration(
            durationMinutes: 240,
            endCalculation: .timer,
            endOnForcedSleep: false,
            preventDisplaySleep: true,
            allowSystemSleepWhenDisplayOff: false,
            preventClosedLidSleep: true,
            blockScreenSaver: false,
            screenSaverIdleMinutes: 45,
            lowBatteryProtectionEnabled: true,
            minimumBatteryLevel: 25,
            warnBeforeBatteryTermination: false,
            ignoreBatteryLevelOnExternalPower: true,
            restartOnPowerReconnect: false
        )
    }

    @Test func profileCaptureSnapsTheCompleteBusinessConfigurationFromSettings() {
        var settings = AwakeSettings.standard
        settings.defaultSession.durationMinutes = 240
        settings.defaultPolicy.preventClosedLidSleep = true
        settings.defaultPolicy.preventDisplaySleep = true
        settings.defaultPolicy.blockScreenSaver = true
        settings.defaultPolicy.screenSaverIdleMinutes = 60
        settings.safetyPolicy.lowBatteryProtectionEnabled = false
        settings.safetyPolicy.minimumBatteryLevel = 30
        settings.defaultSession.warnBeforeBatteryTermination = true

        let configuration = AwakeSessionProfileConfiguration.capture(from: settings)

        #expect(configuration.durationMinutes == 240)
        #expect(configuration.endCalculation == .timer)
        #expect(configuration.preventClosedLidSleep)
        #expect(configuration.preventDisplaySleep)
        #expect(configuration.blockScreenSaver)
        #expect(configuration.screenSaverIdleMinutes == 60)
        #expect(!configuration.lowBatteryProtectionEnabled)
        #expect(configuration.minimumBatteryLevel == 30)
        #expect(configuration.warnBeforeBatteryTermination)
        #expect(configuration.ignoreBatteryLevelOnExternalPower)
    }

    @Test func untilDatePresetIsCapturedAsRemainingMinutes() {
        var settings = AwakeSettings.standard
        settings.defaultSession.usesUntilDate = true
        let now = Date(timeIntervalSince1970: 10_000)
        settings.defaultSession.untilDate = now.addingTimeInterval(90.5 * 60)

        let configuration = AwakeSessionProfileConfiguration.capture(from: settings, now: now)
        #expect(configuration.durationMinutes == 91)

        // 已过期的指定时间按不限时处理，不会得到一个立即结束的方案。
        settings.defaultSession.untilDate = now.addingTimeInterval(-60)
        let expired = AwakeSessionProfileConfiguration.capture(from: settings, now: now)
        #expect(expired.durationMinutes == 0)
        #expect(expired.endCondition == .manual)
    }

    @Test func profilesRoundTripThroughCodableForPersistentStorage() throws {
        let profile = AwakeSessionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "AI 编程",
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastUsedAt: Date(timeIntervalSince1970: 2_000),
            configuration: fullConfiguration
        )

        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([AwakeSessionProfile].self, from: data)

        #expect(decoded == [profile])
    }

    @Test func configurationsWithoutTheProfilesKeyMigrateToAnEmptyList() throws {
        // 旧版 config.json 没有 awakeProfiles 键：解码后必须是空列表而不是失败。
        let decoded = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data("{}".utf8))
        #expect(decoded.awakeProfiles.isEmpty)
    }

    @Test func profileConfigurationDecodesDataMissingTheRetiredEndCalculationKey() throws {
        // beta.5 编码的方案没有 endCalculation 键；这些数据必须能解码回来，
        // 而不是让整份配置作废。重新编码时必须带上该键，旧版本才读得回去。
        let json = """
        {"id": "00000000-0000-0000-0000-000000000001", "name": "默认开启方案",
         "createdAt": 0, "configuration": {"durationMinutes": 240, "endOnForcedSleep": true}}
        """
        let profile = try JSONDecoder().decode(AwakeSessionProfile.self, from: Data(json.utf8))

        #expect(profile.configuration.durationMinutes == 240)
        #expect(profile.configuration.endCalculation == .timer)
        #expect(profile.configuration.endOnForcedSleep)

        let encoded = try JSONEncoder().encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let storedConfiguration = try #require(object["configuration"] as? [String: Any])
        #expect(storedConfiguration["endCalculation"] as? String == "timer")
    }

    @Test func oneUnreadableSectionFallsBackToDefaultsAndKeepsEveryOtherSection() throws {
        // 一节配置的形状对不上时（这里模拟 beta.5 丢键、旧版解码失败的场景），
        // 只有这一节回到默认值，其余节的用户数据必须原样保留。
        let json = """
        {"language": "english", "automaticUpdateChecks": false, "awakeProfiles": ["broken"]}
        """
        let decoded = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data(json.utf8))

        #expect(decoded.awakeProfiles.isEmpty)
        #expect(decoded.unreadableSections == ["awakeProfiles"])
        #expect(decoded.language == .english)
        #expect(!decoded.automaticUpdateChecks)
    }

    @Test func launchingAProfileStartsASessionWithIdenticalParameters() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider(),
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        let profile = store.create(name: "AI 编程", configuration: fullConfiguration)

        let sessionID = store.launch(profile.id, in: manager)

        #expect(sessionID != nil)
        #expect(manager.activeSessionCount == 1)
        let session = manager.activeSessions.first
        #expect(session?.source == .profile(name: "AI 编程"))
        #expect(session?.endCondition == .duration(240 * 60))
        #expect(session?.policy == fullConfiguration.policy)
        #expect(store.profile(id: profile.id)?.lastUsedAt != nil)
    }

    @Test func launchingAProfileAppliesProtectionOptionsGlobally() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }
        var configuration = fullConfiguration
        // warn 关闭：避免测试进程触碰通知授权。
        configuration.warnBeforeBatteryTermination = false
        configuration.lowBatteryProtectionEnabled = false
        configuration.minimumBatteryLevel = 30
        configuration.restartOnPowerReconnect = true
        let store = AwakeProfileStore()
        let profile = store.create(name: "夜间挂机", configuration: configuration)

        _ = store.launch(profile.id, in: manager)

        #expect(!manager.settings.safetyPolicy.lowBatteryProtectionEnabled)
        #expect(manager.settings.safetyPolicy.minimumBatteryLevel == 30)
        #expect(manager.settings.defaultSession.restartOnPowerReconnect)
    }

    @Test func editingAProfileDoesNotAffectTheRunningSession() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        let profile = store.create(name: "AI 编程", configuration: fullConfiguration)
        _ = store.launch(profile.id, in: manager)

        var edited = profile
        edited.configuration.durationMinutes = 60
        store.update(edited)

        #expect(manager.activeSessions.first?.endCondition == .duration(240 * 60))
    }

    @Test func deletingAProfileDoesNotEndTheRunningSession() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        let profile = store.create(name: "AI 编程", configuration: fullConfiguration)
        _ = store.launch(profile.id, in: manager)

        store.delete(id: profile.id)

        #expect(manager.activeSessionCount == 1)
        #expect(store.profiles.isEmpty)
    }

    @Test func switchingProfilesReplacesInteractiveSessionsButKeepsTriggerSessions() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        let profile = store.create(name: "下载任务", configuration: fullConfiguration)

        let triggerID = UUID()
        _ = manager.startSession(source: .trigger(triggerID), endCondition: .manual, policy: .standard)
        _ = manager.startManualSession(duration: 60)
        #expect(manager.hasInteractiveSession)

        _ = store.launch(profile.id, in: manager, replacingActiveSessions: true)

        #expect(manager.activeSessionCount == 2)
        let sources = manager.activeSessions.map(\.source)
        #expect(sources.contains { if case .trigger(triggerID) = $0 { return true } else { return false } })
        #expect(sources.contains(.profile(name: "下载任务")))
        #expect(!sources.contains(.manual))
        #expect(manager.activeInteractiveSessions.count == 1)
    }

    @Test func endingInteractiveSessionsStopsManualAndProfileSessionsOnly() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        let profile = store.create(name: "合盖办公", configuration: fullConfiguration)

        let triggerID = UUID()
        _ = manager.startSession(source: .trigger(triggerID), endCondition: .manual, policy: .standard)
        _ = manager.startManualSession(duration: 60)
        _ = store.launch(profile.id, in: manager)

        manager.endAllInteractiveSessions()

        #expect(manager.activeSessionCount == 1)
        #expect(manager.activeSessions.first?.source == .trigger(triggerID))
    }

    @Test func duplicateProfileCreatesAnIndependentUniquelyNamedCopy() {
        let store = AwakeProfileStore()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let profile = store.create(name: "AI 编程", configuration: fullConfiguration, at: createdAt)

        let copy = store.duplicate(id: profile.id, suggestedName: "AI 编程副本", at: createdAt)
        #expect(copy?.name == "AI 编程副本")
        #expect(copy?.id != profile.id)
        #expect(copy?.configuration == profile.configuration)
        #expect(copy?.lastUsedAt == nil)

        let secondCopy = store.duplicate(id: profile.id, suggestedName: "AI 编程副本", at: createdAt)
        #expect(secondCopy?.name == "AI 编程副本 2")

        // 修改原方案不影响副本。
        var edited = profile
        edited.configuration.durationMinutes = 60
        store.update(edited)
        #expect(copy?.configuration.durationMinutes == 240)
    }

    @Test func overwritingByNameKeepsIdentityAndReplacesTheConfiguration() {
        let store = AwakeProfileStore()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let profile = store.create(name: "AI 编程", configuration: fullConfiguration, at: createdAt)

        var replacement = fullConfiguration
        replacement.durationMinutes = 30
        #expect(store.overwriteConfiguration(of: profile.id, with: replacement))

        let stored = store.profile(named: "AI 编程")
        #expect(stored?.id == profile.id)
        #expect(stored?.createdAt == createdAt)
        #expect(stored?.configuration.durationMinutes == 30)
        #expect(store.profiles.count == 1)

        // 名称查找忽略首尾空白与大小写差异。
        #expect(store.profile(named: "  ai 编程 ")?.id == profile.id)
    }

    @Test func launchProfileAutoStartOnlyFillsAnIdleState() {
        let manager = AwakeSessionManager(
            assertionController: TestAssertionController(),
            powerStateProvider: TestPowerStateProvider()
        )
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        let profile = store.create(name: "AI 编程", configuration: fullConfiguration)

        // 功能未启用 / 方案未配置时不启动。
        #expect(manager.startLaunchProfileSessionIfEnabled(from: store) == nil)
        manager.updateSettings {
            $0.defaultSession.launchProfileEnabled = true
            $0.defaultSession.launchProfileID = profile.id
        }

        let sessionID = manager.startLaunchProfileSessionIfEnabled(from: store)
        #expect(sessionID != nil)
        #expect(manager.activeSessions.first?.source == .profile(name: "AI 编程"))

        // 已有会话时不重复启动。
        #expect(manager.startLaunchProfileSessionIfEnabled(from: store) == nil)
        #expect(manager.activeSessionCount == 1)

        // 配置的方案被删除后回退失败（返回 nil），由调用方使用默认会话。
        manager.endAllSessions()
        store.delete(id: profile.id)
        #expect(manager.startLaunchProfileSessionIfEnabled(from: store) == nil)
        #expect(manager.activeSessionCount == 0)
    }

    @Test func profileSessionSourceRoundTripsThroughCodable() throws {
        let source = SessionSource.profile(name: "AI 编程")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SessionSource.self, from: data)
        #expect(decoded == source)
        #expect(source.isInteractive)
        #expect(!SessionSource.trigger(UUID()).isInteractive)
        #expect(!SessionSource.application(bundleID: "com.example.app").isInteractive)
    }

    @Test func availableNameNeverCollidesWithExistingProfiles() {
        let store = AwakeProfileStore()
        _ = store.create(name: "下载", configuration: fullConfiguration)
        #expect(store.availableName(base: "下载") == "下载 2")
        _ = store.create(name: "下载 2", configuration: fullConfiguration)
        #expect(store.availableName(base: "下载") == "下载 3")
        #expect(store.availableName(base: " 新方案 ") == "新方案")
    }
}


@MainActor
struct AwakeProfileOptionParityTests {
    @Test func protectionChoicesSurviveSavingAndEditingAProfile() throws {
        var settings = AwakeSettings.standard
        settings.defaultSession.durationMinutes = 75
        settings.defaultPolicy.preventDisplaySleep = true
        var draft = AwakeSessionProtectionDraft()
        draft.endOnForcedSleep = true
        draft.allowSystemSleepWhenDisplayOff = true
        draft.blockScreenSaver = true
        draft.screenSaverIdleMinutes = 70
        draft.safetyPolicy.lowBatteryProtectionEnabled = false
        draft.safetyPolicy.minimumBatteryLevel = 33
        draft.ignoreBatteryLevelOnExternalPower = false
        draft.restartOnPowerReconnect = true
        draft.autoStartOnLaunch = true
        draft.autoStartOnWake = true
        let captured = draft.applying(to: .capture(from: settings))
        let store = AwakeProfileStore()
        let created = store.create(name: "工作", configuration: captured)
        let decoded = try JSONDecoder().decode(AwakeSessionProfile.self, from: JSONEncoder().encode(created))
        let editDraft = AwakeSessionProtectionDraft(configuration: decoded.configuration)
        #expect(editDraft.applying(to: decoded.configuration) == captured)
        #expect(decoded.configuration.autoStartOnLaunch)
        #expect(decoded.configuration.autoStartOnWake)
        #expect(decoded.configuration.durationMinutes == 75)
        #expect(decoded.configuration.preventDisplaySleep)
        #expect(decoded.configuration.allowSystemSleepWhenDisplayOff)
        #expect(decoded.configuration.blockScreenSaver)
        #expect(decoded.configuration.screenSaverIdleMinutes == 70)

        var edited = decoded
        var changedDraft = editDraft
        changedDraft.autoStartOnWake = false
        edited.configuration = changedDraft.applying(to: edited.configuration)
        store.update(edited)
        #expect(store.profile(id: created.id)?.configuration.autoStartOnWake == false)
        #expect(store.profile(id: created.id)?.configuration.autoStartOnLaunch == true)
    }

    @Test func legacyLaunchSelectionBecomesAnEditableProfileOption() {
        let store = AwakeProfileStore()
        let profile = store.create(name: "工作", configuration: .capture(from: .standard))
        var settings = AwakeSettings.standard
        settings.defaultSession.launchProfileEnabled = true
        settings.defaultSession.launchProfileID = profile.id
        store.migrateLegacyAutomaticStart(in: &settings)
        #expect(store.profile(id: profile.id)?.configuration.autoStartOnLaunch == true)
        #expect(!settings.defaultSession.launchProfileEnabled)
        #expect(settings.defaultSession.launchProfileID == profile.id)
        var edited = store.profile(id: profile.id)!
        edited.configuration.autoStartOnLaunch = false
        store.update(edited)
        store.migrateLegacyAutomaticStart(in: &settings)
        #expect(store.profile(id: profile.id)?.configuration.autoStartOnLaunch == false)
    }

    @Test func historicalProfilesDefaultNewAutomaticStartOptionsToOff() throws {
        let configuration = try JSONDecoder().decode(AwakeSessionProfileConfiguration.self, from: Data("{}".utf8))
        #expect(!configuration.autoStartOnLaunch)
        #expect(!configuration.autoStartOnWake)
        #expect(configuration.untilDate == nil)
    }

    @Test func specifiedEndTimeSurvivesCreatingAndEditingAProfile() throws {
        let now = Date()
        let deadline = now.addingTimeInterval(3600)
        var settings = AwakeSettings.standard
        settings.defaultSession.usesUntilDate = true
        settings.defaultSession.untilDate = deadline
        let captured = AwakeSessionProfileConfiguration.capture(from: settings, now: now)
        let decoded = try JSONDecoder().decode(AwakeSessionProfileConfiguration.self, from: JSONEncoder().encode(captured))
        #expect(decoded.untilDate == deadline)
        #expect(decoded.endCondition == .date(deadline))
        var target = AwakeSettings.standard
        decoded.applySessionSettings(to: &target)
        #expect(target.defaultSession.endCondition == .date(deadline))
    }

    @Test func automaticStartRunsTheSavedProfileAndUsesItsLatestEdits() {
        let manager = AwakeSessionManager(assertionController: TestAssertionController(), powerStateProvider: TestPowerStateProvider())
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        manager.profileStore = store
        var configuration = AwakeSessionProfileConfiguration.capture(from: .standard)
        configuration.durationMinutes = 75
        configuration.autoStartOnLaunch = true
        configuration.autoStartOnWake = true
        var profile = store.create(name: "工作", configuration: configuration)
        #expect(manager.startLaunchProfileSessionIfEnabled(from: store) != nil)
        #expect(manager.activeSessions.first?.source == .profile(name: "工作"))
        #expect(manager.activeSessions.first?.endCondition == .duration(75 * 60))
        #expect(manager.startLaunchProfileSessionIfEnabled(from: store) == nil)
        manager.endAllInteractiveSessions()
        profile.configuration.durationMinutes = 30
        store.update(profile)
        manager.handleSystemWake()
        #expect(manager.activeSessions.first?.endCondition == .duration(30 * 60))
        #expect(manager.activeSessionCount == 1)
        manager.handleSystemWake()
        #expect(manager.activeSessionCount == 1)
        manager.endAllInteractiveSessions()
        profile.configuration.autoStartOnWake = false
        store.update(profile)
        manager.handleSystemWake()
        #expect(manager.activeSessions.isEmpty)
    }

    @Test func automaticStartSkipsExpiredAndDeletedProfiles() {
        let now = Date(timeIntervalSince1970: 100_000)
        let manager = AwakeSessionManager(assertionController: TestAssertionController(), powerStateProvider: TestPowerStateProvider(), now: { now })
        defer { manager.shutdown() }
        let store = AwakeProfileStore()
        manager.profileStore = store
        var configuration = AwakeSessionProfileConfiguration.capture(from: .standard)
        configuration.autoStartOnLaunch = true
        configuration.autoStartOnWake = true
        configuration.untilDate = now.addingTimeInterval(-60)
        let profile = store.create(name: "已过期", configuration: configuration)
        #expect(manager.startLaunchProfileSessionIfEnabled(from: store) == nil)
        manager.handleSystemWake()
        #expect(manager.activeSessions.isEmpty)
        store.delete(id: profile.id)
        manager.handleSystemWake()
        #expect(manager.activeSessions.isEmpty)
    }
}
