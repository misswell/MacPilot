import Foundation
import Testing
@testable import MacPilot

struct BLEUnlockPerformanceTests {
    @Test func bluetoothStartupDoesNotPromptBeforeExplicitUserAction() {
        #expect(!BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .notDetermined,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: false
        ))
        #expect(BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .notDetermined,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: true
        ))
    }

    @Test func bluetoothStartupRestoresOnlyPreviouslyDecidedAccess() {
        #expect(BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .allowedAlways,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: false
        ))
        #expect(!BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .denied,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: false
        ))
    }

    @Test func deviceRefreshBurstIsCoalescedIntoOnePublication() {
        var batcher = BLEDeviceListRefreshBatcher()

        for _ in 0..<500 {
            batcher.requestRefresh()
        }

        let firstPublication = batcher.takePendingRefresh()
        let secondPublication = batcher.takePendingRefresh()

        #expect(firstPublication)
        #expect(!secondPublication)
    }

    @Test func anyRelationStaysPresentWhileOneDeviceIsNear() {
        #expect(BLEDevicePresencePolicy.isSatisfied(
            presences: [true, false],
            relation: .any
        ))
        #expect(!BLEDevicePresencePolicy.isSatisfied(
            presences: [false, false],
            relation: .any
        ))
    }

    @Test func allRelationRequiresEveryConfiguredDeviceToBeNear() {
        #expect(BLEDevicePresencePolicy.isSatisfied(
            presences: [true, true],
            relation: .all
        ))
        #expect(!BLEDevicePresencePolicy.isSatisfied(
            presences: [true, false],
            relation: .all
        ))
        #expect(!BLEDevicePresencePolicy.isSatisfied(
            presences: [false, false],
            relation: .all
        ))
    }

    @Test func legacyBLESettingsDecodeWithSingleDeviceDefaults() throws {
        let data = Data(#"""
        {
          "isEnabled": true,
          "monitoredDeviceUUID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "monitoredDeviceName": "Phone",
          "lockRSSI": -80,
          "unlockRSSI": -60
        }
        """#.utf8)

        let settings = try JSONDecoder().decode(BLEUnlockSettings.self, from: data)

        #expect(settings.isEnabled)
        #expect(settings.monitoredDeviceUUID == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(settings.secondaryMonitoredDeviceUUID == nil)
        #expect(settings.secondaryMonitoredDeviceName == nil)
        #expect(settings.deviceRelation == .any)
    }

    @Test func twoDeviceBLESettingsRoundTrip() throws {
        var settings = BLEUnlockSettings()
        settings.monitoredDeviceUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        settings.monitoredDeviceName = "Phone"
        settings.secondaryMonitoredDeviceUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        settings.secondaryMonitoredDeviceName = "Watch"
        settings.deviceRelation = .all

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BLEUnlockSettings.self, from: data)

        #expect(decoded.monitoredDeviceUUID == settings.monitoredDeviceUUID)
        #expect(decoded.secondaryMonitoredDeviceUUID == settings.secondaryMonitoredDeviceUUID)
        #expect(decoded.secondaryMonitoredDeviceName == settings.secondaryMonitoredDeviceName)
        #expect(decoded.deviceRelation == .all)
    }

    @Test func bluetoothScanningDoesNotRequestDuplicateAdvertisements() {
        #expect(!BLEScanPolicy.allowsDuplicateAdvertisements)
        #expect(BLEScanPolicy.scanOptions == nil)
    }

    @Test func bluetoothRSSIRequestsCannotOverlap() {
        var gate = BLERequestGate()

        let firstBegin = gate.begin()
        let overlappingBegin = gate.begin()
        #expect(firstBegin)
        #expect(!overlappingBegin)
        gate.finish()
        let secondBegin = gate.begin()
        #expect(secondBegin)
        gate.reset()
        #expect(!gate.isInFlight)
    }

    @Test func bluetoothConnectionRetriesAreThrottledWhileConnecting() {
        var gate = BLEConnectionRetryGate()
        let firstAttempt = Date(timeIntervalSinceReferenceDate: 1_000)

        let firstBegin = gate.begin(at: firstAttempt)
        let throttledBegin = gate.begin(at: firstAttempt.addingTimeInterval(1))
        let nextBegin = gate.begin(at: firstAttempt.addingTimeInterval(BLEConnectionRetryGate.minimumRetryInterval))
        #expect(firstBegin)
        #expect(!throttledBegin)
        #expect(nextBegin)
    }
}
