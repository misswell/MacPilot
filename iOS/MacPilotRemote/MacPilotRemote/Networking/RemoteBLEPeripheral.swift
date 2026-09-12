import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// Advertises the phone's MacPilot L2CAP channel so the Mac can reach it
/// without any network at all.
///
/// The roles are deliberately inverted from what the names suggest: the phone is
/// the peripheral and the Mac is the central. That is the direction BLE actually
/// supports between these two devices — the Mac holds a central link to this
/// iPhone for hours at a time for the proximity unlock, while the opposite
/// direction never establishes a connection at all (the Mac's controller sees no
/// connection request, and the phone's `connect` never calls back).
///
/// The GATT service is only a handshake: the Mac reads the PSM from a
/// characteristic and then opens a stream-oriented L2CAP channel, so the wire
/// protocol — framing, pairing, ChaChaPoly — runs unmodified on top of it.
@MainActor
final class RemoteBLEPeripheral: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    /// Delivers an open L2CAP channel. Ownership passes to the caller.
    var onChannel: ((CBL2CAPChannel) -> Void)?
    var onLog: ((String) -> Void)?

    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var wantsToRun = false
    private var isOnAir = false
    #if DEBUG
    private var diagnosticTransport: L2CAPStreamTransport?
    private var isEchoDiagnostic: Bool {
        ProcessInfo.processInfo.environment["MACPILOT_BLE_ECHO"] == "1"
    }
    #endif

    private var requiresEncryption: Bool {
        #if DEBUG
        if isEchoDiagnostic,
           ProcessInfo.processInfo.environment["MACPILOT_BLE_UNENCRYPTED"] == "1" { return false }
        #endif
        return true
    }

    /// Whether the phone is actually reachable over BLE right now. This is driven
    /// by the advertisement callback, not by intent: reporting intent here is
    /// what let the diagnostic claim the fallback was running while the radio was
    /// off and nothing was being advertised at all.
    var isAdvertising: Bool { isOnAir }

    // MARK: - Lifecycle

    func start() {
        wantsToRun = true
        if let manager {
            // The manager is kept across restarts: recreating it is slow and the
            // state callback that triggers publishing only fires on a change.
            if manager.state == .poweredOn, psm == nil {
                manager.publishL2CAPChannel(withEncryption: requiresEncryption)
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
        #if DEBUG
        diagnosticTransport?.cancel()
        diagnosticTransport = nil
        #endif
        wantsToRun = false
        isOnAir = false
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
        // Only the service UUID goes out. A local name would be dropped in the
        // background anyway, and the Mac finds us by service alone.
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [RemoteBLEService.serviceUUID]
        ])
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            guard wantsToRun else { return }
            onLog?("BLE advertising: radio on; publishing L2CAP channel")
            peripheral.publishL2CAPChannel(withEncryption: requiresEncryption)
        case .unauthorized:
            onLog?("BLE unauthorized; the Bluetooth permission is required for the fallback link")
        case .unsupported:
            onLog?("BLE unsupported on this device")
        default:
            // powered off / resetting / unknown. Naming the raw value is the only
            // way to tell "waiting for the radio" from "advertising".
            isOnAir = false
            onLog?("BLE waiting for Bluetooth: state=\(peripheral.state.rawValue)")
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
        onLog?("BLE L2CAP channel published psm=\(PSM) encryption=\(requiresEncryption)")
        publishService(on: peripheral, psm: PSM)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onLog?("BLE service add failed error=\(error.localizedDescription)")
            return
        }
        startAdvertising(peripheral)
    }

    /// Confirms the advertisement actually went out. Without this the only way
    /// to tell "advertising" from "silently not advertising" is to read the
    /// system Bluetooth log, which is how a peripheral that published a PSM but
    /// never became discoverable stayed invisible.
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            isOnAir = false
            onLog?("BLE advertising failed error=\(error.localizedDescription)")
            return
        }
        isOnAir = true
        onLog?("BLE advertising; waiting for the Mac to connect")
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
        onLog?("BLE the Mac read the PSM; opening the L2CAP channel")
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        onLog?("BLE didOpen channel=\(channel != nil) error=\(error.map { "\(($0 as NSError).domain)/\(($0 as NSError).code): \($0.localizedDescription)" } ?? "none")")
        if let error {
            onLog?("BLE L2CAP open failed error=\(error.localizedDescription)")
            return
        }
        guard let channel else { return }
        onLog?("BLE L2CAP channel open psm=\(channel.psm) peer=\(String(describing: channel.peer))")
        #if DEBUG
        if isEchoDiagnostic {
            diagnosticTransport?.cancel()
            let transport = L2CAPStreamTransport(channel: channel)
            diagnosticTransport = transport
            transport.onDiagnostic = { [weak self] message in self?.onLog?(message) }
            transport.onStateChange = { [weak self] state in self?.onLog?("echo state=\(state)") }
            transport.onReceive = { [weak transport] bytes in transport?.send(bytes) { _ in } }
            transport.start()
            return
        }
        #endif
        onChannel?(channel)
    }
}
