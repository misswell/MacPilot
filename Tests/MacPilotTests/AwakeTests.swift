import Foundation
import Testing
@testable import MacPilot

@MainActor
struct AwakeTests {
    @Test func standardPolicyAllowsDisplaySleepWhileBlockingSystemSleep() {
        #expect(SessionPolicy.standard.preventSystemSleep)
        #expect(!SessionPolicy.standard.preventDisplaySleep)
        #expect(!SessionPolicy.standard.preventClosedLidSleep)
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
