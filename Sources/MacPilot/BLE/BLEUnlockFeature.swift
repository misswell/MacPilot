import AppKit
import ApplicationServices
import CoreBluetooth
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Security
import SystemConfiguration

nonisolated(unsafe) private let deviceInformationUUID = CBUUID(string: "180A")
nonisolated(unsafe) private let manufacturerNameUUID = CBUUID(string: "2A29")
nonisolated(unsafe) private let modelNameUUID = CBUUID(string: "2A24")
nonisolated(unsafe) private let exposureNotificationUUID = CBUUID(string: "FD6F")

// MARK: - Model

@MainActor
final class BLEUnlockModel: NSObject, ObservableObject, ManagedFeature, FeatureResourceReporting, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    let identifier = "ble"
    var isRunning: Bool { !observers.isEmpty }
    var diagnosticTaskCount: Int {
        [deviceRefreshTask != nil, wakeRetryTask != nil, systemWakeRecoveryTask != nil,
         monitoringRecoveryTask != nil, unlockAttemptTask != nil].filter { $0 }.count
            + [scanCleanupTimer, livenessTimer, monitoringDiscoveryTimer, mediaResumeTask, screenUnlockConfirmationTask, userActivityPolicyTimer]
                .filter { $0?.isRunning == true }.count
    }
    var diagnosticObserverCount: Int { observers.count }
    func start() { activateFromConfiguration() }
    func stop() { deactivateFromConfiguration() }
    static let unlockDisabled = 1
    static let lockDisabled = -100
    private static let maximumVisibleDevices = 100
    private static let deviceRefreshInterval: Duration = .milliseconds(200)
    static let rssiOptions: [Int] = Array(stride(from: -30, to: -100, by: -5))
    static let lockDelayOptions: [Int] = [2, 5, 15, 30, 60, 120, 300]
    static let timeoutOptions: [Int] = [30, 60, 120, 300, 600]

    var persist: (@MainActor () -> Void)?

    /// Shared screen control owner. BLE proximity policy lives here; the actual
    /// locking, display power, credential and key-event work lives in the
    /// service so the iPhone remote control reuses the exact same code.
    let screenControl = MacScreenControlService()

    private let userActivityMonitor: BLEUserActivityMonitor
    private let eventScriptRunner: (@MainActor (String) -> Void)?
    private var userActivityPolicyTimer: BackgroundTask?

    init(
        userActivityMonitor: BLEUserActivityMonitor = BLEUserActivityMonitor(),
        bluetoothScanner: any BluetoothScanning = BluetoothScanner(),
        eventScriptRunner: (@MainActor (String) -> Void)? = nil
    ) {
        self.userActivityMonitor = userActivityMonitor
        self.bluetoothScanner = bluetoothScanner
        self.eventScriptRunner = eventScriptRunner
        super.init()
        screenControl.willLock = { [weak self] source in
            guard let self else { return }
            self.pendingLockSource = source.historySource
            self.pendingLockSourceExpiresAt = Date().addingTimeInterval(
                MacScreenControlService.lockAttributionWindow
            )
            // A remote or manual lock outranks the proximity auto-unlock: the
            // paired iPhone may still be sitting right next to the Mac.
            if ScreenControlSuppressionPolicy.suppressesAutomaticUnlock(source: source) {
                self.suppressAutomaticUnlock(reason: "lock-\(source.rawValue)")
            }
        }
        screenControl.didUnlock = { [weak self] source, date in
            guard let self else { return }
            self.recordScreenUnlock(at: date, source: source.historySource)
            if ScreenControlSuppressionPolicy.clearsAutomaticUnlockSuppression(source: source) {
                self.manualLock = false
            }
        }
    }

    // Runtime state published for the UI.
    @Published private(set) var devices: [BLEUnlockDevice] = []
    @Published private(set) var presence = false
    @Published private(set) var lastRSSI: Int?
    /// Latest trusted RSSI for each configured logical device. The header
    /// gauge keeps the aggregate value; these per-device samples let each
    /// bound-device row show which one is actually in range.
    @Published private(set) var deviceRSSI: [UUID: Int] = [:]
    /// Which link produced `lastRSSI`. The two directions never share an
    /// average; this only labels the freshest trusted sample for display.
    @Published private(set) var lastRSSISource: BLEPresenceSignalSource = .none
    @Published private(set) var reverseLinkActive = false
    @Published private(set) var connected = false
    @Published private(set) var activeMode = false
    @Published private(set) var bluetoothPoweredOn = false
    @Published private(set) var bluetoothPowerWarned = false
    @Published private(set) var isScanning = false
    /// True after prolonged silence during active monitoring. This is a
    /// symptom requiring recovery, not a diagnosis of the system or peers.
    @Published private(set) var advertisementStreamStalled = false
    /// Other running copies of this executable, usually MacPilot launched in
    /// another user's fast-switched session.
    @Published private(set) var otherInstanceCount = 0

    var settings = BLEUnlockSettings()
    /// The stable Mac identity and the pairing key for a remote client. Wired
    /// by the app so this model never touches the Keychain itself.
    var remoteOwnDeviceIDProvider: (@MainActor () -> UUID?)?
    var remotePairingKeyProvider: (@MainActor (String) -> Data?)?

    private let bluetoothScanner: any BluetoothScanning
    private var centralMgr: CBCentralManager? {
        get { bluetoothScanner.central }
        set { bluetoothScanner.central = newValue }
    }
    private var deviceMap: [UUID: BLEUnlockDevice] = [:]
    private var deviceRefreshBatcher = BLEDeviceListRefreshBatcher()
    private var deviceRefreshTask: Task<Void, Never>?
    private var scanCleanupTimer: BackgroundTask?
    private var livenessTimer: BackgroundTask?
    private var monitoringDiscoveryTimer: BackgroundTask?
    /// Session-resign notifications have been observed to never arrive for
    /// some console switches, which left a background session scanning until
    /// the system stopped delivering Bluetooth callbacks to the process.
    /// Survives monitoring suspension so it can also detect the return.
    private var consoleOwnershipTimer: BackgroundTask?
    private var lastMonitoringDiscoveryAt: TimeInterval?
    var advertisementLiveness = BLEAdvertisementLiveness()
    /// The watchdog's evidence that callbacks were expected: a daemon-wedged
    /// client can report `isScanning == false` forever while every rediscovery
    /// tick keeps starting scans. Internal test seam; production only sets it
    /// when a scan actually starts.
    var lastScanAttemptAt: Date?
    /// Marks the silence window that already paid for a full BLE client
    /// rebuild, so continuous silence escalates at most once per window.
    private var lastBLEClientRebuildAt: Date?
    var monitoredUUID: UUID?
    var secondaryMonitoredUUID: UUID?
    private var monitoredRuntimes: [UUID: BLEMonitoredDeviceRuntime] = [:]
    /// Reverse-GATT evidence keyed by the configured logical device UUID.
    private var reverseRuntimes: [UUID: BLEReversePresenceRuntime] = [:]
    private var wakeRetryTask: Task<Void, Never>?
    private var systemWakeRecoveryTask: Task<Void, Never>?
    private var monitoringRecoveryTask: Task<Void, Never>?
    var monitoringRecoverySleep: @MainActor (TimeInterval) async -> Void = { delay in
        try? await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
    }
    var signalTimeoutScheduler: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> BackgroundTask = {
        BackgroundTask.once(after: $0, action: $1)
    }
    var proximityTimeoutScheduler: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> BackgroundTask = {
        BackgroundTask.once(after: $0, action: $1)
    }
    private var unlockAttemptTask: Task<Void, Never>?
    private var unlockAttemptSlot = BLEUnlockAttemptSlot()
    /// Learns rotated phone addresses over GATT. Its own central keeps the
    /// monitoring scan's deduplication and connection policy untouched.
    private lazy var presenceAuthenticator: BLEPresenceAuthenticator = {
        let authenticator = BLEPresenceAuthenticator()
        authenticator.onLog = { [weak self] message in self?.log(message) }
        authenticator.bindingProvider = { [weak self] in
            guard let self else { return [] }
            return self.settings.identityRegistry.bindings.map {
                BLEPresenceAuthenticator.Binding(
                    clientID: $0.clientID,
                    keyFingerprint: $0.keyFingerprint
                )
            }
        }
        authenticator.pairingKeyProvider = { [weak self] clientID in
            self?.remotePairingKeyProvider?(clientID)
        }
        authenticator.macIDProvider = { [weak self] in
            self?.remoteOwnDeviceIDProvider?()
        }
        authenticator.isMonitored = { [weak self] uuid in
            self?.monitoredUUIDs.contains(uuid) ?? true
        }
        authenticator.onAuthenticated = { [weak self] clientID, keyFingerprint, peripheralUUID in
            self?.learnAuthenticatedBLEIdentity(
                clientID: clientID,
                keyFingerprint: keyFingerprint,
                peripheralUUID: peripheralUUID
            )
        }
        return authenticator
    }()
    /// Internal so tests can seed a latched cycle without starting real unlock work.
    var unlockSignalTrigger = BLEUnlockSignalTrigger()
    private var lastLoggedRSSIAt = Date.distantPast
    private var lastLoggedRSSI: Int?
    private var lastLoggedRSSIErrorAt = Date.distantPast

    private var displaySleep = false
    private var systemSleep = false
    private var recoveringFromSystemSleep = false
    private var lastActiveConnectionPauseState: Bool?
    var displayUnavailableProbe: () -> Bool = {
        DisplayPower.isDisplayBlanked || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
    /// Fast user switching runs one MacPilot per logged-in user. Only the
    /// session that owns the console may scan, connect, lock or unlock: screen
    /// control injects HID events globally, so a background session acting on
    /// "its" BLE device would type into the other user's screen.
    var sessionOnConsoleProbe: () -> Bool = BLEUnlockModel.currentSessionIsOnConsole
    private var sessionIsOnConsole = true
    private var pickerWasActiveBeforeSessionSuspend = false
    var workspaceNotificationCenterOverride: NotificationCenter?
    var heldBlankNotificationCenterOverride: NotificationCenter?
    var screenStateNotificationCenterOverride: NotificationCenter?
    var screenLockStateProbe: () -> BLEScreenLockState = { ScreenLockStateReader.current() }
    /// Test seam for verifying automatic lock decisions without screen effects.
    var lockScreenOperation: (@MainActor (ScreenControlSource) -> Void)?
    private var manualLock = false
    private var manualLockHasObservedDisplaySleep = false
    private var pendingLockSource: ScreenLockHistorySource?
    private var pendingLockSourceExpiresAt = Date.distantPast
    /// Maintained by `MacScreenControlService`, which owns the distributed
    /// screen-saver notifications because the iPhone remote reads them too.
    private var inScreensaver: Bool { screenControl.screensaverActive }
    private var lastUnlockRequestAt: TimeInterval = 0
    private var lastAutomaticUnlockRequestAt: TimeInterval = 0
    private var lastAutomaticUnlockConfirmationAt: TimeInterval = 0
    private var nowPlayingWasPlaying = false

    var isRecoveringFromSystemSleep: Bool { recoveringFromSystemSleep }
    var isUnlockAttemptScheduled: Bool { unlockAttemptSlot.isOccupied }
    /// True when the feature wants to run but this fast-switched session does
    /// not own the console. A background session never creates a central, so
    /// `bluetoothPoweredOn` stays false there — the UI must not present that
    /// as the radio being off.
    var suspendedForBackgroundSession: Bool {
        settings.isEnabled && !sessionIsOnConsole
    }
    /// Test seam: counts presence actions without performing screen control.
    /// Production never sets this.
    var presenceActionObserver: ((Bool) -> Void)?
    /// Test seam: ends the in-flight unlock attempt so a test can prove the
    /// next close sample still retries. Production never calls this.
    func cancelUnlockAttemptForTesting(reason: String) { cancelUnlockAttempt(reason: reason) }
    var activeConnectionsPaused: Bool {
        BLEActiveConnectionPolicy.shouldPause(
            displayAsleep: displayUnavailable,
            systemAsleep: systemSleep,
            wakeOnProximity: settings.wakeOnProximity
        ) || BLEActiveConnectionPolicy.shouldPauseForUserInactivity(
            wakeOnProximity: settings.wakeOnProximity,
            userIsActive: userActivityMonitor.isUserActive(at: userActivityMonitor.now),
            proximityLockEnabled: settings.lockRSSI != Self.lockDisabled
        )
    }

    private var activeConnectionPauseReason: String {
        if !settings.wakeOnProximity, displayUnavailable || systemSleep { return "displayUnavailable" }
        if BLEActiveConnectionPolicy.shouldPauseForUserInactivity(
            wakeOnProximity: settings.wakeOnProximity,
            userIsActive: userActivityMonitor.isUserActive(at: userActivityMonitor.now),
            proximityLockEnabled: settings.lockRSSI != Self.lockDisabled
        ) { return "userInputIdle" }
        return "none"
    }

    private var automaticUnlockAllowed: Bool {
        settings.isEnabled && presence && monitoringHasFreshSignal && !manualLock && !systemSleep
            && (settings.wakeOnProximity || !activeConnectionsPaused)
    }

    private var waitingForAutomaticUnlock: Bool {
        settings.isEnabled && hasMonitoredDevice && !manualLock
            && settings.unlockRSSI != Self.unlockDisabled && !settings.wakeWithoutUnlocking
            && screenLockState() == .locked
    }
    var screenLockHistory: [ScreenLockHistoryEntry] { settings.screenLockHistory.entries }

    // MediaRemote (private framework, loaded lazily).
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var mrSendCommand: (@convention(c) (Int32, AnyObject?) -> Bool)?
    private var mrGetPlaying: (@convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void)?

    private func log(_ message: @autoclosure () -> String) {
        DiagnosticLog.write("BLEUnlock", message())
    }

    private func logMonitoredRSSI(raw: Int, estimated: Int) {
        let now = Date()
        let changedEnough = lastLoggedRSSI.map { abs($0 - estimated) >= 5 } ?? true
        guard changedEnough || now.timeIntervalSince(lastLoggedRSSIAt) >= 5 else { return }
        lastLoggedRSSIAt = now
        lastLoggedRSSI = estimated
        DiagnosticLog.write("BLEUnlock", "RSSI sample raw=\(raw) estimated=\(estimated) presence=\(presence) active=\(activeMode) connected=\(connected) displaySleep=\(displaySleep) systemSleep=\(systemSleep)", level: .debug)
    }

    private func logRSSIError(_ error: Error?) {
        let now = Date()
        guard now.timeIntervalSince(lastLoggedRSSIErrorAt) >= 5 else { return }
        lastLoggedRSSIErrorAt = now
        log("RSSI read failed error=\(error?.localizedDescription ?? "unknown") presence=\(presence) connected=\(connected)")
    }

    private func logSettings(_ event: String) {
        log("\(event) enabled=\(settings.isEnabled) device=\(settings.monitoredDeviceName ?? "?") uuid=\(monitoredUUID?.uuidString ?? settings.monitoredDeviceUUID ?? "none") secondary=\(secondaryMonitoredUUID?.uuidString ?? settings.secondaryMonitoredDeviceUUID ?? "none") relation=\(settings.deviceRelation.rawValue) lockRSSI=\(settings.lockRSSI) unlockRSSI=\(settings.unlockRSSI) signalTimeout=\(settings.signalTimeout) wakeOnProximity=\(settings.wakeOnProximity) wakeWithoutUnlocking=\(settings.wakeWithoutUnlocking) passive=\(settings.passiveMode)")
    }

    private var logicalDeviceUUIDs: [UUID] {
        var result: [UUID] = []
        if let monitoredUUID { result.append(monitoredUUID) }
        if let secondaryMonitoredUUID, !result.contains(secondaryMonitoredUUID) {
            result.append(secondaryMonitoredUUID)
        }
        return result
    }

    /// Only the primary and the newest authenticated alias are observed.
    /// Every rotation used to leave another runtime with its own signal timer,
    /// so a phone that rotated every ~15 minutes kept a dozen stale timers
    /// firing recovery scans.
    private var monitoredUUIDs: [UUID] {
        var result: [UUID] = []
        for uuid in logicalDeviceUUIDs.flatMap({ settings.identityRegistry.monitoredUUIDs(for: $0) })
        where !result.contains(uuid) {
            result.append(uuid)
        }
        return result
    }

    /// UUID aliases are alternatives for ONE device, not additional devices
    /// in the primary/secondary AND/OR relationship.
    private func logicalDeviceStates(_ predicate: (BLEMonitoredDeviceRuntime) -> Bool) -> [Bool] {
        settings.identityRegistry.logicalStates(primaryUUIDs: logicalDeviceUUIDs) { uuid in
            monitoredRuntimes[uuid].map(predicate) ?? false
        }
    }

    private var hasMonitoredDevice: Bool { !monitoredUUIDs.isEmpty }

    func runtime(for uuid: UUID) -> BLEMonitoredDeviceRuntime? {
        monitoredRuntimes[uuid]
    }

    private func ensureRuntime(for uuid: UUID) -> BLEMonitoredDeviceRuntime {
        if let runtime = monitoredRuntimes[uuid] { return runtime }
        let runtime = BLEMonitoredDeviceRuntime(uuid: uuid)
        monitoredRuntimes[uuid] = runtime
        return runtime
    }

    private func isMonitoredPeripheral(_ peripheral: CBPeripheral) -> Bool {
        monitoredUUIDs.contains(peripheral.identifier)
    }

    private func refreshPublishedMonitoringState() {
        let runtimes = monitoredUUIDs.compactMap { monitoredRuntimes[$0] }
        let latestLegacyRSSI = runtimes.compactMap(\.lastRSSI).max()
        let latestReverseRSSI = reverseRuntimes
            .filter { logicalDeviceUUIDs.contains($0.key) }
            .values.compactMap(\.lastRSSI).max()
        // Display one trusted sample. Never average legacy and reverse values:
        // each direction keeps its own evidence and timers.
        let latestRSSI = latestLegacyRSSI ?? latestReverseRSSI
        let source: BLEPresenceSignalSource = latestLegacyRSSI != nil
            ? .legacy : (latestReverseRSSI != nil ? .reverse : .none)
        let perDeviceRSSI = logicalDeviceUUIDs.reduce(into: [UUID: Int]()) { result, logical in
            let legacy = settings.identityRegistry.uuids(for: logical)
                .compactMap { monitoredRuntimes[$0]?.lastRSSI }
                .max()
            // Match the header's precedence: a live legacy observation wins;
            // the authenticated reverse link fills in when it is the only one.
            if let rssi = legacy ?? reverseRuntimes[logical]?.lastRSSI {
                result[logical] = rssi
            }
        }
        if deviceRSSI != perDeviceRSSI { deviceRSSI = perDeviceRSSI }
        let isConnected = runtimes.contains { $0.peripheral?.state == .connected }
        let isActive = runtimes.contains { $0.activeMode }
        let hasReverseEvidence = reverseRuntimes.values.contains {
            $0.lastAcceptedAt != nil || $0.presence
        }
        if self.lastRSSI != latestRSSI { self.lastRSSI = latestRSSI }
        if lastRSSISource != source { lastRSSISource = source }
        if connected != isConnected { connected = isConnected }
        if activeMode != isActive { activeMode = isActive }
        if reverseLinkActive != hasReverseEvidence { reverseLinkActive = hasReverseEvidence }
    }

    /// One logical device is present when either direction has fresh presence.
    /// Aliases remain alternatives for the same logical device; direction does
    /// not create an extra device.
    private func logicalDevicePresenceStates() -> [Bool] {
        logicalDeviceUUIDs.map { logical in
            let legacy = settings.identityRegistry.uuids(for: logical).contains {
                monitoredRuntimes[$0]?.presence == true
            }
            let reverse = reverseRuntimes[logical]?.presence == true
            return legacy || reverse
        }
    }

    /// A fresh signal from either link satisfies that logical device. The
    /// any/all relation still applies across logical devices.
    private func logicalDeviceFreshSignalStates() -> [Bool] {
        logicalDeviceUUIDs.map { logical in
            let legacy = settings.identityRegistry.uuids(for: logical).contains {
                monitoredRuntimes[$0]?.lastRSSI != nil
            }
            let reverse = reverseRuntimes[logical]?.lastRSSI != nil
            return legacy || reverse
        }
    }

    private func recomputePresence(
        reason: String,
        confirmedDeparture: Bool = false,
        deliverAction: Bool = true
    ) {
        let oldPresence = presence
        let devicePresences = logicalDevicePresenceStates()
        let newPresence = BLEDevicePresencePolicy.isSatisfied(
            presences: devicePresences,
            relation: settings.deviceRelation
        )
        refreshPublishedMonitoringState()
        if manualLock, confirmedDeparture, !newPresence {
            log("manual lock retained reason=confirmedDeparture waitingForDisplayWake=true")
        }
        guard oldPresence != newPresence else {
            log("combined presence unchanged value=\(newPresence) reason=\(reason) devices=\(devicePresences)")
            return
        }
        presence = newPresence
        guard deliverAction else {
            log("combined presence changed value=\(newPresence) reason=\(reason) action=suppressed devices=\(devicePresences)")
            return
        }
        updatePresence(presence: newPresence, reason: reason)
    }

    private func cancelRuntime(for uuid: UUID) {
        guard let runtime = monitoredRuntimes.removeValue(forKey: uuid) else { return }
        runtime.invalidateTimers()
        if let peripheral = runtime.peripheral {
            centralMgr?.cancelPeripheralConnection(peripheral)
            if !deviceMap.values.contains(where: { $0.peripheral === peripheral }) {
                peripheral.delegate = nil
            }
        }
    }

    private func startConfiguredMonitoring(preservingExistingState: Bool = false) {
        guard sessionIsOnConsole else {
            logSettings("monitoring start deferred reason=backgroundSession")
            return
        }
        cancelUnlockAttempt(reason: "monitoring-restarted")
        pruneReversePresenceRuntimes()
        let uuids = monitoredUUIDs
        let initialPresence = uuids.count == 1

        for uuid in Array(monitoredRuntimes.keys) where !uuids.contains(uuid) {
            cancelRuntime(for: uuid)
        }

        for uuid in uuids {
            let hadRuntime = monitoredRuntimes[uuid] != nil
            let runtime = ensureRuntime(for: uuid)
            if preservingExistingState, hadRuntime {
                if runtime.signalTimer == nil {
                    resetSignalTimer(for: uuid)
                }
                continue
            }
            if let peripheral = runtime.peripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
            runtime.invalidateTimers()
            runtime.peripheral = nil
            runtime.lastRSSI = nil
            runtime.latestRSSIs.removeAll(keepingCapacity: true)
            runtime.presence = initialPresence
            resetSignalTimer(for: uuid)
        }

        presence = BLEDevicePresencePolicy.isSatisfied(
            presences: logicalDevicePresenceStates(),
            relation: settings.deviceRelation
        )
        refreshPublishedMonitoringState()
        advertisementLiveness.noteActivity()
        startLivenessTimer()
        startMonitoringDiscoveryTimer()
        scanForPeripherals()
        updatePresenceAuthentication()
        logSettings("monitoring started")
    }

    /// Test seam: production tests must not open a real Bluetooth radio.
    var reversePresencePeripheralOverride: ProximityBLEPeripheral?
    private var reverseGATTProbe: ProximityBLEPeripheral {
        reversePresencePeripheralOverride ?? ProximityBLEPeripheral.shared
    }

    /// The authenticator exists only while an identity binding is configured.
    /// It never creates its radio just because the feature is enabled: the
    /// monitoring scanner already owns that moment, and pairing a phone is
    /// what makes a challenge meaningful.
    private func updatePresenceAuthentication() {
        enableReversePresenceForBoundDeviceIfNeeded()
        let shouldRun = settings.isEnabled
            && sessionIsOnConsole
            && centralMgr != nil
            && !settings.identityRegistry.bindings.isEmpty
            && remoteOwnDeviceIDProvider != nil
            && remotePairingKeyProvider != nil
        presenceAuthenticator.setActive(shouldRun)
        // The reverse link does not depend on the phone-as-peripheral
        // authenticator, so it has its own start conditions. It also does not
        // need the Mac's central manager: its radio is a CBPeripheralManager.
        let reverseShouldRun = settings.isEnabled
            && settings.reverseGATTPresenceEnabled
            && sessionIsOnConsole
            && remoteOwnDeviceIDProvider?() != nil
            && !configuredReverseIdentities().isEmpty
            && remotePairingKeyProvider != nil
        updateReverseGATTPresence(shouldRun: reverseShouldRun)
    }

    /// A bound phone is the opt-in signal for the reverse link: pairing already
    /// proves the user wants proximity unlock from that device. A deliberate
    /// switch-off records `reverseGATTPresenceExplicitlyDisabled` and is never
    /// overridden here.
    private func enableReversePresenceForBoundDeviceIfNeeded() {
        guard settings.isEnabled,
              !settings.reverseGATTPresenceEnabled,
              !settings.reverseGATTPresenceExplicitlyDisabled,
              !settings.identityRegistry.bindings.isEmpty else { return }
        settings.reverseGATTPresenceEnabled = true
        objectWillChange.send()
        persist?()
        log("reverse presence enabled automatically for a bound device")
    }

    /// Bindings that may authenticate the reverse link. Only configured logical
    /// devices qualify; a stale binding for a removed device is ignored.
    private func configuredReverseIdentities() -> [ProximityReversePresenceIdentity] {
        let logical = Set(logicalDeviceUUIDs)
        return settings.identityRegistry.bindings.compactMap { binding in
            guard let primary = UUID(uuidString: binding.primaryUUID),
                  logical.contains(primary) else { return nil }
            return ProximityReversePresenceIdentity(
                clientID: binding.clientID,
                keyFingerprint: binding.keyFingerprint,
                primaryUUID: primary
            )
        }
    }

    /// Runs the reverse-role link as an *additional* proximity path. The
    /// existing phone-as-peripheral authenticator stays untouched and keeps
    /// running; losing either path leaves the other working.
    ///
    /// This is the only place that starts or stops the production peripheral.
    /// The manual diagnostic session is a different role of the same manager,
    /// so stopping production here never stops an explicitly started test.
    private func updateReverseGATTPresence(shouldRun: Bool) {
        let probe = reverseGATTProbe
        guard shouldRun, let macDeviceID = remoteOwnDeviceIDProvider?() else {
            probe.productionIdentityProvider = nil
            probe.productionPairingKeyProvider = nil
            probe.onReversePresenceSample = nil
            probe.stopProduction()
            clearReversePresenceRuntimes(reason: "productionStopped")
            return
        }
        pruneReversePresenceRuntimes()
        probe.productionIdentityProvider = { [weak self] in
            self?.configuredReverseIdentities() ?? []
        }
        probe.productionPairingKeyProvider = { [weak self] clientID in
            self?.remotePairingKeyProvider?(clientID)
        }
        probe.onReversePresenceSample = { [weak self] report in
            // The peripheral already verified the HMAC. The model revalidates
            // the binding, timing and RSSI before any presence state changes.
            self?.acceptReversePresenceSample(
                clientID: report.clientID,
                keyFingerprint: report.keyFingerprint,
                primaryUUID: report.primaryUUID,
                rssi: report.rssi,
                sampledAt: report.sampledAt
            )
        }
        probe.startProduction(macDeviceID: macDeviceID)
    }

    func reverseRuntime(for primaryUUID: UUID) -> BLEReversePresenceRuntime? {
        reverseRuntimes[primaryUUID]
    }

    private func ensureReverseRuntime(
        primaryUUID: UUID,
        clientID: String,
        keyFingerprint: String
    ) -> BLEReversePresenceRuntime {
        if let runtime = reverseRuntimes[primaryUUID],
           runtime.clientID == clientID,
           runtime.keyFingerprint == keyFingerprint {
            return runtime
        }
        reverseRuntimes[primaryUUID]?.invalidateTimers()
        let runtime = BLEReversePresenceRuntime(
            primaryUUID: primaryUUID,
            clientID: clientID,
            keyFingerprint: keyFingerprint
        )
        reverseRuntimes[primaryUUID] = runtime
        return runtime
    }

    /// Drops reverse evidence whose binding disappeared or changed identity.
    private func pruneReversePresenceRuntimes() {
        let identities = Dictionary(
            uniqueKeysWithValues: configuredReverseIdentities().map { ($0.primaryUUID, $0) }
        )
        for (primary, runtime) in reverseRuntimes {
            guard let identity = identities[primary],
                  identity.clientID == runtime.clientID,
                  identity.keyFingerprint == runtime.keyFingerprint else {
                runtime.invalidateTimers()
                reverseRuntimes.removeValue(forKey: primary)
                continue
            }
        }
    }

    /// Explicit stop (feature off, console loss, app teardown). Timers and
    /// evidence are discarded so a later enable cannot inherit old presence.
    private func clearReversePresenceRuntimes(reason: String) {
        guard !reverseRuntimes.isEmpty else {
            reverseLinkActive = false
            return
        }
        log("reverse presence cleared reason=\(reason) devices=\(reverseRuntimes.count)")
        for runtime in reverseRuntimes.values {
            runtime.invalidateTimers()
        }
        reverseRuntimes.removeAll(keepingCapacity: false)
        reverseLinkActive = false
        refreshPublishedMonitoringState()
    }

    /// Accepts a sample that already passed the GATT-layer challenge check.
    /// Revalidates everything the model owns: feature state, console session,
    /// binding identity/fingerprint, key availability, freshness and range.
    /// Any mismatch returns false and leaves presence untouched.
    @discardableResult
    func acceptReversePresenceSample(
        clientID: String,
        keyFingerprint: String,
        primaryUUID: UUID,
        rssi: Int,
        sampledAt: Date,
        now: Date = Date()
    ) -> Bool {
        guard settings.isEnabled, settings.reverseGATTPresenceEnabled else {
            log("reverse sample rejected reason=featureDisabled")
            return false
        }
        guard sessionIsOnConsole else {
            log("reverse sample rejected reason=backgroundSession")
            return false
        }
        guard !systemSleep else {
            log("reverse sample rejected reason=systemSleep")
            return false
        }
        guard RemoteBLEReversePresenceSample.isValidRSSI(rssi) else {
            log("reverse sample rejected reason=rssiRange value=\(rssi)")
            return false
        }
        let age = now.timeIntervalSince(sampledAt)
        guard age.isFinite,
              age >= -RemoteBLEReversePresenceSample.maximumFutureSkew,
              age <= RemoteBLEReversePresenceSample.maximumAge else {
            log("reverse sample rejected reason=staleTimestamp ageMs=\(Int(age * 1000))")
            return false
        }
        guard logicalDeviceUUIDs.contains(primaryUUID),
              settings.identityRegistry.bindings.contains(where: {
                  UUID(uuidString: $0.primaryUUID) == primaryUUID
                      && $0.clientID == clientID
                      && $0.keyFingerprint == keyFingerprint
              }),
              remotePairingKeyProvider?(clientID) != nil else {
            log("reverse sample rejected reason=bindingMismatch client=\(clientID)")
            return false
        }

        let runtime = ensureReverseRuntime(
            primaryUUID: primaryUUID,
            clientID: clientID,
            keyFingerprint: keyFingerprint
        )
        runtime.lastError = nil
        runtime.lastRSSI = rssi
        runtime.lastRSSISampledAt = userActivityMonitor.now
        runtime.lastAcceptedAt = now
        runtime.sampleCount += 1
        runtime.signalObservationIsContinuous = !activeConnectionsPaused && !systemSleep
        // A fresh authenticated sample ends any loss verification in progress,
        // exactly as a legacy advertisement does in `updateMonitoredPeripheral`.
        // Without this the flag stayed set after a recovery, so the next
        // signal loss skipped the verification window and locked immediately.
        if runtime.verifyingSignalLoss {
            log("reverse signal recovered during loss verification device=\(primaryUUID.uuidString)")
            runtime.verifyingSignalLoss = false
        }

        let unlockThreshold = settings.unlockRSSI == Self.unlockDisabled
            ? settings.lockRSSI : settings.unlockRSSI
        // Whether this sample already drove the presence action. `recomputePresence`
        // dispatches `updatePresence(true)` on a false→true edge, and the unlock
        // gate below dispatches the same thing for a steady-state retry. Running
        // both for one sample repeats the display wake and the unlock preflight.
        var dispatchedPresenceAction = false
        if rssi >= unlockThreshold && !runtime.presence {
            log("reverse RSSI crossed threshold rssi=\(rssi) threshold=\(unlockThreshold) device=\(primaryUUID.uuidString)")
            runtime.presence = true
            let presenceBefore = presence
            recomputePresence(reason: "reverseClose")
            dispatchedPresenceAction = !presenceBefore && presence
        }

        let lockThreshold = settings.lockRSSI == Self.lockDisabled
            ? settings.unlockRSSI : settings.lockRSSI
        if rssi >= lockThreshold {
            if runtime.proximityTimer != nil {
                log("reverse RSSI recovered above lock threshold rssi=\(rssi) threshold=\(lockThreshold); cancelling away timer")
            }
            runtime.cancelProximityTimer()
        } else if (runtime.presence || manualLock) && runtime.proximityTimer == nil {
            scheduleReverseProximityTimer(for: runtime)
        }

        resetReverseSignalTimer(for: runtime)
        refreshPublishedMonitoringState()
        log("reverse RSSI sample rssi=\(rssi) ageMs=\(Int(age * 1000)) device=\(primaryUUID.uuidString) presence=\(runtime.presence)")

        // The sample enters the same unlock gate as a legacy advertisement.
        // Authentication only proves identity; this RSSI must still clear the
        // configured unlock threshold and every existing suppression rule.
        let unlockConditionsAreEligible = settings.unlockRSSI != Self.unlockDisabled
            && !settings.wakeWithoutUnlocking
            && rssi >= settings.unlockRSSI
            && automaticUnlockAllowed
        if unlockConditionsAreEligible || unlockSignalTrigger.hasScheduledForLock {
            let triggerAllowsAttempt = unlockSignalTrigger.allowsAttempt(screenState: screenLockState())
            if unlockConditionsAreEligible && triggerAllowsAttempt && !dispatchedPresenceAction {
                // Continuous proximity still retries an unlock that has not
                // completed yet; only the sample that already dispatched the
                // presence edge is skipped.
                updatePresence(presence: true, reason: "reverseNearbySignal")
                if unlockAttemptSlot.isOccupied { unlockSignalTrigger.noteScheduled() }
            }
        }
        return true
    }

    // MARK: Settings mutations

    private func notifyChange() {
        objectWillChange.send()
        persist?()
    }

    func hasIdentityBinding(clientID: String, keyFingerprint: String) -> Bool {
        settings.identityRegistry.bindings.contains {
            logicalDeviceUUIDs.map(\.uuidString).contains($0.primaryUUID)
                && $0.clientID == clientID && $0.keyFingerprint == keyFingerprint
        }
    }

    func bindRemoteIdentity(primaryUUID: UUID, clientID: String?, keyFingerprint: String?) {
        guard logicalDeviceUUIDs.contains(primaryUUID) else { return }
        if let clientID, let keyFingerprint {
            settings.identityRegistry.bind(primaryUUID: primaryUUID, clientID: clientID, keyFingerprint: keyFingerprint)
        } else {
            settings.identityRegistry.unbind(primaryUUID: primaryUUID)
        }
        settings.identityRegistry.normalize(primaryUUIDs: logicalDeviceUUIDs)
        pruneUnmonitoredAliasRuntimes()
        pruneReversePresenceRuntimes()
        let manualLockWasSuppressed = manualLock
        recomputePresence(reason: "identityBindingChanged")
        manualLock = manualLockWasSuppressed
        updatePresenceAuthentication()
        notifyChange()
    }

    func reconcileRemoteIdentities(_ identities: [String: String]) {
        let previous = settings.identityRegistry
        settings.identityRegistry.reconcile(identities: identities)
        settings.identityRegistry.normalize(primaryUUIDs: logicalDeviceUUIDs)
        guard previous != settings.identityRegistry else { return }
        pruneUnmonitoredAliasRuntimes()
        pruneReversePresenceRuntimes()
        let manualLockWasSuppressed = manualLock
        recomputePresence(reason: "identityRevoked")
        manualLock = manualLockWasSuppressed
        updatePresenceAuthentication()
        notifyChange()
    }

    func learnAuthenticatedBLEIdentity(clientID: String, keyFingerprint: String, peripheralUUID: UUID, now: Date = Date()) {
        guard hasIdentityBinding(clientID: clientID, keyFingerprint: keyFingerprint) else { return }
        let previousUUIDs = Set(monitoredUUIDs)
        let previousActive = activeAliasByLogicalDevice()
        guard settings.identityRegistry.learn(
            clientID: clientID, keyFingerprint: keyFingerprint, peripheralUUID: peripheralUUID,
            now: now, reservedPrimaryUUIDs: logicalDeviceUUIDs
        ) else { return }

        // A routine address rotation must not look like a departure. Carry the
        // live observation to the new alias before the retired runtime is
        // pruned, or the logical device reads as absent for a moment and an
        // unlocked screen locks on every rotation.
        let currentActive = activeAliasByLogicalDevice()
        for (logicalUUID, previousUUID) in previousActive {
            guard let activeUUID = currentActive[logicalUUID],
                  activeUUID != previousUUID,
                  let previousRuntime = monitoredRuntimes[previousUUID] else { continue }
            let activeRuntime = ensureRuntime(for: activeUUID)
            activeRuntime.presence = previousRuntime.presence
            activeRuntime.lastRSSI = previousRuntime.lastRSSI
            activeRuntime.lastRSSISampledAt = previousRuntime.lastRSSISampledAt
            activeRuntime.latestRSSIs = previousRuntime.latestRSSIs
            activeRuntime.signalObservationIsContinuous = previousRuntime.signalObservationIsContinuous
            log("alias handover from=\(previousUUID.uuidString) to=\(activeUUID.uuidString) presence=\(activeRuntime.presence) lastRSSI=\(activeRuntime.lastRSSI.map(String.init) ?? "none")")
        }

        pruneUnmonitoredAliasRuntimes()
        if !previousUUIDs.subtracting(Set(monitoredUUIDs)).isEmpty {
            // Bounded retention can evict an alias. Never leave its cached
            // presence contributing after its runtime was removed.
            let manualLockWasSuppressed = manualLock
            recomputePresence(reason: "identityAliasPruned")
            manualLock = manualLockWasSuppressed
        }
        let added = Set(monitoredUUIDs).subtracting(previousUUIDs)
        // Authentication proves ownership, NOT proximity. New runtimes start
        // absent and require the ordinary RSSI callback/threshold policy.
        if settings.isEnabled {
            for uuid in added {
                _ = ensureRuntime(for: uuid)
                resetSignalTimer(for: uuid)
            }
            if !added.isEmpty, let central = centralMgr, central.state == .poweredOn {
                restoreKnownMonitoredPeripherals(using: central)
                // The monitoring scan is deduplicated: it already reported this
                // peripheral before the alias existed, so simply starting it
                // again (a no-op while `isScanning`) would never deliver the
                // advertisement that now belongs to a monitored device. A
                // restart creates a fresh discovery session and lets the
                // connect that follows turn this alias into a live RSSI link.
                if central.isScanning {
                    _ = bluetoothScanner.restartIfPoweredOn()
                } else {
                    scanForPeripherals()
                }
            }
        }
        log("authenticated BLE identity learned uuid=\(peripheralUUID.uuidString) newAlias=\(!added.isEmpty)")
        notifyChange()
    }

    private func activeAliasByLogicalDevice() -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for logicalUUID in logicalDeviceUUIDs {
            if let activeUUID = settings.identityRegistry.activeUUID(for: logicalUUID) {
                result[logicalUUID] = activeUUID
            }
        }
        return result
    }

    private func pruneUnmonitoredAliasRuntimes() {
        let retained = Set(monitoredUUIDs)
        for uuid in Array(monitoredRuntimes.keys) where !retained.contains(uuid) { cancelRuntime(for: uuid) }
        refreshPublishedMonitoringState()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        log("setEnabled from=\(settings.isEnabled) to=\(enabled)")
        settings.isEnabled = enabled
        if enabled {
            sessionIsOnConsole = sessionOnConsoleProbe()
            startObservingSystemState()
            if sessionIsOnConsole, hasMonitoredDevice {
                // Toggling the feature is an explicit user action, so this is
                // the one path allowed to start the first Bluetooth prompt.
                ensureCentralManager(explicitUserAction: true)
                if centralMgr?.state == .poweredOn { startConfiguredMonitoring() }
            } else if !sessionIsOnConsole {
                log("monitoring deferred reason=backgroundSession")
            }
        } else {
            stopMonitoring()
            stopObservingSystemState()
        }
        notifyChange()
    }

    func activateFromConfiguration() {
        guard settings.isEnabled else {
            logSettings("configuration activation skipped")
            return
        }
        logSettings("configuration activation")
        sessionIsOnConsole = sessionOnConsoleProbe()
        // System observers are only installed for an enabled feature: while BLE
        // is off they would keep the process awake for lock/sleep notifications
        // nothing consumes.
        startObservingSystemState()
        guard sessionIsOnConsole else {
            logSettings("configuration activation deferred reason=backgroundSession")
            return
        }
        // Do not create CBCentralManager during launch while Bluetooth access
        // is still undecided.  Creating it here makes every newly installed
        // or identity-mismatched build prompt before the user asks to use BLE.
        ensureCentralManager()
        if hasMonitoredDevice { startConfiguredMonitoring() }
    }

    /// Releases BLE monitoring without shutting down the shared screen
    /// control service used by other features.
    func deactivateFromConfiguration() {
        stopMonitoring()
        stopObservingSystemState()
    }

    /// Releases every runtime resource owned by the feature. Called on app
    /// termination; disabling the feature goes through `setEnabled(false)`.
    func shutdown() {
        stopMonitoring()
        stopObservingSystemState()
        presenceAuthenticator.shutdown()
        screenControl.shutdown()
    }

    func setLockRSSI(_ value: Int) {
        log("setLockRSSI from=\(settings.lockRSSI) to=\(value)")
        settings.lockRSSI = value
        reconcileActiveConnectionPolicy(reason: "lockThresholdChanged")
        notifyChange()
    }
    func setUnlockRSSI(_ value: Int) { log("setUnlockRSSI from=\(settings.unlockRSSI) to=\(value)"); settings.unlockRSSI = value; notifyChange() }
    func setProximityTimeout(_ value: Int) { log("setProximityTimeout from=\(settings.proximityTimeout) to=\(value)"); settings.proximityTimeout = value; notifyChange() }
    func setSignalTimeout(_ value: Int) {
        log("setSignalTimeout from=\(settings.signalTimeout) to=\(value)")
        settings.signalTimeout = value
        if monitoringDiscoveryTimer != nil {
            monitoringDiscoveryTimer?.stop()
            monitoringDiscoveryTimer = nil
            startMonitoringDiscoveryTimer()
        }
        notifyChange()
    }
    func setThresholdRSSI(_ value: Int) { log("setThresholdRSSI from=\(settings.thresholdRSSI) to=\(value)"); settings.thresholdRSSI = value; notifyChange() }
    func setWakeOnProximity(_ value: Bool) {
        log("setWakeOnProximity from=\(settings.wakeOnProximity) to=\(value)")
        settings.wakeOnProximity = value
        reconcileActiveConnectionPolicy(reason: "wakeOnProximityChanged", force: true)
        notifyChange()
    }
    func setWakeWithoutUnlocking(_ value: Bool) { log("setWakeWithoutUnlocking from=\(settings.wakeWithoutUnlocking) to=\(value)"); settings.wakeWithoutUnlocking = value; notifyChange() }
    func setPauseNowPlaying(_ value: Bool) { log("setPauseNowPlaying from=\(settings.pauseNowPlaying) to=\(value)"); settings.pauseNowPlaying = value; notifyChange() }
    func setUseScreensaver(_ value: Bool) { log("setUseScreensaver from=\(settings.useScreensaver) to=\(value)"); settings.useScreensaver = value; notifyChange() }
    func setTurnOffScreen(_ value: Bool) { log("setTurnOffScreen from=\(settings.turnOffScreen) to=\(value)"); settings.turnOffScreen = value; notifyChange() }

    func setDeviceRelation(_ value: BLEDevicePresenceRelation) {
        guard settings.deviceRelation != value else { return }
        log("setDeviceRelation from=\(settings.deviceRelation.rawValue) to=\(value.rawValue)")
        settings.deviceRelation = value
        recomputePresence(reason: "relationChanged")
        notifyChange()
    }

    func setPassiveMode(_ value: Bool) {
        log("setPassiveMode from=\(settings.passiveMode) to=\(value)")
        settings.passiveMode = value
        applyPassiveMode()
        notifyChange()
    }

    /// Extra recognition path for rotated phone addresses. Turning it on only
    /// adds the reverse-role GATT challenge beside the existing authenticator;
    /// turning it off stops that probe, leaves every other link untouched and
    /// records an opt-out that automatic enabling must respect.
    func setReverseGATTPresenceEnabled(_ value: Bool) {
        log("setReverseGATTPresenceEnabled from=\(settings.reverseGATTPresenceEnabled) to=\(value)")
        settings.reverseGATTPresenceEnabled = value
        settings.reverseGATTPresenceExplicitlyDisabled = !value
        updatePresenceAuthentication()
        // Turning the path off drops its evidence immediately, but an explicit
        // settings change must not lock the screen the user is looking at.
        recomputePresence(reason: "reversePresenceToggled", deliverAction: false)
        notifyChange()
    }

    func selectDevice(_ uuid: UUID) {
        deviceMap[uuid]?.resolveIdentity()
        let selectedName = deviceMap[uuid]?.displayName
        log("selectDevice uuid=\(uuid.uuidString) name=\(selectedName ?? "?") rssi=\(deviceMap[uuid]?.rssi ?? 0)")
        stopScanning()
        if let oldUUID = monitoredUUID, oldUUID != uuid { settings.identityRegistry.unbind(primaryUUID: oldUUID) }
        if secondaryMonitoredUUID == uuid {
            clearSecondaryDevice(notify: false)
        }
        settings.monitoredDeviceUUID = uuid.uuidString
        settings.monitoredDeviceName = selectedName
        monitoredUUID = uuid
        settings.identityRegistry.normalize(primaryUUIDs: logicalDeviceUUIDs)
        ensureCentralManager(explicitUserAction: true)
        startConfiguredMonitoring(preservingExistingState: true)
        notifyChange()
    }

    func selectSecondaryDevice(_ uuid: UUID) {
        guard uuid != monitoredUUID else {
            log("selectSecondaryDevice ignored reason=duplicatePrimary uuid=\(uuid.uuidString)")
            return
        }
        deviceMap[uuid]?.resolveIdentity()
        let selectedName = deviceMap[uuid]?.displayName
        log("selectSecondaryDevice uuid=\(uuid.uuidString) name=\(selectedName ?? "?") rssi=\(deviceMap[uuid]?.rssi ?? 0)")
        stopScanning()
        if let oldUUID = secondaryMonitoredUUID, oldUUID != uuid {
            settings.identityRegistry.unbind(primaryUUID: oldUUID)
            cancelRuntime(for: oldUUID)
        }
        secondaryMonitoredUUID = uuid
        settings.secondaryMonitoredDeviceUUID = uuid.uuidString
        settings.secondaryMonitoredDeviceName = selectedName
        settings.identityRegistry.normalize(primaryUUIDs: logicalDeviceUUIDs)
        ensureCentralManager(explicitUserAction: true)
        startConfiguredMonitoring(preservingExistingState: true)
        notifyChange()
    }

    func removeSecondaryDevice() {
        guard secondaryMonitoredUUID != nil || settings.secondaryMonitoredDeviceUUID != nil else { return }
        log("removeSecondaryDevice")
        clearSecondaryDevice(notify: true)
    }

    private func clearSecondaryDevice(notify: Bool) {
        if let uuid = secondaryMonitoredUUID {
            settings.identityRegistry.unbind(primaryUUID: uuid)
            cancelRuntime(for: uuid)
        }
        secondaryMonitoredUUID = nil
        settings.secondaryMonitoredDeviceUUID = nil
        settings.secondaryMonitoredDeviceName = nil
        settings.deviceRelation = .any
        settings.identityRegistry.normalize(primaryUUIDs: logicalDeviceUUIDs)
        if hasMonitoredDevice {
            startConfiguredMonitoring(preservingExistingState: true)
        } else {
            presence = false
            refreshPublishedMonitoringState()
        }
        if notify { notifyChange() }
    }

    func applyLoadedSettings(_ loaded: BLEUnlockSettings) {
        settings = loaded
        monitoredUUID = nil
        secondaryMonitoredUUID = nil
        monitoredRuntimes.removeAll(keepingCapacity: false)
        deviceRSSI.removeAll(keepingCapacity: false)
        for runtime in reverseRuntimes.values { runtime.invalidateTimers() }
        reverseRuntimes.removeAll(keepingCapacity: false)
        if let uuidString = loaded.monitoredDeviceUUID, let uuid = UUID(uuidString: uuidString) {
            monitoredUUID = uuid
        }
        if let uuidString = loaded.secondaryMonitoredDeviceUUID,
           let uuid = UUID(uuidString: uuidString),
           uuid != monitoredUUID {
            secondaryMonitoredUUID = uuid
        } else {
            settings.secondaryMonitoredDeviceUUID = nil
            settings.secondaryMonitoredDeviceName = nil
        }
        settings.identityRegistry.normalize(primaryUUIDs: logicalDeviceUUIDs)
        objectWillChange.send()
        logSettings("settings loaded")
    }

    // MARK: Lifecycle

    func ensureCentralManager(explicitUserAction: Bool = false) {
        guard centralMgr == nil else {
            log("central manager already exists state=\(String(describing: centralMgr?.state))")
            return
        }
        let authorization = CBManager.authorization
        guard BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: authorization,
            settingsEnabled: settings.isEnabled,
            hasMonitoredDevice: hasMonitoredDevice,
            explicitUserAction: explicitUserAction
        ) else {
            log("central manager creation skipped authorization=\(String(describing: authorization)) enabled=\(settings.isEnabled) hasDevice=\(hasMonitoredDevice) explicitUserAction=\(explicitUserAction)")
            return
        }
        log("creating central manager authorization=\(String(describing: authorization)) explicitUserAction=\(explicitUserAction)")
        bluetoothScanner.createIfNeeded(delegate: self)
    }

    func startScanning() {
        log("startScanning")
        ensureCentralManager(explicitUserAction: true)
        isScanning = true
        startScanCleanupTimer()
        // A deduplicated scan reports each peripheral exactly once. The picker
        // removes rows after `signalTimeout`, so without duplicate callbacks
        // every row disappears about a minute after opening and never returns
        // while the same scan session is still running.
        bluetoothScanner.setAllowsDuplicateAdvertisements(true)
        _ = bluetoothScanner.restartIfPoweredOn()
        scanForPeripherals()
    }

    func stopScanning() {
        log("stopScanning devices=\(deviceMap.count) monitored=\(monitoredUUIDs.count)")
        isScanning = false
        scanCleanupTimer?.stop()
        scanCleanupTimer = nil
        clearDiscoveredDevices()
        // Restore the bounded monitoring scan. `restartIfPoweredOn` applies the
        // new options to a scan that is already running.
        bluetoothScanner.setAllowsDuplicateAdvertisements(false)
        if settings.isEnabled && hasMonitoredDevice {
            _ = bluetoothScanner.restartIfPoweredOn()
        } else {
            bluetoothScanner.stop()
        }
    }

    private func stopMonitoring() {
        log("stopMonitoring")
        isScanning = false
        scanCleanupTimer?.stop(); scanCleanupTimer = nil
        deviceRefreshTask?.cancel(); deviceRefreshTask = nil
        wakeRetryTask?.cancel(); wakeRetryTask = nil
        systemWakeRecoveryTask?.cancel(); systemWakeRecoveryTask = nil
        cancelMonitoringRecovery(reason: "monitoringStopped")
        cancelUnlockAttempt()
        bluetoothScanner.setAllowsDuplicateAdvertisements(false)
        bluetoothScanner.stop()
        clearDiscoveredDevices()
        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
            if let peripheral = runtime.peripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
        }
        monitoredRuntimes.removeAll(keepingCapacity: false)
        presence = false
        lastRSSI = nil
        deviceRSSI.removeAll(keepingCapacity: false)
        connected = false
        activeMode = false
        recoveringFromSystemSleep = false
        stopLivenessTimer()
        monitoringDiscoveryTimer?.stop()
        monitoringDiscoveryTimer = nil
        lastMonitoringDiscoveryAt = nil
        advertisementStreamStalled = false
        otherInstanceCount = 0
        presenceAuthenticator.setActive(false)
        // The reverse link is production-only; disabling the feature must end
        // its advertisement, pending challenges and retries too.
        updateReverseGATTPresence(shouldRun: false)
        lastRSSISource = .none
        // Drop the CoreBluetooth central too: holding it keeps a Bluetooth XPC
        // session (and its delegate graph) alive for nothing while the feature
        // is off. `ensureCentralManager()` recreates it on the next enable.
        bluetoothScanner.release()
    }

    private func clearDiscoveredDevices() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        deviceRefreshBatcher = BLEDeviceListRefreshBatcher()
        let discoveredPeripherals = deviceMap.values.compactMap(\.peripheral)
        deviceMap.removeAll(keepingCapacity: false)
        devices.removeAll(keepingCapacity: false)
        for peripheral in discoveredPeripherals where !isMonitoredPeripheral(peripheral) {
            centralMgr?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
    }

    private func scanForPeripherals() {
        guard sessionIsOnConsole else {
            log("scan skipped reason=backgroundSession")
            return
        }
        guard let central = centralMgr else {
            log("scan skipped reason=noCentralManager")
            return
        }
        guard central.state == .poweredOn else {
            log("scan skipped reason=bluetoothState state=\(String(describing: central.state))")
            return
        }
        guard !central.isScanning else { return }
        log("scan started monitored=\(monitoredUUIDs.map(\.uuidString).joined(separator: ","))")
        if bluetoothScanner.startIfPoweredOn() { lastScanAttemptAt = Date() }
    }

    private var displayUnavailable: Bool {
        displaySleep || displayUnavailableProbe()
    }

    private var workspaceNotificationCenter: NotificationCenter {
        workspaceNotificationCenterOverride ?? NSWorkspace.shared.notificationCenter
    }

    private var heldBlankNotificationCenter: NotificationCenter {
        heldBlankNotificationCenterOverride ?? .default
    }

    /// Pauses all active connections while keeping advertisement scanning alive.
    private func reconcileActiveConnectionPolicy(reason: String, force: Bool = false) {
        let paused = activeConnectionsPaused
        guard force || lastActiveConnectionPauseState != paused else { return }
        lastActiveConnectionPauseState = paused
        log("active connection policy paused=\(paused) reason=\(reason) displaySleep=\(displaySleep) heldBlank=\(DisplayPower.isDisplayBlanked) systemSleep=\(systemSleep) wakeOnProximity=\(settings.wakeOnProximity)")

        if paused {
            let pauseReason = activeConnectionPauseReason
            cancelUnlockAttempt(reason: pauseReason)
            wakeRetryTask?.cancel()
            wakeRetryTask = nil
            for runtime in monitoredRuntimes.values {
                runtime.cancelProximityTimer()
                runtime.signalObservationIsContinuous = false
                runtime.activeModeTimer?.stop()
                runtime.activeModeTimer = nil
                runtime.activeMode = false
                runtime.connectionTimer?.stop()
                runtime.connectionTimer = nil
                runtime.connectionRetryGate.reset()
                runtime.rssiRequestTimeoutTimer?.stop()
                runtime.rssiRequestTimeoutTimer = nil
                runtime.rssiReadGate.reset()
            }
            var peripheralsByID: [UUID: CBPeripheral] = [:]
            for runtime in monitoredRuntimes.values {
                if let peripheral = runtime.peripheral { peripheralsByID[peripheral.identifier] = peripheral }
            }
            for device in deviceMap.values {
                guard let peripheral = device.peripheral,
                      !isMonitoredPeripheral(peripheral) else { continue }
                peripheralsByID[peripheral.identifier] = peripheral
            }
            for peripheral in peripheralsByID.values {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
            refreshPublishedMonitoringState()
        } else {
            for uuid in monitoredUUIDs where !settings.passiveMode {
                connectMonitoredPeripheral(for: uuid)
            }
            if isScanning {
                for device in deviceMap.values where device.bluetoothName == nil {
                    guard let peripheral = device.peripheral,
                          peripheral.name == nil, device.rssi >= -55 else { continue }
                    peripheral.delegate = self
                    centralMgr?.connect(peripheral, options: nil)
                }
            }
        }
        scanForPeripherals()
    }

    func recordUserInput(at time: TimeInterval? = nil) {
        userActivityMonitor.recordInput(at: time ?? userActivityMonitor.now)
    }

    private func handleObservedUserInput() {
        let wasPaused = lastActiveConnectionPauseState ?? activeConnectionsPaused
        // A genuine wake input may precede AppKit's screensDidWake notification.
        if manualLock, manualLockHasObservedDisplaySleep, !displayUnavailableProbe(), !systemSleep {
            displaySleep = false
            screenControl.noteDisplaySleeping(false)
            rearmAutomaticUnlockAfterManualLockDisplayWake(trigger: "userInputWake")
            startDisplayWakeMonitoringRecovery(clearSignal: true)
        }
        reconcileActiveConnectionPolicy(reason: "userInput")
        guard wasPaused else { return }
        if !activeConnectionsPaused { tryUnlockScreen(trigger: "userInput") }
    }

    func evaluateUserActivityPolicy() {
        let isActive = userActivityMonitor.isUserActive(at: userActivityMonitor.now)
        let pauseReason = BLEActiveConnectionPolicy.shouldPauseForUserInactivity(
            wakeOnProximity: settings.wakeOnProximity,
            userIsActive: isActive,
            proximityLockEnabled: settings.lockRSSI != Self.lockDisabled
        ) ? "userInputIdle" : (isActive ? "userInputActive" : "proximityMonitoring")
        reconcileActiveConnectionPolicy(reason: pauseReason)
    }

    private func applyPassiveMode() {
        for runtime in monitoredRuntimes.values {
            if settings.passiveMode {
                runtime.activeModeTimer?.stop()
                runtime.activeModeTimer = nil
                runtime.activeMode = false
                if let peripheral = runtime.peripheral {
                    centralMgr?.cancelPeripheralConnection(peripheral)
                }
            } else if runtime.peripheral != nil {
                connectMonitoredPeripheral(for: runtime.uuid)
            }
        }
        refreshPublishedMonitoringState()
        scanForPeripherals()
    }

    func startMonitor(_ uuid: UUID) {
        log("startMonitor uuid=\(uuid.uuidString) previousPresence=\(presence)")
        monitoredUUID = uuid
        startConfiguredMonitoring()
    }

    private func resetSignalTimer(for uuid: UUID, minimumDelay: TimeInterval = 0, delayOverride: TimeInterval? = nil) {
        guard let runtime = runtime(for: uuid) else { return }
        let delay = delayOverride ?? max(TimeInterval(settings.signalTimeout), minimumDelay)
        let now = userActivityMonitor.now
        let deadline = now + delay
        runtime.signalTimeoutDeadline = deadline

        // RSSI can arrive several times per second. Keep an earlier armed
        // wakeup and let it check the renewed deadline, instead of cancelling
        // and creating a task for every sample. If policy shortens the window,
        // move the wakeup forward immediately.
        if let timer = runtime.signalTimer,
           timer.isRunning,
           let scheduledDeadline = runtime.signalTimerScheduledDeadline,
           scheduledDeadline <= deadline {
            return
        }

        runtime.signalTimer?.stop()
        runtime.signalTimer = nil
        runtime.signalTimerScheduledDeadline = nil
        runtime.signalTimerGeneration &+= 1
        scheduleSignalTimer(
            for: uuid,
            runtime: runtime,
            generation: runtime.signalTimerGeneration,
            delay: delay,
            deadline: deadline
        )
    }

    private func scheduleSignalTimer(
        for uuid: UUID,
        runtime: BLEMonitoredDeviceRuntime,
        generation: UInt64,
        delay: TimeInterval,
        deadline: TimeInterval
    ) {
        runtime.signalTimerScheduledDeadline = deadline
        runtime.signalTimer = signalTimeoutScheduler(delay) { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            guard self.runtime(for: uuid) === runtime, runtime.signalTimerGeneration == generation else {
                self.log("signal timeout ignored reason=superseded uuid=\(uuid.uuidString)")
                return
            }
            runtime.signalTimer = nil
            runtime.signalTimerScheduledDeadline = nil
            // Each arm gets a distinct generation so even a duplicate callback
            // from an expired one-shot cannot consume the replacement timer.
            runtime.signalTimerGeneration &+= 1
            guard let latestDeadline = runtime.signalTimeoutDeadline else {
                self.log("signal timeout ignored reason=noDeadline uuid=\(uuid.uuidString)")
                return
            }
            let now = self.userActivityMonitor.now
            guard now >= latestDeadline else {
                self.scheduleSignalTimer(
                    for: uuid,
                    runtime: runtime,
                    generation: runtime.signalTimerGeneration,
                    delay: latestDeadline - now,
                    deadline: latestDeadline
                )
                return
            }
            self.handleMonitoredSignalTimeout(for: uuid)
        }
    }

    func handleMonitoredSignalTimeout(for uuid: UUID) {
        guard let runtime = runtime(for: uuid) else { return }
        // This method also serves as a deterministic timeout entry point in
        // tests. Treat a direct call like consuming the currently armed timer.
        if runtime.signalTimer != nil || runtime.signalTimerScheduledDeadline != nil {
            runtime.signalTimer?.stop()
            runtime.signalTimer = nil
            runtime.signalTimerScheduledDeadline = nil
            runtime.signalTimerGeneration &+= 1
        }
        log("signal timeout fired uuid=\(uuid.uuidString) timeout=\(settings.signalTimeout) devicePresence=\(runtime.presence)")
        // Invalidate RSSI immediately, but give discovery one bounded chance
        // before locking. The old code locked first and cancelled a reconnect
        // just before its own 60-second connection deadline could finish.
        if runtime.presence, !runtime.verifyingSignalLoss,
           settings.lockRSSI != Self.lockDisabled, !isScreenLocked(), !activeConnectionsPaused, !systemSleep {
            let lastRSSI = runtime.lastRSSI
            runtime.verifyingSignalLoss = true
            runtime.lastRSSI = nil
            runtime.latestRSSIs.removeAll(keepingCapacity: true)
            runtime.cancelProximityTimer()
            refreshPublishedMonitoringState()
            let delay = BLEScanPolicy.signalLossVerificationDelay(
                signalTimeout: settings.signalTimeout,
                lastRSSI: lastRSSI
            )
            resetSignalTimer(for: uuid, minimumDelay: 0, delayOverride: delay)
            log("signal loss verification started uuid=\(uuid.uuidString) seconds=\(delay) lastRSSI=\(lastRSSI.map(String.init) ?? "none") nearby=\(lastRSSI.map { $0 >= BLEScanPolicy.nearbySignalRSSI } ?? false) preservingConnections=true")
            refreshMonitoringDiscovery(reason: "signalLossVerification")
            return
        }
        // Normal monitoring's full no-signal window is also a departure. A
        // deliberate pause/reset must never manufacture that evidence.
        let confirmedDeparture = manualLock && runtime.signalObservationIsContinuous
            && runtime.lastRSSI != nil && !activeConnectionsPaused && !systemSleep
            && runtime.signalTimeoutDeadline.map { userActivityMonitor.now >= $0 } == true
        runtime.signalObservationIsContinuous = false
        runtime.verifyingSignalLoss = false
        runtime.signalTimeoutDeadline = nil
        runtime.signalTimer = nil
        runtime.signalTimerScheduledDeadline = nil
        runtime.lastRSSI = nil
        runtime.activeMode = false
        if runtime.presence || confirmedDeparture {
            runtime.presence = false
            recomputePresence(reason: "lost", confirmedDeparture: confirmedDeparture)
        } else {
            refreshPublishedMonitoringState()
        }
        // In "any device" mode an absent secondary must not tear down
        // the healthy primary's connection every signal-timeout interval.
        // Only a legacy signal proves the legacy link recovered.
        if !monitoringHasLegacyFreshSignal {
            startMonitoringRecovery(reason: "signalTimeout", restartImmediately: true)
        }
    }

    private func resetReverseSignalTimer(
        for runtime: BLEReversePresenceRuntime,
        minimumDelay: TimeInterval = 0,
        delayOverride: TimeInterval? = nil
    ) {
        let delay = delayOverride ?? max(TimeInterval(settings.signalTimeout), minimumDelay)
        let now = userActivityMonitor.now
        let deadline = now + delay
        runtime.signalTimeoutDeadline = deadline

        if let timer = runtime.signalTimer,
           timer.isRunning,
           let scheduledDeadline = runtime.signalTimerScheduledDeadline,
           scheduledDeadline <= deadline {
            return
        }

        runtime.signalTimer?.stop()
        runtime.signalTimer = nil
        runtime.signalTimerScheduledDeadline = nil
        runtime.signalTimerGeneration &+= 1
        scheduleReverseSignalTimer(
            for: runtime,
            generation: runtime.signalTimerGeneration,
            delay: delay,
            deadline: deadline
        )
    }

    private func scheduleReverseSignalTimer(
        for runtime: BLEReversePresenceRuntime,
        generation: UInt64,
        delay: TimeInterval,
        deadline: TimeInterval
    ) {
        let primaryUUID = runtime.primaryUUID
        runtime.signalTimerScheduledDeadline = deadline
        runtime.signalTimer = signalTimeoutScheduler(delay) { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            guard self.reverseRuntimes[primaryUUID] === runtime,
                  runtime.signalTimerGeneration == generation else {
                self.log("reverse signal timeout ignored reason=superseded device=\(primaryUUID.uuidString)")
                return
            }
            runtime.signalTimer = nil
            runtime.signalTimerScheduledDeadline = nil
            runtime.signalTimerGeneration &+= 1
            guard let latestDeadline = runtime.signalTimeoutDeadline else {
                self.log("reverse signal timeout ignored reason=noDeadline device=\(primaryUUID.uuidString)")
                return
            }
            let now = self.userActivityMonitor.now
            guard now >= latestDeadline else {
                self.scheduleReverseSignalTimer(
                    for: runtime,
                    generation: runtime.signalTimerGeneration,
                    delay: latestDeadline - now,
                    deadline: latestDeadline
                )
                return
            }
            self.handleReverseSignalTimeout(for: primaryUUID)
        }
    }

    /// Reverse samples are the only evidence for this runtime. When they stop,
    /// freshness expires even if the GATT link still reports "connected"; a
    /// connected link alone must never keep the Mac unlocked indefinitely.
    func handleReverseSignalTimeout(for primaryUUID: UUID) {
        guard let runtime = reverseRuntimes[primaryUUID] else { return }
        if runtime.signalTimer != nil || runtime.signalTimerScheduledDeadline != nil {
            runtime.signalTimer?.stop()
            runtime.signalTimer = nil
            runtime.signalTimerScheduledDeadline = nil
            runtime.signalTimerGeneration &+= 1
        }
        log("reverse signal timeout fired device=\(primaryUUID.uuidString) timeout=\(settings.signalTimeout) presence=\(runtime.presence)")
        if runtime.presence, !runtime.verifyingSignalLoss,
           settings.lockRSSI != Self.lockDisabled, !isScreenLocked(),
           !activeConnectionsPaused, !systemSleep {
            let lastRSSI = runtime.lastRSSI
            runtime.verifyingSignalLoss = true
            runtime.lastRSSI = nil
            runtime.cancelProximityTimer()
            refreshPublishedMonitoringState()
            let delay = BLEScanPolicy.signalLossVerificationDelay(
                signalTimeout: settings.signalTimeout,
                lastRSSI: lastRSSI
            )
            resetReverseSignalTimer(for: runtime, minimumDelay: 0, delayOverride: delay)
            log("reverse signal loss verification started device=\(primaryUUID.uuidString) seconds=\(delay)")
            return
        }
        let confirmedDeparture = manualLock && runtime.signalObservationIsContinuous
            && runtime.lastRSSI != nil && !activeConnectionsPaused && !systemSleep
            && runtime.signalTimeoutDeadline.map { userActivityMonitor.now >= $0 } == true
        runtime.signalObservationIsContinuous = false
        runtime.verifyingSignalLoss = false
        runtime.signalTimeoutDeadline = nil
        runtime.signalTimer = nil
        runtime.signalTimerScheduledDeadline = nil
        runtime.lastRSSI = nil
        runtime.lastRSSISampledAt = nil
        if runtime.presence || confirmedDeparture {
            runtime.presence = false
            recomputePresence(reason: "reverseLost", confirmedDeparture: confirmedDeparture)
        } else {
            refreshPublishedMonitoringState()
        }
    }

    private func scheduleReverseProximityTimer(for runtime: BLEReversePresenceRuntime) {
        let primaryUUID = runtime.primaryUUID
        runtime.proximityTimerGeneration &+= 1
        let generation = runtime.proximityTimerGeneration
        runtime.proximityTimer = proximityTimeoutScheduler(TimeInterval(settings.proximityTimeout)) { [weak self, weak runtime] in
            guard let self, let runtime,
                  self.reverseRuntimes[primaryUUID] === runtime,
                  runtime.proximityTimerGeneration == generation else { return }
            runtime.proximityTimerGeneration &+= 1
            let currentThreshold = self.settings.lockRSSI == Self.lockDisabled
                ? self.settings.unlockRSSI : self.settings.lockRSSI
            let sampleAge = runtime.lastRSSISampledAt.map { self.userActivityMonitor.now - $0 }
            let sampleIsFresh = sampleAge.map { $0 >= 0 && $0 < TimeInterval(self.settings.signalTimeout) } == true
            let confirmedDeparture = sampleIsFresh && runtime.lastRSSI.map { $0 < currentThreshold } == true
            runtime.proximityTimer = nil
            guard confirmedDeparture else {
                self.log("reverse away timer ignored device=\(primaryUUID.uuidString) reason=noFreshDistantSignal")
                return
            }
            runtime.presence = false
            self.recomputePresence(reason: "reverseAway", confirmedDeparture: true)
        }
    }

    private func estimatedRSSI(_ rssi: Int, for runtime: BLEMonitoredDeviceRuntime) -> Int {
        runtime.latestRSSIs.append(Double(rssi))
        if runtime.latestRSSIs.count > 5 { runtime.latestRSSIs.removeFirst() }
        let mean = runtime.latestRSSIs.reduce(0, +) / Double(runtime.latestRSSIs.count)
        return Int(mean)
    }

    func updateMonitoredPeripheral(_ rssi: Int, for uuid: UUID) {
        guard let runtime = runtime(for: uuid) else { return }
        runtime.verifyingSignalLoss = false
        noteAdvertisementActivity()
        let unlockThreshold = settings.unlockRSSI == Self.unlockDisabled ? settings.lockRSSI : settings.unlockRSSI
        if rssi >= unlockThreshold && !runtime.presence {
            log("RSSI crossed unlock threshold raw=\(rssi) threshold=\(unlockThreshold) previousPresence=false")
            runtime.presence = true
            recomputePresence(reason: "close")
            runtime.latestRSSIs.removeAll()
        }

        let estimated = estimatedRSSI(rssi, for: runtime)
        runtime.lastRSSI = estimated
        runtime.lastRSSISampledAt = userActivityMonitor.now
        runtime.signalObservationIsContinuous = !activeConnectionsPaused && !systemSleep
        stopMonitoringRecovery(reason: "freshRSSI")
        runtime.activeMode = runtime.activeModeTimer != nil
        refreshPublishedMonitoringState()
        logMonitoredRSSI(raw: rssi, estimated: estimated)

        let lockThreshold = settings.lockRSSI == Self.lockDisabled ? settings.unlockRSSI : settings.lockRSSI
        if estimated >= lockThreshold {
            if runtime.proximityTimer != nil {
                log("RSSI recovered above lock threshold estimated=\(estimated) threshold=\(lockThreshold); cancelling away timer")
            }
            runtime.cancelProximityTimer()
        } else if (runtime.presence || manualLock) && runtime.proximityTimer == nil {
            log("RSSI below lock threshold estimated=\(estimated) threshold=\(lockThreshold); scheduling away timer seconds=\(settings.proximityTimeout)")
            runtime.proximityTimerGeneration &+= 1
            let generation = runtime.proximityTimerGeneration
            runtime.proximityTimer = proximityTimeoutScheduler(TimeInterval(settings.proximityTimeout)) { [weak self, weak runtime] in
                guard let self, let runtime,
                      self.runtime(for: uuid) === runtime,
                      runtime.proximityTimerGeneration == generation else { return }
                runtime.proximityTimerGeneration &+= 1
                self.log("away timer fired uuid=\(uuid.uuidString) estimatedRSSI=\(runtime.lastRSSI.map(String.init) ?? "none")")
                let currentThreshold = self.settings.lockRSSI == Self.lockDisabled
                    ? self.settings.unlockRSSI : self.settings.lockRSSI
                let sampleAge = runtime.lastRSSISampledAt.map { self.userActivityMonitor.now - $0 }
                let sampleIsFresh = sampleAge.map { $0 >= 0 && $0 < TimeInterval(self.settings.signalTimeout) } == true
                let confirmedDeparture = sampleIsFresh && runtime.lastRSSI.map { $0 < currentThreshold } == true
                runtime.proximityTimer = nil
                guard confirmedDeparture else {
                    self.log("away timer ignored uuid=\(uuid.uuidString) reason=noFreshDistantSignal")
                    return
                }
                runtime.presence = false
                self.recomputePresence(reason: "away", confirmedDeparture: confirmedDeparture)
            }
        }
        resetSignalTimer(for: uuid)
        // Monitoring one phone starts with a conservative "present" state to
        // avoid locking before its first sample. That state, and steady presence
        // across a later lock, have no presence edge to trigger an unlock.
        // Only a new close RSSI sample and a confirmed locked session authorize
        // this route; pairing/retained presence alone never does.
        let unlockConditionsAreEligible = settings.unlockRSSI != Self.unlockDisabled
            && !settings.wakeWithoutUnlocking
            && rssi >= settings.unlockRSSI
            && automaticUnlockAllowed
        // Preserve the missed-notification recovery path: while a lock cycle
        // is latched, samples still observe the actual state so an unlocked
        // screen can clear the latch even when the current RSSI is ineligible.
        if unlockConditionsAreEligible || unlockSignalTrigger.hasScheduledForLock {
            let triggerAllowsAttempt = unlockSignalTrigger.allowsAttempt(screenState: screenLockState())
            if unlockConditionsAreEligible && triggerAllowsAttempt {
                updatePresence(presence: true, reason: "nearbySignal")
                if unlockAttemptSlot.isOccupied { unlockSignalTrigger.noteScheduled() }
            }
        }
    }

    private func startScanCleanupTimer() {
        guard scanCleanupTimer == nil else { return }
        scanCleanupTimer = BackgroundTask.repeating(every: 5) { [weak self] in
            self?.removeStaleDevices()
        }
    }

    private func removeStaleDevices() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(settings.signalTimeout))
        let stale = deviceMap.values.filter { $0.lastSeenAt < cutoff }
        guard !stale.isEmpty else { return }
        log("removing stale devices count=\(stale.count) timeout=\(settings.signalTimeout)")
        for device in stale {
            deviceMap.removeValue(forKey: device.uuid)
            if let peripheral = device.peripheral, !isMonitoredPeripheral(peripheral) {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
        }
        requestDeviceRefresh(immediate: true)
    }

    private func requestDeviceRefresh(immediate: Bool = false) {
        deviceRefreshBatcher.requestRefresh()
        if immediate {
            deviceRefreshTask?.cancel()
            deviceRefreshTask = nil
            publishDeviceListIfNeeded()
            return
        }
        guard deviceRefreshTask == nil else { return }
        deviceRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.deviceRefreshInterval)
            guard !Task.isCancelled else { return }
            self?.deviceRefreshTask = nil
            self?.publishDeviceListIfNeeded()
        }
    }

    private func publishDeviceListIfNeeded() {
        guard deviceRefreshBatcher.takePendingRefresh() else { return }
        devices = deviceMap.values.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    private func connectMonitoredPeripheral(for uuid: UUID) {
        guard !activeConnectionsPaused else {
            log("connect skipped reason=displayUnavailable wakeOnProximity=\(settings.wakeOnProximity) uuid=\(uuid.uuidString)")
            return
        }
        guard let runtime = runtime(for: uuid), let peripheral = runtime.peripheral else {
            log("connect skipped reason=noMonitoredPeripheral")
            return
        }

        peripheral.delegate = self
        if peripheral.state == .connected {
            requestRSSIRead(for: runtime)
            return
        }
        guard peripheral.state == .disconnected else { return }
        guard runtime.connectionRetryGate.begin(at: Date()) else { return }

        log("connect monitored peripheral uuid=\(uuid.uuidString) state=\(String(describing: peripheral.state)) passive=\(settings.passiveMode)")
        centralMgr?.connect(peripheral, options: nil)
        runtime.connectionTimer?.stop()
        runtime.connectionTimer = BackgroundTask.once(after: BLEConnectionRetryGate.connectionTimeout) { [weak self] in
            guard let self, let runtime = self.runtime(for: uuid),
                  let peripheral = runtime.peripheral, peripheral.state == .connecting else { return }
            self.log("connection timed out uuid=\(uuid.uuidString) timeout=\(BLEConnectionRetryGate.connectionTimeout); cancelling pending connection")
            self.centralMgr?.cancelPeripheralConnection(peripheral)
            runtime.connectionTimer = nil
        }
    }

    private func requestRSSIRead(for runtime: BLEMonitoredDeviceRuntime) {
        guard let peripheral = runtime.peripheral,
              peripheral.state == .connected,
              runtime.rssiReadGate.begin() else { return }
        scheduleRSSIRequestTimeout(for: runtime)
        peripheral.readRSSI()
    }

    private func scheduleRSSIRequestTimeout(for runtime: BLEMonitoredDeviceRuntime) {
        runtime.rssiRequestTimeoutTimer?.stop()
        let uuid = runtime.uuid
        runtime.rssiRequestTimeoutTimer = BackgroundTask.once(after: BLERequestGate.requestTimeout) { [weak self] in
            guard let self, let currentRuntime = self.runtime(for: uuid) else { return }
            currentRuntime.rssiRequestTimeoutTimer = nil
            guard currentRuntime.rssiReadGate.hasTimedOut(at: Date()) else { return }
            self.log("RSSI request timed out uuid=\(currentRuntime.uuid.uuidString) timeout=\(BLERequestGate.requestTimeout)")
            currentRuntime.rssiReadGate.reset()
            self.startMonitoringRecovery(reason: "rssiRequestTimeout", restartImmediately: true)
        }
    }

    // MARK: CBCentralManagerDelegate

    /// Shared by the real discovery callback and isolated radio regressions.
    func receiveMonitoredAdvertisement(_ rssi: Int, for uuid: UUID) {
        guard runtime(for: uuid) != nil else { return }
        updateMonitoredPeripheral(rssi, for: uuid)
        if !settings.passiveMode { connectMonitoredPeripheral(for: uuid) }
    }

    private func startMonitoringDiscoveryTimer() {
        guard monitoringDiscoveryTimer == nil else { return }
        let interval = BLEScanPolicy.rediscoveryInterval(signalTimeout: settings.signalTimeout)
        monitoringDiscoveryTimer = BackgroundTask.repeating(every: interval) { [weak self] in
            self?.evaluateMonitoringDiscovery()
        }
    }

    func evaluateMonitoringDiscovery() {
        guard monitoringDiscoveryTimer != nil, settings.isEnabled, hasMonitoredDevice, !systemSleep else { return }
        let now = userActivityMonitor.now
        let interval = BLEScanPolicy.rediscoveryInterval(signalTimeout: settings.signalTimeout)
        // Each logical device needs its own working observation path. A fresh
        // phone must not suppress rediscovery of the missing watch in OR mode;
        // an unknown alias must not cause scans if that same phone is healthy.
        let observed = logicalDeviceUUIDs.map { logical -> Bool in
            let legacy = settings.identityRegistry.uuids(for: logical).contains { uuid in
                guard let runtime = monitoredRuntimes[uuid],
                      runtime.lastRSSI != nil,
                      let sampled = runtime.lastRSSISampledAt else { return false }
                let age = now - sampled
                return age >= 0 && age < interval
            }
            let reverse = reverseRuntimes[logical].map { runtime in
                guard runtime.lastRSSI != nil, let sampled = runtime.lastRSSISampledAt else { return false }
                let age = now - sampled
                return age >= 0 && age < interval
            } ?? false
            return legacy || reverse
        }
        guard observed.contains(false) else { return }
        refreshMonitoringDiscovery(reason: "missingDeviceSignal")
    }

    private func refreshMonitoringDiscovery(reason: String) {
        guard settings.isEnabled, hasMonitoredDevice, !systemSleep else { return }
        let now = userActivityMonitor.now
        let interval = BLEScanPolicy.rediscoveryInterval(signalTimeout: settings.signalTimeout)
        if let last = lastMonitoringDiscoveryAt, now >= last, now - last < interval { return }
        lastMonitoringDiscoveryAt = now
        let scanning = bluetoothScanner.restartIfPoweredOn()
        if scanning { lastScanAttemptAt = Date() }
        log("monitoring discovery \(scanning ? "restarted" : "deferred") reason=\(reason) preservingConnections=true devices=[\(monitoringSignalSnapshot(at: now))]")
        if let central = centralMgr, central.state == .poweredOn {
            restoreKnownMonitoredPeripherals(using: central)
        }
    }

    private func monitoringSignalSnapshot(at now: TimeInterval) -> String {
        logicalDeviceUUIDs.map { logical in
            let addresses = settings.identityRegistry.monitoredUUIDs(for: logical).map { uuid in
                guard let runtime = runtime(for: uuid) else { return "\(uuid.uuidString):unobserved" }
                let age = runtime.lastRSSISampledAt.map { String(format: "%.1f", now - $0) } ?? "none"
                let state = runtime.peripheral.map { String($0.state.rawValue) } ?? "none"
                return "\(uuid.uuidString):rssi=\(runtime.lastRSSI.map(String.init) ?? "none"),age=\(age),link=\(state)"
            }.joined(separator: ";")
            return "\(logical.uuidString)={\(addresses)}"
        }.joined(separator: " ")
    }

    private var allLogicalDevicesHaveRSSIPolling: Bool {
        let links = logicalDeviceStates { runtime in
            !BLEScanPolicy.needsAdvertisements(
                connectionState: runtime.peripheral?.state,
                hasRSSIPoller: runtime.activeModeTimer != nil
            )
        }
        return !links.isEmpty && links.allSatisfy { $0 }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === centralMgr else { return }
        handleCentralStateChange(central.state)
    }

    /// Shared by the delegate callback and isolated radio regressions.
    func handleCentralStateChange(_ state: CBManagerState) {
        log("central state updated state=\(String(describing: state)) authorization=\(String(describing: CBManager.authorization))")
        switch state {
        case .poweredOn:
            bluetoothPoweredOn = true
            bluetoothPowerWarned = false
            guard sessionIsOnConsole else {
                log("bluetooth powered on in a background session; monitoring stays suspended")
                return
            }
            if settings.isEnabled && hasMonitoredDevice {
                if monitoredUUIDs.contains(where: { monitoredRuntimes[$0] == nil }) {
                    startConfiguredMonitoring()
                } else {
                    scanForPeripherals()
                }
                if let central = centralMgr { restoreKnownMonitoredPeripherals(using: central) }
                updatePresenceAuthentication()
            } else if isScanning {
                scanForPeripherals()
            }
        case .poweredOff:
            log("bluetooth powered off; clearing presence")
            bluetoothPoweredOn = false
            presence = false
            for runtime in monitoredRuntimes.values {
                runtime.invalidateTimers()
                runtime.peripheral = nil
                runtime.lastRSSI = nil
                runtime.presence = false
            }
            for runtime in reverseRuntimes.values {
                runtime.invalidateTimers()
                runtime.clearEvidence()
            }
            lastRSSISource = .none
            refreshPublishedMonitoringState()
            if !bluetoothPowerWarned {
                bluetoothPowerWarned = true
            }
        default:
            log("bluetooth unavailable state=\(String(describing: state))")
            for runtime in monitoredRuntimes.values {
                runtime.signalObservationIsContinuous = false
                runtime.cancelProximityTimer()
            }
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === centralMgr else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        noteAdvertisementActivity()

        if settings.isEnabled,
           let uuid = monitoredUUIDs.first(where: { $0 == peripheral.identifier }) {
            let runtime = ensureRuntime(for: uuid)
            let firstDiscovery = runtime.peripheral == nil
            runtime.peripheral = peripheral
            if firstDiscovery {
                log("monitored peripheral discovered uuid=\(uuid.uuidString) rssi=\(rssi) passive=\(settings.passiveMode)")
            }
            // An active-mode timer can outlive the connection it polls.
            // A real advertisement remains evidence even while reconnecting.
            receiveMonitoredAdvertisement(rssi, for: uuid)
        }

        guard isScanning else { return }
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            if uuids.contains(exposureNotificationUUID) { return }
        }

        if let existing = deviceMap[peripheral.identifier] {
            existing.rssi = rssi
            existing.lastSeenAt = Date()
            requestDeviceRefresh()
            return
        }

        guard rssi >= settings.thresholdRSSI else { return }
        if deviceMap.count >= Self.maximumVisibleDevices {
            guard let weakest = deviceMap.values.min(by: { $0.rssi < $1.rssi }), rssi > weakest.rssi else { return }
            deviceMap.removeValue(forKey: weakest.uuid)
            if let oldPeripheral = weakest.peripheral { central.cancelPeripheralConnection(oldPeripheral) }
        }
        let device = BLEUnlockDevice(uuid: peripheral.identifier)
        device.peripheral = peripheral
        device.rssi = rssi
        device.advertisementData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        if peripheral.name == nil, rssi >= -60 { device.resolveIdentity() }
        deviceMap[peripheral.identifier] = device
        log("device discovered uuid=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? device.bluetoothName ?? "unknown") rssi=\(rssi) visibleCount=\(deviceMap.count)")
        if device.bluetoothName == nil, peripheral.name == nil, rssi >= -55 {
            if activeConnectionsPaused {
                log("name resolution connection skipped reason=displayUnavailable uuid=\(peripheral.identifier.uuidString)")
            } else {
                central.connect(peripheral, options: nil)
            }
        }
        requestDeviceRefresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === centralMgr else { return }
        let monitoredRuntime = runtime(for: peripheral.identifier)
        let isMonitored = monitoredRuntime != nil
        log("peripheral connected monitored=\(isMonitored) uuid=\(peripheral.identifier.uuidString) state=\(String(describing: peripheral.state))")
        guard !activeConnectionsPaused else {
            log("connected peripheral cancelled because display policy blocks active connections")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard isScanning || isMonitored else {
            log("connected peripheral cancelled because it is not monitored or scanning")
            central.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
            return
        }
        peripheral.delegate = self
        if isScanning { peripheral.discoverServices([deviceInformationUUID]) }
        if isMonitored, !settings.passiveMode, let monitoredRuntime {
            monitoredRuntime.connectionTimer?.stop()
            monitoredRuntime.connectionTimer = nil
            monitoredRuntime.connectionRetryGate.reset()
            requestRSSIRead(for: monitoredRuntime)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === centralMgr else { return }
        log("peripheral connection failed monitored=\(runtime(for: peripheral.identifier) != nil) error=\(error?.localizedDescription ?? "unknown")")
        if let runtime = runtime(for: peripheral.identifier) {
            runtime.connectionTimer?.stop()
            runtime.connectionTimer = nil
            runtime.rssiRequestTimeoutTimer?.stop()
            runtime.rssiRequestTimeoutTimer = nil
            runtime.rssiReadGate.reset()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === centralMgr else { return }
        log("peripheral disconnected monitored=\(runtime(for: peripheral.identifier) != nil) error=\(error?.localizedDescription ?? "none")")
        if let runtime = runtime(for: peripheral.identifier) {
            runtime.connectionTimer?.stop()
            runtime.connectionTimer = nil
            runtime.rssiRequestTimeoutTimer?.stop()
            runtime.rssiRequestTimeoutTimer = nil
            runtime.rssiReadGate.reset()
            runtime.activeMode = runtime.activeModeTimer != nil
            refreshPublishedMonitoringState()
            refreshMonitoringDiscovery(reason: "peripheralDisconnected")
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let runtime = runtime(for: peripheral.identifier), runtime.peripheral === peripheral else { return }
        runtime.rssiRequestTimeoutTimer?.stop()
        runtime.rssiRequestTimeoutTimer = nil
        runtime.rssiReadGate.finish()
        if let error {
            logRSSIError(error)
            startMonitoringRecovery(reason: "rssiReadFailed", restartImmediately: true)
            return
        }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(rssi, for: runtime.uuid)

        if runtime.activeModeTimer == nil && !settings.passiveMode && !activeConnectionsPaused {
            let runtimeUUID = runtime.uuid
            runtime.activeModeTimer = BackgroundTask.repeating(every: 2) { [weak self] in
                guard let self, let runtime = self.runtime(for: runtimeUUID),
                      let peripheral = runtime.peripheral else { return }
                if peripheral.state == .connected {
                    self.requestRSSIRead(for: runtime)
                } else {
                    self.connectMonitoredPeripheral(for: runtime.uuid)
                }
            }
            runtime.activeMode = true
            // A cached CBPeripheral is not a working observation channel.
            // Keep discovering a watch that is disconnected or still waiting
            // for its first successful RSSI, even when the phone is healthy.
            if !isScanning && allLogicalDevicesHaveRSSIPolling { centralMgr?.stopScan() }
            refreshPublishedMonitoringState()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("service discovery failed error=\(error.localizedDescription)")
        } else {
            log("service discovery completed serviceCount=\(peripheral.services?.count ?? 0)")
        }
        for service in peripheral.services ?? [] where service.uuid == deviceInformationUUID {
            peripheral.discoverCharacteristics([manufacturerNameUUID, modelNameUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("characteristic discovery failed service=\(service.uuid.uuidString) error=\(error.localizedDescription)")
        }
        for chara in service.characteristics ?? [] where chara.uuid == manufacturerNameUUID || chara.uuid == modelNameUUID {
            peripheral.readValue(for: chara)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("characteristic value update failed characteristic=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
        }
        guard let value = characteristic.value, let str = String(data: value, encoding: .utf8) else { return }
        guard let device = deviceMap[peripheral.identifier] else { return }
        if characteristic.uuid == manufacturerNameUUID { device.manufacturer = str }
        if characteristic.uuid == modelNameUUID { device.model = str }
        if device.model != nil, !isMonitoredPeripheral(peripheral) {
            centralMgr?.cancelPeripheralConnection(peripheral)
        }
        requestDeviceRefresh()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log("peripheral services modified invalidated=\(invalidatedServices.map { $0.uuid.uuidString }.joined(separator: ","))")
        peripheral.discoverServices([deviceInformationUUID])
    }

    // MARK: Screen control

    func lockNow() {
        guard !isScreenLocked() else {
            log("manual lock skipped reason=alreadyLocked")
            return
        }
        log("manual lock requested")
        suppressAutomaticUnlock(reason: "lock-localManual")
        pauseNowPlaying()
        lockOrSaveScreen(source: .localManual)
    }

    private func lockOrSaveScreen(source: ScreenControlSource) {
        guard sessionIsOnConsole else {
            log("lock skipped reason=backgroundSession source=\(source.rawValue)")
            return
        }
        if let lockScreenOperation {
            lockScreenOperation(source)
            return
        }
        screenControl.markPendingLock(source: source)
        log("locking screen useScreensaver=\(settings.useScreensaver) turnOffScreen=\(settings.turnOffScreen)")
        if settings.useScreensaver {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        } else {
            screenControl.executor.lockScreenShortcut()
            if settings.turnOffScreen { DisplayPower.sleepDisplay() }
        }
    }

    private func recordScreenLock(at date: Date) {
        let source: ScreenLockHistorySource
        if let pendingLockSource, date <= pendingLockSourceExpiresAt {
            source = pendingLockSource
        } else {
            source = .manual
        }
        pendingLockSource = nil
        pendingLockSourceExpiresAt = .distantPast

        // A system shortcut/menu lock never passes through screenControl.willLock.
        // Unattributed locks must withdraw proximity permission immediately,
        // including an attempt queued before this notification or a duplicate
        // notification whose history entry is already open.
        screenUnlockConfirmationTask?.stop()
        screenUnlockConfirmationTask = nil
        if source != .automatic {
            suppressAutomaticUnlock(reason: "screenIsLocked-\(source.rawValue)")
        }

        guard settings.screenLockHistory.recordLock(at: date, source: source) else {
            log("screen lock history ignored reason=duplicate source=\(source.rawValue)")
            return
        }
        log("screen lock history recorded source=\(source.rawValue) at=\(date.timeIntervalSince1970)")
        notifyChange()
    }

    private func recordScreenUnlock(at date: Date, source: ScreenLockHistorySource) {
        unlockSignalTrigger.reset()
        guard settings.screenLockHistory.recordUnlock(at: date, source: source) else {
            log("screen unlock history ignored reason=unpaired-or-duplicate source=\(source.rawValue)")
            return
        }
        log("screen unlock history recorded source=\(source.rawValue) at=\(date.timeIntervalSince1970)")
        notifyChange()
    }

    func clearScreenLockHistory() {
        guard !settings.screenLockHistory.entries.isEmpty else { return }
        settings.screenLockHistory.clear()
        log("screen lock history cleared")
        notifyChange()
    }

    private func screenLockState() -> BLEScreenLockState {
        screenLockStateProbe()
    }

    /// A missing session dictionary keeps the pre-existing behavior; only an
    /// explicit `kCGSSessionOnConsoleKey = false` marks a fast-switched
    /// background session.
    ///
    /// `CGSessionCopyCurrentDictionary` describes the console session even
    /// when read from a fast-switched background session, so its on-console
    /// key says "true" about whoever owns the console — not about this
    /// process. That lie kept a background instance scanning for hours.
    /// The dynamic store names the real console user; this process is on
    /// console only when that user is this process's own UID.
    nonisolated static func currentSessionIsOnConsole() -> Bool {
        var consoleUID: uid_t = 0
        if let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) as String? {
            return !consoleUser.isEmpty && consoleUID == getuid()
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? true
    }

    func isScreenLocked() -> Bool {
        screenLockState() == .locked
    }

    private func tryUnlockScreen(trigger: String = "unspecified") {
        guard settings.isEnabled else {
            log("unlock skipped trigger=\(trigger) reason=featureDisabled")
            return
        }
        guard sessionIsOnConsole else {
            log("unlock skipped trigger=\(trigger) reason=backgroundSession")
            return
        }
        if manualLock {
            log("unlock skipped trigger=\(trigger) reason=manualLock")
            return
        }
        guard presence else {
            log("unlock skipped trigger=\(trigger) reason=notPresent")
            return
        }
        guard monitoringHasFreshSignal else {
            log("unlock skipped trigger=\(trigger) reason=noFreshSignal")
            return
        }
        guard settings.unlockRSSI != Self.unlockDisabled else {
            log("unlock skipped trigger=\(trigger) reason=unlockRSSIDisabled")
            return
        }
        guard !systemSleep else {
            log("unlock skipped trigger=\(trigger) reason=systemSleep")
            return
        }
        if !settings.wakeOnProximity, displayUnavailable {
            log("unlock skipped trigger=\(trigger) reason=displayUnavailable wakeOnProximity=false")
            return
        }
        if !automaticUnlockAllowed {
            log("unlock skipped trigger=\(trigger) reason=\(activeConnectionPauseReason)")
            return
        }
        log("unlock requested trigger=\(trigger) displaySleep=\(displaySleep) inScreensaver=\(inScreensaver) lastRSSI=\(lastRSSI.map(String.init) ?? "none")")

        if inScreensaver {
            screenControl.executor.dismissScreensaver()
        }

        guard !settings.wakeWithoutUnlocking else {
            log("unlock skipped trigger=\(trigger) reason=wakeWithoutUnlocking")
            return
        }

        // Do not make the unlock depend on a single display-wake notification.
        // A keyboard wake can make the display usable before AppKit delivers
        // `screensDidWake`, and the opposite ordering is also possible.
        scheduleUnlockAttempt(trigger: trigger)
    }

    private func displayIsReadyForUnlock() -> Bool {
        // `displaySleep` is maintained from notifications and is therefore a
        // useful hint, but it can remain stale when the user wakes the Mac by
        // pressing a key. Query the display as well so that wake recovery can
        // proceed even when that notification was missed.
        let isAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let heldBlankBlocksUnlock = !settings.wakeOnProximity && displayUnavailable
        log("display readiness checked asleep=\(isAsleep) notificationSleep=\(displaySleep) heldBlankBlocksUnlock=\(heldBlankBlocksUnlock) systemSleep=\(systemSleep)")
        if !isAsleep, displaySleep {
            // Repair the notification-derived state as soon as the display
            // proves that it has actually woken.
            displaySleep = false
            wakeRetryTask?.cancel()
            wakeRetryTask = nil
        }
        return !isAsleep && !heldBlankBlocksUnlock
    }

    private func cancelUnlockAttempt(reason: String = "unspecified") {
        if unlockAttemptSlot.isOccupied {
            log("unlock attempt cancelled reason=\(reason)")
        }
        unlockAttemptTask?.cancel()
        unlockAttemptTask = nil
        unlockAttemptSlot.invalidate()
        unlockSignalTrigger.reset()
        lastUnlockRequestAt = 0
    }

    private func suppressAutomaticUnlock(reason: String) {
        manualLock = true
        manualLockHasObservedDisplaySleep = displayUnavailable
        // A departure window must start from a fresh distant sample after this
        // lock, rather than inheriting an old timer or a recovery reset.
        for runtime in monitoredRuntimes.values {
            runtime.cancelProximityTimer()
            let sampleAge = runtime.lastRSSISampledAt.map { userActivityMonitor.now - $0 }
            let sampleIsFresh = sampleAge.map { $0 >= 0 && $0 < TimeInterval(settings.signalTimeout) } == true
            runtime.signalObservationIsContinuous = runtime.signalObservationIsContinuous
                && runtime.lastRSSI != nil && sampleIsFresh && !activeConnectionsPaused
            // Every lock gets a complete observation window. An old timer
            // about to expire cannot immediately undo a new manual lock.
            resetSignalTimer(for: runtime.uuid)
        }
        for runtime in reverseRuntimes.values {
            runtime.cancelProximityTimer()
            let sampleAge = runtime.lastRSSISampledAt.map { userActivityMonitor.now - $0 }
            let sampleIsFresh = sampleAge.map { $0 >= 0 && $0 < TimeInterval(settings.signalTimeout) } == true
            runtime.signalObservationIsContinuous = runtime.signalObservationIsContinuous
                && runtime.lastRSSI != nil && sampleIsFresh && !activeConnectionsPaused
            resetReverseSignalTimer(for: runtime)
        }
        cancelUnlockAttempt(reason: reason)
        wakeRetryTask?.cancel()
        wakeRetryTask = nil
        lastAutomaticUnlockRequestAt = 0
        lastAutomaticUnlockConfirmationAt = 0
        log("automatic unlock suppressed reason=\(reason)")
    }

    private func rearmAutomaticUnlockAfterManualLockDisplayWake(trigger: String) {
        guard manualLock, manualLockHasObservedDisplaySleep else { return }
        manualLock = false
        manualLockHasObservedDisplaySleep = false
        unlockSignalTrigger.reset()
        log("automatic unlock rearmed reason=manualLockDisplayWake trigger=\(trigger)")
    }

    private func formattedUnlockAge(_ age: TimeInterval?) -> String {
        guard let age else { return "none" }
        return String(format: "%.3f", age)
    }

    private func recentAutomaticUnlockRequestAge(at date: Date) -> TimeInterval? {
        guard lastAutomaticUnlockRequestAt > 0 else { return nil }
        let age = date.timeIntervalSince1970 - lastAutomaticUnlockRequestAt
        guard age >= 0, age < 15 else { return nil }
        return age
    }

    func noteAutomaticUnlockRequest(at time: TimeInterval) {
        lastUnlockRequestAt = time
        lastAutomaticUnlockRequestAt = time
    }

    func confirmAutomaticUnlock(source: String, eventDate: Date = Date()) {
        let now = Date().timeIntervalSince1970
        let state = screenLockState()
        guard BLEUnlockConfirmation.isConfirmed(screenState: state) else {
            log("unlock confirmation rejected source=\(source) screenState=\(state.rawValue)")
            return
        }
        unlockSignalTrigger.reset()

        let requestAge = lastUnlockRequestAt > 0 ? now - lastUnlockRequestAt : nil
        let automaticRequestAge = recentAutomaticUnlockRequestAge(at: eventDate)
        let hasOpenSession = settings.screenLockHistory.entries.contains(where: \.isStillLocked)
        guard automaticRequestAge != nil || hasOpenSession else {
            // A wake retry can find an already unlocked desktop. Without a
            // command or an open session there is no new unlock to attribute,
            // no event script to run and no notification to suppress later.
            log("unlock completion skipped source=\(source) reason=noPendingRequestOrSession")
            lastUnlockRequestAt = 0
            lastAutomaticUnlockRequestAt = 0
            manualLock = false
            return
        }

        let historySource: ScreenLockHistorySource = automaticRequestAge == nil ? .manual : .automatic
        lastAutomaticUnlockConfirmationAt = now
        log("screen unlock confirmed source=\(source) screenState=unlocked requestAge=\(formattedUnlockAge(requestAge)) historySource=\(historySource.rawValue)")
        // Complete history now: the delayed distributed notification may
        // arrive after this state probe and be de-duplicated.
        recordScreenUnlock(at: eventDate, source: historySource)
        lastUnlockRequestAt = 0
        lastAutomaticUnlockRequestAt = 0
        manualLock = false
        playNowPlaying()
        if historySource == .automatic {
            runScript("unlocked")
        } else if settings.unlockRSSI != Self.unlockDisabled {
            runScript("intruded")
        }
    }

    private func scheduleUnlockAttempt(trigger: String) {
        guard let generation = unlockAttemptSlot.claim() else {
            log("unlock attempt already scheduled trigger=\(trigger)")
            return
        }

        log("unlock attempt scheduled trigger=\(trigger) deadlines=\(BLEUnlockAttemptPlan.standard.deadlines)")
        unlockAttemptTask = Task { [weak self] in
            var previousDeadline: TimeInterval = 0
            var progress = BLEUnlockAttemptProgress(plan: .standard)
            while let deadline = progress.nextDeadline {
                let wait = deadline - previousDeadline
                if wait > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(wait * 1_000)))
                }
                guard !Task.isCancelled, let self else { return }
                guard self.unlockAttemptSlot.generation == generation else {
                    self.log("unlock attempt stopped deadline=\(deadline) reason=generationChanged")
                    return
                }
                switch BLEUnlockAttemptGate.decide(
                    presence: self.presence,
                    manualLock: self.manualLock,
                    unlockDisabled: self.settings.unlockRSSI == Self.unlockDisabled,
                    wakeWithoutUnlocking: self.settings.wakeWithoutUnlocking,
                    systemSleep: self.systemSleep
                ) {
                case .stop:
                    self.log("unlock attempt stopped deadline=\(deadline) reason=stateChanged manualLock=\(self.manualLock) presence=\(self.presence) systemSleep=\(self.systemSleep)")
                    self.unlockAttemptSlot.release(generation: generation)
                    return
                case .waitForPresence:
                    // The display-wake recovery rebuilds the BLE link and resets
                    // presence while the phone is already next to this Mac. Skip
                    // this deadline but keep the rest of the plan armed, so the
                    // retry survives the reconnect instead of dying with it.
                    self.log("unlock attempt deferred deadline=\(deadline) reason=presencePending")
                    progress.skipCurrentDeadline()
                    previousDeadline = deadline
                    continue
                case .proceed:
                    break
                }
                self.log("unlock attempt checking deadline=\(deadline)")

                // Keep waiting while the display is genuinely asleep. This
                // handles both proximity-wake and a later keyboard wake.
                if !self.displayIsReadyForUnlock() {
                    self.log("unlock attempt deferred deadline=\(deadline) reason=displayAsleep")
                    progress.skipCurrentDeadline()
                    previousDeadline = deadline
                    continue
                }

                let screenState = self.screenLockState()
                self.log("unlock screen state sampled deadline=\(deadline) state=\(screenState.rawValue)")
                switch progress.nextAction(screenState: screenState) {
                case .confirmed:
                    self.unlockAttemptTask = nil
                    self.unlockAttemptSlot.release(generation: generation)
                    self.confirmAutomaticUnlock(source: "screenState deadline=\(deadline)")
                    return
                case .stateUnavailable:
                    self.log("unlock attempt deferred deadline=\(deadline) reason=screenStateUnavailable")
                case .exhausted:
                    self.log("unlock attempt exhausted before posting deadline=\(deadline)")
                case .postPassword(let attemptDeadline):
                    guard self.automaticUnlockAllowed else {
                        self.log("unlock attempt stopped deadline=\(attemptDeadline) reason=\(self.activeConnectionPauseReason)")
                        self.unlockAttemptSlot.release(generation: generation)
                        return
                    }
                    guard let password = self.fetchPassword(warn: true) else {
                        self.log("unlock attempt stopped deadline=\(attemptDeadline) reason=passwordUnavailable")
                        self.unlockAttemptSlot.release(generation: generation)
                        return
                    }
                    let requestTimestamp = Date().timeIntervalSince1970
                    self.noteAutomaticUnlockRequest(at: requestTimestamp)
                    self.log("posting unlock key events deadline=\(attemptDeadline) screenState=locked accessibilityTrusted=\(AXIsProcessTrusted())")
                    guard self.settings.wakeOnProximity || !self.displayUnavailable else {
                        self.lastUnlockRequestAt = 0
                        self.lastAutomaticUnlockRequestAt = 0
                        self.log("unlock attempt stopped deadline=\(attemptDeadline) reason=displayBecameUnavailable wakeOnProximity=false")
                        self.unlockAttemptSlot.release(generation: generation)
                        return
                    }
                    await self.fakeKeyStrokes(password)
                    self.log("unlock key events posted deadline=\(attemptDeadline) screenStateAfterPost=\(self.screenLockState().rawValue)")
                }
                previousDeadline = deadline
            }

            guard let self, self.unlockAttemptSlot.generation == generation else { return }
            self.unlockAttemptSlot.release(generation: generation)
            self.log("unlock attempt exhausted without unlock screenState=\(self.screenLockState().rawValue)")
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        presenceActionObserver?(presence)
        log("presence handler value=\(presence) reason=\(reason) currentState=\(self.presence) lastRSSI=\(lastRSSI.map(String.init) ?? "none") displaySleep=\(displaySleep) systemSleep=\(systemSleep)")
        guard settings.isEnabled else {
            log("presence action skipped reason=featureDisabled")
            return
        }
        if presence {
            guard !manualLock else {
                log("presence close ignored reason=manualLock")
                return
            }
            if settings.unlockRSSI != Self.unlockDisabled {
                if displaySleep && !systemSleep && settings.wakeOnProximity {
                    log("waking display due to proximity reason=\(reason)")
                    DisplayPower.wakeDisplay()
                    wakeRetryTask?.cancel()
                    wakeRetryTask = Task { [weak self] in
                        // A missing screensDidWake notification must not leave
                        // an endless user-activity assertion running overnight.
                        for _ in 0..<10 {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, self != nil else { return }
                            DisplayPower.wakeDisplay()
                        }
                        self?.wakeRetryTask = nil
                        self?.log("display wake retry task finished")
                    }
                }
                tryUnlockScreen(trigger: "presence-\(reason)")
            } else {
                log("presence close observed but auto-unlock is disabled")
            }
        } else {
            wakeRetryTask?.cancel(); wakeRetryTask = nil
            cancelUnlockAttempt(reason: "presence-\(reason)")
            if !isScreenLocked() && settings.lockRSSI != Self.lockDisabled {
                log("locking due to presence loss reason=\(reason)")
                pauseNowPlaying()
                lockOrSaveScreen(source: .bleAutomatic)
                runScript(reason)
            } else {
                log("presence loss did not lock screen alreadyLocked=\(isScreenLocked()) lockRSSIDisabled=\(settings.lockRSSI == Self.lockDisabled)")
            }
            // Only a sustained distant RSSI window or a full signal timeout
            // under uninterrupted monitoring rearms a manual lock. Pause and
            // recovery resets cannot replace a departure observation.
        }
    }

    private func fakeKeyStrokes(_ string: String) async {
        // The implementation lives in ScreenUnlockExecutor so the BLE proximity
        // unlock and the iPhone remote unlock type the same keystrokes.
        await screenControl.executor.postPassword(string, shouldContinue: { [weak self] in
            self?.automaticUnlockAllowed == true
        })
    }

    // MARK: Keychain password

    /// BLE proximity unlock and the LAN remote control share one Keychain item
    /// through `ScreenCredentialStore`. The password never leaves this Mac.
    var hasPassword: Bool { screenControl.credentials.hasCredential }

    @discardableResult
    func storePassword(_ password: String) -> Bool {
        let success = screenControl.credentials.storePassword(password)
        if success { unlockSignalTrigger.reset() }
        objectWillChange.send()
        return success
    }

    func fetchPassword(warn: Bool = false) -> String? {
        screenControl.credentials.loadPassword(warn: warn)
    }

    // MARK: MediaRemote (optional)

    private func ensureMediaRemote() {
        guard mediaRemoteHandle == nil else { return }
        mediaRemoteHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        guard let handle = mediaRemoteHandle else { return }
        let sendPtr = dlsym(handle, "MRMediaRemoteSendCommand")
        let getPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        if let sendPtr { mrSendCommand = unsafeBitCast(sendPtr, to: (@convention(c) (Int32, AnyObject?) -> Bool).self) }
        if let getPtr { mrGetPlaying = unsafeBitCast(getPtr, to: (@convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void).self) }
    }

    private func pauseNowPlaying() {
        guard settings.pauseNowPlaying else { return }
        ensureMediaRemote()
        guard let get = mrGetPlaying else { return }
        get(.main) { [weak self] playing in
            guard let self else { return }
            self.nowPlayingWasPlaying = playing
            if playing { _ = self.mrSendCommand?(1, nil) }
        }
    }

    private func playNowPlaying() {
        guard settings.pauseNowPlaying, nowPlayingWasPlaying else { return }
        mediaResumeTask?.stop()
        mediaResumeTask = BackgroundTask.once(after: 0.5) { [weak self] in
            guard let self else { return }
            self.mediaResumeTask = nil
            self.nowPlayingWasPlaying = false
            _ = self.mrSendCommand?(0, nil)
        }
    }

    // MARK: Event script

    func runScript(_ arg: String) {
        if let eventScriptRunner {
            eventScriptRunner(arg)
            return
        }
        let scriptsDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Scripts")
        var bundleIdentifiers = [Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier]
        bundleIdentifiers.append(contentsOf: AppIdentity.knownBundleIdentifiers.filter { !bundleIdentifiers.contains($0) })
        guard let file = bundleIdentifiers
            .map({ scriptsDirectory.appendingPathComponent($0).appendingPathComponent("event") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            log("event script not found arg=\(arg)")
            return
        }
        let process = Process()
        process.executableURL = file
        process.arguments = lastRSSI.map { [arg, String($0)] } ?? [arg]
        do {
            try process.run()
            log("event script started arg=\(arg) path=\(file.path)")
        } catch {
            log("event script failed arg=\(arg) error=\(error.localizedDescription)")
        }
    }

    // MARK: Display / system observers

    private let observers = ObserverBag()
    private var mediaResumeTask: BackgroundTask?
    private var screenUnlockConfirmationTask: BackgroundTask?

    func handleSystemWillSleep() {
        log("system will sleep presence=\(presence) lastRSSI=\(lastRSSI.map(String.init) ?? "none") monitored=\(monitoredUUIDs.count)")
        systemSleep = true
        reconcileActiveConnectionPolicy(reason: "systemWillSleep", force: true)
        screenControl.noteSystemSleeping(true)
        recoveringFromSystemSleep = true
        wakeRetryTask?.cancel(); wakeRetryTask = nil
        cancelUnlockAttempt()
        systemWakeRecoveryTask?.cancel(); systemWakeRecoveryTask = nil
        cancelMonitoringRecovery(reason: "systemSleep")

        // Run-loop timers become immediately overdue after a long sleep. Stop
        // them here so they cannot turn a pre-sleep sample into a false wake
        // decision before CoreBluetooth has produced a fresh RSSI value.
        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
        }
        for runtime in reverseRuntimes.values {
            runtime.invalidateTimers()
        }
        refreshPublishedMonitoringState()
    }

    private func prepareMonitoringForWakeRecovery() {
        guard settings.isEnabled, hasMonitoredDevice else {
            log("wake recovery preparation skipped enabled=\(settings.isEnabled) monitored=\(hasMonitoredDevice)")
            return
        }
        log("preparing monitoring for system wake recovery")

        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
            runtime.latestRSSIs.removeAll(keepingCapacity: true)
            if let peripheral = runtime.peripheral {
                centralMgr?.cancelPeripheralConnection(peripheral)
            }
            runtime.peripheral = nil
            runtime.presence = false
            runtime.lastRSSI = nil
        }
        for runtime in reverseRuntimes.values {
            runtime.invalidateTimers()
            runtime.clearEvidence()
        }
        cancelUnlockAttempt()

        // A CBPeripheral or scan that survived ordinary display sleep can be
        // stale after deep idle. Discard both and wait for a fresh sample.
        centralMgr?.stopScan()
        presence = false
        refreshPublishedMonitoringState()
        log("monitoring reset for system wake recovery")
    }

    private func restartMonitoringAfterWake() {
        guard settings.isEnabled, hasMonitoredDevice else {
            log("monitoring restart after wake skipped enabled=\(settings.isEnabled) monitored=\(hasMonitoredDevice)")
            return
        }
        log("restarting monitoring after system wake")
        ensureCentralManager()
        guard let central = centralMgr, central.state == .poweredOn else {
            log("monitoring restart after wake deferred centralState=\(String(describing: centralMgr?.state))")
            return
        }

        restoreKnownMonitoredPeripherals(using: central)

        // CoreBluetooth can continue reporting isScanning after deep idle even
        // though no discoveries arrive. A stop/start creates a fresh session.
        central.stopScan()
        scanForPeripherals()
    }

    private func restoreKnownMonitoredPeripherals(using central: CBCentralManager) {
        BLEMonitoringRestoration.restore(
            identifiers: monitoredUUIDs,
            passiveMode: settings.passiveMode,
            activeConnectionsPaused: activeConnectionsPaused,
            retrieve: { uuid in
                let runtime = self.ensureRuntime(for: uuid)
                return runtime.peripheral ?? central.retrievePeripherals(withIdentifiers: [uuid]).first
            },
            connect: { uuid, peripheral in
                self.ensureRuntime(for: uuid).peripheral = peripheral
                self.log("restoring known monitored peripheral uuid=\(uuid.uuidString) state=\(peripheral.state.rawValue)")
                self.connectMonitoredPeripheral(for: uuid)
            },
            armSignalTimeout: { uuid in
                let runtime = self.ensureRuntime(for: uuid)
                if runtime.signalTimer == nil { self.resetSignalTimer(for: uuid) }
            }
        )
    }

    private var monitoringHasFreshSignal: Bool {
        BLEDevicePresencePolicy.isSatisfied(
            presences: logicalDeviceFreshSignalStates(),
            relation: settings.deviceRelation
        )
    }

    /// Legacy-link discovery still needs to recover when only the reverse link
    /// is fresh: the two directions run in parallel and one must never be used
    /// as evidence that the other is healthy.
    private var monitoringHasLegacyFreshSignal: Bool {
        BLEDevicePresencePolicy.isSatisfied(
            presences: logicalDeviceLegacyFreshSignalStates(),
            relation: settings.deviceRelation
        )
    }

    private func logicalDeviceLegacyFreshSignalStates() -> [Bool] {
        logicalDeviceUUIDs.map { logical in
            settings.identityRegistry.uuids(for: logical).contains {
                monitoredRuntimes[$0]?.lastRSSI != nil
            }
        }
    }

    private func startDisplayWakeMonitoringRecovery(clearSignal: Bool) {
        guard settings.isEnabled, hasMonitoredDevice, !systemSleep else { return }
        // Wake must not wait behind a signal-timeout recovery already in flight.
        cancelMonitoringRecovery(reason: "displayWake")
        if clearSignal {
            for runtime in monitoredRuntimes.values {
                runtime.lastRSSI = nil
                runtime.signalObservationIsContinuous = false
                runtime.latestRSSIs.removeAll(keepingCapacity: true)
                runtime.presence = false
                runtime.cancelProximityTimer()
                // The pre-sleep deadline must not interrupt the cold reconnect.
                // Presence stays false; this extends recovery, never RSSI validity.
                resetSignalTimer(for: runtime.uuid, minimumDelay: BLEConnectionRetryGate.connectionTimeout)
            }
            for runtime in reverseRuntimes.values {
                runtime.clearEvidence()
                runtime.invalidateTimers()
                resetReverseSignalTimer(
                    for: runtime,
                    minimumDelay: BLEConnectionRetryGate.connectionTimeout
                )
            }
            presence = false
            refreshPublishedMonitoringState()
        }
        startMonitoringRecovery(reason: "displayWake", restartImmediately: true)
    }

    private func restartMonitoringAfterRecovery(reason: String, resetCentral: Bool) {
        guard settings.isEnabled, hasMonitoredDevice, !systemSleep else { return }
        if reason == "displayWake" || reason == "signalTimeout"
            || reason == "rssiRequestTimeout" || reason == "rssiReadFailed"
            || !resetCentral || activeConnectionsPaused {
            // Discover immediately using the existing session. Recreating the
            // central here (and again at 3/10 seconds) cancels the connections
            // that the wake transition has just started restoring.
            ensureCentralManager()
            let scanning = bluetoothScanner.restartIfPoweredOn()
            lastMonitoringDiscoveryAt = userActivityMonitor.now
            let event = reason == "displayWake" ? "display wake scan" : "monitoring recovery scan"
            log("\(event) \(scanning ? "restarted" : "deferred") preservingConnections=true reason=\(reason)")
            if let central = centralMgr, central.state == .poweredOn {
                restoreKnownMonitoredPeripherals(using: central)
            }
            return
        }
        log("restarting monitoring after recovery reason=\(reason)")

        let central = centralMgr
        central?.stopScan()
        for runtime in monitoredRuntimes.values {
            runtime.invalidateTimers()
            if let peripheral = runtime.peripheral {
                central?.cancelPeripheralConnection(peripheral)
                peripheral.delegate = nil
            }
            runtime.peripheral = nil
            runtime.lastRSSI = nil
            runtime.latestRSSIs.removeAll(keepingCapacity: true)
            runtime.presence = false
        }
        // Resetting the published presence here must not cancel an armed
        // unlock attempt: this restart happens right after a proximity wake,
        // and the attempt has to survive the reconnect. `BLEUnlockAttemptGate`
        // treats the transient false presence as "wait", not "stop".
        presence = false
        refreshPublishedMonitoringState()

        // Recreate the central manager rather than trusting a scan session
        // which may still claim to be active after an idle display wake.
        central?.delegate = nil
        centralMgr = nil
        ensureCentralManager()
    }

    private func startMonitoringRecovery(reason: String, restartImmediately: Bool = false) {
        guard !systemSleep,
              let plan = BLEMonitoringRecoveryPlan.make(
                isEnabled: settings.isEnabled,
                hasMonitoredDevice: hasMonitoredDevice
              ) else { return }
        guard monitoringRecoveryTask == nil else {
            log("monitoring recovery already scheduled reason=\(reason)")
            return
        }

        let restartDelays: [TimeInterval]
        if restartImmediately {
            restartMonitoringAfterRecovery(reason: reason, resetCentral: true)
            guard !monitoringHasLegacyFreshSignal else { return }
            restartDelays = plan.restartDelays.filter { $0 > 0 }
        } else {
            restartDelays = plan.restartDelays
        }
        log("monitoring recovery scheduled reason=\(reason) delays=\(plan.restartDelays)")
        monitoringRecoveryTask = Task { [weak self] in
            var previousDeadline: TimeInterval = 0
            for deadline in restartDelays {
                let wait = deadline - previousDeadline
                if wait > 0 {
                    guard let sleep = self?.monitoringRecoverySleep else { return }
                    await sleep(wait)
                }
                guard !Task.isCancelled, let self else { return }
                guard !self.monitoringHasLegacyFreshSignal else { break }
                // Only the first checkpoint can replace a broken session.
                // Retrying discovery at 3/10s must not cancel a 60s connection.
                self.restartMonitoringAfterRecovery(reason: reason, resetCentral: deadline == 0)
                previousDeadline = deadline
            }
            self?.monitoringRecoveryTask = nil
            self?.log("monitoring recovery finished legacyFreshSignal=\(self?.monitoringHasLegacyFreshSignal ?? false)")
        }
    }

    private func stopMonitoringRecovery(reason: String) {
        guard monitoringRecoveryTask != nil, monitoringHasLegacyFreshSignal else { return }
        cancelMonitoringRecovery(reason: reason)
    }

    private func cancelMonitoringRecovery(reason: String) {
        guard monitoringRecoveryTask != nil else { return }
        monitoringRecoveryTask?.cancel()
        monitoringRecoveryTask = nil
        log("monitoring recovery cancelled reason=\(reason)")
    }

    // MARK: Advertisement liveness watchdog

    /// Any advertisement callback — monitored or not — proves the system is
    /// still delivering Bluetooth data to this process.
    private func noteAdvertisementActivity() {
        advertisementLiveness.noteActivity()
        if advertisementStreamStalled {
            advertisementStreamStalled = false
            log("advertisement stream recovered")
        }
    }

    private func startLivenessTimer() {
        guard livenessTimer == nil else { return }
        livenessTimer = BackgroundTask.repeating(every: 60) { [weak self] in
            self?.evaluateAdvertisementLiveness()
        }
    }

    private func stopLivenessTimer() {
        livenessTimer?.stop()
        livenessTimer = nil
    }

    /// Internal so tests can drive the silence watchdog without waiting out
    /// real thresholds.
    func evaluateAdvertisementLiveness() {
        let monitoringActive = BLEAdvertisementLiveness.monitoringActive(
            featureEnabled: settings.isEnabled,
            hasMonitoredDevice: hasMonitoredDevice,
            bluetoothPoweredOn: bluetoothPoweredOn,
            displayAsleep: displayUnavailable,
            systemAsleep: systemSleep,
            centralScanning: advertisementCallbacksExpected
        )
        let now = Date()
        let silent = advertisementLiveness.evaluate(now: now, monitoringActive: monitoringActive)
        if silent, !advertisementStreamStalled {
            advertisementStreamStalled = true
            log("advertisement stream stalled reason=noCallbacksWhileMonitoringActive threshold=\(Int(advertisementLiveness.silenceThreshold))s; attempting monitoring recovery")
            // Silence alone does not identify its cause. Restore monitoring
            // and report the symptom without blaming other running copies.
            startMonitoringRecovery(reason: "advertisementSilence", restartImmediately: true)
        }
        if silent {
            let escalationInterval = advertisementLiveness.silenceThreshold * 3
            let silentFor = now.timeIntervalSince(advertisementLiveness.lastActivityAt)
            let lastRebuildIsStale = lastBLEClientRebuildAt.map {
                now.timeIntervalSince($0) >= escalationInterval
            } ?? true
            if silentFor >= escalationInterval, lastRebuildIsStale {
                rebuildBLEClientStack(reason: "advertisementSilence")
            }
        }
        checkOtherInstances()
    }

    /// The scan leg of the watchdog's `monitoringActive` input.
    var advertisementCallbacksExpected: Bool {
        let rediscovery = BLEScanPolicy.rediscoveryInterval(signalTimeout: settings.signalTimeout)
        return centralMgr?.isScanning == true
            || lastScanAttemptAt.map { Date().timeIntervalSince($0) < max(15, rediscovery * 2) } == true
    }

    /// Scan restarts reuse the same daemon-wedged CoreBluetooth client
    /// forever. A full teardown releases the XPC session behind it and
    /// rebuilds every radio the feature owns — the one recovery a scan
    /// restart cannot express. Bounded to once per three silence windows so
    /// a merely quiet room only ever pays the scan restart.
    private func rebuildBLEClientStack(reason: String) {
        guard sessionIsOnConsole, settings.isEnabled, hasMonitoredDevice else { return }
        lastBLEClientRebuildAt = Date()
        log("rebuilding BLE client reason=\(reason)")
        stopMonitoring()
        ensureCentralManager()
        if centralMgr?.state == .poweredOn { startConfiguredMonitoring() }
    }

    private func checkOtherInstances() {
        let count = DuplicateInstanceDetector.otherInstanceCount()
        guard count != otherInstanceCount else { return }
        if count > otherInstanceCount {
            log("other instances detected count=\(count) bluetoothActivity=unknown; process presence does not establish a BLE conflict")
        }
        otherInstanceCount = count
    }

    private var monitoringNeedsWakeRestart: Bool {
        logicalDeviceStates { $0.lastRSSI != nil }.contains(false)
    }

    func startSystemWakeRecovery(using plan: BLEWakeRecoveryPlan) {
        log("system wake recovery scheduled monitoringDelays=\(plan.monitoringRestartDelays) unlockDelays=\(plan.unlockRetryDelays)")
        recoveringFromSystemSleep = true
        systemWakeRecoveryTask?.cancel()
        systemWakeRecoveryTask = Task { [weak self] in
            let deadlines = Set(plan.monitoringRestartDelays + plan.unlockRetryDelays).sorted()
            var previousDeadline: TimeInterval = 0

            for deadline in deadlines {
                let wait = deadline - previousDeadline
                if wait > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(wait * 1_000)))
                }
                guard !Task.isCancelled, let self else { return }
                self.log("system wake recovery deadline reached deadline=\(deadline) lastRSSI=\(self.lastRSSI.map(String.init) ?? "none") presence=\(self.presence)")

                if plan.monitoringRestartDelays.contains(deadline), self.monitoringNeedsWakeRestart {
                    self.restartMonitoringAfterWake()
                }
                if plan.unlockRetryDelays.contains(deadline) {
                    self.tryUnlockScreen(trigger: "systemWakeRecovery-\(deadline)")
                }
                previousDeadline = deadline
            }
            self?.recoveringFromSystemSleep = false
            self?.systemWakeRecoveryTask = nil
            self?.log("system wake recovery finished")
            self?.tryUnlockScreen(trigger: "systemWakeRecovery-finished")
        }
    }

    private func handleSystemDidWake() {
        log("system did wake")
        systemSleep = false
        if !displayUnavailable {
            rearmAutomaticUnlockAfterManualLockDisplayWake(trigger: "systemWakeDisplayReady")
        }
        screenControl.noteSystemSleeping(false)
        cancelMonitoringRecovery(reason: "systemWake")
        guard let plan = BLEWakeRecoveryPlan.make(
            isEnabled: settings.isEnabled,
            hasMonitoredDevice: hasMonitoredDevice
        ) else {
            log("system wake recovery not needed enabled=\(settings.isEnabled) monitored=\(hasMonitoredDevice)")
            recoveringFromSystemSleep = false
            return
        }

        prepareMonitoringForWakeRecovery()
        startSystemWakeRecovery(using: plan)
    }

    func startObservingSystemState() {
        guard observers.isEmpty else {
            log("system observers already installed count=\(observers.count)")
            return
        }
        log("installing system observers")
        if sessionIsOnConsole { startUserActivityObservation() }
        startConsoleOwnershipPolling()
        let nc = workspaceNotificationCenter
        observers.add(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displaySleep = true
                if self.manualLock { self.manualLockHasObservedDisplaySleep = true }
                self.screenControl.noteDisplaySleeping(true)
                self.log("display sleep notification received")
                self.reconcileActiveConnectionPolicy(reason: "screensDidSleep", force: true)
            }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hadSleepTransition = self.displaySleep || self.systemSleep
                self.log("display wake notification received")
                self.displaySleep = false
                self.rearmAutomaticUnlockAfterManualLockDisplayWake(trigger: "screensDidWake")
                self.screenControl.noteDisplaySleeping(false)
                self.userActivityMonitor.noteDisplayWake(
                    fromSleep: hadSleepTransition, waitingForUnlock: self.waitingForAutomaticUnlock
                )
                self.recoveringFromSystemSleep = false
                self.wakeRetryTask?.cancel()
                self.startDisplayWakeMonitoringRecovery(clearSignal: hadSleepTransition)
                self.reconcileActiveConnectionPolicy(reason: "screensDidWake", force: true)
                self.tryUnlockScreen(trigger: "screensDidWake")
            }
        }, center: nc)
        observers.add(heldBlankNotificationCenter.addObserver(
            forName: DisplayPower.blankStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.displayUnavailable {
                    self.rearmAutomaticUnlockAfterManualLockDisplayWake(trigger: "heldBlankRestored")
                    self.userActivityMonitor.noteDisplayWake(
                        fromSleep: true, waitingForUnlock: self.waitingForAutomaticUnlock
                    )
                    self.startDisplayWakeMonitoringRecovery(clearSignal: true)
                } else if self.manualLock {
                    self.manualLockHasObservedDisplaySleep = true
                }
                self.reconcileActiveConnectionPolicy(reason: "heldBlankChanged", force: true)
            }
        }, center: heldBlankNotificationCenter)
        observers.add(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemWillSleep() }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("system wake notification received")
                self?.handleSystemDidWake()
            }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSessionDidResignActive() }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSessionDidBecomeActive() }
        }, center: nc)

        let dnc = screenStateNotificationCenterOverride ?? DistributedNotificationCenter.default
        observers.add(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionIsOnConsole else { return }
                self.recordScreenLock(at: Date())
            }
        }, center: dnc)
        observers.add(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            let eventDate = Date()
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.sessionIsOnConsole else {
                    self.log("screen unlock notification ignored reason=backgroundSession")
                    return
                }
                self.screenUnlockConfirmationTask?.stop()
                self.screenUnlockConfirmationTask = BackgroundTask.once(after: 2) { [weak self] in
                    guard let self else { return }
                    self.screenUnlockConfirmationTask = nil
                    let now = Date().timeIntervalSince1970
                    let screenState = self.screenLockState()
                    let requestAge = self.recentAutomaticUnlockRequestAge(at: eventDate)
                    let confirmationAge = self.lastAutomaticUnlockConfirmationAt > 0 ? now - self.lastAutomaticUnlockConfirmationAt : nil
                    self.log("screen unlocked notification received screenState=\(screenState.rawValue) requestAge=\(self.formattedUnlockAge(requestAge)) confirmationAge=\(self.formattedUnlockAge(confirmationAge))")

                    guard BLEUnlockConfirmation.isConfirmed(screenState: screenState) else {
                        self.log("screen unlock notification ignored reason=sessionStillLocked")
                        return
                    }

                    if let requestAge, requestAge >= 0, requestAge < 15 {
                        self.confirmAutomaticUnlock(source: "screenIsUnlockedNotification", eventDate: eventDate)
                        return
                    }

                    if let confirmationAge, confirmationAge >= 0, confirmationAge < 5,
                       !self.settings.screenLockHistory.entries.contains(where: \.isStillLocked) {
                        self.log("screen unlock notification already handled reason=recentConfirmation")
                        self.manualLock = false
                        return
                    }

                    self.recordScreenUnlock(at: eventDate, source: .manual)
                    if self.settings.unlockRSSI != Self.unlockDisabled { self.runScript("intruded") }
                    self.playNowPlaying()
                    self.log("screen unlock classified as external or manual")
                    self.manualLock = false
                }
            }
        }, center: dnc)
    }

    /// Removes the observers installed by `startObservingSystemState()`. Safe to
    /// call repeatedly; used when BLE is switched off and on app termination.
    func stopObservingSystemState() {
        stopUserActivityObservation()
        stopConsoleOwnershipPolling()
        mediaResumeTask?.stop()
        mediaResumeTask = nil
        screenUnlockConfirmationTask?.stop()
        screenUnlockConfirmationTask = nil
        guard !observers.isEmpty else { return }
        observers.removeAll()
        log("removed system observers")
    }

    /// Backstop for `NSWorkspace` session notifications, which have been
    /// observed to never arrive for some console switches. Polls the true
    /// console owner and drives the same suspend/resume paths.
    private func startConsoleOwnershipPolling() {
        guard consoleOwnershipTimer == nil else { return }
        consoleOwnershipTimer = BackgroundTask.repeating(every: 30) { [weak self] in
            self?.evaluateConsoleOwnership()
        }
    }

    private func stopConsoleOwnershipPolling() {
        consoleOwnershipTimer?.stop()
        consoleOwnershipTimer = nil
    }

    func evaluateConsoleOwnership() {
        let onConsole = sessionOnConsoleProbe()
        guard onConsole != sessionIsOnConsole else { return }
        if onConsole {
            handleSessionDidBecomeActive()
        } else {
            handleSessionDidResignActive()
        }
    }

    private func startUserActivityObservation() {
        guard userActivityPolicyTimer == nil else { return }
        userActivityMonitor.onInput = { [weak self] in self?.handleObservedUserInput() }
        userActivityMonitor.start()
        userActivityPolicyTimer = BackgroundTask.repeating(every: 5) { [weak self] in
            self?.evaluateUserActivityPolicy()
        }
    }

    private func stopUserActivityObservation() {
        userActivityPolicyTimer?.stop()
        userActivityPolicyTimer = nil
        userActivityMonitor.onInput = nil
        userActivityMonitor.stop()
    }

    /// Fast user switching keeps this process alive in the background. Stop
    /// every BLE action there — the central, its connections and the signal
    /// timers — while leaving the system observers installed for the return.
    func handleSessionDidResignActive() {
        guard sessionIsOnConsole else { return }
        sessionIsOnConsole = false
        log("session left the console; suspending BLE monitoring")
        pickerWasActiveBeforeSessionSuspend = isScanning
        stopUserActivityObservation()
        stopMonitoring()
    }

    func handleSessionDidBecomeActive() {
        let wasSuspended = !sessionIsOnConsole
        sessionIsOnConsole = true
        log("session became active on the console")
        guard settings.isEnabled else {
            log("session resume skipped reason=featureDisabled")
            return
        }
        startUserActivityObservation()
        let resumePicker = pickerWasActiveBeforeSessionSuspend
        pickerWasActiveBeforeSessionSuspend = false
        if hasMonitoredDevice, wasSuspended || monitoredRuntimes.isEmpty {
            ensureCentralManager()
            if centralMgr?.state == .poweredOn { startConfiguredMonitoring() }
        }
        if resumePicker { startScanning() }
    }
}

// MARK: - Low-level display helpers
