import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol

/// GATT contract for the direction the existing remote link does not use:
/// the Mac advertises, the phone scans and connects.
///
/// The existing `RemoteBLEService` is the opposite direction (phone peripheral,
/// Mac central) and hands out an L2CAP PSM. This service deliberately stops at
/// plain GATT: its only job is to prove the reversed roles can discover,
/// connect, read, subscribe and write before anything is built on top.
///
/// The first eight bytes still spell "macPilot"; the fifth group identifies the
/// direction (`0002`) so the two services cannot be confused in a packet trace.
public enum ProximityGATTService {
    // `CBUUID` is immutable at runtime but is not annotated `Sendable`, so the
    // fixed identifiers are opted out of the global-variable check explicitly.
    public nonisolated(unsafe) static let serviceUUID = CBUUID(string: "6D616350-696C-6F74-0002-000000000001")
    /// Read-only. Answers `ProximityGATTMacInfo.encoded`.
    public nonisolated(unsafe) static let macInfoCharacteristicUUID = CBUUID(string: "6D616350-696C-6F74-0002-000000000002")
    /// Notifying. The Mac echoes every accepted response here.
    public nonisolated(unsafe) static let echoCharacteristicUUID = CBUUID(string: "6D616350-696C-6F74-0002-000000000003")
    /// Write-only. The phone writes a fresh random payload and expects it back
    /// on the echo characteristic.
    public nonisolated(unsafe) static let responseCharacteristicUUID = CBUUID(string: "6D616350-696C-6F74-0002-000000000004")
    /// Read + write. Carries the authenticated presence challenge used by the
    /// proximity fallback. Optional: an older phone simply has no such
    /// characteristic, and the round-trip test above keeps working without it.
    public nonisolated(unsafe) static let presenceChallengeCharacteristicUUID = CBUUID(string: "6D616350-696C-6F74-0002-000000000005")
}

/// The read-only payload that tells the phone which Mac it reached.
public struct ProximityGATTMacInfo: Equatable, Sendable {
    public static let version: UInt8 = 1
    /// version + 16 byte device identifier. 17 bytes fits a default 23 byte
    /// ATT MTU even before any exchange.
    public static let encodedLength = 17

    /// `nil` when remote control has never been enabled, so this Mac has no
    /// permanent identifier yet. The rest of the payload stays usable.
    public let deviceID: UUID?

    public init(deviceID: UUID?) {
        self.deviceID = deviceID
    }

    public var encoded: Data {
        var data = Data([Self.version])
        if let deviceID {
            data.append(withUnsafeBytes(of: deviceID.uuid) { Data($0) })
        } else {
            data.append(Data(repeating: 0, count: 16))
        }
        return data
    }

    /// Strict decode: an unknown version or a wrong length is rejected instead
    /// of being interpreted with guessed field offsets.
    public init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.encodedLength, bytes[0] == Self.version else { return nil }
        let idBytes = Array(bytes[1..<Self.encodedLength])
        if idBytes.allSatisfy({ $0 == 0 }) {
            deviceID = nil
            return
        }
        deviceID = UUID(uuid: (
            idBytes[0], idBytes[1], idBytes[2], idBytes[3],
            idBytes[4], idBytes[5], idBytes[6], idBytes[7],
            idBytes[8], idBytes[9], idBytes[10], idBytes[11],
            idBytes[12], idBytes[13], idBytes[14], idBytes[15]
        ))
    }
}

/// The phase-one round trip payload: length-bounded, constant-time compared,
/// and carrying no identity whatsoever. Authentication is deliberately absent
/// until the link itself is proven to work.
public enum ProximityGATTEcho {
    public static let length = 16

    public static func random() -> Data {
        RemoteCrypto.randomData(count: length)
    }

    public static func isValid(_ echoed: Data, matching sent: Data) -> Bool {
        sent.count == length
            && echoed.count == length
            && RemoteCrypto.constantTimeEquals(echoed, sent)
    }
}

/// Authenticates a reverse-GATT central before its address may be treated as a
/// proximity observation.
///
/// The reverse link exists because iOS rotates its advertised address, which
/// makes the Mac see a new peripheral each time. Without a challenge, echoing
/// sixteen bytes would only prove *some* device is nearby, so any phone running
/// PilotNest could stand in for the paired one. This reuses the very same
/// `RemoteBLEPresenceChallenge` proof as the existing phone-as-peripheral path:
/// only a device holding the long-term pairing key can answer, and the answer
/// is bound to this Mac's identity and a fresh nonce.
///
/// Authentication proves identity, never proximity: the caller must still take
/// ordinary RSSI samples before the address may unlock anything.
public enum ProximityGATTPresence {
    /// Mac writes a `RemoteBLEPresenceChallenge`; the phone answers with the
    /// keyed proof on the same characteristic. Both directions are length
    /// checked, and the encoded challenge already carries its own version byte.
    public static func response(for challenge: RemoteBLEPresenceChallenge, pairingKey: Data) -> Data {
        challenge.response(pairingKey: pairingKey)
    }

    public static func isValidResponse(
        _ response: Data,
        challenge: RemoteBLEPresenceChallenge,
        pairingKey: Data
    ) -> Bool {
        challenge.isValidResponse(response, pairingKey: pairingKey)
    }
}
