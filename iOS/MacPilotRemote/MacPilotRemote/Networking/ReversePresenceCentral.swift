import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Holds the one nonce this phone may answer. A response is only built from a
/// challenge delivered on the live subscription; after a suspension the gate is
/// emptied so an old notification cannot be replayed into a new sample.
struct ReversePresenceChallengeGate: Equatable {
    private(set) var pendingNonce: Data?
    private(set) var lastConsumedNonce: Data?

    var hasPendingNonce: Bool { pendingNonce != nil }

    mutating func receive(_ nonce: Data) -> Bool {
        guard nonce.count == RemoteBLEReversePresenceSample.nonceLength,
              nonce != pendingNonce,
              nonce != lastConsumedNonce else { return false }
        pendingNonce = nonce
        return true
    }

    mutating func takeNonce() -> Data? {
        guard let nonce = pendingNonce else { return nil }
        pendingNonce = nil
        lastConsumedNonce = nonce
        return nonce
    }

    mutating func reset() {
        pendingNonce = nil
        lastConsumedNonce = nil
    }
}

/// Production central for the reverse-role link: the Mac advertises, this phone
/// connects, measures RSSI and returns a keyed proximity sample.
///
/// This is separate from `ProximityBLECentral`, which remains the manually
/// started echo test. They use different managers, restoration identifiers,
/// defaults keys and delegate objects, so starting or stopping one never
/// controls the other. Nothing here can unlock anything: the Mac verifies the
/// sample and applies its own presence and unlock policy.
@MainActor
final class ReversePresenceCentral: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = ReversePresenceCentral()

    static let restorationIdentifier = "com.misswell.macpilot.reverse-presence.central"
    /// Production intent. Deliberately not the diagnostic `enabledKey`.
    static let enabledKey = "reversePresence.wantsToRun"
    /// A user who switched the feature off is not opted in again by a later
    /// pairing or by the upgrade migration.
    static let userDisabledKey = "reversePresence.disabledByUser"
    static let migrationKey = "reversePresence.autoEnableMigrated"
    /// Non-secret Mac UUIDs only. Pairing keys stay in the Keychain.
    static let knownMacIDsKey = "reversePresence.knownMacIDs"

    enum Status: Equatable {
        case off
        case waitingForPairing
        case starting
        case scanning
        case connected
        case bluetoothUnavailable
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var status: Status = .off
    @Published private(set) var lastError: String?
    @Published private(set) var lastSampleAt: Date?
    @Published private(set) var lastRSSI: Int?
    @Published private(set) var acceptedSampleCount = 0
    @Published private(set) var logLines: [String] = []

    private struct Connection {
        let peripheral: CBPeripheral
        var macID: UUID?
        var pairingKey: Data?
        var macInfoCharacteristic: CBCharacteristic?
        var presenceCharacteristic: CBCharacteristic?
        var challenges = ReversePresenceChallengeGate()
        var subscribed = false
        var readInFlight = false
        var writeInFlight = false
        var lastSampledRSSI: Int?
        /// Set when the app leaves the foreground. Only a challenge delivered
        /// after that point may produce a sample.
        var awaitingFreshChallenge = false
    }

    private let defaults: UserDefaults
    private let pairingKeyLookup: @MainActor (UUID) -> Data?
    private let radioFactory: (@MainActor () -> CBCentralManager?)?
    private var manager: CBCentralManager?
    private var connections: [UUID: Connection] = [:]
    private var connectionTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var readTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var writeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var retryAfter: [UUID: Date] = [:]
    private var ignoredUntil: [UUID: Date] = [:]
    private var retry = ProximityGATTRetry()
    private var knownMacIDs: Set<String>
    private var userDisabled: Bool
    private var sessionID = UUID()
    private let logLimit = 120
    private let maximumConnections = 4
    private let connectionTimeout: TimeInterval = 12
    private let readTimeout: TimeInterval = 4
    private let writeTimeout: TimeInterval = 5

    init(
        defaults: UserDefaults = .standard,
        pairingKeyLookup: @escaping @MainActor (UUID) -> Data? = {
            RemoteKeychain.pairingKey(for: $0.uuidString)
        },
        radioFactory: (@MainActor () -> CBCentralManager?)? = nil
    ) {
        self.defaults = defaults
        self.pairingKeyLookup = pairingKeyLookup
        self.radioFactory = radioFactory
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.userDisabled = defaults.bool(forKey: Self.userDisabledKey)
        self.knownMacIDs = Set(defaults.stringArray(forKey: Self.knownMacIDsKey) ?? [])
        super.init()
    }

    // MARK: - Lifecycle

    /// Records non-secret Mac identities so a background relaunch can decide
    /// whether this feature has anything to do without loading app state.
    func importPairedMacs(_ macIDs: [UUID]) {
        let before = knownMacIDs
        for id in macIDs { knownMacIDs.insert(id.uuidString) }
        if before != knownMacIDs { persistKnownMacs() }
    }

    /// Called at launch. Upgrades from versions without production BLE presence
    /// opt existing paired users in once, unless they explicitly opted out.
    func resumeAtLaunch() {
        migrateAutoEnableIfNeeded()
        guard isEnabled else {
            status = .off
            return
        }
        startIfPossible()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            userDisabled = false
            defaults.set(false, forKey: Self.userDisabledKey)
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            startIfPossible()
        } else {
            userDisabled = true
            defaults.set(true, forKey: Self.userDisabledKey)
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            stopRadio(reason: "userDisabled")
            status = .off
        }
    }

    /// Called after a Mac authenticated and its long-term key is in the
    /// Keychain. Respects an explicit opt-out made in Settings.
    func handlePairedMac(_ macID: UUID) {
        importPairedMacs([macID])
        guard !userDisabled, pairingKeyLookup(macID) != nil else { return }
        if !isEnabled {
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
        }
        startIfPossible()
        // Scanning with duplicate filtering reports each Mac once. A Mac that
        // was rejected before this pairing would otherwise never be offered
        // again in this scan, so restart discovery now that it is trusted.
        if isRunning, !connections.values.contains(where: { $0.macID == macID }) {
            retryAfter.removeAll()
            ignoredUntil.removeAll()
            restartScanning()
        }
    }

    /// One Mac was forgotten. Other paired Macs keep their link; when the last
    /// key is gone the radio is released but the user's preference is kept.
    func forgetMac(_ macID: UUID) {
        knownMacIDs.remove(macID.uuidString)
        persistKnownMacs()
        let affected = connections.compactMap { identifier, connection in
            connection.macID == macID ? identifier : nil
        }
        for identifier in affected {
            rejectConnection(identifier, reason: "macForgotten", ignoreFor: nil)
        }
        if !hasAnyPairedKey {
            stopRadio(reason: "noPairedMac")
            status = isEnabled ? .waitingForPairing : .off
        }
    }

    func forgetAllMacs() {
        knownMacIDs.removeAll()
        persistKnownMacs()
        stopRadio(reason: "allMacsForgotten")
        status = isEnabled ? .waitingForPairing : .off
    }

    /// Whether this phone has a long-term key for the Mac. The Mac identity
    /// alone is not permission to connect or answer.
    func canAuthenticate(_ macID: UUID) -> Bool {
        pairingKeyLookup(macID) != nil
    }

    /// State restoration is a hint, never proof. A restored connection still
    /// has to read Mac info, find a stored key and receive a fresh challenge.
    nonisolated static func shouldResumeRestoration(isEnabled: Bool, hasPairingKey: Bool) -> Bool {
        isEnabled && hasPairingKey
    }

    func applicationStateChanged(isActive: Bool) {
        guard isRunning else { return }
        if !isActive {
            for identifier in connections.keys {
                connections[identifier]?.challenges.reset()
                connections[identifier]?.awaitingFreshChallenge = true
            }
            log("background; waiting for a fresh challenge")
            return
        }
        log("foreground; ensuring discovery")
        if let manager, manager.state == .poweredOn {
            restartScanning()
        }
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - Intent and radio

    private var hasAnyPairedKey: Bool {
        knownMacIDs.contains { raw in
            guard let id = UUID(uuidString: raw) else { return false }
            return pairingKeyLookup(id) != nil
        }
    }

    private func migrateAutoEnableIfNeeded() {
        guard !defaults.bool(forKey: Self.migrationKey) else { return }
        // Mac IDs are imported from the pairing store after launch; deciding
        // before that would burn the one-time migration for a user who does
        // have pairings but no cached IDs yet.
        guard !knownMacIDs.isEmpty else { return }
        defaults.set(true, forKey: Self.migrationKey)
        guard !userDisabled, !isEnabled, hasAnyPairedKey else { return }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        log("migrated an existing paired user to automatic reverse presence")
    }

    private func startIfPossible() {
        guard isEnabled else {
            status = .off
            return
        }
        guard hasAnyPairedKey else {
            status = .waitingForPairing
            return
        }
        guard !isRunning else {
            refreshStatus()
            return
        }
        isRunning = true
        sessionID = UUID()
        retry.reset()
        status = .starting
        log("production central starting")
        if manager == nil {
            if let radioFactory {
                manager = radioFactory()
            } else {
                manager = CBCentralManager(
                    delegate: self,
                    queue: .main,
                    options: [
                        CBCentralManagerOptionShowPowerAlertKey: false,
                        CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier
                    ]
                )
            }
        }
        if let manager, manager.state == .poweredOn {
            beginScanning()
        } else if manager == nil {
            // Test seam: no radio was supplied; intent is still recorded.
            status = .starting
        }
    }

    private func stopRadio(reason: String) {
        isRunning = false
        manager?.stopScan()
        for identifier in Array(connections.keys) {
            cancelTimers(for: identifier)
            if let peripheral = connections[identifier]?.peripheral {
                manager?.cancelPeripheralConnection(peripheral)
            }
        }
        for task in reconnectTasks.values { task.cancel() }
        for task in connectionTimeoutTasks.values { task.cancel() }
        for task in readTimeoutTasks.values { task.cancel() }
        for task in writeTimeoutTasks.values { task.cancel() }
        connections.removeAll()
        reconnectTasks.removeAll()
        connectionTimeoutTasks.removeAll()
        readTimeoutTasks.removeAll()
        writeTimeoutTasks.removeAll()
        retryAfter.removeAll()
        ignoredUntil.removeAll()
        log("production central stopped reason=\(reason)")
    }

    private func beginScanning() {
        guard isRunning, let manager, manager.state == .poweredOn else { return }
        if manager.isScanning { refreshStatus(); return }
        manager.scanForPeripherals(
            withServices: [ProximityGATTService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        refreshStatus()
        log("scanning for the reverse presence service")
    }

    /// CoreBluetooth reports each peripheral once per scan with duplicate
    /// filtering, so a fresh scan is the only way to be offered a Mac that was
    /// discovered and rejected earlier in the same session.
    private func restartScanning() {
        guard isRunning, let manager, manager.state == .poweredOn else { return }
        if manager.isScanning { manager.stopScan() }
        manager.scanForPeripherals(
            withServices: [ProximityGATTService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        refreshStatus()
        log("scan restarted")
    }

    private func refreshStatus() {
        guard isEnabled else { status = .off; return }
        guard hasAnyPairedKey else { status = .waitingForPairing; return }
        guard isRunning else { status = .off; return }
        guard let manager else { status = .starting; return }
        guard manager.state == .poweredOn else { status = .bluetoothUnavailable; return }
        status = connections.values.contains { $0.subscribed } ? .connected : .scanning
    }

    private func log(_ message: @autoclosure () -> String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(sessionID.uuidString)] \(message())"
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    private func persistKnownMacs() {
        defaults.set(knownMacIDs.sorted(), forKey: Self.knownMacIDsKey)
    }

    // MARK: - Connection setup

    private func adopt(_ peripheral: CBPeripheral) {
        let identifier = peripheral.identifier
        guard connections[identifier] == nil, connections.count < maximumConnections else {
            manager?.cancelPeripheralConnection(peripheral)
            return
        }
        guard retryAfter[identifier].map({ Date.now >= $0 }) ?? true,
              ignoredUntil[identifier].map({ Date.now >= $0 }) ?? true else { return }
        peripheral.delegate = self
        connections[identifier] = Connection(peripheral: peripheral)
        scheduleConnectionTimeout(for: identifier)
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard isRunning, let manager else { return }
        switch peripheral.state {
        case .connected:
            discover(on: peripheral)
        case .connecting, .disconnecting:
            break
        case .disconnected:
            log("connecting to \(peripheral.identifier.uuidString.prefix(8))")
            manager.connect(peripheral)
        @unknown default:
            rejectConnection(peripheral.identifier, reason: "unknownPeripheralState", ignoreFor: 15)
        }
    }

    private func discover(on peripheral: CBPeripheral) {
        guard isRunning, let connection = connections[peripheral.identifier],
              connection.presenceCharacteristic == nil else { return }
        peripheral.delegate = self
        peripheral.discoverServices([ProximityGATTService.serviceUUID])
    }

    private func scheduleConnectionTimeout(for identifier: UUID) {
        connectionTimeoutTasks[identifier]?.cancel()
        connectionTimeoutTasks[identifier] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.connectionTimeout ?? 12))
            guard let self, !Task.isCancelled,
                  let connection = self.connections[identifier],
                  !connection.subscribed else { return }
            self.rejectConnection(identifier, reason: "setupTimeout", ignoreFor: 15)
        }
    }

    private func scheduleReconnect(for peripheral: CBPeripheral) {
        let identifier = peripheral.identifier
        guard isRunning else { return }
        if let ignoreUntil = ignoredUntil[identifier], Date.now < ignoreUntil { return }
        reconnectTasks[identifier]?.cancel()
        let delay = retry.nextDelay()
        log("reconnect in \(delay)s")
        reconnectTasks[identifier] = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let peripheral, !Task.isCancelled, self.isRunning,
                  self.connections[identifier] == nil else { return }
            self.reconnectTasks[identifier] = nil
            self.retryAfter[identifier] = nil
            self.adopt(peripheral)
        }
    }

    private func rejectConnection(_ identifier: UUID, reason: String, ignoreFor: TimeInterval?) {
        cancelTimers(for: identifier)
        if let connection = connections.removeValue(forKey: identifier) {
            manager?.cancelPeripheralConnection(connection.peripheral)
            if let macID = connection.macID {
                log("rejected mac=\(macID.uuidString.prefix(8)) reason=\(reason)")
            } else {
                log("rejected connection \(identifier.uuidString.prefix(8)) reason=\(reason)")
            }
        }
        if let ignoreFor {
            ignoredUntil[identifier] = Date.now.addingTimeInterval(ignoreFor)
        }
        refreshStatus()
    }

    private func cancelTimers(for identifier: UUID) {
        connectionTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        readTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        writeTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        reconnectTasks.removeValue(forKey: identifier)?.cancel()
    }

    private func scheduleReadTimeout(for identifier: UUID) {
        readTimeoutTasks[identifier]?.cancel()
        readTimeoutTasks[identifier] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.readTimeout ?? 4))
            guard let self, !Task.isCancelled, var connection = self.connections[identifier],
                  connection.readInFlight else { return }
            connection.readInFlight = false
            self.connections[identifier] = connection
            self.log("RSSI read timed out; waiting for the next challenge")
        }
    }

    private func scheduleWriteTimeout(for identifier: UUID) {
        writeTimeoutTasks[identifier]?.cancel()
        writeTimeoutTasks[identifier] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.writeTimeout ?? 5))
            guard let self, !Task.isCancelled, var connection = self.connections[identifier],
                  connection.writeInFlight else { return }
            connection.writeInFlight = false
            self.connections[identifier] = connection
            self.log("sample write timed out; waiting for the next challenge")
        }
    }

    // MARK: - Challenge exchange

    private func requestSample(for identifier: UUID) {
        guard var connection = connections[identifier],
              connection.subscribed,
              !connection.readInFlight,
              !connection.writeInFlight,
              connection.challenges.hasPendingNonce else { return }
        connection.readInFlight = true
        connections[identifier] = connection
        scheduleReadTimeout(for: identifier)
        connection.peripheral.readRSSI()
    }

    private func sendSample(for identifier: UUID, rssi: Int) {
        guard var connection = connections[identifier],
              connection.subscribed,
              !connection.writeInFlight,
              let macID = connection.macID,
              let pairingKey = connection.pairingKey,
              let nonce = connection.challenges.takeNonce(),
              let characteristic = connection.presenceCharacteristic else { return }
        guard RemoteBLEReversePresenceSample.isValidRSSI(rssi),
              let sample = RemoteBLEReversePresenceSample(
                  macID: macID,
                  nonce: nonce,
                  rssi: rssi,
                  sampledAt: .now,
                  pairingKey: pairingKey
              ) else {
            log("sample discarded reason=invalidRSSI value=\(rssi)")
            return
        }
        connection.writeInFlight = true
        connection.lastSampledRSSI = rssi
        connections[identifier] = connection
        scheduleWriteTimeout(for: identifier)
        lastError = nil
        log("sample writing mac=\(macID.uuidString.prefix(8)) rssi=\(rssi)")
        connection.peripheral.writeValue(sample.encoded, for: characteristic, type: .withResponse)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        switch central.state {
        case .poweredOn:
            log("radio on")
            refreshStatus()
            if isRunning { beginScanning() }
        case .poweredOff:
            dropConnections(reason: "radioOff")
            lastError = "Bluetooth is off"
            status = .bluetoothUnavailable
            log("radio off; waiting for recovery")
        case .unauthorized:
            dropConnections(reason: "radioUnauthorized")
            lastError = "Bluetooth unauthorized"
            status = .bluetoothUnavailable
            log("radio unauthorized")
        case .unsupported:
            dropConnections(reason: "radioUnsupported")
            lastError = "Bluetooth unsupported"
            status = .bluetoothUnavailable
            log("radio unsupported")
        default:
            dropConnections(reason: "radioUnavailable")
            status = .bluetoothUnavailable
            log("waiting for Bluetooth state=\(central.state.rawValue)")
        }
    }

    private func dropConnections(reason: String) {
        for identifier in Array(connections.keys) {
            cancelTimers(for: identifier)
            if let peripheral = connections[identifier]?.peripheral {
                manager?.cancelPeripheralConnection(peripheral)
            }
        }
        connections.removeAll()
        reconnectTasks.removeAll()
        retryAfter.removeAll()
        ignoredUntil.removeAll()
        log("connections dropped reason=\(reason)")
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard central === manager else { return }
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard Self.shouldResumeRestoration(isEnabled: isEnabled, hasPairingKey: hasAnyPairedKey) else {
            central.stopScan()
            for peripheral in restored { central.cancelPeripheralConnection(peripheral) }
            log("restoration refused reason=featureOffOrNoKey")
            return
        }
        log("restoring \(restored.count) peripheral(s); authentication starts over")
        for peripheral in restored {
            adopt(peripheral)
        }
        if restored.isEmpty, central.state == .poweredOn {
            beginScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === manager, isRunning, central.state == .poweredOn else { return }
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard advertised.isEmpty || advertised.contains(ProximityGATTService.serviceUUID) else { return }
        guard connections[peripheral.identifier] == nil,
              connections.count < maximumConnections,
              peripheral.state == .disconnected else { return }
        if let retryAt = retryAfter[peripheral.identifier], Date.now < retryAt { return }
        if let ignoreUntil = ignoredUntil[peripheral.identifier], Date.now < ignoreUntil { return }
        if reconnectTasks[peripheral.identifier] != nil {
            reconnectTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        }
        log("discovered \(peripheral.identifier.uuidString.prefix(8)) rssi=\(RSSI.intValue)")
        adopt(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, isRunning, connections[peripheral.identifier] != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("connected \(peripheral.identifier.uuidString.prefix(8)); discovering")
        discover(on: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager else { return }
        retryAfter[peripheral.identifier] = Date.now.addingTimeInterval(5)
        rejectConnection(peripheral.identifier, reason: "connectFailed", ignoreFor: nil)
        if isRunning { scheduleReconnect(for: peripheral) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager else { return }
        let known = connections[peripheral.identifier]?.macID != nil
        cancelTimers(for: peripheral.identifier)
        connections.removeValue(forKey: peripheral.identifier)
        refreshStatus()
        log("disconnected \(peripheral.identifier.uuidString.prefix(8)) knownMac=\(known)")
        if isRunning, known {
            scheduleReconnect(for: peripheral)
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isRunning, connections[peripheral.identifier] != nil else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: {
                  $0.uuid == ProximityGATTService.serviceUUID
              }) else {
            rejectConnection(peripheral.identifier, reason: "serviceMissing", ignoreFor: 30)
            return
        }
        log("service found; discovering identity and presence characteristics")
        peripheral.discoverCharacteristics([
            ProximityGATTService.macInfoCharacteristicUUID,
            ProximityGATTService.presenceChallengeCharacteristicUUID
        ], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isRunning, var connection = connections[peripheral.identifier] else { return }
        guard error == nil,
              let macInfo = service.characteristics?.first(where: {
                  $0.uuid == ProximityGATTService.macInfoCharacteristicUUID
              }),
              let presence = service.characteristics?.first(where: {
                  $0.uuid == ProximityGATTService.presenceChallengeCharacteristicUUID
              }) else {
            rejectConnection(peripheral.identifier, reason: "characteristicsMissing", ignoreFor: 60)
            return
        }
        guard macInfo.properties.contains(.read),
              presence.properties.contains(.notify),
              presence.properties.contains(.write) else {
            rejectConnection(peripheral.identifier, reason: "characteristicPropertiesUnsupported", ignoreFor: 60)
            return
        }
        connection.macInfoCharacteristic = macInfo
        connection.presenceCharacteristic = presence
        connections[peripheral.identifier] = connection
        peripheral.readValue(for: macInfo)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning, var connection = connections[peripheral.identifier] else { return }
        if characteristic === connection.macInfoCharacteristic {
            guard error == nil else {
                rejectConnection(peripheral.identifier, reason: "macInfoReadFailed", ignoreFor: 10)
                return
            }
            guard let data = characteristic.value,
                  let info = ProximityGATTMacInfo(encoded: data),
                  let macID = info.deviceID else {
                rejectConnection(peripheral.identifier, reason: "macInfoInvalid", ignoreFor: 30)
                return
            }
            guard let key = pairingKeyLookup(macID) else {
                rejectConnection(peripheral.identifier, reason: "unknownOrDeletedMac", ignoreFor: 30)
                return
            }
            connection.macID = macID
            connection.pairingKey = key
            connections[peripheral.identifier] = connection
            log("Mac identity verified mac=\(macID.uuidString.prefix(8)); subscribing")
            guard let presence = connection.presenceCharacteristic else {
                rejectConnection(peripheral.identifier, reason: "presenceCharacteristicLost", ignoreFor: 60)
                return
            }
            peripheral.setNotifyValue(true, for: presence)
            return
        }
        if characteristic === connection.presenceCharacteristic {
            guard error == nil, connection.subscribed, characteristic.isNotifying,
                  let data = characteristic.value else {
                if let error { log("challenge notification failed reason=\(error.localizedDescription)") }
                return
            }
            guard connection.challenges.receive(data) else {
                log("challenge ignored reason=duplicateOrWrongLength")
                return
            }
            connection.awaitingFreshChallenge = false
            connections[peripheral.identifier] = connection
            requestSample(for: peripheral.identifier)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isRunning, var connection = connections[peripheral.identifier],
              characteristic === connection.presenceCharacteristic else { return }
        if let error {
            rejectConnection(peripheral.identifier, reason: "subscribeFailed", ignoreFor: 30)
            log("subscribe failed reason=\(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            rejectConnection(peripheral.identifier, reason: "subscribeRefused", ignoreFor: 30)
            return
        }
        connection.subscribed = true
        connections[peripheral.identifier] = connection
        connectionTimeoutTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        refreshStatus()
        log("subscribed; waiting for an authenticated challenge mac=\(connection.macID?.uuidString.prefix(8) ?? "unknown")")
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard isRunning, var connection = connections[peripheral.identifier],
              connection.readInFlight else { return }
        connection.readInFlight = false
        connections[peripheral.identifier] = connection
        readTimeoutTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        guard !connection.awaitingFreshChallenge else {
            log("RSSI read dropped reason=challengePredatesBackground")
            return
        }
        guard error == nil else {
            log("RSSI read failed reason=\(error?.localizedDescription ?? "unknown")")
            return
        }
        let rssi = RSSI.intValue
        guard RemoteBLEReversePresenceSample.isValidRSSI(rssi) else {
            log("RSSI read discarded reason=invalidRange value=\(rssi)")
            return
        }
        sendSample(for: peripheral.identifier, rssi: rssi)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isRunning, var connection = connections[peripheral.identifier],
              characteristic === connection.presenceCharacteristic else { return }
        connection.writeInFlight = false
        writeTimeoutTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        if let error {
            lastError = "The Mac rejected a proximity sample"
            log("sample rejected reason=\(error.localizedDescription)")
        } else {
            acceptedSampleCount += 1
            lastSampleAt = .now
            lastRSSI = connection.lastSampledRSSI
            status = .connected
            log("sample verified by the Mac")
        }
        connections[peripheral.identifier] = connection
        if connection.challenges.hasPendingNonce {
            requestSample(for: peripheral.identifier)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isRunning, connections[peripheral.identifier] != nil,
              invalidatedServices.contains(where: { $0.uuid == ProximityGATTService.serviceUUID }) else {
            return
        }
        retryAfter[peripheral.identifier] = Date.now.addingTimeInterval(5)
        rejectConnection(peripheral.identifier, reason: "serviceInvalidated", ignoreFor: nil)
        scheduleReconnect(for: peripheral)
    }
}
