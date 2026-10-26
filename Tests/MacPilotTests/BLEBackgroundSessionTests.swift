import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEBackgroundSessionTests {
    @Test func aBackgroundSessionDoesNotStartMonitoringOrScanningAtLaunch() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true

        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        h.model.handleCentralStateChange(.poweredOn)

        #expect(h.model.diagnosticObserverCount > 0, "Observers must stay installed so the return can resume BLE")
        #expect(h.model.runtime(for: h.phone) == nil)
        #expect(h.scanner.starts == 0)
    }

    @Test func returningToTheConsoleResumesMonitoringAfterABackgroundLaunch() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        #expect(h.model.runtime(for: h.phone) == nil)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()
        h.model.handleCentralStateChange(.poweredOn)

        #expect(h.model.runtime(for: h.phone) != nil)
        #expect(h.model.diagnosticTaskCount > 0)
    }

    @Test func leavingTheConsoleReleasesTheCentralAndItsConnections() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        #expect(h.model.runtime(for: h.phone) != nil)

        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()

        #expect(h.model.runtime(for: h.phone) == nil)
        #expect(h.scanner.releases == 1)
        #expect(!h.model.presence)
        #expect(h.model.diagnosticTaskCount == 0)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()
        h.model.handleCentralStateChange(.poweredOn)
        #expect(h.model.runtime(for: h.phone) != nil)
        #expect(h.scanner.releases == 1, "Returning to the console must recreate, not release, the central")
    }

    @Test func aBackgroundSessionCannotLockTheActiveUsersScreen() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()

        h.model.lockNow()

        #expect(h.locks.isEmpty)
    }

    @Test func theDevicePickerResumesAfterReturningToTheConsole() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startScanning()
        #expect(h.model.isScanning)

        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()
        #expect(!h.model.isScanning)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()

        #expect(h.model.isScanning)
        #expect(h.scanner.duplicateModes == [true, false, true])
    }

    @Test func theIdentityLearnerKeepsLearningWhileTheSessionIsSuspended() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.bluetoothAuthorizationProbe = { .allowedAlways }
        h.model.remoteOwnDeviceIDProvider = { UUID() }
        h.model.remotePairingKeyProvider = { _ in Data([1, 2, 3]) }
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "fp")
        #expect(h.model.identityLearnerActive)

        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()

        // Monitoring and its central are gone, but the passive learner keeps
        // its own radio so rotated addresses are still learned in background.
        #expect(h.model.runtime(for: h.phone) == nil)
        #expect(h.scanner.releases == 1)
        #expect(h.model.identityLearnerActive)

        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()
        h.model.handleCentralStateChange(.poweredOn)
        #expect(h.model.identityLearnerActive)
    }

    @Test func theIdentityLearnerNeverPromptsOnAFreshInstall() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.bluetoothAuthorizationProbe = { .notDetermined }
        h.model.remoteOwnDeviceIDProvider = { UUID() }
        h.model.remotePairingKeyProvider = { _ in Data([1, 2, 3]) }
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        h.model.bindRemoteIdentity(primaryUUID: h.phone, clientID: "phone", keyFingerprint: "fp")

        // A binding alone must not create the learner's radio while Bluetooth
        // access is undecided; enabling BLE (creating the central) is the
        // consent moment.
        #expect(!h.model.identityLearnerActive)
    }

    @Test func suspensionCauseDistinguishesTheLoginWindowFromAnotherUser() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)

        h.model.consoleUserNameProbe = { "agentuse" }
        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()
        #expect(!h.model.suspendedAtLoginWindow)

        // The console session logs out; the screen shows the login window.
        h.model.consoleUserNameProbe = { "loginwindow" }
        h.onConsoleFlag = true
        h.model.handleSessionDidBecomeActive()
        h.onConsoleFlag = false
        h.model.handleSessionDidResignActive()
        #expect(h.model.suspendedAtLoginWindow)
    }

    @Test func backgroundSessionSuspensionIsVisibleToTheUI() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()

        // A background session never creates a central, so bluetoothPoweredOn
        // stays false; the UI must read the suspension flag, not the radio.
        #expect(h.model.suspendedForBackgroundSession)
        #expect(!h.model.bluetoothPoweredOn)

        h.onConsoleFlag = true
        h.model.evaluateConsoleOwnership()
        #expect(!h.model.suspendedForBackgroundSession)
    }

    @Test func consoleOwnershipPollSuspendsMonitoringWhenTheResignNotificationNeverArrived() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        #expect(h.model.runtime(for: h.phone) != nil)

        // A console switch whose NSWorkspace notification never arrives must
        // still suspend monitoring once the ownership poll catches it.
        h.onConsoleFlag = false
        h.model.evaluateConsoleOwnership()

        #expect(h.model.runtime(for: h.phone) == nil)
        #expect(h.scanner.releases == 1)
    }

    @Test func consoleOwnershipPollResumesMonitoringWhenTheBecomeActiveNotificationNeverArrived() {
        let h = Harness(onConsole: false)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        #expect(h.model.runtime(for: h.phone) == nil)

        h.onConsoleFlag = true
        h.model.evaluateConsoleOwnership()
        h.model.handleCentralStateChange(.poweredOn)

        #expect(h.model.runtime(for: h.phone) != nil)
    }

    @Test func aRecentScanAttemptStillExpectsAdvertisementCallbacks() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        h.model.handleCentralStateChange(.poweredOn)

        // The fake scanner has no central, so `isScanning` can never be true;
        // only a fresh scan attempt can make the watchdog expect callbacks.
        h.model.lastScanAttemptAt = Date()
        #expect(h.model.advertisementCallbacksExpected)

        h.model.lastScanAttemptAt = Date(timeIntervalSinceNow: -3_600)
        #expect(!h.model.advertisementCallbacksExpected)
    }

    @Test func prolongedSilenceRebuildsTheBLEClientOncePerEscalationWindow() {
        let h = Harness(onConsole: true)
        defer { h.model.shutdown() }
        h.model.settings.isEnabled = true
        h.model.activateFromConfiguration()
        h.model.startMonitor(h.phone)
        h.model.handleCentralStateChange(.poweredOn)

        // Silence far beyond three thresholds with monitoring active: the
        // watchdog must escalate from scan restarts to a full client rebuild.
        h.model.advertisementLiveness = BLEAdvertisementLiveness(
            silenceThreshold: 600,
            now: Date(timeIntervalSinceNow: -2_400)
        )
        h.model.lastScanAttemptAt = Date()

        h.model.evaluateAdvertisementLiveness()
        // The trip escalates straight through the rebuild, whose stopMonitoring
        // resets the published stall flag — the release is the observable proof.
        #expect(h.scanner.releases == 1)

        // The same silence window must not pay for a second rebuild.
        h.model.advertisementLiveness = BLEAdvertisementLiveness(
            silenceThreshold: 600,
            now: Date(timeIntervalSinceNow: -2_400)
        )
        h.model.evaluateAdvertisementLiveness()
        #expect(h.scanner.releases == 1)
    }

    @MainActor
    private final class Harness {
        let phone = UUID()
        let scanner = Scanner()
        var onConsoleFlag: Bool
        var model: BLEUnlockModel!
        var locks: [ScreenControlSource] = []

        init(onConsole: Bool) {
            onConsoleFlag = onConsole
            let scanner = self.scanner
            model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(uptime: { 1_000 }, observesEvents: false),
                bluetoothScanner: scanner,
                eventScriptRunner: { _ in }
            )
            model.sessionOnConsoleProbe = { [weak self] in self?.onConsoleFlag ?? true }
            model.workspaceNotificationCenterOverride = NotificationCenter()
            model.heldBlankNotificationCenterOverride = NotificationCenter()
            model.screenStateNotificationCenterOverride = NotificationCenter()
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .unlocked }
            model.lockScreenOperation = { [weak self] in self?.locks.append($0) }
            model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
            model.settings.pauseNowPlaying = false
            model.signalTimeoutScheduler = { _, _ in BackgroundTask.once(after: 3_600) {} }
            model.proximityTimeoutScheduler = { _, _ in BackgroundTask.once(after: 3_600) {} }
        }
    }

    @MainActor
    private final class Scanner: BluetoothScanning {
        var central: CBCentralManager? {
            get { nil }
            set {}
        }
        var starts = 0
        var restarts = 0
        var releases = 0
        var duplicateModes: [Bool] = []

        func createIfNeeded(delegate: CBCentralManagerDelegate) {}
        func startIfPoweredOn() -> Bool { starts += 1; return true }
        func restartIfPoweredOn() -> Bool { restarts += 1; return true }
        func stop() {}
        func release() { releases += 1 }
        func setAllowsDuplicateAdvertisements(_ allowed: Bool) { duplicateModes.append(allowed) }
    }
}
