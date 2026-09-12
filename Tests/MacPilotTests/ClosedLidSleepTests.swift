import Foundation
import MacPilotPowerIPC
import Testing
@testable import MacPilot

// MARK: - Pure ownership / watchdog logic

struct SleepDisabledPlannerTests {
    @Test func firstEnableRecordsOwnershipAndRestoresToZero() {
        let original = SleepDisabledRuntimeState.empty
        #expect(SleepDisabledPlanner.planEnable(currentSleepDisabled: false, state: original) == .enableByRunningPMSet)

        var owned = original
        owned.macPilotOwnedSleepDisable = true
        #expect(SleepDisabledPlanner.planDisable(currentSleepDisabled: true, state: owned) == .disableByRunningPMSet)

        let released = SleepDisabledPlanner.stateAfterDisable(currentSleepDisabled: false, state: owned)
        #expect(!released.macPilotOwnedSleepDisable)
        #expect(!released.previousSleepDisabled)
    }

    @Test func alreadyDisabledByAnotherToolIsNeverClaimedOrReleased() {
        let original = SleepDisabledRuntimeState.empty
        // Somebody else already turned it on: MacPilot must not run pmset.
        #expect(SleepDisabledPlanner.planEnable(currentSleepDisabled: true, state: original) == .noChange)

        let afterEnable = SleepDisabledPlanner.stateAfterEnable(
            currentSleepDisabled: true,
            state: original,
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(!afterEnable.macPilotOwnedSleepDisable)
        #expect(afterEnable.previousSleepDisabled)

        // Without ownership, releasing is a no-op and the system value stays 1.
        #expect(SleepDisabledPlanner.planDisable(currentSleepDisabled: true, state: afterEnable) == .noChange)
        let afterRelease = SleepDisabledPlanner.stateAfterDisable(currentSleepDisabled: true, state: afterEnable)
        #expect(!afterRelease.macPilotOwnedSleepDisable)
        #expect(afterRelease.previousSleepDisabled)
    }

    @Test func repeatedEnableIsIdempotent() {
        var owned = SleepDisabledRuntimeState.empty
        owned.macPilotOwnedSleepDisable = true
        #expect(SleepDisabledPlanner.planEnable(currentSleepDisabled: true, state: owned) == .noChange)
    }

    @Test func watchdogRecoversOnlyOwnedSettingsAfterTheTimeout() {
        let now = Date(timeIntervalSince1970: 1_000)
        var owned = SleepDisabledRuntimeState(
            macPilotOwnedSleepDisable: true,
            previousSleepDisabled: false,
            lastHeartbeat: now.addingTimeInterval(-89)
        )
        #expect(!SleepDisabledPlanner.shouldWatchdogRecover(state: owned, now: now, timeout: 90))

        owned.lastHeartbeat = now.addingTimeInterval(-91)
        #expect(SleepDisabledPlanner.shouldWatchdogRecover(state: owned, now: now, timeout: 90))

        // Never owned: nothing to recover.
        let notOwned = SleepDisabledRuntimeState(macPilotOwnedSleepDisable: false, lastHeartbeat: nil)
        #expect(!SleepDisabledPlanner.shouldWatchdogRecover(state: notOwned, now: now, timeout: 90))

        // Owned with no heartbeat at all is treated as stale.
        let silent = SleepDisabledRuntimeState(macPilotOwnedSleepDisable: true, lastHeartbeat: nil)
        #expect(SleepDisabledPlanner.shouldWatchdogRecover(state: silent, now: now, timeout: 90))
    }

    @Test func pmsetOutputParsingReadsTheRealValue() {
        #expect(SleepDisabledPlanner.parseSleepDisabled(fromPMSetOutput: " SleepDisabled\t\t1\n") == true)
        #expect(SleepDisabledPlanner.parseSleepDisabled(fromPMSetOutput: " SleepDisabled\t\t0\n") == false)
        #expect(SleepDisabledPlanner.parseSleepDisabled(
            fromPMSetOutput: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n"
        ) == true)
        #expect(SleepDisabledPlanner.parseSleepDisabled(fromPMSetOutput: "Currently in use:\n") == nil)
        #expect(SleepDisabledPlanner.parseSleepDisabled(fromPMSetOutput: " SleepDisabled\t\tmaybe\n") == nil)
    }

    @Test func runtimeStateSurvivesStorage() throws {
        let now = Date(timeIntervalSince1970: 500)
        let state = SleepDisabledRuntimeState(
            macPilotOwnedSleepDisable: true,
            previousSleepDisabled: false,
            lastHeartbeat: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SleepDisabledRuntimeState.self, from: encoder.encode(state))
        #expect(decoded == state)
    }
}

// MARK: - Awake integration

@MainActor
struct ClosedLidSleepTests {
    @Test func standardPolicyKeepsClosedLidSleepOff() {
        #expect(!SessionPolicy.standard.preventClosedLidSleep)
    }

    @Test func closedLidPolicyAlwaysPreventsSystemSleep() {
        let policy = SessionPolicy(preventSystemSleep: false, preventClosedLidSleep: true)
        #expect(policy.preventSystemSleep)
        #expect(policy.preventClosedLidSleep)

        var mutated = SessionPolicy(preventSystemSleep: false)
        mutated.setPreventClosedLidSleep(true)
        #expect(mutated.preventSystemSleep)

        mutated.setPreventClosedLidSleep(false)
        #expect(!mutated.preventClosedLidSleep)
    }

    @Test func olderStoredPoliciesDecodeWithClosedLidSleepOff() throws {
        let decoded = try JSONDecoder().decode(SessionPolicy.self, from: Data("{\"preventSystemSleep\":true}".utf8))
        #expect(!decoded.preventClosedLidSleep)
        #expect(decoded.preventSystemSleep)
    }

    @Test func closedLidSessionDrivesThePrivilegedController() {
        let controller = ClosedLidTestController()
        let manager = makeManager(controller: controller)
        defer { manager.shutdown() }

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )

        #expect(manager.desiredAwakeState.preventClosedLidSleep)
        #expect(manager.desiredAwakeState.preventSystemSleep)
        #expect(controller.requestedValues == [true])
        #expect(manager.isClosedLidSleepActive)
    }

    @Test func onlyTheLastClosedLidSessionReleasesTheController() throws {
        let controller = ClosedLidTestController()
        let manager = makeManager(controller: controller)
        defer { manager.shutdown() }

        let closedLid = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        let plain = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy()
        )
        #expect(controller.requestedValues == [true])

        manager.endSession(plain)
        #expect(manager.desiredAwakeState.preventClosedLidSleep)
        #expect(controller.requestedValues == [true])

        manager.endSession(closedLid)
        #expect(!manager.desiredAwakeState.preventClosedLidSleep)
        #expect(controller.requestedValues == [true, false])
        #expect(!manager.isClosedLidSleepActive)
    }

    @Test func lowBatteryProtectionReleasesClosedLidSleep() {
        let controller = ClosedLidTestController()
        let powerProvider = ClosedLidPowerStateProvider(
            state: PowerState(batteryLevel: 80, charging: false, onExternalPower: false)
        )
        let manager = makeManager(controller: controller, powerProvider: powerProvider)
        defer { manager.shutdown() }

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        #expect(controller.requestedValues == [true])

        powerProvider.state = PowerState(batteryLevel: 5, charging: false, onExternalPower: false)
        manager.refreshPowerState()

        #expect(manager.activeSessions.isEmpty)
        #expect(controller.requestedValues == [true, false])
        #expect(manager.desiredAwakeState.preventClosedLidSleep == false)
    }

    @Test func controllerFailureIsSurfacedWithoutCrashing() {
        let controller = ClosedLidTestController()
        controller.enableResult = .failure(.requestFailed("pmset denied"))
        let manager = makeManager(controller: controller)
        defer { manager.shutdown() }

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )

        #expect(manager.activeSessionCount == 1)
        #expect(manager.desiredAwakeState.preventClosedLidSleep)
        #expect(manager.lastClosedLidFailure == .requestFailed("pmset denied"))
        #expect(manager.closedLidServiceState == .error("pmset denied"))
        #expect(!manager.isClosedLidSleepActive)
    }

    @Test func agentTriggerCarriesClosedLidPolicyAndReleasesOnExit() {
        let controller = ClosedLidTestController()
        let powerProvider = ClosedLidPowerStateProvider()
        let manager = AwakeSessionManager(
            assertionController: ClosedLidAssertionController(),
            powerStateProvider: powerProvider,
            closedLidSleepController: controller,
            lidStateMonitor: ClosedLidTestLidMonitor(),
            displayStateProvider: ClosedLidTestDisplayProvider()
        )
        let processProvider = ClosedLidTestProcessProvider()
        let engine = AwakeTriggerEngine(
            sessionManager: manager,
            powerStateProvider: powerProvider,
            applicationStateProvider: ClosedLidTestApplicationProvider(),
            processStateProvider: processProvider,
            displayStateProvider: ClosedLidTestDisplayProvider()
        )
        defer {
            engine.shutdown()
            manager.shutdown()
        }

        engine.addTrigger(AwakeAgentPreset.claudeCode.makeTrigger(name: "Claude Code"))
        #expect(controller.requestedValues.isEmpty)

        processProvider.setState(ProcessState(runningNames: ["claude"], runningExecutablePaths: []))
        #expect(manager.activeSessionCount == 1)
        #expect(manager.desiredAwakeState.preventClosedLidSleep)
        #expect(controller.requestedValues == [true])

        processProvider.setState(.unknown)
        #expect(manager.activeSessionCount == 0)
        #expect(controller.requestedValues == [true, false])
    }

    @Test func agentPresetsUseTheExistingProcessTriggerModel() {
        for preset in AwakeAgentPreset.allCases {
            let trigger = preset.makeTrigger(name: preset.titleKey)
            #expect(trigger.conditions == [.processRunning(name: preset.processName)])
            #expect(trigger.sessionPolicy.preventClosedLidSleep)
            #expect(trigger.sessionPolicy.preventSystemSleep)
            #expect(!trigger.sessionPolicy.preventDisplaySleep)
        }
        #expect(AwakeAgentPreset.claudeCode.processName == "claude")
        #expect(AwakeAgentPreset.codex.processName == "codex")
        #expect(AwakeAgentPreset.openCode.processName == "opencode")
    }

    @Test func shutdownReleasesThePrivilegedController() {
        let controller = ClosedLidTestController()
        let manager = makeManager(controller: controller)

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        #expect(controller.requestedValues == [true])

        manager.shutdown()
        #expect(controller.shutdownCalled)
        #expect(!controller.isActive)
    }
}

// MARK: - Lid / display behavior

@MainActor
struct ClosedLidDisplayTests {
    @Test func lidCloseWithoutExternalDisplaySleepsTheDisplayAndWakesItOnOpen() {
        let lid = ClosedLidTestLidMonitor(state: .open)
        let display = ClosedLidTestDisplayProvider()
        var sleepCount = 0
        var wakeCount = 0
        let manager = makeManager(
            controller: ClosedLidTestController(),
            lidMonitor: lid,
            displayProvider: display,
            sleepDisplay: { sleepCount += 1 },
            wakeDisplay: { wakeCount += 1 }
        )
        defer { manager.shutdown() }

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        #expect(lid.isMonitoring)
        #expect(sleepCount == 0)

        lid.setState(.closed)
        #expect(sleepCount == 1)
        #expect(wakeCount == 0)
        #expect(manager.isLidClosed)

        lid.setState(.open)
        #expect(wakeCount == 1)
        #expect(!manager.isLidClosed)
    }

    @Test func lidCloseWithAnExternalDisplayNeverSleepsTheDisplays() {
        let lid = ClosedLidTestLidMonitor(state: .open)
        let display = ClosedLidTestDisplayProvider(externalDisplayCount: 1)
        var sleepCount = 0
        var wakeCount = 0
        let manager = makeManager(
            controller: ClosedLidTestController(),
            lidMonitor: lid,
            displayProvider: display,
            sleepDisplay: { sleepCount += 1 },
            wakeDisplay: { wakeCount += 1 }
        )
        defer { manager.shutdown() }

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        lid.setState(.closed)
        lid.setState(.open)

        #expect(sleepCount == 0)
        #expect(wakeCount == 0)
    }

    @Test func lidOpenDoesNotWakeADisplayMacPilotNeverSlept() {
        let lid = ClosedLidTestLidMonitor(state: .open)
        // The user had already turned the display off; MacPilot only reacts to
        // displays it slept itself.
        let display = ClosedLidTestDisplayProvider(externalDisplayCount: 1)
        var wakeCount = 0
        let manager = makeManager(
            controller: ClosedLidTestController(),
            lidMonitor: lid,
            displayProvider: display,
            sleepDisplay: {},
            wakeDisplay: { wakeCount += 1 }
        )
        defer { manager.shutdown() }

        _ = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        lid.setState(.closed)
        lid.setState(.open)

        #expect(wakeCount == 0)
    }

    @Test func lidMonitorStopsWhenClosedLidSleepIsNoLongerNeeded() {
        let lid = ClosedLidTestLidMonitor(state: .open)
        let manager = makeManager(controller: ClosedLidTestController(), lidMonitor: lid)
        defer { manager.shutdown() }

        let id = manager.startSession(
            source: .manual,
            endCondition: .manual,
            policy: SessionPolicy(preventClosedLidSleep: true)
        )
        #expect(lid.isMonitoring)

        manager.endSession(id)
        #expect(!lid.isMonitoring)
    }
}

// MARK: - Controller state machine

@MainActor
struct ClosedLidSleepControllerTests {
    @Test func repeatedEnableRequestsAreIdempotent() async {
        let helper = ClosedLidTestPowerHelper()
        let controller = ClosedLidSleepController(
            helper: helper,
            heartbeatInterval: .seconds(60),
            reconnectDelays: []
        )
        defer { controller.shutdown() }

        controller.setEnabled(true)
        controller.setEnabled(true)
        controller.setEnabled(true)
        await waitUntil { controller.isActive }

        #expect(helper.setSleepDisabledCalls == [true])
        #expect(controller.serviceState == .enabled)
    }

    @Test func enablingWithoutApprovalReportsRequiresApproval() async {
        let helper = ClosedLidTestPowerHelper()
        helper.registrationState = .requiresApproval
        let controller = ClosedLidSleepController(helper: helper, heartbeatInterval: .seconds(60), reconnectDelays: [])
        defer { controller.shutdown() }

        controller.setEnabled(true)
        await waitUntil { controller.serviceState == .requiresApproval }

        #expect(helper.setSleepDisabledCalls.isEmpty)
        #expect(!controller.isActive)
    }

    @Test func disableReleasesAndStopsHeartbeats() async {
        let helper = ClosedLidTestPowerHelper()
        let controller = ClosedLidSleepController(helper: helper, heartbeatInterval: .seconds(60), reconnectDelays: [])
        defer { controller.shutdown() }

        controller.setEnabled(true)
        await waitUntil { controller.isActive }
        controller.setEnabled(false)
        await waitUntil { !controller.isActive }

        #expect(helper.setSleepDisabledCalls == [true, false])
        #expect(controller.serviceState == .ready)
    }

    @Test func heartbeatFailureTriggersABoundedReconnect() async {
        let helper = ClosedLidTestPowerHelper()
        let controller = ClosedLidSleepController(
            helper: helper,
            heartbeatInterval: .milliseconds(10),
            reconnectDelays: [.milliseconds(10)]
        )
        defer { controller.shutdown() }

        controller.setEnabled(true)
        await waitUntil { controller.isActive }

        helper.heartbeatResult = .failure(.requestFailed("connection invalid"))
        await waitUntil { helper.setSleepDisabledCalls.count >= 2 }

        #expect(helper.setSleepDisabledCalls == [true, true])
        await waitUntil { controller.serviceState == .enabled }
    }

    @Test func shutdownReleasesSynchronously() async {
        let helper = ClosedLidTestPowerHelper()
        let controller = ClosedLidSleepController(helper: helper, heartbeatInterval: .seconds(60), reconnectDelays: [])

        controller.setEnabled(true)
        await waitUntil { controller.isActive }
        controller.shutdown()

        #expect(helper.releaseSynchronouslyCallCount == 1)
        #expect(!controller.isActive)
    }
}

// MARK: - Test doubles

@MainActor
private func makeManager(
    controller: ClosedLidTestController,
    powerProvider: ClosedLidPowerStateProvider = ClosedLidPowerStateProvider(),
    lidMonitor: ClosedLidTestLidMonitor = ClosedLidTestLidMonitor(),
    displayProvider: ClosedLidTestDisplayProvider = ClosedLidTestDisplayProvider(),
    sleepDisplay: @escaping @MainActor () -> Void = {},
    wakeDisplay: @escaping () -> Void = {}
) -> AwakeSessionManager {
    AwakeSessionManager(
        assertionController: ClosedLidAssertionController(),
        powerStateProvider: powerProvider,
        closedLidSleepController: controller,
        lidStateMonitor: lidMonitor,
        displayStateProvider: displayProvider,
        sleepDisplay: sleepDisplay,
        wakeDisplay: wakeDisplay
    )
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private final class ClosedLidTestController: ClosedLidSleepControlling {
    var serviceState: ClosedLidSleepServiceState = .ready
    var isActive = false
    var lastFailure: ClosedLidSleepFailure?
    var systemSleepDisabled: Bool?
    var onStateChange: (@MainActor () -> Void)?

    private(set) var requestedValues: [Bool] = []
    private(set) var shutdownCalled = false
    var enableResult: Result<Bool, ClosedLidSleepFailure> = .success(true)

    func prepareIfNeeded() async {}
    func openSystemSettings() {}

    func setEnabled(_ enabled: Bool) {
        requestedValues.append(enabled)
        switch enableResult {
        case .success:
            isActive = enabled
            lastFailure = nil
            serviceState = enabled ? .enabled : .ready
        case .failure(let failure):
            isActive = false
            if enabled {
                lastFailure = failure
                serviceState = .error(failure.message)
            } else {
                lastFailure = nil
                serviceState = .ready
            }
        }
        onStateChange?()
    }

    func shutdown() {
        shutdownCalled = true
        isActive = false
        onStateChange?()
    }
}

@MainActor
private final class ClosedLidAssertionController: AwakeAssertionControlling {
    var isSystemAssertionActive: Bool { lastState.preventSystemSleep }
    var isDisplayAssertionActive: Bool { lastState.preventDisplaySleep }
    private(set) var lastState = DesiredAwakeState.inactive

    @discardableResult
    func apply(_ desiredState: DesiredAwakeState) -> Result<Void, AwakeAssertionFailure> {
        lastState = desiredState
        return .success(())
    }

    @discardableResult
    func releaseAll() -> Result<Void, AwakeAssertionFailure> {
        lastState = .inactive
        return .success(())
    }
}

private final class ClosedLidPowerStateProvider: AwakePowerStateProviding {
    var state: PowerState

    init(state: PowerState = PowerState(batteryLevel: 80, charging: true, onExternalPower: true)) {
        self.state = state
    }

    func currentPowerState() -> PowerState { state }
}

@MainActor
private final class ClosedLidTestLidMonitor: LidStateMonitoring {
    private(set) var currentState: LidState
    private(set) var isMonitoring = false
    private var handler: (@MainActor (LidState) -> Void)?

    init(state: LidState = .unknown) {
        self.currentState = state
    }

    func start(onChange: @escaping @MainActor (LidState) -> Void) {
        isMonitoring = true
        handler = onChange
        handler?(currentState)
    }

    func stop() {
        isMonitoring = false
        handler = nil
    }

    func setState(_ state: LidState) {
        currentState = state
        handler?(state)
    }
}

@MainActor
private final class ClosedLidTestDisplayProvider: AwakeDisplayStateProviding {
    var currentState: DisplayState

    init(externalDisplayCount: Int = 0) {
        currentState = DisplayState(
            onlineDisplays: [],
            externalDisplayCount: externalDisplayCount,
            mirroringActive: false
        )
    }

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}
    func refreshNow() {}
}

@MainActor
private final class ClosedLidTestProcessProvider: AwakeProcessStateProviding {
    var currentState = ProcessState.unknown
    private var handler: (@MainActor () -> Void)?

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        handler()
    }

    func stopMonitoring() { handler = nil }

    func setState(_ state: ProcessState) {
        currentState = state
        handler?()
    }
}

@MainActor
private final class ClosedLidTestApplicationProvider: AwakeApplicationStateProviding {
    var currentState = ApplicationState.unknown

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}
}

@MainActor
private final class ClosedLidTestPowerHelper: PowerHelperServicing {
    var registrationState: ClosedLidSleepServiceState = .ready
    var registerError: (any Error)?
    private(set) var registerCallCount = 0
    private(set) var openSettingsCallCount = 0
    private(set) var setSleepDisabledCalls: [Bool] = []
    private(set) var heartbeatCallCount = 0
    private(set) var releaseSynchronouslyCallCount = 0
    var setSleepDisabledResult: Result<Bool, ClosedLidSleepFailure> = .success(true)
    var heartbeatResult: Result<Bool, ClosedLidSleepFailure> = .success(true)

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        registrationState = .ready
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }

    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure> {
        setSleepDisabledCalls.append(disabled)
        return setSleepDisabledResult
    }

    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure> {
        .success(true)
    }

    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure> {
        heartbeatCallCount += 1
        return heartbeatResult
    }

    func releaseSynchronously() {
        releaseSynchronouslyCallCount += 1
    }
}
