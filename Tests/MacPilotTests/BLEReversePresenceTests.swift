import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Testing
@testable import MacPilot

/// The reverse link may inform presence only after an authenticated sample for
/// a binding the user configured. These tests exercise the model's own
/// revalidation, threshold and lifetime rules with a fake radio.
@MainActor
struct BLEReversePresenceTests {
    private func freshSample(_ h: Harness, rssi: Int = -50) -> Bool {
        h.model.acceptReversePresenceSample(
            clientID: "phone",
            keyFingerprint: "fp",
            primaryUUID: h.phone,
            rssi: rssi,
            sampledAt: Date()
        )
    }

    @Test func aBoundAuthenticatedSampleBecomesPresence() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        #expect(freshSample(h))
        #expect(h.model.presence)
        #expect(h.model.lastRSSI == -50)
        #expect(h.model.lastRSSISource == .reverse)
        let runtime = try #require(h.model.reverseRuntime(for: h.phone))
        #expect(runtime.presence)
        #expect(runtime.lastRSSI == -50)
        #expect(runtime.sampleCount == 1)
        #expect(h.model.runtime(for: h.phone)?.lastRSSI == nil, "Reverse evidence must not enter the legacy runtime")
        #expect(h.model.settings.identityRegistry.bindings.allSatisfy { $0.aliases.isEmpty },
                "Reverse central UUIDs are never learned as legacy aliases")
        #expect(!h.model.isUnlockAttemptScheduled)
    }

    @Test func aSampleWithoutTheConfiguredBindingIsRejected() {
        let h = Harness()
        defer { h.model.shutdown() }
        #expect(!h.model.acceptReversePresenceSample(
            clientID: "stranger", keyFingerprint: "fp",
            primaryUUID: h.phone, rssi: -40, sampledAt: Date()
        ))
        #expect(!h.model.acceptReversePresenceSample(
            clientID: "phone", keyFingerprint: "other-key",
            primaryUUID: h.phone, rssi: -40, sampledAt: Date()
        ))
        #expect(!h.model.acceptReversePresenceSample(
            clientID: "phone", keyFingerprint: "fp",
            primaryUUID: UUID(), rssi: -40, sampledAt: Date()
        ))
        #expect(!h.model.presence)
        #expect(h.model.lastRSSI == nil)
        #expect(h.model.reverseRuntime(for: h.phone) == nil)
    }

    @Test func samplesFromARevokedOrForgottenBindingAreRejected() {
        let h = Harness()
        defer { h.model.shutdown() }
        #expect(freshSample(h))
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: nil, keyFingerprint: nil)
        #expect(!freshSample(h, rssi: -40))
        #expect(!h.model.presence)
        #expect(h.model.reverseRuntime(for: h.phone) == nil)
    }

    @Test func staleFutureAndOutOfRangeSamplesAreRejected() {
        let h = Harness()
        defer { h.model.shutdown() }
        let sampledAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!h.model.acceptReversePresenceSample(
            clientID: "phone", keyFingerprint: "fp",
            primaryUUID: h.phone, rssi: -50, sampledAt: sampledAt,
            now: sampledAt.addingTimeInterval(RemoteBLEReversePresenceSample.maximumAge + 1)
        ))
        #expect(!h.model.acceptReversePresenceSample(
            clientID: "phone", keyFingerprint: "fp",
            primaryUUID: h.phone, rssi: -50, sampledAt: sampledAt,
            now: sampledAt.addingTimeInterval(-RemoteBLEReversePresenceSample.maximumFutureSkew - 1)
        ))
        #expect(!h.model.acceptReversePresenceSample(
            clientID: "phone", keyFingerprint: "fp",
            primaryUUID: h.phone, rssi: 5, sampledAt: Date()
        ))
        #expect(!h.model.presence)
        #expect(h.model.reverseRuntime(for: h.phone) == nil)
    }

    @Test func disabledFeatureToggleSleepAndBackgroundConsoleAllReject() {
        let toggledOff = Harness(reverseEnabled: false, explicitOptOut: true)
        defer { toggledOff.model.shutdown() }
        #expect(!freshSample(toggledOff))
        #expect(!toggledOff.model.presence)

        let sleeping = Harness()
        defer { sleeping.model.shutdown() }
        sleeping.model.handleSystemWillSleep()
        #expect(!freshSample(sleeping))
        #expect(!sleeping.model.presence)

        let background = Harness(onConsole: false)
        defer { background.model.shutdown() }
        background.model.setEnabled(false)
        background.model.setEnabled(true)
        #expect(!freshSample(background))
        #expect(!background.model.presence)

        let disabled = Harness()
        defer { disabled.model.shutdown() }
        disabled.model.setEnabled(false)
        #expect(!freshSample(disabled))
        #expect(!disabled.model.presence)
    }

    @Test func aCloseSampleStillNeedsTheExistingUnlockGate() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.settings.unlockRSSI = -55
        h.model.settings.wakeWithoutUnlocking = true
        #expect(freshSample(h))
        #expect(h.model.presence)
        #expect(!h.model.isUnlockAttemptScheduled)
        #expect(h.locks.isEmpty)
    }

    @Test func manualLockKeepsReversePresenceFromUnlocking() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.settings.unlockRSSI = -55
        h.model.lockNow()
        #expect(h.locks == [.localManual])

        #expect(freshSample(h))
        #expect(h.model.presence)
        #expect(h.locks == [.localManual])
        #expect(!h.model.isUnlockAttemptScheduled)
    }

    @Test func distantSamplesUseTheExistingProximityTimeout() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        #expect(freshSample(h, rssi: -50))
        #expect(h.model.presence)

        #expect(freshSample(h, rssi: -90))
        let away = try #require(h.proximityActions.last)
        #expect(away.delay == 5)
        h.now += 5
        away.action()
        #expect(!h.model.presence)
        #expect(h.locks == [.bleAutomatic])
    }

    @Test func signalTimeoutVerifiesThenDropsReversePresence() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        #expect(freshSample(h, rssi: -50))
        #expect(h.model.presence)

        h.now += 60
        h.model.handleReverseSignalTimeout(for: h.phone)
        let verification = try #require(h.signalActions.last)
        #expect(verification.delay == 240)
        #expect(h.model.presence, "A nearby signal loss gets one bounded verification window")

        h.now += 240
        verification.action()
        #expect(!h.model.presence)
        #expect(h.locks == [.bleAutomatic])
        #expect(h.model.reverseRuntime(for: h.phone)?.lastRSSI == nil)
    }

    @Test func bothDirectionsMergePerLogicalDeviceWithoutMixingRSSI() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        #expect(h.model.lastRSSI == -50)
        #expect(h.model.lastRSSISource == .legacy)

        #expect(freshSample(h, rssi: -70))
        #expect(h.model.lastRSSI == -50, "A reverse sample must not replace or average the legacy observation")
        #expect(h.model.lastRSSISource == .legacy)
        #expect(h.model.presence)

        h.now += 60
        h.model.handleReverseSignalTimeout(for: h.phone)
        let verification = h.signalActions.last
        h.now += 240
        verification?.action()
        #expect(h.model.presence, "Losing the reverse link must not tear down a healthy legacy link")
        #expect(h.model.lastRSSI == -50)
        #expect(h.model.lastRSSISource == .legacy)
        #expect(h.locks.isEmpty)
    }

    @Test func reverseFreshnessDoesNotSuppressLegacyMonitoringRecovery() async {
        let h = Harness()
        defer { h.model.shutdown() }
        // Disable the lock threshold so the timeout takes the plain
        // legacy-recovery branch instead of starting loss verification.
        h.model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        let delays = AsyncStream<TimeInterval>.makeStream()
        var sleepContinuation: CheckedContinuation<Void, Never>?
        h.model.monitoringRecoverySleep = { delay in
            await withCheckedContinuation { continuation in
                sleepContinuation = continuation
                delays.continuation.yield(delay)
            }
        }
        defer {
            sleepContinuation?.resume()
            delays.continuation.finish()
        }

        h.model.receiveMonitoredAdvertisement(-50, for: h.phone)
        #expect(freshSample(h, rssi: -50))
        #expect(h.model.presence)

        h.now += 60
        h.model.handleMonitoredSignalTimeout(for: h.phone)
        #expect(h.model.reverseRuntime(for: h.phone)?.lastRSSI == -50)

        var iterator = delays.stream.makeAsyncIterator()
        let firstDelay = await iterator.next()
        #expect(firstDelay == 3, "A fresh reverse link must not cancel legacy discovery recovery")
    }

    @Test func aDeviceRowFallsBackToTheAuthenticatedReverseSample() {
        let h = Harness()
        defer { h.model.shutdown() }

        #expect(freshSample(h, rssi: -57))
        #expect(h.model.deviceRSSI[h.phone] == -57)
        #expect(h.model.deviceRSSI[h.watch] == nil)

        // A live legacy observation keeps precedence, exactly like the header.
        h.model.receiveMonitoredAdvertisement(-51, for: h.phone)
        #expect(h.model.deviceRSSI[h.phone] == -51)
        #expect(freshSample(h, rssi: -40))
        #expect(h.model.deviceRSSI[h.phone] == -51)
    }

    @Test func reversePresenceSatisfiesAnyButStillNeedsTheOtherDeviceForAll() {
        let h = Harness()
        defer { h.model.shutdown() }
        h.model.settings.deviceRelation = .any
        #expect(freshSample(h))
        #expect(h.model.presence)

        h.model.setDeviceRelation(.all)
        #expect(!h.model.presence, "ALL still requires a live observation for the second logical device")

        h.model.receiveMonitoredAdvertisement(-50, for: h.watch)
        #expect(h.model.presence, "A fresh legacy signal for the watch completes the ALL relation")
    }

    @Test func productionStartsOnlyWithABindingAndStopsWithTheFeature() {
        let h = Harness(bindIdentity: false)
        defer { h.model.shutdown() }
        h.model.startMonitor(h.phone)
        #expect(h.peripheral.productionStarts.isEmpty)
        #expect(!h.peripheral.productionRunning)

        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "fp")
        #expect(h.peripheral.productionStarts == [h.macID])
        #expect(h.peripheral.productionRunning)

        h.model.setEnabled(false)
        #expect(!h.peripheral.productionRunning)
        #expect(h.model.reverseRuntime(for: h.phone) == nil)
    }

    @Test func bindingAPhoneTurnsOnReversePresenceByDefault() {
        let h = Harness(bindIdentity: false, reverseEnabled: false)
        defer { h.model.shutdown() }
        #expect(!h.model.settings.reverseGATTPresenceEnabled)
        #expect(h.peripheral.productionStarts.isEmpty)

        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "fp")
        #expect(h.model.settings.reverseGATTPresenceEnabled)
        #expect(h.peripheral.productionStarts == [h.macID])
        #expect(h.peripheral.productionRunning)
    }

    @Test func anExplicitOptOutSurvivesLaterBindings() {
        let h = Harness(bindIdentity: false, reverseEnabled: false)
        defer { h.model.shutdown() }
        h.model.setReverseGATTPresenceEnabled(false)
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "fp")
        #expect(!h.model.settings.reverseGATTPresenceEnabled, "A deliberate switch-off is not overridden")
        #expect(h.peripheral.productionStarts.isEmpty)

        h.model.setReverseGATTPresenceEnabled(true)
        #expect(h.peripheral.productionStarts == [h.macID])

        h.model.setReverseGATTPresenceEnabled(false)
        #expect(!h.peripheral.productionRunning)
        #expect(h.model.reverseRuntime(for: h.phone) == nil)
    }

    @Test func reverseTimersAreDiscardedWhenMonitoringStops() throws {
        let h = Harness()
        defer { h.model.shutdown() }
        #expect(freshSample(h))
        let runtime = try #require(h.model.reverseRuntime(for: h.phone))
        h.model.setEnabled(false)
        #expect(h.model.reverseRuntime(for: h.phone) == nil)
        #expect(runtime.signalTimer == nil)
        #expect(runtime.proximityTimer == nil)
        #expect(!h.model.presence)
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        var now: TimeInterval = 100
        let phone = UUID()
        let watch = UUID()
        let macID = UUID()
        let key = Data(repeating: 7, count: 32)
        let scanner = Scanner()
        let peripheral = RecordingPeripheral()
        var model: BLEUnlockModel!
        var locks: [ScreenControlSource] = []
        var signalActions: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
        var proximityActions: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

        init(bindIdentity: Bool = true, reverseEnabled: Bool = true, onConsole: Bool = true, explicitOptOut: Bool = false) {
            model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(uptime: { [weak self] in self?.now ?? 0 }, observesEvents: false),
                bluetoothScanner: scanner,
                eventScriptRunner: { _ in }
            )
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .unlocked }
            model.lockScreenOperation = { [weak self] in self?.locks.append($0) }
            model.settings.isEnabled = true
            model.settings.deviceRelation = .any
            model.settings.signalTimeout = 60
            model.settings.proximityTimeout = 5
            model.settings.lockRSSI = -80
            model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
            model.settings.reverseGATTPresenceEnabled = reverseEnabled
            model.settings.reverseGATTPresenceExplicitlyDisabled = explicitOptOut
            model.settings.pauseNowPlaying = false
            model.reversePresencePeripheralOverride = peripheral
            model.sessionOnConsoleProbe = { onConsole }
            model.remoteOwnDeviceIDProvider = { [macID] in macID }
            model.remotePairingKeyProvider = { [key] clientID in clientID == "phone" ? key : nil }
            model.signalTimeoutScheduler = { [weak self] delay, action in
                self?.signalActions.append((delay, action))
                return BackgroundTask.once(after: 3_600) {}
            }
            model.proximityTimeoutScheduler = { [weak self] delay, action in
                self?.proximityActions.append((delay, action))
                return BackgroundTask.once(after: 3_600) {}
            }
            model.secondaryMonitoredUUID = watch
            model.startMonitor(phone)
            if bindIdentity {
                model.bindRemoteIdentity(primaryUUID: phone, clientID: "phone", keyFingerprint: "fp")
            }
        }
    }

    @MainActor
    private final class RecordingPeripheral: ProximityBLEPeripheral {
        var productionStarts: [UUID] = []
        private(set) var productionStops = 0
        private(set) var productionRunning = false

        override func startProduction(macDeviceID: UUID) {
            productionStarts.append(macDeviceID)
            productionRunning = true
        }

        override func stopProduction() {
            productionStops += 1
            productionRunning = false
        }
    }

    @MainActor
    private final class Scanner: BluetoothScanning {
        var central: CBCentralManager? {
            get { nil }
            set {}
        }
        func createIfNeeded(delegate: CBCentralManagerDelegate) {}
        func startIfPoweredOn() -> Bool { true }
        func restartIfPoweredOn() -> Bool { true }
        func stop() {}
        func release() {}
    }
}
