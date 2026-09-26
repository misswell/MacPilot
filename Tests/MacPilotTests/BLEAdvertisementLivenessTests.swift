import Foundation
import Testing
@testable import MacPilot

/// The September 2026 wedge: CoreBluetooth claimed a powered-on radio and an
/// active scan while delivering zero advertisements to the process — for days.
/// These tests pin the detection contract that surfaces that state to the user.
struct BLEAdvertisementLivenessTests {
    @Test func backgroundScanArmsLivenessWithoutDevicePicker() {
        #expect(BLEAdvertisementLiveness.monitoringActive(
            featureEnabled: true,
            hasMonitoredDevice: true,
            bluetoothPoweredOn: true,
            displayAsleep: false,
            systemAsleep: false,
            centralScanning: true
        ))
        #expect(!BLEAdvertisementLiveness.monitoringActive(
            featureEnabled: true,
            hasMonitoredDevice: true,
            bluetoothPoweredOn: true,
            displayAsleep: false,
            systemAsleep: false,
            centralScanning: false
        ))
    }

    @Test func silenceTripsOnlyAfterTheThresholdWhileMonitoringIsActive() {
        var liveness = BLEAdvertisementLiveness(silenceThreshold: 600, now: Date(timeIntervalSince1970: 0))

        let beforeThreshold = liveness.evaluate(now: Date(timeIntervalSince1970: 599), monitoringActive: true)
        let atThreshold = liveness.evaluate(now: Date(timeIntervalSince1970: 600), monitoringActive: true)
        let longAfter = liveness.evaluate(now: Date(timeIntervalSince1970: 1_200), monitoringActive: true)

        #expect(!beforeThreshold)
        #expect(atThreshold)
        #expect(longAfter)
    }

    @Test func monitoringInactiveKeepsTheBaselineFreshSoRearmingCannotTrip() {
        var liveness = BLEAdvertisementLiveness(silenceThreshold: 600, now: Date(timeIntervalSince1970: 0))

        // Long quiet stretch while the display was asleep.
        let whileAsleep = liveness.evaluate(now: Date(timeIntervalSince1970: 10_000), monitoringActive: false)
        // Monitoring resumes; the stale quiet stretch must not trip instantly.
        let justAfterWake = liveness.evaluate(now: Date(timeIntervalSince1970: 10_001), monitoringActive: true)
        let aWindowLater = liveness.evaluate(now: Date(timeIntervalSince1970: 10_601), monitoringActive: true)

        #expect(!whileAsleep)
        #expect(!justAfterWake)
        #expect(aWindowLater)
    }

    @Test func anyAdvertisementCallbackReopensTheSilenceWindow() {
        var liveness = BLEAdvertisementLiveness(silenceThreshold: 600, now: Date(timeIntervalSince1970: 0))

        _ = liveness.evaluate(now: Date(timeIntervalSince1970: 500), monitoringActive: true)
        liveness.noteActivity(now: Date(timeIntervalSince1970: 550))
        let withinNewWindow = liveness.evaluate(now: Date(timeIntervalSince1970: 1_000), monitoringActive: true)
        let afterNewWindow = liveness.evaluate(now: Date(timeIntervalSince1970: 1_151), monitoringActive: true)

        #expect(!withinNewWindow)
        #expect(afterNewWindow)
    }
}
