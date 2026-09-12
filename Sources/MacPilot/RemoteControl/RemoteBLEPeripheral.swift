import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Advertises a MacPilot L2CAP channel over BLE.
///
/// The GATT service is only a handshake: the phone reads the PSM from a
/// characteristic and then opens a stream-oriented L2CAP channel, so the wire
/// protocol — framing, pairing, ChaChaPoly — runs unmodified on top of it.
///
/// This matters for the case the network cannot cover: a Mac on Ethernet, a
/// phone on cellular, a guest network that isolates clients, or a router that is
/// simply down. BLE needs none of it.
@MainActor
final class RemoteBLEPeripheral: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    /// Hands a newly opened channel to the remote control server.
    var onChannel: ((CBL2CAPChannel) -> Void)?
    var onLog: ((String) -> Void)?

    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var wantsToRun = false

    var isRunning: Bool { manager != nil }

    func start() {
        wantsToRun = true
        if let manager {
            // The manager is kept across restarts: recreating it is slow and the
            // state callback that triggers publishing only fires on a change.
            if manager.state == .poweredOn, psm == nil {
                manager.publishL2CAPChannel(withEncryption: true)
            }
            return
        }
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        wantsToRun = false
        guard let manager else { return }
        manager.stopAdvertising()
        if let psm {
            manager.unpublishL2CAPChannel(psm)
            self.psm = nil
        }
        manager.removeAllServices()
    }

    // MARK: - GATT

    /// The service is built only once the PSM exists, because the characteristic
    /// carries it. Order matters: publish the channel, then the service, then
    /// advertise.
    private func publishService(on manager: CBPeripheralManager, psm: CBL2CAPPSM) {
        let characteristic = CBMutableCharacteristic(
            type: RemoteBLEService.psmCharacteristicUUID,
            properties: [.read],
            value: RemoteBLEService.encodePSM(psm),
            permissions: [.readable]
        )
        let service = CBMutableService(type: RemoteBLEService.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        manager.add(service)
    }

    private func startAdvertising(_ manager: CBPeripheralManager) {
        // The service UUID is the only thing the phone needs to find us; the
        // Mac's name is deliberately not advertised.
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [RemoteBLEService.serviceUUID]
        ])
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            guard wantsToRun else { return }
            onLog?("BLE peripheral powered on; publishing L2CAP channel")
            peripheral.publishL2CAPChannel(withEncryption: true)
        case .unauthorized:
            onLog?("BLE peripheral unauthorized; Bluetooth permission is required")
        case .unsupported:
            onLog?("BLE peripheral unsupported on this Mac")
        default:
            break
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didPublishL2CAPChannel PSM: CBL2CAPPSM,
        error: Error?
    ) {
        if let error {
            onLog?("BLE L2CAP publish failed error=\(error.localizedDescription)")
            return
        }
        psm = PSM
        onLog?("BLE L2CAP channel published psm=\(PSM)")
        publishService(on: peripheral, psm: PSM)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onLog?("BLE service add failed error=\(error.localizedDescription)")
            return
        }
        startAdvertising(peripheral)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == RemoteBLEService.psmCharacteristicUUID, let psm else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        let value = RemoteBLEService.encodePSM(psm)
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        if let error {
            onLog?("BLE L2CAP open failed error=\(error.localizedDescription)")
            return
        }
        guard let channel else { return }
        onLog?("BLE L2CAP channel opened")
        onChannel?(channel)
    }
}
