import CryptoKit
import Foundation

/// A P-256 key agreement exchange that culminates in a shared pairing key.
///
/// Both peers derive the same six digit confirmation code from the ECDH
/// secret. The code only proves there is no man in the middle; the long term
/// key is derived separately and never equals the code.
public struct RemotePairingExchange: Sendable {
    public let privateKey: P256.KeyAgreement.PrivateKey
    public let clientNonce: Data
    public let serverNonce: Data

    public init(clientNonce: Data, serverNonce: Data) {
        self.privateKey = P256.KeyAgreement.PrivateKey()
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
    }

    public var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    /// Derives the shared secret against the peer's raw public key.
    public func sharedSecret(withPeerPublicKey data: Data) throws -> SharedSecret {
        let publicKey: P256.KeyAgreement.PublicKey
        do {
            publicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: data)
        } catch {
            throw RemoteProtocolError.invalidMessage
        }
        do {
            return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch {
            throw RemoteProtocolError.authenticationFailed
        }
    }

    public func pairCode(withPeerPublicKey data: Data) throws -> String {
        let secret = try sharedSecret(withPeerPublicKey: data)
        return RemoteCrypto.pairCode(
            sharedSecret: secret,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
    }

    public func pairingKey(withPeerPublicKey data: Data) throws -> Data {
        let secret = try sharedSecret(withPeerPublicKey: data)
        return RemoteCrypto.pairingKey(
            sharedSecret: secret,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
    }
}

/// Validation helpers for the user-entered confirmation code.
public enum RemotePairingCode {
    public static func normalize(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    public static func isValid(_ raw: String) -> Bool {
        normalize(raw).count == RemoteCrypto.pairCodeLength
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard left.count == right.count else { return false }
        return RemoteCrypto.constantTimeEquals(Data(left.utf8), Data(right.utf8))
    }
}
