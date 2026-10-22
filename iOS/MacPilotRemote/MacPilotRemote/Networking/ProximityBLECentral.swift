import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Scans for the Mac's reversed-role GATT service and measures every step.
///
/// Opt-in test session, independent of the existing peripheral/L2CAP transport.
/// The app owns it so navigation/backgrounding does not destroy the manager.
/// Nothing here authenticates the Mac or feeds the unlock path.
@MainActor
final class ProximityBLECentral: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = ProximityBLECentral()
    static let restorationIdentifier = "com.misswell.macpilot.reverse-gatt.central"
    static let enabledKey = "reverseGATTTest.wantsToRun"

    enum Status: Equatable {
        case idle
        case starting
        case scanning
        case connecting
        case discovering
        case echoing
        case verified(roundTripMs: Int)
        case failed(String)
    }

    struct Timings: Equatable {
        var connectMs: Int?
        var discoverMs: Int?
        var readMs: Int?
        var subscribeMs: Int?
        var echoMs: Int?
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var macInfo: ProximityGATTMacInfo?
    @Published private(set) var timings = Timings()
    @Published private(set) var isRunning = false

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discoveredService: CBService?
    private var macInfoCharacteristic: CBCharacteristic?
    private var echoCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    @Published private(set) var probe = ProximityGATTProbe()
    @Published private(set) var lastVerifiedAt: Date?
    @Published private(set) var isConnected = false
    @Published private(set) var isSubscribed = false
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private var retry = ProximityGATTRetry()
    private var retryTask: Task<Void, Never>?
    private var retiredPeripherals: [UUID: CBPeripheral] = [:]
    private var sessionID = UUID()
    private var writeAcknowledgementPending = false
    private var connectStartedAt: Date?
    private var discoverStartedAt: Date?
    private var readStartedAt: Date?
    private var subscribeStartedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    private let attemptTimeout: TimeInterval = 15
    private let logLimit = 200

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Called at application launch, before the test screen exists. Only a
    /// previously explicit start creates a restorable Bluetooth manager.
    func resumeIfEnabled() {
        if defaults.bool(forKey: Self.enabledKey) { start() }
    }

    func start() {
        guard !isRunning else { return }
        defaults.set(true, forKey: Self.enabledKey)
        isRunning = true
        sessionID = UUID()
        retry.reset()
        probe = ProximityGATTProbe()
        lastVerifiedAt = nil
        lastError = nil
        resetAttempt()
        status = .starting
        log("central starting")
        if manager == nil {
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [
                    CBCentralManagerOptionShowPowerAlertKey: false,
                    CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier
                ]
            )
        } else {
            beginScanning()
        }
    }

    func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        resetAttempt()
        status = .idle
        log("central stopped; restoration disabled")
    }

    func clearLog() { logLines.removeAll() }

    func applicationStateChanged(isActive: Bool) {
        guard isRunning else { return }
        log(isActive ? "app foreground" : "app background; execution is scheduled by iOS")
        guard isActive else { return }
        if probe.payload != nil, let sentAt = probe.sentAt,
           Date.now.timeIntervalSince(sentAt) >= probe.timeout {
            fail("echo expired while suspended")
        } else if isSubscribed {
            sendEcho()
        } else if peripheral == nil, retryTask == nil {
            beginScanning()
        }
    }

    private func resetAttempt() {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            if peripheral.state != .disconnected {
                retiredPeripherals[peripheral.identifier] = peripheral
                manager?.cancelPeripheralConnection(peripheral)
            }
        }
        peripheral = nil
        discoveredService = nil
        macInfoCharacteristic = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        probe.cancel()
        writeAcknowledgementPending = false
        isConnected = false
        isSubscribed = false
        macInfo = nil
        timings = Timings()
        connectStartedAt = nil
        discoverStartedAt = nil
        readStartedAt = nil
        subscribeStartedAt = nil
    }

    private func beginScanning() {
        guard isRunning, peripheral == nil, let manager, manager.state == .poweredOn else { return }
        guard retryTask == nil else { return }
        status = .scanning
        guard !manager.isScanning else { return }
        log("scanning for \(ProximityGATTService.serviceUUID.uuidString)")
        manager.scanForPeripherals(withServices: [ProximityGATTService.serviceUUID], options: nil)
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.attemptTimeout ?? 15))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.fail("timed out while \(self.statusLabel)")
        }
    }

    private var statusLabel: String {
        switch status {
        case .idle: return "idle"
        case .starting: return "starting"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .discovering: return "discovering"
        case .echoing: return "waiting for the echo"
        case .verified: return "verified"
        case .failed: return "failed"
        }
    }

    private func fail(_ reason: String, retryWhenPoweredOn: Bool = true) {
        guard isRunning else { return }
        resetAttempt()
        status = .failed(reason)
        lastError = reason
        log("failed: \(reason)")
        retryTask?.cancel()
        retryTask = nil
        guard retryWhenPoweredOn, manager?.state == .poweredOn else { return }
        let delay = retry.nextDelay()
        log("retry in \(delay)s")
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.retryTask = nil
            self.sessionID = UUID()
            self.beginScanning()
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(sessionID.uuidString)] \(message())"
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    private func elapsedMs(since start: Date?) -> Int? {
        guard let start else { return nil }
        return max(0, Int((Date.now.timeIntervalSince(start) * 1000).rounded()))
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        if central.state != .poweredOn { retiredPeripherals.removeAll() }
        guard isRunning else { return }
        switch central.state {
        case .poweredOn:
            log("radio on")
            if let peripheral {
                resumeRestoredPeripheral(peripheral, on: central)
            } else { beginScanning() }
        case .unauthorized:
            fail("Bluetooth unauthorized", retryWhenPoweredOn: false)
        case .unsupported:
            fail("Bluetooth unsupported", retryWhenPoweredOn: false)
        case .poweredOff:
            fail("Bluetooth is off; waiting for radio recovery", retryWhenPoweredOn: false)
            retiredPeripherals.removeAll()
        default:
            fail("waiting for Bluetooth state=\(central.state.rawValue)", retryWhenPoweredOn: false)
            retiredPeripherals.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard central === manager else { return }
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard isRunning, defaults.bool(forKey: Self.enabledKey) else {
            central.stopScan()
            for peer in restored { central.cancelPeripheralConnection(peer) }
            return
        }
        log("restoring state: peers=\(restored.count), filtered scan=\(dict[CBCentralManagerRestoredStateScanServicesKey] != nil)")
        // The manager's private restoration ID belongs only to this service.
        // Never trust restored characteristic caches as proof of liveness.
        peripheral = restored.first
        peripheral?.delegate = self
        for extra in restored.dropFirst() { central.cancelPeripheralConnection(extra) }
        if central.state == .poweredOn {
            if let peripheral { resumeRestoredPeripheral(peripheral, on: central) }
            else { central.stopScan(); beginScanning() }
        }
    }

    private func resumeRestoredPeripheral(_ peer: CBPeripheral, on central: CBCentralManager) {
        guard isRunning else { return }
        scheduleTimeout()
        switch peer.state {
        case .connected:
            discover(on: peer)
        case .connecting:
            status = .connecting
            connectStartedAt = .now
            log("restored pending connection; waiting for didConnect")
        case .disconnected:
            status = .connecting
            connectStartedAt = .now
            central.connect(peer)
        case .disconnecting:
            fail("restored peripheral is disconnecting")
        @unknown default:
            fail("restored peripheral has an unknown state")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === manager, isRunning, retryTask == nil, self.peripheral == nil,
              retiredPeripherals[peripheral.identifier] == nil,
              peripheral.state == .disconnected else { return }
        sessionID = UUID()
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectStartedAt = .now
        status = .connecting
        log("discovered name=\(peripheral.name ?? "unknown") uuid=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue)")
        scheduleTimeout()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager else { return }
        guard isRunning, peripheral === self.peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        timings.connectMs = elapsedMs(since: connectStartedAt)
        log("central connected in \(timings.connectMs ?? 0) ms")
        discover(on: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager else { return }
        let retired = retiredPeripherals.removeValue(forKey: peripheral.identifier) != nil
        guard peripheral === self.peripheral else {
            if retired { restartScanAfterRetirement() }
            return
        }
        fail("connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === manager else { return }
        let retired = retiredPeripherals.removeValue(forKey: peripheral.identifier) != nil
        guard isRunning, peripheral === self.peripheral else {
            if retired { restartScanAfterRetirement() }
            return
        }
        fail("disconnected: \(error?.localizedDescription ?? "no error")")
    }

    private func restartScanAfterRetirement() {
        guard isRunning, peripheral == nil, retryTask == nil else { return }
        // A discovery ignored while cancellation was pending may be suppressed
        // as a duplicate by iOS. A fresh filtered scan makes it eligible again.
        manager?.stopScan()
        beginScanning()
    }

    private func discover(on peripheral: CBPeripheral) {
        isConnected = true
        isSubscribed = false
        discoveredService = nil
        macInfoCharacteristic = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        discoverStartedAt = .now
        status = .discovering
        peripheral.delegate = self
        log("discovering service; restored caches are revalidated")
        scheduleTimeout()
        peripheral.discoverServices([ProximityGATTService.serviceUUID])
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isRunning, peripheral === self.peripheral else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == ProximityGATTService.serviceUUID }) else {
            fail("service lookup failed: \(error?.localizedDescription ?? "not found")")
            return
        }
        guard status == .discovering else { return }
        discoveredService = service
        log("service discovered; discovering characteristics")
        peripheral.discoverCharacteristics([
            ProximityGATTService.macInfoCharacteristicUUID,
            ProximityGATTService.echoCharacteristicUUID,
            ProximityGATTService.responseCharacteristicUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isRunning, peripheral === self.peripheral,
              service === discoveredService,
              status == .discovering else { return }
        guard error == nil else {
            fail("characteristic lookup failed: \(error?.localizedDescription ?? "unknown error")")
            return
        }
        let characteristics = service.characteristics ?? []
        guard let macInfo = characteristics.first(where: { $0.uuid == ProximityGATTService.macInfoCharacteristicUUID }),
              let echo = characteristics.first(where: { $0.uuid == ProximityGATTService.echoCharacteristicUUID }),
              let response = characteristics.first(where: { $0.uuid == ProximityGATTService.responseCharacteristicUUID }) else {
            fail("one or more characteristics are missing")
            return
        }
        guard macInfo.properties.contains(.read), echo.properties.contains(.notify),
              response.properties.contains(.write) else {
            fail("characteristic properties do not support read/notify/write")
            return
        }
        macInfoCharacteristic = macInfo
        echoCharacteristic = echo
        responseCharacteristic = response
        timings.discoverMs = elapsedMs(since: discoverStartedAt)
        log("characteristics found in \(timings.discoverMs ?? 0) ms; reading Mac info")
        readStartedAt = .now
        peripheral.readValue(for: macInfo)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning, peripheral === self.peripheral else { return }
        if characteristic === macInfoCharacteristic, status == .discovering {
            handleMacInfo(characteristic, error: error)
        } else if characteristic === echoCharacteristic, isSubscribed {
            handleEcho(characteristic, error: error)
        }
    }

    private func handleMacInfo(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Mac info read failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, let info = ProximityGATTMacInfo(encoded: data) else {
            fail("Mac info decode failed (\(characteristic.value?.count ?? 0) bytes)")
            return
        }
        macInfo = info
        timings.readMs = elapsedMs(since: readStartedAt)
        log("Mac info version=\(ProximityGATTMacInfo.version) id=\(info.deviceID?.uuidString ?? "not configured") read in \(timings.readMs ?? 0) ms")
        guard let echoCharacteristic else {
            fail("echo characteristic disappeared")
            return
        }
        subscribeStartedAt = .now
        peripheral?.setNotifyValue(true, for: echoCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isRunning, peripheral === self.peripheral,
              characteristic === echoCharacteristic else { return }
        if let error {
            fail("subscribe failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            fail("Mac refused the echo subscription")
            return
        }
        timings.subscribeMs = elapsedMs(since: subscribeStartedAt)
        guard !isSubscribed else { return }
        isSubscribed = true
        log("central subscribed in \(timings.subscribeMs ?? 0) ms; writing echo")
        sendEcho()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isRunning, peripheral === self.peripheral,
              characteristic === responseCharacteristic else { return }
        writeAcknowledgementPending = false
        if let error {
            fail("echo write failed: \(error.localizedDescription)")
            return
        }
        log("echo write acknowledged; waiting for the notification")
    }

    /// Manual repeat and foreground resume use the same single in-flight slot.
    func sendEcho() {
        guard isRunning, isSubscribed, !writeAcknowledgementPending,
              let peripheral, peripheral.state == .connected,
              let responseCharacteristic, let payload = probe.begin() else { return }
        writeAcknowledgementPending = true
        status = .echoing
        log("sending 16 bytes")
        scheduleTimeout()
        peripheral.writeValue(payload, for: responseCharacteristic, type: .withResponse)
    }

    private func handleEcho(_ characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("echo notification failed: \(error.localizedDescription)")
            return
        }
        guard let received = characteristic.value else { return }
        log("received \(received.count) bytes")
        guard let roundTrip = probe.receive(received) else {
            log("ignored late, duplicate or mismatched echo")
            return
        }
        timings.echoMs = roundTrip
        lastVerifiedAt = .now
        retry.reset()
        timeoutTask?.cancel()
        timeoutTask = nil
        status = .verified(roundTripMs: roundTrip)
        log("round-trip verified in \(roundTrip) ms; count=\(probe.verifiedCount)")
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isRunning, peripheral === self.peripheral,
              invalidatedServices.contains(where: { $0.uuid == ProximityGATTService.serviceUUID }) else { return }
        fail("GATT service removed; Mac may have stopped advertising")
    }
}
