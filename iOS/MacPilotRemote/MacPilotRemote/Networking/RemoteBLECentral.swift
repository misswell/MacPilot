import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Finds the Mac over BLE and opens a stream-oriented L2CAP channel to it.
///
/// This is the fallback link: it needs no router, no shared subnet and no
/// peer-to-peer Wi-Fi, so it covers the cases the network path cannot — a Mac on
/// Ethernet, a phone on cellular, a client-isolating guest network.
///
/// It only runs while the app is in the foreground and not already connected, so
/// scanning never costs battery in the background.
@MainActor
final class RemoteBLECentral: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    /// Delivers an open L2CAP channel. Ownership passes to the caller.
    var onChannel: ((CBL2CAPChannel) -> Void)?
    var onLog: ((String) -> Void)?

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var isScanning = false
    private var wantsChannel = false
    private var attemptWatchdog: Task<Void, Never>?

    /// How long a single discovery attempt may take before it is restarted.
    /// Connecting, discovering and opening a channel are each a round trip, and
    /// a stalled step would otherwise leave the fallback silently dead.
    private let attemptTimeout: TimeInterval = 12

    var isActive: Bool { wantsChannel }

    // MARK: - Lifecycle

    func start() {
        wantsChannel = true
        if manager == nil {
            onLog?("BLE central starting")
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
            return
        }
        beginScanningIfPossible()
    }

    func stop() {
        wantsChannel = false
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        isScanning = false
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    private func beginScanningIfPossible() {
        // Every early return names its reason. A silent return here is
        // indistinguishable from a healthy scan at the UI, which is exactly how
        // a fallback that never connects stays invisible.
        guard wantsChannel else {
            onLog?("BLE idle; the fallback is not needed")
            return
        }
        guard let manager else {
            onLog?("BLE waiting for the central manager")
            return
        }
        guard manager.state == .poweredOn else {
            onLog?("BLE waiting for Bluetooth: state=\(manager.state.rawValue)")
            return
        }
        guard !isScanning, peripheral == nil else { return }
        isScanning = true
        onLog?("BLE scanning for the MacPilot service")
        // A service-filtered scan is required for any background wake-up, and
        // it is also what keeps this cheap in the foreground.
        manager.scanForPeripherals(withServices: [RemoteBLEService.serviceUUID])
        armWatchdog()
    }

    /// Restarts discovery if the current attempt stalls mid-handshake.
    private func armWatchdog() {
        attemptWatchdog?.cancel()
        attemptWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.attemptTimeout ?? 12))
            guard let self, !Task.isCancelled, self.wantsChannel else { return }
            self.onLog?("BLE attempt stalled; restarting discovery")
            self.resetAttempt()
        }
    }

    private func resetAttempt() {
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        isScanning = false
        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        psmCharacteristic = nil
        beginScanningIfPossible()
    }

    private var psmCharacteristic: CBCharacteristic?

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // The raw state is logged on every transition, including the ones that
        // have no dedicated case: a powered-off radio used to fall into
        // `default` and leave no trace at all.
        onLog?("BLE central state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            beginScanningIfPossible()
        case .unauthorized:
            onLog?("BLE unauthorized; the Bluetooth permission is required for the fallback link")
        case .unsupported:
            onLog?("BLE unsupported on this device")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard wantsChannel, self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        isScanning = false
        onLog?("BLE found the Mac; connecting")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([RemoteBLEService.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onLog?("BLE connect failed error=\(error?.localizedDescription ?? "unknown")")
        resetAttempt()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // A disconnect is only a problem while we still need a channel; once
        // one is open the L2CAP stream outlives this callback's caller.
        guard wantsChannel, self.peripheral === peripheral else { return }
        resetAttempt()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == RemoteBLEService.serviceUUID }) else {
            onLog?("BLE service discovery failed error=\(error?.localizedDescription ?? "not found")")
            resetAttempt()
            return
        }
        peripheral.discoverCharacteristics([RemoteBLEService.psmCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == RemoteBLEService.psmCharacteristicUUID })
        else {
            onLog?("BLE PSM characteristic missing error=\(error?.localizedDescription ?? "not found")")
            resetAttempt()
            return
        }
        psmCharacteristic = characteristic
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == RemoteBLEService.psmCharacteristicUUID,
              let data = characteristic.value,
              let psm = RemoteBLEService.decodePSM(data)
        else {
            onLog?("BLE PSM read failed error=\(error?.localizedDescription ?? "bad value")")
            resetAttempt()
            return
        }
        onLog?("BLE opening L2CAP channel psm=\(psm)")
        peripheral.openL2CAPChannel(psm)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        guard error == nil, let channel else {
            onLog?("BLE L2CAP open failed error=\(error?.localizedDescription ?? "unknown")")
            resetAttempt()
            return
        }
        // The GATT link stays up: the L2CAP channel belongs to this peripheral,
        // so tearing the peripheral down would close the stream with it.
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        onLog?("BLE L2CAP channel open")
        onChannel?(channel)
    }
}
