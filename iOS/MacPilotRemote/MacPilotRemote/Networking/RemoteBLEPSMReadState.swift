import CoreBluetooth
import Foundation
import MacPilotRemoteTransport

/// The active PSM is scoped to the currently published L2CAP channel. Reads
/// are answered from this state rather than from a value cached in a GATT
/// characteristic, so a service refresh can never intentionally serve an old
/// publication's PSM.
struct RemoteBLEPSMReadState {
    private(set) var currentPSM: CBL2CAPPSM?

    mutating func publish(_ psm: CBL2CAPPSM) {
        currentPSM = psm
    }

    mutating func clear() {
        currentPSM = nil
    }

    func response(offset: Int) -> Data? {
        guard let currentPSM else { return nil }
        let value = RemoteBLEService.encodePSM(currentPSM)
        guard offset >= 0, offset <= value.count else { return nil }
        return value.subdata(in: offset..<value.count)
    }
}

enum RemoteBLEPSMCharacteristic {
    static func make() -> CBMutableCharacteristic {
        CBMutableCharacteristic(
            type: RemoteBLEService.psmCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
    }
}
