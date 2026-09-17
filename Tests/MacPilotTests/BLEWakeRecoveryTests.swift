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

    @Test func displayWakeRetriesMonitoringWhenNoFreshSignalExists() throws {
        let plan = try #require(BLEMonitoringRecoveryPlan.make(
            isEnabled: true,
            hasMonitoredDevice: true
        ))

        #expect(plan.restartDelays == [0, 3, 10])
        #expect(BLEMonitoringRecoveryPlan.make(isEnabled: false, hasMonitoredDevice: true) == nil)
    }

    @Test func unlockAttemptPlanRetriesAfterARealDisplayWake() {
        #expect(BLEUnlockAttemptPlan.standard.deadlines == [2, 5, 9, 14, 20])
        #expect(BLEUnlockAttemptPlan.standard.deadlines == BLEUnlockAttemptPlan.standard.deadlines.sorted())
    }

    @Test func unlockAttemptRetriesWhileTheScreenRemainsLocked() {
        var progress = BLEUnlockAttemptProgress(plan: .standard)

        #expect(progress.nextAction(screenState: .locked) == .postPassword(deadline: 2))
        #expect(progress.nextAction(screenState: .locked) == .postPassword(deadline: 5))
        #expect(progress.nextAction(screenState: .unlocked) == .confirmed)
    }

    /// The regression behind the 17:34 wake that never unlocked: the
    /// display-wake recovery restarts monitoring and resets presence while the
    /// phone is already next to the Mac, so an armed attempt must wait for the
    /// reconnect instead of treating that transient state as a terminal one.
    @Test func unlockAttemptWaitsForThePresenceThatWakeRecoveryReset() {
        #expect(BLEUnlockAttemptGate.decide(
            presence: false,
            manualLock: false,
            unlockDisabled: false,
            wakeWithoutUnlocking: false,
            systemSleep: false
        ) == .waitForPresence)
        #expect(BLEUnlockAttemptGate.decide(
            presence: true,
            manualLock: false,
            unlockDisabled: false,
            wakeWithoutUnlocking: false,
            systemSleep: false
        ) == .proceed)
    }

    @Test func unlockAttemptStillStopsWhenAutoUnlockWasWithdrawn() {
        let withdrawn: [(manualLock: Bool, unlockDisabled: Bool, wakeWithoutUnlocking: Bool, systemSleep: Bool)] = [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
        ]

        for state in withdrawn {
            #expect(BLEUnlockAttemptGate.decide(
                presence: true,
                manualLock: state.manualLock,
                unlockDisabled: state.unlockDisabled,
                wakeWithoutUnlocking: state.wakeWithoutUnlocking,
                systemSleep: state.systemSleep
            ) == .stop)
        }
    }

    @Test func stoppedUnlockAttemptReleasesItsSlotForTheNextWake() {
        var slot = BLEUnlockAttemptSlot()

        let generation = slot.claim()
        let heldWhileInFlight = slot.claim()
        #expect(generation != nil)
        #expect(heldWhileInFlight == nil)

        if let generation {
            slot.release(generation: generation)
        }
        #expect(!slot.isOccupied)
        let afterRelease = slot.claim()
        #expect(afterRelease != nil)
    }

    @Test func cancelledUnlockAttemptCannotReleaseTheSuccessorAttemptSlot() throws {
        var slot = BLEUnlockAttemptSlot()

        let staleClaim = slot.claim()
        let staleGeneration = try #require(staleClaim)
        slot.invalidate()
        let currentClaim = slot.claim()
        let currentGeneration = try #require(currentClaim)

        #expect(currentGeneration != staleGeneration)
        slot.release(generation: staleGeneration)
        #expect(slot.isOccupied)
        let blockedClaim = slot.claim()
        #expect(blockedClaim == nil)
    }

    @Test func unlockConfirmationRequiresAConfirmedUnlockedSession() {
        #expect(!BLEUnlockConfirmation.isConfirmed(screenState: .locked))
        #expect(!BLEUnlockConfirmation.isConfirmed(screenState: .unknown))
        #expect(BLEUnlockConfirmation.isConfirmed(screenState: .unlocked))
    }

    @Test func unlockAttemptDoesNotTypeWhenSessionStateIsUnknown() {
        var progress = BLEUnlockAttemptProgress(plan: .standard)

        #expect(progress.nextAction(screenState: .unknown) == .stateUnavailable)
        #expect(progress.nextAction(screenState: .locked) == .postPassword(deadline: 5))
    }

    @Test func missingLockFlagMeansUnlockedForTheCurrentCompletedSession() {
        #expect(BLEScreenLockStateResolver.resolve(
            locked: nil,
            loginDone: true,
            sessionUserName: "guofeng",
            currentUserName: "guofeng"
        ) == .unlocked)
    }

    @Test func missingLockFlagRemainsUnknownForAnotherOrIncompleteSession() {
        #expect(BLEScreenLockStateResolver.resolve(
            locked: nil,
            loginDone: true,
            sessionUserName: "another-user",
            currentUserName: "guofeng"
        ) == .unknown)
        #expect(BLEScreenLockStateResolver.resolve(
            locked: nil,
            loginDone: false,
            sessionUserName: "guofeng",
            currentUserName: "guofeng"
        ) == .unknown)
    }

    @Test func explicitLockFlagWinsDuringSessionTransitions() {
        #expect(BLEScreenLockStateResolver.resolve(
            locked: true,
            loginDone: true,
            sessionUserName: "guofeng",
            currentUserName: "guofeng"
        ) == .locked)
        #expect(BLEScreenLockStateResolver.resolve(
            locked: false,
            loginDone: false,
            sessionUserName: nil,
            currentUserName: "guofeng"
        ) == .unlocked)
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
