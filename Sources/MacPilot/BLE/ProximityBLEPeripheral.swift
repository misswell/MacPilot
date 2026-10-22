import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Independent Mac-as-peripheral connectivity test. Its advertisement, GATT
/// service, bounded echo queue and retries never touch the old BLE managers,
/// remote commands or the proximity/lock policy. Notification delivery is
/// measured here; only the phone can verify the round trip.
@MainActor
final class ProximityBLEPeripheral: NSObject, ObservableObject, @preconcurrency CBPeripheralManagerDelegate {
    static let shared = ProximityBLEPeripheral()

    enum Status: Equatable {
        case idle
        case starting
        case advertising
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastEchoAt: Date?
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var receivedBytes = 0
    @Published private(set) var sentBytes = 0
    @Published private(set) var isAdvertising = false
    @Published private(set) var subscriberCount = 0
    @Published private(set) var isRunning = false

    private var manager: CBPeripheralManager?
    private var macInfo = Data()
    private var publishedService: CBMutableService?
    private var echoCharacteristic: CBMutableCharacteristic?
    private var responseCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var wantsToRun = false
    private var isPublishing = false
    private var isStartingAdvertising = false
    private var echoQueue = ProximityGATTEchoQueue()
    private var retry = ProximityGATTRetry()
    private var retryTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var sessionID = UUID()
    private let logLimit = 200

    // MARK: - Lifecycle

    func start(macDeviceID: UUID?) {
        if manager != nil { stop() }
        wantsToRun = true
        isRunning = true
        sessionID = UUID()
        retry.reset()
        receivedBytes = 0
        sentBytes = 0
        lastReceivedAt = nil
        status = .starting
        lastEchoAt = nil
        macInfo = ProximityGATTMacInfo(deviceID: macDeviceID).encoded
        log("peripheral starting; MacID=\(macDeviceID?.uuidString ?? "not configured")")
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        wantsToRun = false
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        echoQueue.reset()
        isAdvertising = false
        subscriberCount = 0
        subscribedCentrals.removeAll()
        publishedService = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        isPublishing = false
        isStartingAdvertising = false
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            manager.delegate = nil
        }
        manager = nil
        status = .idle
        log("peripheral stopped")
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - GATT

    private func publishService(on manager: CBPeripheralManager) {
        guard wantsToRun, !isPublishing, publishedService == nil, manager.state == .poweredOn else { return }
        isPublishing = true

        let macInfoCharacteristic = CBMutableCharacteristic(
            type: ProximityGATTService.macInfoCharacteristicUUID,
            properties: [.read],
            value: macInfo,
            permissions: [.readable]
        )
        let echo = CBMutableCharacteristic(
            type: ProximityGATTService.echoCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let response = CBMutableCharacteristic(
            type: ProximityGATTService.responseCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: ProximityGATTService.serviceUUID, primary: true)
        service.characteristics = [macInfoCharacteristic, echo, response]
        publishedService = service
        echoCharacteristic = echo
        responseCharacteristic = response
        log("publishing GATT service \(ProximityGATTService.serviceUUID.uuidString)")
        manager.add(service)
    }

    private func startAdvertising(_ manager: CBPeripheralManager) {
        guard wantsToRun, manager.state == .poweredOn,
              !manager.isAdvertising, !isStartingAdvertising else { return }
        isStartingAdvertising = true
        // Service UUID only; the local name is optional for discovery and would
        // shrink the room left for the UUID in the legacy advertising payload.
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [ProximityGATTService.serviceUUID]
        ])
    }

    private func log(_ message: @autoclosure () -> String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(sessionID.uuidString)] \(message())"
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    private func fail(_ reason: String) {
        status = .failed(reason)
        log("peripheral failed: \(reason)")
    }

    private func scheduleRetry(on peripheral: CBPeripheralManager) {
        guard wantsToRun, peripheral.state == .poweredOn else { return }
        retryTask?.cancel()
        let delay = retry.nextDelay()
        log("retry in \(delay)s")
        retryTask = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let peripheral,
                  peripheral === self.manager, self.wantsToRun,
                  peripheral.state == .poweredOn else { return }
            self.status = .starting
            if self.publishedService == nil { self.publishService(on: peripheral) }
            else { self.startAdvertising(peripheral) }
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        if peripheral.state != .poweredOn {
            retryTask?.cancel()
            resetPublishedService()
        }
        switch peripheral.state {
        case .poweredOn:
            log("radio on")
            if wantsToRun { status = .starting }
            publishService(on: peripheral)
        case .unauthorized:
            fail("Bluetooth unauthorized")
        case .unsupported:
            fail("Bluetooth unsupported")
        case .poweredOff:
            fail("Bluetooth is off; waiting for radio recovery")
        default:
            status = .starting
            log("waiting for Bluetooth state=\(peripheral.state.rawValue)")
        }
    }

    /// A radio that leaves the powered-on state drops its GATT registrations.
    /// Clearing the references lets the next powered-on callback publish them
    /// again; keeping them made a Bluetooth toggle leave the harness dead.
    private func resetPublishedService() {
        publishedService = nil
        echoCharacteristic = nil
        responseCharacteristic = nil
        isPublishing = false
        isStartingAdvertising = false
        echoQueue.reset()
        expiryTask?.cancel()
        isAdvertising = false
        subscriberCount = 0
        subscribedCentrals.removeAll()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, service === publishedService else { return }
        isPublishing = false
        if let error {
            publishedService = nil
            echoCharacteristic = nil
            responseCharacteristic = nil
            peripheral.removeAllServices()
            fail("service add failed: \(error.localizedDescription)")
            scheduleRetry(on: peripheral)
            return
        }
        log("GATT service added; starting advertisement")
        startAdvertising(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager, wantsToRun, peripheral.state == .poweredOn,
              publishedService != nil else { return }
        isStartingAdvertising = false
        if let error {
            isAdvertising = false
            fail("advertising failed: \(error.localizedDescription)")
            scheduleRetry(on: peripheral)
            return
        }
        guard wantsToRun else {
            peripheral.stopAdvertising()
            return
        }
        isAdvertising = peripheral.isAdvertising
        retry.reset()
        status = subscriberCount == 0 ? .advertising : .connected
        log("advertising started")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager, wantsToRun,
              request.characteristic.service === publishedService,
              request.characteristic.uuid == ProximityGATTService.macInfoCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = macInfo
        log("central read Mac info (\(macInfo.count) bytes)")
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // CoreBluetooth requires one ATT response for the entire batch. Validate
        // into a copy first so a rejected batch cannot partially echo data.
        var staged = echoQueue
        for request in requests {
            guard peripheral === manager, wantsToRun,
                  request.characteristic === responseCharacteristic else {
                peripheral.respond(to: first, withResult: .requestNotSupported)
                return
            }
            guard request.offset == 0 else {
                peripheral.respond(to: first, withResult: .invalidOffset)
                return
            }
            guard let value = request.value, value.count == ProximityGATTEcho.length else {
                log("rejected write: invalid length \(request.value?.count ?? 0)")
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                return
            }
            guard subscribedCentrals[request.central.identifier] != nil else {
                log("rejected write: no subscriber for central=\(request.central.identifier)")
                peripheral.respond(to: first, withResult: .unlikelyError)
                return
            }
            guard staged.enqueue(value, for: request.central.identifier) else {
                log("rejected write: notification queue busy")
                peripheral.respond(to: first, withResult: .insufficientResources)
                return
            }
        }
        echoQueue = staged
        lastReceivedAt = .now
        receivedBytes += requests.count * ProximityGATTEcho.length
        log("received 16 bytes; writes=\(requests.count)")
        peripheral.respond(to: first, withResult: .success)
        deliverEchoes(on: peripheral)
    }

    private func deliverEchoes(on peripheral: CBPeripheralManager) {
        guard let echoCharacteristic else { return }
        echoQueue.discardExpired()
        while let entry = echoQueue.entries.first {
            guard let central = subscribedCentrals[entry.centralID] else {
                echoQueue.removeFirst()
                continue
            }
            guard peripheral.updateValue(entry.payload, for: echoCharacteristic, onSubscribedCentrals: [central]) else {
                log("echo not queued; waiting for notification buffer central=\(entry.centralID)")
                scheduleQueueExpiry()
                return
            }
            echoQueue.removeFirst()
            lastEchoAt = .now
            sentBytes += entry.payload.count
            log("echoed 16 bytes central=\(entry.centralID); queued, verification belongs to iPhone")
        }
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func scheduleQueueExpiry() {
        expiryTask?.cancel()
        guard let expiry = echoQueue.entries.first?.expiresAt else { return }
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.log("notification queue deadline reached")
            self.echoQueue.discardExpired()
            if let manager = self.manager { self.deliverEchoes(on: manager) }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        log("notification buffer ready")
        deliverEchoes(on: peripheral)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, wantsToRun,
              characteristic === echoCharacteristic else { return }
        subscribedCentrals[central.identifier] = central
        subscriberCount = subscribedCentrals.count
        isAdvertising = peripheral.isAdvertising
        status = .connected
        log("central subscribed uuid=\(central.identifier.uuidString)")
        // Subscription proves notification availability, not round-trip success.
        if peripheral.isAdvertising == false {
            log("advertisement paused while connected")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, wantsToRun,
              characteristic === echoCharacteristic else { return }
        subscribedCentrals.removeValue(forKey: central.identifier)
        subscriberCount = subscribedCentrals.count
        echoQueue.remove(centralID: central.identifier)
        isAdvertising = peripheral.isAdvertising
        log("central unsubscribed uuid=\(central.identifier.uuidString)")
        if subscribedCentrals.isEmpty {
            if !wantsToRun {
                status = .idle
            } else {
                status = peripheral.isAdvertising ? .advertising : .starting
            }
        }
        if wantsToRun, peripheral.state == .poweredOn, peripheral.isAdvertising == false {
            startAdvertising(peripheral)
        }
    }
}
