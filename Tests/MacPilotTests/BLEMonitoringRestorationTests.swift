import AppKit
import CoreBluetooth
import Foundation
import Testing
@testable import MacPilot

@MainActor
struct BLEMonitoringRestorationTests {
    @Test func anIdleUserMustNotPauseMonitoringNeededForProximityLock() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        // Even a broken presence path can never lock or type into the real screen.
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = -80
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)

        now = 131
        model.evaluateUserActivityPolicy()

        #expect(!model.activeConnectionsPaused, "No keyboard input cannot stop the connection that determines whether the phone has left")
        #expect(model.presence)
        // A genuinely silent phone must still become absent; do not fix this
        // by indefinitely trusting the previous close sample.
        model.handleMonitoredSignalTimeout(for: phone)
        #expect(!model.presence)
    }

    @Test func eachBoundDevicePublishesItsOwnSignalForTheDeviceRows() throws {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner(),
            eventScriptRunner: { _ in }
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .unlocked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled

        let phone = UUID()
        let watch = UUID()
        model.secondaryMonitoredUUID = watch
        model.startMonitor(phone)

        model.updateMonitoredPeripheral(-50, for: phone)
        model.updateMonitoredPeripheral(-72, for: watch)

        #expect(model.deviceRSSI[phone] == -50)
        #expect(model.deviceRSSI[watch] == -72)
        #expect(model.lastRSSI == -50, "The header gauge keeps the strongest aggregate sample")

        model.updateMonitoredPeripheral(-88, for: phone)
        let phoneRSSI = try #require(model.runtime(for: phone)?.lastRSSI)
        #expect(model.deviceRSSI[phone] == phoneRSSI)
        #expect(model.deviceRSSI[watch] == model.runtime(for: watch)?.lastRSSI)
        #expect(model.deviceRSSI[phone] != model.deviceRSSI[watch])

        model.setEnabled(false)
        #expect(model.deviceRSSI.isEmpty)
    }

    @Test func enablingProximityLockWhileIdleResumesMonitoringButCannotWakeABlankedDisplay() {
        var now: TimeInterval = 100
        var isBlanked = false
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        model.displayUnavailableProbe = { isBlanked }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.startObservingSystemState()
        model.startMonitor(UUID())
        now = 131
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)

        model.setLockRSSI(-80)
        #expect(!model.activeConnectionsPaused)
        isBlanked = true
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused, "Keeping proximity monitoring must still respect display sleep without proximity wake")
        isBlanked = false
        model.evaluateUserActivityPolicy()
        #expect(!model.activeConnectionsPaused)
        model.setLockRSSI(BLEUnlockModel.lockDisabled)
        #expect(model.activeConnectionsPaused, "Unlock-only mode retains its finite activity policy")
    }

    @Test func aWakeNotificationCannotAuthorizeUnlockBeforeAnyPhoneSignal() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        let center = NotificationCenter()
        model.workspaceNotificationCenterOverride = center
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        model.startMonitor(UUID())

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        #expect(model.lastRSSI == nil)
        #expect(!model.isUnlockAttemptScheduled, "A bound phone without a fresh signal must not authorize a password attempt")
    }

    @Test func firstFreshNearbySignalCanUnlockASingleBoundPhoneWithoutAPresenceEdge() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        #expect(!model.isUnlockAttemptScheduled, "Binding alone cannot authorize typing")

        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(model.isUnlockAttemptScheduled, "A fresh close sample must trigger unlock even if presence was already true")
    }

    @Test func disabledAndWakeOnlyUnlockModesSkipScreenLockProbe() {
        var screenLockProbeCount = 0
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner(),
            eventScriptRunner: { _ in }
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = {
            screenLockProbeCount += 1
            return .unlocked
        }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        let phone = UUID()
        model.startMonitor(phone)

        for _ in 0..<10 { model.updateMonitoredPeripheral(-50, for: phone) }
        #expect(screenLockProbeCount == 0, "Disabled automatic unlock does not need a system screen-state query")

        model.settings.unlockRSSI = -70
        model.settings.wakeWithoutUnlocking = true
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(screenLockProbeCount == 0, "Wake-only mode skips the unlock screen-state query")

        model.settings.wakeWithoutUnlocking = false
        model.updateMonitoredPeripheral(-80, for: phone)
        #expect(screenLockProbeCount == 0, "A distant signal skips the unlock screen-state query")
        #expect(!model.isUnlockAttemptScheduled)
    }

    @Test func latchedCycleObservesUnlockDuringIneligibleSignalAndAllowsANewLock() {
        var screenLockProbeCount = 0
        var screenState = BLEScreenLockState.unlocked
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner(),
            eventScriptRunner: { _ in }
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = {
            screenLockProbeCount += 1
            return screenState
        }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        screenLockProbeCount = 0

        // Seed a previous lock cycle without starting real unlock work.
        model.unlockSignalTrigger.noteScheduled()
        model.updateMonitoredPeripheral(-80, for: phone)
        #expect(screenLockProbeCount == 1, "A latched cycle still observes an ineligible signal to detect an unlock")
        #expect(!model.unlockSignalTrigger.hasScheduledForLock)
        #expect(!model.isUnlockAttemptScheduled)

        screenState = .locked
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(screenLockProbeCount == 2, "An eligible signal checks the actual screen state last")
        #expect(model.isUnlockAttemptScheduled, "A newly observed lock can schedule an unlock after the prior cycle cleared")
    }

    @Test func freshSignalCannotUndoAnExplicitManualOrRemoteLock() {
        for source in [ScreenControlSource.localManual, .remoteExplicit] {
            let model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
                bluetoothScanner: RecordingBluetoothScanner()
            )
            defer { model.shutdown() }
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { .locked }
            model.settings.isEnabled = true
            model.settings.lockRSSI = BLEUnlockModel.lockDisabled
            model.settings.unlockRSSI = -70
            let phone = UUID()
            model.startMonitor(phone)
            // Invoke attribution only, without locking a screen or posting keys.
            model.screenControl.willLock?(source)
            model.updateMonitoredPeripheral(-50, for: phone)
            #expect(!model.isUnlockAttemptScheduled)
        }
    }

    @Test func anAlreadyNearbyPhoneCanTriggerUnlockAfterTheSessionLocks() {
        var state = BLEScreenLockState.unlocked
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { state }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled)

        state = .locked
        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(model.isUnlockAttemptScheduled, "Unlock must not require the phone to leave and return after locking")
    }

    @Test func bindingAndAWeakOrUnlockedSampleDoNotAuthorizeUnlock() {
        for state in [BLEScreenLockState.locked, .unlocked, .unknown] {
            let model = BLEUnlockModel(
                userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
                bluetoothScanner: RecordingBluetoothScanner()
            )
            defer { model.shutdown() }
            model.displayUnavailableProbe = { false }
            model.screenLockStateProbe = { state }
            model.settings.isEnabled = true
            model.settings.lockRSSI = BLEUnlockModel.lockDisabled
            model.settings.unlockRSSI = -70
            let phone = UUID()
            model.startMonitor(phone)
            #expect(!model.isUnlockAttemptScheduled)
            model.updateMonitoredPeripheral(state == .locked ? -90 : -50, for: phone)
            #expect(!model.isUnlockAttemptScheduled)
        }
    }

    @Test func freshSignalAfterTenSecondsOfLockedWakeStillSchedulesUnlock() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        let center = NotificationCenter()
        model.workspaceNotificationCenterOverride = center
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        now = 131
        model.evaluateUserActivityPolicy()
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!model.presence, "Wake requires a fresh signal")

        now = 142
        model.evaluateUserActivityPolicy()
        model.updateMonitoredPeripheral(-50, for: phone)

        #expect(!model.activeConnectionsPaused, "The lock screen cannot rely on NSEvent input to keep reconnecting")
        #expect(model.isUnlockAttemptScheduled, "The ten-second discovery deadline must not cancel later unlock retries")
    }

    @Test func lockedWakeRecoveryExpiresAndDuplicateWakesCannotExtendIt() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        let center = NotificationCenter()
        model.workspaceNotificationCenterOverride = center
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        model.startMonitor(UUID())
        now = 131
        model.evaluateUserActivityPolicy()
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        now = 131 + BLEUserActivityMonitor.unlockRecoveryWakeGrace - 1
        model.evaluateUserActivityPolicy()
        #expect(!model.activeConnectionsPaused)
        now += 1
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(model.activeConnectionsPaused, "A repeated notification must not keep Bluetooth active indefinitely")
    }

    @Test func displayWakePreemptsAnOlderSignalTimeoutRecovery() {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        // This timeout exercises recovery, never the user's real lock screen.
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.startObservingSystemState()
        let monitored = UUID()
        model.startMonitor(monitored)
        model.handleMonitoredSignalTimeout(for: monitored)
        let resetsBeforeWake = scanner.centralResets
        let scansBeforeWake = scanner.scanRestarts
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        #expect(scanner.scanRestarts == scansBeforeWake + 1, "An earlier recovery must not defer the wake scan")
        #expect(scanner.centralResets == resetsBeforeWake)
    }

    @Test func manualDisplayUnblankImmediatelyRestartsDiscovery() {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        var isBlanked = false
        let blankCenter = NotificationCenter()
        model.displayUnavailableProbe = { isBlanked }
        model.heldBlankNotificationCenterOverride = blankCenter
        model.settings.isEnabled = true
        model.startObservingSystemState()
        model.startMonitor(UUID())
        isBlanked = true
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)
        #expect(scanner.scanRestarts == 0)

        isBlanked = false
        blankCenter.post(name: DisplayPower.blankStateDidChangeNotification, object: nil)

        #expect(scanner.scanRestarts == 1)
        #expect(scanner.centralResets == 0)
        #expect(!model.activeConnectionsPaused)
    }

    @Test func displayWakeImmediatelyRestartsScanningWithoutReplacingTheCentral() {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()
        let monitored = UUID()
        model.startMonitor(monitored)
        model.updateMonitoredPeripheral(-50, for: monitored)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        #expect(scanner.scanRestarts == 1, "Discovery must restart synchronously on display wake")
        #expect(scanner.centralResets == 0, "The reconnect must keep its CoreBluetooth session")
        #expect(!model.presence, "Pre-wake RSSI must not authorize unlock")
        #expect(!model.isUnlockAttemptScheduled)

        model.updateMonitoredPeripheral(-50, for: monitored)
        #expect(model.presence)
        #expect(model.isUnlockAttemptScheduled, "Fresh nearby signal must resume automatic unlock")
    }

    @Test func displayWakeScanRetriesPreserveTheCentralAndStopAfterFreshSignal() async {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(uptime: { 100 }, observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        let delays = AsyncStream<TimeInterval>.makeStream()
        var sleepContinuation: CheckedContinuation<Void, Never>?
        model.monitoringRecoverySleep = { delay in
            await withCheckedContinuation { continuation in
                sleepContinuation = continuation
                delays.continuation.yield(delay)
            }
        }
        defer {
            sleepContinuation?.resume()
            delays.continuation.finish()
        }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()
        let monitored = UUID()
        model.startMonitor(monitored)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        var delayIterator = delays.stream.makeAsyncIterator()
        let firstDelay = await delayIterator.next()
        #expect(firstDelay == 3)
        sleepContinuation?.resume()
        sleepContinuation = nil
        let secondDelay = await delayIterator.next()
        #expect(secondDelay == 7)
        #expect(scanner.scanRestarts == 2)
        #expect(scanner.centralResets == 0, "The three-second retry must not cancel a pending connection")
        let taskCount = model.diagnosticTaskCount
        model.updateMonitoredPeripheral(-50, for: monitored)
        #expect(model.presence)
        // Fresh RSSI cancels the remaining ten-second scan retry immediately.
        #expect(model.diagnosticTaskCount == taskCount - 1)
    }

    @Test func preWakeTimeoutCallbacksCannotCancelAColdReconnectOrClearANewSignal() throws {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        var timeouts: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
        model.signalTimeoutScheduler = { delay, action in
            timeouts.append((delay, action))
            return BackgroundTask()
        }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        model.settings.signalTimeout = 30
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)
        let preSleepTimeout = try #require(timeouts.last)
        #expect(preSleepTimeout.delay == 30)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        let wakeTimeout = try #require(timeouts.last)
        #expect(wakeTimeout.delay >= BLEConnectionRetryGate.connectionTimeout)
        #expect(!model.presence)
        preSleepTimeout.action()
        #expect(scanner.centralResets == 0, "An overdue pre-sleep callback must not replace the wake session")
        model.updateMonitoredPeripheral(-50, for: phone)
        #expect(model.presence)
        #expect(timeouts.last?.delay == 30, "A fresh sample returns to the configured freshness limit")
        wakeTimeout.action()
        #expect(model.presence, "The replaced wake timer must not discard newly received RSSI")
        #expect(scanner.centralResets == 0)
    }

    @Test func signalTimeoutRecoveryAndBothScanRetriesPreserveTheExistingSession() async {
        let scanner = RecordingBluetoothScanner()
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: scanner
        )
        defer { model.shutdown() }
        model.displayUnavailableProbe = { false }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.settings.unlockRSSI = BLEUnlockModel.unlockDisabled
        let delays = AsyncStream<TimeInterval>.makeStream()
        let scans = AsyncStream<Int>.makeStream()
        var sleepContinuation: CheckedContinuation<Void, Never>?
        model.monitoringRecoverySleep = { delay in
            await withCheckedContinuation { continuation in
                sleepContinuation = continuation
                delays.continuation.yield(delay)
            }
        }
        scanner.onScanRestart = { scans.continuation.yield(scanner.scanRestarts) }
        defer {
            sleepContinuation?.resume()
            delays.continuation.finish()
            scans.continuation.finish()
            scanner.onScanRestart = nil
        }
        let phone = UUID()
        model.startMonitor(phone)
        model.handleMonitoredSignalTimeout(for: phone)
        #expect(scanner.centralResets == 0)
        var delayIterator = delays.stream.makeAsyncIterator()
        let firstDelay = await delayIterator.next()
        #expect(firstDelay == 3)
        sleepContinuation?.resume()
        sleepContinuation = nil
        let secondDelay = await delayIterator.next()
        #expect(secondDelay == 7)
        #expect(scanner.centralResets == 0, "The three-second retry must preserve the cold connection")
        sleepContinuation?.resume()
        sleepContinuation = nil
        var scanIterator = scans.stream.makeAsyncIterator()
        let firstScan = await scanIterator.next()
        let secondScan = await scanIterator.next()
        #expect(firstScan == 1)
        #expect(secondScan == 2)
        #expect(scanner.centralResets == 0, "The ten-second retry must also preserve the session")
    }

    @Test func absentSecondaryDoesNotResetAFreshPrimaryInAnyDeviceMode() {
        let primary = UUID()
        let secondary = UUID()
        let model = BLEUnlockModel(userActivityMonitor: BLEUserActivityMonitor(observesEvents: false))
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
        #expect(!BLEActiveConnectionPolicy.shouldPauseForUserInactivity(
            wakeOnProximity: true,
            userIsActive: false
        ))
    }

    @Test func startupAndRecentInputPreventIdlePauseUntilThirtySecondsPass() {
        var now: TimeInterval = 100
        let monitor = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        monitor.start()
        #expect(monitor.isUserActive(at: 129.9))
        #expect(!monitor.isUserActive(at: 130))

        monitor.recordInput(at: 140)
        #expect(monitor.isUserActive(at: 169.9))
        #expect(!monitor.isUserActive(at: 170))
        now = 171
        #expect(!monitor.isUserActive(at: now))
        monitor.stop()
        now = 200
        monitor.start()
        #expect(monitor.isUserActive(at: 229.9), "Re-enabling BLE starts a fresh grace window")
    }

    @Test func idleModelCancelsUnlockAndObservedInputResumesIt() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity, bluetoothScanner: RecordingBluetoothScanner())
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()
        #expect(activity.isMonitoring)
        let monitored = UUID()
        model.startMonitor(monitored)
        model.updateMonitoredPeripheral(-50, for: monitored)
        model.updatePresence(presence: true, reason: "test-before-idle")
        #expect(model.isUnlockAttemptScheduled)

        now = 131
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        #expect(!model.isUnlockAttemptScheduled)

        model.handleMonitoredSignalTimeout(for: monitored)
        model.updateMonitoredPeripheral(-50, for: monitored)
        #expect(model.presence)
        #expect(!model.isUnlockAttemptScheduled, "A new presence edge during idle must not schedule unlock")

        model.recordUserInput(at: now)
        #expect(!model.activeConnectionsPaused)
        #expect(model.isUnlockAttemptScheduled)

        let taskCountBeforeObserverStop = model.diagnosticTaskCount
        model.stopObservingSystemState()
        #expect(!activity.isMonitoring)
        #expect(model.diagnosticTaskCount < taskCountBeforeObserverStop)
    }

    @Test func repeatedDisplayWakeNotificationsCannotRenewIdleAllowance() {
        var now: TimeInterval = 100
        let activity = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        let model = BLEUnlockModel(userActivityMonitor: activity)
        defer { model.shutdown() }
        let workspaceCenter = NotificationCenter()
        model.workspaceNotificationCenterOverride = workspaceCenter
        model.displayUnavailableProbe = { false }
        model.screenLockStateProbe = { .unlocked }
        model.settings.isEnabled = true
        model.settings.lockRSSI = BLEUnlockModel.lockDisabled
        model.startObservingSystemState()

        now = 131
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!model.activeConnectionsPaused, "A real sleep/wake transition gets one short allowance")

        now = 141
        model.evaluateUserActivityPolicy()
        #expect(model.activeConnectionsPaused)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(model.activeConnectionsPaused, "A second wake in this idle epoch cannot renew the allowance")

        model.recordUserInput(at: now)
        #expect(!model.activeConnectionsPaused, "Real input restores the active connection policy")
    }

    @Test func displayWakeAllowanceIsFiniteAndCannotRenewUntilActualInput() {
        var now: TimeInterval = 100
        let monitor = BLEUserActivityMonitor(uptime: { now }, observesEvents: false)
        monitor.start()
        now = 131
        #expect(!monitor.isUserActive(at: now))

        monitor.noteDisplayWake(fromSleep: true)
        #expect(monitor.isUserActive(at: now))
        now = 141
        #expect(!monitor.isUserActive(at: now))
        monitor.noteDisplayWake(fromSleep: true)
        #expect(!monitor.isUserActive(at: now), "Repeated wake notifications must not extend the allowance")

        monitor.recordInput(at: now)
        now = 172
        #expect(!monitor.isUserActive(at: now))
        monitor.noteDisplayWake(fromSleep: true)
        #expect(monitor.isUserActive(at: now), "Actual input begins a new idle epoch")
    }

    @Test func noOpPointerAndMarkedUnlockEventsDoNotCountAsUserInput() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let noOp = try #require(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
        #expect(!BLEUserActivityMonitor.isGenuineUserInput(try #require(NSEvent(cgEvent: noOp))))

        let movement = try #require(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
        movement.setDoubleValueField(.mouseEventDeltaX, value: 1)
        #expect(BLEUserActivityMonitor.isGenuineUserInput(try #require(NSEvent(cgEvent: movement))))

        let synthetic = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        BLEUserActivityMonitor.markAutomaticUnlockEvent(synthetic)
        #expect(!BLEUserActivityMonitor.isGenuineUserInput(try #require(NSEvent(cgEvent: synthetic))))
    }

    @Test func heldBlankNotificationPausesConnectionsCancelsUnlockAndResumesOnUnblank() {
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        var isBlanked = false
        let blankCenter = NotificationCenter()
        model.displayUnavailableProbe = { isBlanked }
        model.screenLockStateProbe = { .locked }
        model.heldBlankNotificationCenterOverride = blankCenter
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        model.startObservingSystemState()
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)

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
        let model = BLEUnlockModel(
            userActivityMonitor: BLEUserActivityMonitor(observesEvents: false),
            bluetoothScanner: RecordingBluetoothScanner()
        )
        defer { model.shutdown() }
        var displayUnavailable = true
        model.displayUnavailableProbe = { displayUnavailable }
        model.screenLockStateProbe = { .locked }
        model.settings.isEnabled = true
        model.settings.unlockRSSI = -70
        let phone = UUID()
        model.startMonitor(phone)
        model.updateMonitoredPeripheral(-50, for: phone)
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
        let model = BLEUnlockModel(userActivityMonitor: BLEUserActivityMonitor(observesEvents: false))
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

@MainActor
private final class RecordingBluetoothScanner: BluetoothScanning {
    var central: CBCentralManager? {
        get { nil }
        set { centralResets += 1 }
    }
    private(set) var scanRestarts = 0
    private(set) var centralResets = 0
    var onScanRestart: (() -> Void)?
    func createIfNeeded(delegate: CBCentralManagerDelegate) {}
    func startIfPoweredOn() -> Bool { true }
    func restartIfPoweredOn() -> Bool {
        scanRestarts += 1
        onScanRestart?()
        return true
    }
    func stop() {}
    func release() {}
}
