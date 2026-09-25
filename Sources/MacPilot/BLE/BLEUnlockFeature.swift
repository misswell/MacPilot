import AppKit
import ApplicationServices
import CoreBluetooth
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Security

nonisolated(unsafe) private let deviceInformationUUID = CBUUID(string: "180A")
nonisolated(unsafe) private let manufacturerNameUUID = CBUUID(string: "2A29")
nonisolated(unsafe) private let modelNameUUID = CBUUID(string: "2A24")
nonisolated(unsafe) private let exposureNotificationUUID = CBUUID(string: "FD6F")

// MARK: - Model

@MainActor
final class BLEUnlockModel: NSObject, ObservableObject, ManagedFeature, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    let identifier = "ble"
    var isRunning: Bool { !observers.isEmpty }
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

    override init() {
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
                self.manualLock = true
                self.cancelUnlockAttempt(reason: "lock-\(source.rawValue)")
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
    @Published private(set) var connected = false
    @Published private(set) var activeMode = false
    @Published private(set) var bluetoothPoweredOn = false
    @Published private(set) var bluetoothPowerWarned = false
    @Published private(set) var isScanning = false
    /// True when monitoring should be producing CoreBluetooth callbacks but
    /// none have arrived for a long window — the signature of the system
    /// stopping advertisement delivery to this process.
    @Published private(set) var advertisementStreamStalled = false
    /// Other running copies of this executable, usually MacPilot launched in
    /// another user's fast-switched session.
    @Published private(set) var conflictingInstanceCount = 0

    var settings = BLEUnlockSettings()

    private let bluetoothScanner = BluetoothScanner()
    private var centralMgr: CBCentralManager? {
        get { bluetoothScanner.central }
        set { bluetoothScanner.central = newValue }
    }
    private var deviceMap: [UUID: BLEUnlockDevice] = [:]
    private var deviceRefreshBatcher = BLEDeviceListRefreshBatcher()
    private var deviceRefreshTask: Task<Void, Never>?
    private var scanCleanupTimer: BackgroundTask?
    private var livenessTimer: BackgroundTask?
    private var advertisementLiveness = BLEAdvertisementLiveness()
    var monitoredUUID: UUID?
    var secondaryMonitoredUUID: UUID?
    private var monitoredRuntimes: [UUID: BLEMonitoredDeviceRuntime] = [:]
    private var wakeRetryTask: Task<Void, Never>?
    private var systemWakeRecoveryTask: Task<Void, Never>?
    private var monitoringRecoveryTask: Task<Void, Never>?
    private var unlockAttemptTask: Task<Void, Never>?
    private var unlockAttemptSlot = BLEUnlockAttemptSlot()
    private var lastLoggedRSSIAt = Date.distantPast
    private var lastLoggedRSSI: Int?
    private var lastLoggedRSSIErrorAt = Date.distantPast

    private var displaySleep = false
    private var systemSleep = false
    private var recoveringFromSystemSleep = false
    private var manualLock = false
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

    private var monitoredUUIDs: [UUID] {
        var result: [UUID] = []
        if let monitoredUUID { result.append(monitoredUUID) }
        if let secondaryMonitoredUUID, !result.contains(secondaryMonitoredUUID) {
            result.append(secondaryMonitoredUUID)
        }
        return result
    }

    private var hasMonitoredDevice: Bool { !monitoredUUIDs.isEmpty }

    private func runtime(for uuid: UUID) -> BLEMonitoredDeviceRuntime? {
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
        let latestRSSI = runtimes.compactMap(\.lastRSSI).max()
        let isConnected = runtimes.contains { $0.peripheral?.state == .connected }
        let isActive = runtimes.contains { $0.activeMode }
        if lastRSSI != latestRSSI { lastRSSI = latestRSSI }
        if connected != isConnected { connected = isConnected }
        if activeMode != isActive { activeMode = isActive }
    }

    private func recomputePresence(reason: String) {
        let oldPresence = presence
        let devicePresences = monitoredUUIDs.map { monitoredRuntimes[$0]?.presence ?? false }
        let newPresence = BLEDevicePresencePolicy.isSatisfied(
            presences: devicePresences,
            relation: settings.deviceRelation
        )
        refreshPublishedMonitoringState()
        guard oldPresence != newPresence else {
            log("combined presence unchanged value=\(newPresence) reason=\(reason) devices=\(devicePresences)")
            return
        }
        presence = newPresence
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
        cancelUnlockAttempt(reason: "monitoring-restarted")
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
            presences: uuids.map { monitoredRuntimes[$0]?.presence ?? false },
            relation: settings.deviceRelation
        )
        refreshPublishedMonitoringState()
        advertisementLiveness.noteActivity()
        startLivenessTimer()
        scanForPeripherals()
        logSettings("monitoring started")
    }

    // MARK: Settings mutations

    private func notifyChange() {
        objectWillChange.send()
        persist?()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        log("setEnabled from=\(settings.isEnabled) to=\(enabled)")
        settings.isEnabled = enabled
        if enabled {
            startObservingSystemState()
            if hasMonitoredDevice {
                // Toggling the feature is an explicit user action, so this is
                // the one path allowed to start the first Bluetooth prompt.
                ensureCentralManager(explicitUserAction: true)
                if centralMgr?.state == .poweredOn { startConfiguredMonitoring() }
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
        // System observers are only installed for an enabled feature: while BLE
        // is off they would keep the process awake for lock/sleep notifications
        // nothing consumes.
        startObservingSystemState()
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
        screenControl.shutdown()
    }

    func setLockRSSI(_ value: Int) { log("setLockRSSI from=\(settings.lockRSSI) to=\(value)"); settings.lockRSSI = value; notifyChange() }
    func setUnlockRSSI(_ value: Int) { log("setUnlockRSSI from=\(settings.unlockRSSI) to=\(value)"); settings.unlockRSSI = value; notifyChange() }
    func setProximityTimeout(_ value: Int) { log("setProximityTimeout from=\(settings.proximityTimeout) to=\(value)"); settings.proximityTimeout = value; notifyChange() }
    func setSignalTimeout(_ value: Int) { log("setSignalTimeout from=\(settings.signalTimeout) to=\(value)"); settings.signalTimeout = value; notifyChange() }
    func setThresholdRSSI(_ value: Int) { log("setThresholdRSSI from=\(settings.thresholdRSSI) to=\(value)"); settings.thresholdRSSI = value; notifyChange() }
    func setWakeOnProximity(_ value: Bool) { log("setWakeOnProximity from=\(settings.wakeOnProximity) to=\(value)"); settings.wakeOnProximity = value; notifyChange() }
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

    func selectDevice(_ uuid: UUID) {
        deviceMap[uuid]?.resolveIdentity()
        let selectedName = deviceMap[uuid]?.displayName
        log("selectDevice uuid=\(uuid.uuidString) name=\(selectedName ?? "?") rssi=\(deviceMap[uuid]?.rssi ?? 0)")
        stopScanning()
        if secondaryMonitoredUUID == uuid {
            clearSecondaryDevice(notify: false)
        }
        settings.monitoredDeviceUUID = uuid.uuidString
        settings.monitoredDeviceName = selectedName
        monitoredUUID = uuid
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
            cancelRuntime(for: oldUUID)
        }
        secondaryMonitoredUUID = uuid
        settings.secondaryMonitoredDeviceUUID = uuid.uuidString
        settings.secondaryMonitoredDeviceName = selectedName
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
            cancelRuntime(for: uuid)
        }
        secondaryMonitoredUUID = nil
        settings.secondaryMonitoredDeviceUUID = nil
        settings.secondaryMonitoredDeviceName = nil
        settings.deviceRelation = .any
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
        scanForPeripherals()
    }

    func stopScanning() {
        log("stopScanning devices=\(deviceMap.count) monitored=\(monitoredUUIDs.count)")
        isScanning = false
        scanCleanupTimer?.stop()
        scanCleanupTimer = nil
        clearDiscoveredDevices()
        if !hasMonitoredDevice && !activeMode { bluetoothScanner.stop() }
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
        connected = false
        activeMode = false
        recoveringFromSystemSleep = false
        stopLivenessTimer()
        advertisementStreamStalled = false
        conflictingInstanceCount = 0
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
        _ = bluetoothScanner.startIfPoweredOn()
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

    private func resetSignalTimer(for uuid: UUID) {
        guard let runtime = runtime(for: uuid) else { return }
        runtime.signalTimer?.stop()
        runtime.signalTimer = BackgroundTask.once(after: TimeInterval(settings.signalTimeout)) { [weak self] in
            guard let self, let runtime = self.runtime(for: uuid) else { return }
            self.log("signal timeout fired uuid=\(uuid.uuidString) timeout=\(self.settings.signalTimeout) devicePresence=\(runtime.presence)")
            runtime.signalTimer = nil
            runtime.lastRSSI = nil
            runtime.activeMode = false
            if runtime.presence {
                runtime.presence = false
                self.recomputePresence(reason: "lost")
            } else {
                self.refreshPublishedMonitoringState()
            }
            self.startMonitoringRecovery(reason: "signalTimeout", restartImmediately: true)
        }
    }

    private func estimatedRSSI(_ rssi: Int, for runtime: BLEMonitoredDeviceRuntime) -> Int {
        runtime.latestRSSIs.append(Double(rssi))
        if runtime.latestRSSIs.count > 5 { runtime.latestRSSIs.removeFirst() }
        let mean = runtime.latestRSSIs.reduce(0, +) / Double(runtime.latestRSSIs.count)
        return Int(mean)
    }

    private func updateMonitoredPeripheral(_ rssi: Int, for uuid: UUID) {
        guard let runtime = runtime(for: uuid) else { return }
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
        stopMonitoringRecovery(reason: "freshRSSI")
        runtime.activeMode = runtime.activeModeTimer != nil
        refreshPublishedMonitoringState()
        logMonitoredRSSI(raw: rssi, estimated: estimated)

        let lockThreshold = settings.lockRSSI == Self.lockDisabled ? settings.unlockRSSI : settings.lockRSSI
        if estimated >= lockThreshold {
            if runtime.proximityTimer != nil {
                log("RSSI recovered above lock threshold estimated=\(estimated) threshold=\(lockThreshold); cancelling away timer")
            }
            runtime.proximityTimer?.stop()
            runtime.proximityTimer = nil
        } else if runtime.presence && runtime.proximityTimer == nil {
            log("RSSI below lock threshold estimated=\(estimated) threshold=\(lockThreshold); scheduling away timer seconds=\(settings.proximityTimeout)")
            runtime.proximityTimer = BackgroundTask.once(after: TimeInterval(settings.proximityTimeout)) { [weak self] in
                guard let self, let runtime = self.runtime(for: uuid) else { return }
                self.log("away timer fired uuid=\(uuid.uuidString) estimatedRSSI=\(runtime.lastRSSI.map(String.init) ?? "none")")
                runtime.presence = false
                runtime.proximityTimer = nil
                self.recomputePresence(reason: "away")
            }
        }
        resetSignalTimer(for: uuid)
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
        guard let runtime = runtime(for: uuid), let peripheral = runtime.peripheral else {
            log("connect skipped reason=noMonitoredPeripheral")
            return
        }

        if peripheral.state == .connected {
            requestRSSIRead(for: runtime)
            return
        }
        guard peripheral.state == .disconnected else { return }
        guard runtime.connectionRetryGate.begin(at: Date()) else { return }

        log("connect monitored peripheral uuid=\(uuid.uuidString) state=\(String(describing: peripheral.state)) passive=\(settings.passiveMode)")
        centralMgr?.connect(peripheral, options: nil)
        runtime.connectionTimer?.stop()
        runtime.connectionTimer = BackgroundTask.once(after: 60) { [weak self] in
            guard let self, let runtime = self.runtime(for: uuid),
                  let peripheral = runtime.peripheral, peripheral.state == .connecting else { return }
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
            self.startMonitoringRecovery(reason: "rssiRequestTimeout", restartImmediately: true)
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state updated state=\(String(describing: central.state)) authorization=\(String(describing: CBManager.authorization))")
        switch central.state {
        case .poweredOn:
            bluetoothPoweredOn = true
            bluetoothPowerWarned = false
            if settings.isEnabled && hasMonitoredDevice {
                if monitoredUUIDs.contains(where: { monitoredRuntimes[$0] == nil }) {
                    startConfiguredMonitoring()
                } else {
                    scanForPeripherals()
                }
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
            refreshPublishedMonitoringState()
            if !bluetoothPowerWarned {
                bluetoothPowerWarned = true
            }
        default:
            log("bluetooth unavailable state=\(String(describing: central.state))")
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
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
            if runtime.activeModeTimer == nil {
                updateMonitoredPeripheral(rssi, for: uuid)
                if !settings.passiveMode { connectMonitoredPeripheral(for: uuid) }
            }
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
            central.connect(peripheral, options: nil)
        }
        requestDeviceRefresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let monitoredRuntime = runtime(for: peripheral.identifier)
        let isMonitored = monitoredRuntime != nil
        log("peripheral connected monitored=\(isMonitored) uuid=\(peripheral.identifier.uuidString) state=\(String(describing: peripheral.state))")
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
        log("peripheral disconnected monitored=\(runtime(for: peripheral.identifier) != nil) error=\(error?.localizedDescription ?? "none")")
        if let runtime = runtime(for: peripheral.identifier) {
            runtime.connectionTimer?.stop()
            runtime.connectionTimer = nil
            runtime.rssiRequestTimeoutTimer?.stop()
            runtime.rssiRequestTimeoutTimer = nil
            runtime.rssiReadGate.reset()
            runtime.activeMode = runtime.activeModeTimer != nil
            refreshPublishedMonitoringState()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let runtime = runtime(for: peripheral.identifier) else { return }
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

        if runtime.activeModeTimer == nil && !settings.passiveMode {
            let anotherDeviceNeedsScan = monitoredUUIDs.contains {
                monitoredRuntimes[$0]?.peripheral == nil
            }
            if !isScanning && !anotherDeviceNeedsScan { centralMgr?.stopScan() }
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
        manualLock = true
        cancelUnlockAttempt()
        pauseNowPlaying()
        lockOrSaveScreen(source: .localManual)
    }

    private func lockOrSaveScreen(source: ScreenControlSource) {
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

        guard settings.screenLockHistory.recordLock(at: date, source: source) else {
            log("screen lock history ignored reason=duplicate source=\(source.rawValue)")
            return
        }
        log("screen lock history recorded source=\(source.rawValue) at=\(date.timeIntervalSince1970)")
        notifyChange()
    }

    private func recordScreenUnlock(at date: Date, source: ScreenLockHistorySource) {
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
        ScreenLockStateReader.current()
    }

    func isScreenLocked() -> Bool {
        screenLockState() == .locked
    }

    private func tryUnlockScreen(trigger: String = "unspecified") {
        guard settings.isEnabled else {
            log("unlock skipped trigger=\(trigger) reason=featureDisabled")
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
        guard settings.unlockRSSI != Self.unlockDisabled else {
            log("unlock skipped trigger=\(trigger) reason=unlockRSSIDisabled")
            return
        }
        guard !systemSleep else {
            log("unlock skipped trigger=\(trigger) reason=systemSleep")
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
        log("display readiness checked asleep=\(isAsleep) notificationSleep=\(displaySleep) systemSleep=\(systemSleep)")
        if !isAsleep, displaySleep {
            // Repair the notification-derived state as soon as the display
            // proves that it has actually woken.
            displaySleep = false
            wakeRetryTask?.cancel()
            wakeRetryTask = nil
        }
        return !isAsleep
    }

    private func cancelUnlockAttempt(reason: String = "unspecified") {
        if unlockAttemptSlot.isOccupied {
            log("unlock attempt cancelled reason=\(reason)")
        }
        unlockAttemptTask?.cancel()
        unlockAttemptTask = nil
        unlockAttemptSlot.invalidate()
        lastUnlockRequestAt = 0
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

    private func confirmAutomaticUnlock(source: String, eventDate: Date = Date()) {
        let now = Date().timeIntervalSince1970
        let state = screenLockState()
        guard BLEUnlockConfirmation.isConfirmed(screenState: state) else {
            log("unlock confirmation rejected source=\(source) screenState=\(state.rawValue)")
            return
        }

        let requestAge = lastUnlockRequestAt > 0 ? now - lastUnlockRequestAt : nil
        if now - lastAutomaticUnlockConfirmationAt < 2 {
            log("unlock confirmation already handled source=\(source) requestAge=\(formattedUnlockAge(requestAge))")
            lastUnlockRequestAt = 0
            lastAutomaticUnlockRequestAt = 0
            manualLock = false
            return
        }

        lastAutomaticUnlockConfirmationAt = now
        log("screen unlock confirmed source=\(source) screenState=unlocked requestAge=\(formattedUnlockAge(requestAge))")
        if recentAutomaticUnlockRequestAge(at: eventDate) != nil {
            recordScreenUnlock(at: eventDate, source: .automatic)
        }
        lastUnlockRequestAt = 0
        lastAutomaticUnlockRequestAt = 0
        manualLock = false
        playNowPlaying()
        runScript("unlocked")
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
                    guard let password = self.fetchPassword(warn: true) else {
                        self.log("unlock attempt stopped deadline=\(attemptDeadline) reason=passwordUnavailable")
                        self.unlockAttemptSlot.release(generation: generation)
                        return
                    }
                    let requestTimestamp = Date().timeIntervalSince1970
                    self.lastUnlockRequestAt = requestTimestamp
                    self.lastAutomaticUnlockRequestAt = requestTimestamp
                    self.log("posting unlock key events deadline=\(attemptDeadline) screenState=locked accessibilityTrusted=\(AXIsProcessTrusted())")
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
        log("presence handler value=\(presence) reason=\(reason) currentState=\(self.presence) lastRSSI=\(lastRSSI.map(String.init) ?? "none") displaySleep=\(displaySleep) systemSleep=\(systemSleep)")
        guard settings.isEnabled else {
            log("presence action skipped reason=featureDisabled")
            return
        }
        if presence {
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
            manualLock = false
        }
    }

    private func fakeKeyStrokes(_ string: String) async {
        // The implementation lives in ScreenUnlockExecutor so the BLE proximity
        // unlock and the iPhone remote unlock type the same keystrokes.
        await screenControl.executor.postPassword(string)
    }

    // MARK: Keychain password

    /// BLE proximity unlock and the LAN remote control share one Keychain item
    /// through `ScreenCredentialStore`. The password never leaves this Mac.
    var hasPassword: Bool { screenControl.credentials.hasCredential }

    @discardableResult
    func storePassword(_ password: String) -> Bool {
        let success = screenControl.credentials.storePassword(password)
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

        for uuid in monitoredUUIDs {
            let runtime = ensureRuntime(for: uuid)
            if runtime.peripheral == nil,
               let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
                runtime.peripheral = peripheral
                if !settings.passiveMode {
                    connectMonitoredPeripheral(for: uuid)
                }
            }
        }

        // CoreBluetooth can continue reporting isScanning after deep idle even
        // though no discoveries arrive. A stop/start creates a fresh session.
        central.stopScan()
        scanForPeripherals()
    }

    private var monitoringHasFreshSignal: Bool {
        BLEDevicePresencePolicy.isSatisfied(
            presences: monitoredUUIDs.map { monitoredRuntimes[$0]?.lastRSSI != nil },
            relation: settings.deviceRelation
        )
    }

    private func restartMonitoringAfterRecovery(reason: String) {
        guard settings.isEnabled, hasMonitoredDevice, !systemSleep else { return }
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
            restartMonitoringAfterRecovery(reason: reason)
            guard !monitoringHasFreshSignal else { return }
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
                    try? await Task.sleep(for: .milliseconds(Int64(wait * 1_000)))
                }
                guard !Task.isCancelled, let self else { return }
                guard !self.monitoringHasFreshSignal else { break }
                self.restartMonitoringAfterRecovery(reason: reason)
                previousDeadline = deadline
            }
            self?.monitoringRecoveryTask = nil
            self?.log("monitoring recovery finished freshSignal=\(self?.monitoringHasFreshSignal ?? false)")
        }
    }

    private func stopMonitoringRecovery(reason: String) {
        guard monitoringRecoveryTask != nil, monitoringHasFreshSignal else { return }
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

    private func evaluateAdvertisementLiveness() {
        let monitoringActive = settings.isEnabled
            && hasMonitoredDevice
            && bluetoothPoweredOn
            && !displaySleep
            && !systemSleep
            && (isScanning || monitoredRuntimes.values.contains { $0.activeModeTimer != nil })
        let silent = advertisementLiveness.evaluate(now: Date(), monitoringActive: monitoringActive)
        if silent, !advertisementStreamStalled {
            advertisementStreamStalled = true
            log("advertisement stream stalled reason=noCallbacksWhileMonitoringActive threshold=\(Int(advertisementLiveness.silenceThreshold))s; attempting monitoring recovery")
            // In-process recovery cannot fix every cause (the 2026-09 wedge
            // survived it), but it is free to try and the published flag is
            // what tells the user something the callbacks never will.
            startMonitoringRecovery(reason: "advertisementSilence", restartImmediately: true)
        }
        checkConflictingInstances()
    }

    private func checkConflictingInstances() {
        let count = DuplicateInstanceDetector.conflictingInstanceCount()
        guard count != conflictingInstanceCount else { return }
        if count > conflictingInstanceCount {
            log("conflicting instances detected count=\(count) hint=same-bundle instances in other sessions can wedge BLE advertisement delivery")
        }
        conflictingInstanceCount = count
    }

    private var monitoringNeedsWakeRestart: Bool {
        monitoredUUIDs.contains { monitoredRuntimes[$0]?.lastRSSI == nil }
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
        let nc = NSWorkspace.shared.notificationCenter
        observers.add(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displaySleep = true
                self.screenControl.noteDisplaySleeping(true)
                self.log("display sleep notification received")
            }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("display wake notification received")
                self?.displaySleep = false
                self?.screenControl.noteDisplaySleeping(false)
                self?.recoveringFromSystemSleep = false
                self?.wakeRetryTask?.cancel()
                self?.startMonitoringRecovery(reason: "displayWake", restartImmediately: true)
                self?.tryUnlockScreen(trigger: "screensDidWake")
            }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemWillSleep() }
        }, center: nc)
        observers.add(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("system wake notification received")
                self?.handleSystemDidWake()
            }
        }, center: nc)

        let dnc = DistributedNotificationCenter.default
        observers.add(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordScreenLock(at: Date())
            }
        }, center: dnc)
        observers.add(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            let eventDate = Date()
            MainActor.assumeIsolated {
                guard let self else { return }
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

                    if let confirmationAge, confirmationAge >= 0, confirmationAge < 5 {
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
        mediaResumeTask?.stop()
        mediaResumeTask = nil
        screenUnlockConfirmationTask?.stop()
        screenUnlockConfirmationTask = nil
        guard !observers.isEmpty else { return }
        observers.removeAll()
        log("removed system observers")
    }
}

// MARK: - Low-level display helpers
