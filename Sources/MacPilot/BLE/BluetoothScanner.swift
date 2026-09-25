import CoreBluetooth
import Foundation

/// The monitored peripherals receive their periodic RSSI reads through the
/// connected-peripheral path below; duplicate advertisements only create an
/// unbounded XPC/Mach-message stream on macOS.
enum BLEScanPolicy {
    static let allowsDuplicateAdvertisements = false

    static var scanOptions: [String: Any]? {
        allowsDuplicateAdvertisements
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : nil
    }
}


/// Owns the CoreBluetooth session so feature stop can close its XPC/delegate
/// graph, not merely stop advertising callbacks.
@MainActor
final class BluetoothScanner {
    var central: CBCentralManager?

    func createIfNeeded(delegate: CBCentralManagerDelegate) {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: delegate,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func startIfPoweredOn() -> Bool {
        guard let central, central.state == .poweredOn else { return false }
        guard !central.isScanning else { return true }
        central.scanForPeripherals(withServices: nil, options: BLEScanPolicy.scanOptions)
        return true
    }

    func stop() { central?.stopScan() }

    func release() {
        central?.stopScan()
        central?.delegate = nil
        central = nil
    }
}
