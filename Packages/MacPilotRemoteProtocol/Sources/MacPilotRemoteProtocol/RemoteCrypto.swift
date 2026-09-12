import CryptoKit
import Foundation
import Security

/// A 32-byte symmetric key used to seal traffic for one connection.
public struct RemoteSessionKey: Sendable, Equatable {
    /// Not exposed as raw bytes on purpose: callers pass the value around but
    /// never log or persist it.
    private let key: SymmetricKey

    public init(rawBytes: Data) {
        self.key = SymmetricKey(data: rawBytes)
    }

    init(symmetricKey: SymmetricKey) {
        self.key = symmetricKey
    }

    var symmetricKey: SymmetricKey { key }
}

/// Replay protection for a single connection.
///
/// TCP keeps frames ordered, so requiring a strictly increasing sequence is
/// enough to reject a captured frame replayed by another device. Fresh
/// connections use a fresh session key and reset the counter.
public struct RemoteReplayGuard: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case replayedSequence
        case staleTimestamp
    }

    /// How far a request timestamp may deviate from the local clock.
    public var maximumClockSkew: TimeInterval
    private var highestSequence: UInt64 = 0

    public init(maximumClockSkew: TimeInterval = 300) {
        self.maximumClockSkew = maximumClockSkew
    }

    public var lastAcceptedSequence: UInt64 { highestSequence }

    /// Validates then records a sequence. Throws `Rejection` when the frame
    /// must be dropped.
    public mutating func accept(sequence: UInt64, timestampMilliseconds: Int64, now: Date = Date()) throws {
        guard sequence > highestSequence else { throw Rejection.replayedSequence }
        if timestampMilliseconds > 0 {
            let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1000)
            let skew = abs(Double(nowMilliseconds - timestampMilliseconds)) / 1000
            guard skew <= maximumClockSkew else { throw Rejection.staleTimestamp }
        }
        highestSequence = sequence
    }
}

/// CryptoKit helpers shared by both platforms.
public enum RemoteCrypto {
    public static let nonceLength = 32
    public static let pairingKeyLength = 32
    public static let pairCodeLength = 6

    private static let sessionInfo = Data("MacPilotRemote-v1-session".utf8)
    private static let pairingInfo = Data("MacPilotRemote-v1-pairing".utf8)
    private static let pairCodeInfo = Data("MacPilotRemote-v1-paircode".utf8)
    private static let serverProofInfo = Data("MacPilotRemote-v1-server-proof".utf8)
    private static let clientProofInfo = Data("MacPilotRemote-v1-client-proof".utf8)

    public static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    public static func bigEndianBytes(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    public static func sequence(fromBigEndian data: Data) -> UInt64 {
        data.withUnsafeBytes { raw -> UInt64 in
            var value: UInt64 = 0
            for byte in raw { value = (value << 8) | UInt64(byte) }
            return value
        }
    }

    // MARK: - Key derivation

    /// Salt binds both nonces so a replayed handshake cannot reuse a key.
    public static func handshakeSalt(clientNonce: Data, serverNonce: Data) -> Data {
        var salt = Data()
        salt.append(clientNonce)
        salt.append(serverNonce)
        return salt
    }

    public static func sessionKey(pairingKey: Data, clientNonce: Data, serverNonce: Data) -> RemoteSessionKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingKey),
            salt: handshakeSalt(clientNonce: clientNonce, serverNonce: serverNonce),
            info: sessionInfo,
            outputByteCount: 32
        )
        return RemoteSessionKey(symmetricKey: derived)
    }

    /// Long term pairing key. Deliberately distinct from the 6 digit code.
    public static func pairingKey(sharedSecret: SharedSecret, clientNonce: Data, serverNonce: Data) -> Data {
        let derived = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: handshakeSalt(clientNonce: clientNonce, serverNonce: serverNonce),
            sharedInfo: pairingInfo,
            outputByteCount: pairingKeyLength
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// Six digit confirmation code derived from the ECDH secret. A man in the
    /// middle produces different codes on each side, so the user catches it.
    public static func pairCode(sharedSecret: SharedSecret, clientNonce: Data, serverNonce: Data) -> String {
        let derived = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: handshakeSalt(clientNonce: clientNonce, serverNonce: serverNonce),
            sharedInfo: pairCodeInfo,
            outputByteCount: 8
        )
        let bytes = derived.withUnsafeBytes { Data($0) }
        var value: UInt64 = 0
        for byte in bytes.prefix(4) { value = (value << 8) | UInt64(byte) }
        let code = value % 1_000_000
        return String(format: "%06llu", code)
    }

    public static func clientProof(pairingKey: Data, clientNonce: Data, serverNonce: Data) -> Data {
        proof(pairingKey: pairingKey, info: clientProofInfo, clientNonce: clientNonce, serverNonce: serverNonce)
    }

    public static func serverProof(pairingKey: Data, clientNonce: Data, serverNonce: Data) -> Data {
        proof(pairingKey: pairingKey, info: serverProofInfo, clientNonce: clientNonce, serverNonce: serverNonce)
    }

    private static func proof(pairingKey: Data, info: Data, clientNonce: Data, serverNonce: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingKey),
            salt: handshakeSalt(clientNonce: clientNonce, serverNonce: serverNonce),
            info: info,
            outputByteCount: 32
        )
        // A constant-time comparison on the receiving side is provided by
        // `constantTimeEquals`.
        return key.withUnsafeBytes { Data($0) }
    }

    /// Length independent, constant time comparison. `Data ==` short-circuits
    /// on the first differing byte.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    // MARK: - Sealing

    /// Nonce layout keeps the counter unique per key: 4 zero bytes followed by
    /// the big-endian sequence.
    public static func nonce(sequence: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(bigEndianBytes(sequence))
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    public static func seal(_ plaintext: Data, key: RemoteSessionKey, sequence: UInt64) throws -> Data {
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key.symmetricKey, nonce: nonce(sequence: sequence))
            return box.combined
        } catch {
            throw RemoteProtocolError.internalError
        }
    }

    public static func open(_ box: Data, key: RemoteSessionKey, sequence: UInt64) throws -> Data {
        do {
            let sealed = try ChaChaPoly.SealedBox(combined: box)
            return try ChaChaPoly.open(sealed, using: key.symmetricKey)
        } catch {
            throw RemoteProtocolError.decryptionFailed
        }
    }
}
