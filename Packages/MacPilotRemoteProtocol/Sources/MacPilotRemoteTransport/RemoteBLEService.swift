import CoreBluetooth

/// The GATT contract both apps must agree on.
///
/// The service exists only to hand over an L2CAP PSM: once the channel is open
/// it is a byte stream and the regular wire protocol runs on it, so nothing
/// about commands, framing or encryption is duplicated here.
///
/// The UUIDs spell "macPilot" in the first eight bytes so they are recognisable
/// in a packet capture; the trailing fields are a fixed service/characteristic
/// pair rather than anything derived at runtime.
public enum RemoteBLEService {
    // `CBUUID` is immutable at runtime but is not annotated `Sendable`, so the
    // fixed identifiers are opted out of the global-variable check explicitly.
    public nonisolated(unsafe) static let serviceUUID = CBUUID(string: "6D616350-696C-6F74-0001-000000000001")
    /// Read-only, holds the 16-bit little-endian L2CAP PSM.
    public nonisolated(unsafe) static let psmCharacteristicUUID = CBUUID(string: "6D616350-696C-6F74-0001-000000000002")

    /// The PSM as it travels on the wire.
    public static func encodePSM(_ psm: CBL2CAPPSM) -> Data {
        withUnsafeBytes(of: psm.littleEndian) { Data($0) }
    }

    public static func decodePSM(_ data: Data) -> CBL2CAPPSM? {
        guard data.count >= 2 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }
}
