import Foundation
import MacPilotRemoteProtocol

/// Lets a paired Mac prove that a newly seen BLE peripheral is its phone.
///
/// iOS rotates the advertised BLE address every few minutes, and the Mac sees
/// each address as a new `CBPeripheral.identifier`. The foreground identity
/// claim cannot cover that: it needs an authenticated network session and the
/// phone app in the foreground, while the rotation happens with the app asleep
/// in a pocket. This challenge runs entirely over GATT, which the phone's
/// `bluetooth-peripheral` background mode keeps answering.
///
/// Authentication proves *identity*, never proximity: the caller still requires
/// ordinary RSSI samples before the learned address may unlock anything.
public struct RemoteBLEPresenceChallenge: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let nonceLength = 16
    public static let responseLength = 32
    public static let encodedLength = 1 + nonceLength + 16

    /// Domain separation: this tag can never be confused with a pairing proof
    /// or a session key even if the same long-term key is used.
    private static let label = Data("MacPilotRemote-v1-ble-presence".utf8)

    public let macID: UUID
    public let nonce: Data

    public init(macID: UUID, nonce: Data = RemoteCrypto.randomData(count: nonceLength)) {
        self.macID = macID
        self.nonce = nonce
    }

    /// Strict decode: an unrecognised version or an unexpected length is
    /// rejected rather than interpreted with guessed field offsets.
    public init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.encodedLength, bytes[0] == Self.version else { return nil }
        let nonceEnd = 1 + Self.nonceLength
        let idBytes = Array(bytes[nonceEnd..<Self.encodedLength])
        self.macID = UUID(uuid: (
            idBytes[0], idBytes[1], idBytes[2], idBytes[3],
            idBytes[4], idBytes[5], idBytes[6], idBytes[7],
            idBytes[8], idBytes[9], idBytes[10], idBytes[11],
            idBytes[12], idBytes[13], idBytes[14], idBytes[15]
        ))
        self.nonce = Data(bytes[1..<nonceEnd])
    }

    public var encoded: Data {
        var data = Data([Self.version])
        data.append(nonce)
        data.append(Self.bytes(of: macID))
        return data
    }

    /// The phone computes this with the Mac's pairing key. Only the two paired
    /// devices can produce or verify it.
    public func response(pairingKey: Data) -> Data {
        RemoteCrypto.hmacSHA256(key: pairingKey, data: Self.message(macID: macID, nonce: nonce))
    }

    public func isValidResponse(_ response: Data, pairingKey: Data) -> Bool {
        RemoteCrypto.constantTimeEquals(response, self.response(pairingKey: pairingKey))
    }

    private static func message(macID: UUID, nonce: Data) -> Data {
        var data = label
        data.append(bytes(of: macID))
        data.append(nonce)
        return data
    }

    private static func bytes(of uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}

/// A reverse-role proximity sample: the phone measured its own RSSI towards the
/// Mac and proves both the measurement and the moment it was taken.
///
/// The legacy `RemoteBLEPresenceChallenge` answer proves identity only; its
/// bytes say nothing about distance, and anyone who captured it could replay it
/// against the same nonce. This type adds the two fields the reverse path needs
/// — the RSSI value and the time the iOS app packages its callback — inside the
/// HMAC and under a separate domain label, so a proximity proof can never be
/// confused with an identity proof. CoreBluetooth exposes the RSSI callback,
/// not the underlying radio measurement time, and the phone can set this wall
/// clock timestamp; it is diagnostic data rather than trusted freshness proof.
///
/// The payload is written once per fresh challenge. The Mac keeps the challenge
/// pending and consumes it on the first accepted sample, which makes every
/// sample single-use even though the wire format itself carries no sequence
/// number.
public struct RemoteBLEReversePresenceSample: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let nonceLength = 16
    public static let signatureLength = 32
    /// version + nonce + mac ID + RSSI + timestamp + signature.
    public static let encodedLength = 1 + nonceLength + 16 + 1 + 8 + signatureLength
    /// Convenience wall-clock freshness bounds for callers that compare the
    /// phone's diagnostic timestamp. Production presence authorization uses
    /// the Mac-local monotonic challenge lifetime instead.
    public static let maximumAge: TimeInterval = 12
    /// Convenience tolerance for future phone timestamps during diagnostics.
    public static let maximumFutureSkew: TimeInterval = 3

    private static let label = Data("MacPilotRemote-v1-reverse-presence".utf8)
    private static let rssiOffset = 1 + nonceLength + 16
    private static let timestampOffset = rssiOffset + 1
    private static let signatureOffset = timestampOffset + 8

    public let macID: UUID
    public let nonce: Data
    public let rssi: Int
    /// Phone wall-clock time at sample construction; signed for diagnostics,
    /// not a trusted RSSI measurement timestamp.
    public let sampledAtMilliseconds: UInt64
    public let signature: Data

    /// Constructs a well-formed signed payload. `sampledAt` is supplied by the
    /// caller and must not be treated as proof of when the radio read occurred.
    public init?(
        macID: UUID,
        nonce: Data,
        rssi: Int,
        sampledAt: Date,
        pairingKey: Data
    ) {
        guard nonce.count == Self.nonceLength, Self.isValidRSSI(rssi) else { return nil }
        let milliseconds = sampledAt.timeIntervalSince1970 * 1000
        guard milliseconds >= 0, milliseconds < Double(UInt64.max) else { return nil }
        let rounded = UInt64(milliseconds.rounded())
        self.macID = macID
        self.nonce = nonce
        self.rssi = rssi
        self.sampledAtMilliseconds = rounded
        self.signature = Self.signature(
            macID: macID,
            nonce: nonce,
            rssi: rssi,
            sampledAtMilliseconds: rounded,
            pairingKey: pairingKey
        )
    }

    /// Strict decode: unknown version, wrong length or an out-of-range RSSI is
    /// rejected before the signature is even considered.
    public init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.encodedLength, bytes[0] == Self.version else { return nil }
        let nonceEnd = 1 + Self.nonceLength
        let rssi = Int(Int8(bitPattern: bytes[Self.rssiOffset]))
        guard Self.isValidRSSI(rssi) else { return nil }
        var milliseconds: UInt64 = 0
        for byte in bytes[Self.timestampOffset..<Self.signatureOffset] {
            milliseconds = (milliseconds << 8) | UInt64(byte)
        }
        self.nonce = Data(bytes[1..<nonceEnd])
        self.macID = UUID(uuid: (
            bytes[nonceEnd], bytes[nonceEnd + 1], bytes[nonceEnd + 2], bytes[nonceEnd + 3],
            bytes[nonceEnd + 4], bytes[nonceEnd + 5], bytes[nonceEnd + 6], bytes[nonceEnd + 7],
            bytes[nonceEnd + 8], bytes[nonceEnd + 9], bytes[nonceEnd + 10], bytes[nonceEnd + 11],
            bytes[nonceEnd + 12], bytes[nonceEnd + 13], bytes[nonceEnd + 14], bytes[nonceEnd + 15]
        ))
        self.rssi = rssi
        self.sampledAtMilliseconds = milliseconds
        self.signature = Data(bytes[Self.signatureOffset..<Self.encodedLength])
    }

    public var encoded: Data {
        var data = Data([Self.version])
        data.append(nonce)
        data.append(withUnsafeBytes(of: macID.uuid) { Data($0) })
        data.append(UInt8(bitPattern: Int8(rssi)))
        var milliseconds = sampledAtMilliseconds.bigEndian
        withUnsafeBytes(of: &milliseconds) { data.append(contentsOf: $0) }
        data.append(signature)
        return data
    }

    public var sampledAt: Date {
        Date(timeIntervalSince1970: Double(sampledAtMilliseconds) / 1000)
    }

    public static func isValidRSSI(_ rssi: Int) -> Bool {
        (-127...0).contains(rssi)
    }

    public func isValidSignature(pairingKey: Data) -> Bool {
        RemoteCrypto.constantTimeEquals(
            signature,
            Self.signature(
                macID: macID,
                nonce: nonce,
                rssi: rssi,
                sampledAtMilliseconds: sampledAtMilliseconds,
                pairingKey: pairingKey
            )
        )
    }

    public func isFresh(
        now: Date,
        maximumAge: TimeInterval = Self.maximumAge,
        maximumFutureSkew: TimeInterval = Self.maximumFutureSkew
    ) -> Bool {
        // This value only describes the signed phone wall-clock field. It
        // cannot prove when CoreBluetooth measured RSSI or resist a paired
        // client that chooses its own timestamp.
        let age = now.timeIntervalSince(sampledAt)
        return age <= maximumAge && age >= -maximumFutureSkew
    }

    /// Convenience validation for the signed phone timestamp plus proof
    /// binding. This does not replace the Mac's production check, which
    /// validates the live challenge using its local monotonic clock and HMAC.
    public func isValid(
        pairingKey: Data,
        expectedMacID: UUID,
        expectedNonce: Data,
        now: Date = .now,
        maximumAge: TimeInterval = Self.maximumAge,
        maximumFutureSkew: TimeInterval = Self.maximumFutureSkew
    ) -> Bool {
        macID == expectedMacID
            && RemoteCrypto.constantTimeEquals(nonce, expectedNonce)
            && isFresh(now: now, maximumAge: maximumAge, maximumFutureSkew: maximumFutureSkew)
            && isValidSignature(pairingKey: pairingKey)
    }

    private static func signature(
        macID: UUID,
        nonce: Data,
        rssi: Int,
        sampledAtMilliseconds: UInt64,
        pairingKey: Data
    ) -> Data {
        var data = label
        data.append(version)
        data.append(nonce)
        data.append(withUnsafeBytes(of: macID.uuid) { Data($0) })
        data.append(UInt8(bitPattern: Int8(rssi)))
        var milliseconds = sampledAtMilliseconds.bigEndian
        withUnsafeBytes(of: &milliseconds) { data.append(contentsOf: $0) }
        return RemoteCrypto.hmacSHA256(key: pairingKey, data: data)
    }
}

/// Mac-local lifetime for one reverse-presence nonce. Phone wall-clock time is
/// authenticated diagnostic data, never the clock that expires this challenge.
/// This lifetime prevents nonce replay and limits callback delay; by itself it
/// cannot prevent a client holding the pairing key from fabricating an RSSI.
public struct RemoteBLEReversePresenceChallenge: Sendable {
    public let macID: UUID
    public let nonce: Data
    public let issuedAt: TimeInterval
    public let lifetime: TimeInterval
    public private(set) var consumed = false

    public init(macID: UUID, nonce: Data, issuedAt: TimeInterval, lifetime: TimeInterval = 15) {
        self.macID = macID
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.lifetime = lifetime
    }

    public func isPending(at uptime: TimeInterval) -> Bool {
        let elapsed = uptime - issuedAt
        return !consumed && elapsed.isFinite && elapsed >= 0 && elapsed <= lifetime
    }

    public mutating func consume(_ sample: RemoteBLEReversePresenceSample, pairingKey: Data, at uptime: TimeInterval) -> Bool {
        // Do not use `sample.isFresh` here: its phone wall-clock timestamp is
        // not a trustworthy measurement clock. The production trust boundary
        // is the Mac-local challenge expiry, nonce/Mac binding and HMAC.
        guard isPending(at: uptime), sample.macID == macID,
              RemoteCrypto.constantTimeEquals(sample.nonce, nonce),
              sample.isValidSignature(pairingKey: pairingKey) else { return false }
        consumed = true
        return true
    }
}
