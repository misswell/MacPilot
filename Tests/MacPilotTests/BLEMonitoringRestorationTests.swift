import AppKit
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEMonitoringRestorationTests {
    @Test func absentSecondaryDoesNotResetAFreshPrimaryInAnyDeviceMode() {
        let primary = UUID()
        let secondary = UUID()
        let model = BLEUnlockModel()
        defer { model.shutdown() }
        model.settings.isEnabled = true
        model.settings.deviceRelation = .any
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.secondaryMonitoredUUID = secondary
        model.startMonitor(primary)
        model.updateMonitoredPeripheral(-50, for: primary)
        let taskCount = model.diagnosticTaskCount

        model.handleMonitoredSignalTimeout(for: secondary)

        #expect(model.presence)
        #expect(model.lastRSSI == -50)
        #expect(model.diagnosticTaskCount == taskCount)
    }

    @Test func activeRecoveryReconnectsKnownDevicesWithoutAnAdvertisement() {
        let known = UUID()
        let unknown = UUID()
        var retrieved: [UUID] = []
        var connected: [UUID] = []
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [known, unknown],
            passiveMode: false,
            retrieve: { identifier -> String? in
                retrieved.append(identifier)
                return identifier == known ? "cached peripheral" : nil
            },
            connect: { identifier, device in
                #expect(device == "cached peripheral")
                connected.append(identifier)
            },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(retrieved == [known, unknown])
        #expect(connected == [known])
        // Unknown or absent devices must still get another recovery opportunity.
        #expect(timeouts == [known, unknown])
    }

    @Test func passiveRecoveryArmsTimeoutsWithoutConnecting() {
        let identifier = UUID()
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [identifier],
            passiveMode: true,
            retrieve: { _ -> String? in
                Issue.record("Passive monitoring must not retrieve devices for connection")
                return "device"
            },
            connect: { _, _ in Issue.record("Passive monitoring must not connect") },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(timeouts == [identifier])
    }

    @Test func displaySleepRecoveryKeepsPassiveScanningWithoutRetrievingForConnection() {
        let identifier = UUID()
        var timeouts: [UUID] = []
        BLEMonitoringRestoration.restore(
            identifiers: [identifier],
            passiveMode: false,
            activeConnectionsPaused: true,
            retrieve: { _ -> String? in
                Issue.record("A sleeping display must not retrieve a peripheral for connection")
                return "cached peripheral"
            },
            connect: { _, _ in Issue.record("A sleeping display must not reconnect") },
            armSignalTimeout: { timeouts.append($0) }
        )
        #expect(timeouts == [identifier])
    }

    @Test func explicitProximityWakeKeepsActiveConnectionPolicyEnabledDuringDisplaySleep() {
        #expect(!BLEActiveConnectionPolicy.shouldPause(
            displayAsleep: true,
            systemAsleep: false,
            wakeOnProximity: true
        ))
    }

    @Test func heldBlankNotificationPausesConnectionsCancelsUnlockAndResumesOnUnblank() {
        let model = BLEUnlockModel()
        defer { model.shutdown() }
        var isBlanked = false
        let blankCenter = NotificationCenter()
        model.displayUnavailableProbe = { isBlanked }
        model.heldBlankNotificationCenterOverride = blankCenter
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        model.startMonitor(UUID())

        model.updatePresence(presence: true, reason: "test-before-blank")
        #expect(model.isUnlockAttemptScheduled)
        #expect(!model.activeConnectionsPaused)

        isBlanked = true
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)
        #expect(model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)

        isBlanked = false
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)
        #expect(!model.activeConnectionsPaused)
    }

    @Test func asleepDisplayWithoutWakeDoesNotScheduleUnlockButExplicitWakeCan() {
        let model = BLEUnlockModel()
        defer { model.shutdown() }
        var displayUnavailable = true
        model.displayUnavailableProbe = { displayUnavailable }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.startMonitor(UUID())
        model.updatePresence(presence: true, reason: "test-asleep")
        #expect(model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)

        model.setWakeOnProximity(true)
        #expect(!model.activeConnectionsPaused)
        model.updatePresence(presence: true, reason: "test-explicit-wake")
        #expect(model.isUnlockAttemptScheduled)
        displayUnavailable = false
    }

    @Test func systemDisplaySleepAndWakeNotificationsToggleTheModelConnectionPolicy() {
        let model = BLEUnlockModel()
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        model.startObservingSystemState()

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(model.activeConnectionsPaused)

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!model.activeConnectionsPaused)
    }
}
