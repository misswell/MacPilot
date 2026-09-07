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
