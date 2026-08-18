import Foundation
import Testing
@testable import MacPilot

struct BLEWakeRecoveryTests {
    /// 在并发测试负载下，固定时长 sleep 不够可靠；改为有界轮询等待条件成立。
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func deepSleepWakeRestartsMonitoringAndRetriesUnlock() throws {
        let plan = try #require(BLEWakeRecoveryPlan.make(
            isEnabled: true,
            hasMonitoredDevice: true
        ))

        #expect(plan.monitoringRestartDelays == [0, 1, 3, 6, 10])
        #expect(plan.unlockRetryDelays == [1, 3, 6, 10])
    }

    @Test func wakeDoesNothingWhenMonitoringIsNotConfigured() {
        #expect(BLEWakeRecoveryPlan.make(isEnabled: false, hasMonitoredDevice: true) == nil)
        #expect(BLEWakeRecoveryPlan.make(isEnabled: true, hasMonitoredDevice: false) == nil)
    }

    @MainActor
    @Test func wakeRecoveryFinishesWithoutAScreensDidWakeNotification() async throws {
        let model = BLEUnlockModel()
        let plan = BLEWakeRecoveryPlan(monitoringRestartDelays: [0], unlockRetryDelays: [0])

        model.startSystemWakeRecovery(using: plan)
        try await Task.sleep(for: .milliseconds(20))

        #expect(!model.isRecoveringFromSystemSleep)
    }

    @MainActor
    @Test func overdueSignalTimeoutClearsThePreSleepPresence() async throws {
        let model = BLEUnlockModel()
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.signalTimeout = 0
        model.startMonitor(UUID())

        await waitUntil { !model.presence }

        #expect(!model.presence)
    }

    @MainActor
    @Test func systemSleepFreezesTheOldSignalTimeout() async throws {
        let model = BLEUnlockModel()
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.signalTimeout = 0
        model.startMonitor(UUID())

        model.handleSystemWillSleep()
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.presence)
    }
}
