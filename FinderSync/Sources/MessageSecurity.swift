import CryptoKit
import Foundation
import OSLog
import Security

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.macpilot.rightclick",
    category: "MessageSecurity"
)

/// Authenticated wire payload shared by the main app and FinderSync.
public struct SignedPayload: Codable, Equatable {
    public let messageID: UUID
    public let action: String
    public let issuedAtMilliseconds: Int64
    public let signature: String
    public let jsonData: String

    init(
        messageID: UUID,
        action: String,
        issuedAtMilliseconds: Int64,
        signature: String,
        payloadData: Data
    ) {
        self.messageID = messageID
        self.action = action
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.signature = signature
        jsonData = payloadData.base64EncodedString()
    }
}

public enum MessageSecurity {
    static let maximumMessageAgeMilliseconds: Int64 = 5 * 60 * 1_000

    public static func sign<T: Codable>(
        _ payload: T?,
        messageID: UUID,
        action: String,
        issuedAt: Date = .now
    ) throws -> SignedPayload {
        let payloadData = try payload.map { try JSONEncoder().encode($0) } ?? Data("null".utf8)
        return sign(
            payloadData: payloadData,
            messageID: messageID,
            action: action,
            issuedAtMilliseconds: Int64(issuedAt.timeIntervalSince1970 * 1_000)
        )
    }

    static func sign(
        payloadData: Data,
        messageID: UUID,
        action: String,
        issuedAtMilliseconds: Int64
    ) -> SignedPayload {
        let authenticated = authenticatedData(
            payloadData: payloadData,
            messageID: messageID,
            action: action,
            issuedAtMilliseconds: issuedAtMilliseconds
        )
        let key = SymmetricKey(data: MessageSecretStore.key())
        let hmac = HMAC<SHA256>.authenticationCode(for: authenticated, using: key)
        return SignedPayload(
            messageID: messageID,
            action: action,
            issuedAtMilliseconds: issuedAtMilliseconds,
            signature: Data(hmac).base64EncodedString(),
            payloadData: payloadData
        )
    }

    /// Returns the only payload bytes callers may decode.
    public static func verifiedPayload(
        _ signed: SignedPayload,
        expectedMessageID: UUID,
        expectedAction: String,
        now: Date = .now
    ) -> Data? {
        guard signed.messageID == expectedMessageID,
              signed.action == expectedAction,
              let signatureData = Data(base64Encoded: signed.signature),
              let payloadData = Data(base64Encoded: signed.jsonData) else {
            logger.error("Signed message context or encoding is invalid")
            return nil
        }

        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let age = nowMilliseconds - signed.issuedAtMilliseconds
        guard age >= -30_000, age <= maximumMessageAgeMilliseconds else {
            logger.warning("Rejected stale or future-dated signed message")
            return nil
        }

        let authenticated = authenticatedData(
            payloadData: payloadData,
            messageID: signed.messageID,
            action: signed.action,
            issuedAtMilliseconds: signed.issuedAtMilliseconds
        )
        let key = SymmetricKey(data: MessageSecretStore.key())
        let expectedHMAC = HMAC<SHA256>.authenticationCode(for: authenticated, using: key)
        guard signatureData.elementsEqual(Data(expectedHMAC)) else {
            logger.warning("Message signature verification failed")
            return nil
        }
        return payloadData
    }

    private static func authenticatedData(
        payloadData: Data,
        messageID: UUID,
        action: String,
        issuedAtMilliseconds: Int64
    ) -> Data {
        var data = Data(messageID.uuidString.lowercased().utf8)
        data.append(0)
        data.append(contentsOf: action.utf8)
        data.append(0)
        data.append(contentsOf: String(issuedAtMilliseconds).utf8)
        data.append(0)
        data.append(payloadData)
        return data
    }
}

/// A random per-install key in the private App Group replaces the extractable
/// source-code constant. The fixed fallback is used only by unentitled test or
/// development hosts that cannot resolve the production App Group container.
private enum MessageSecretStore {
    private static let keySize = 32
    private static let fallbackKey = Data("MacPilot_RightClick_IPC_TestFallback_v3".utf8)
    private static let fileName = ".ipc-authentication-key-v3"
    private static let resolvedKey = loadOrCreate()

    static func key() -> Data { resolvedKey }

    private static func loadOrCreate() -> Data {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RightClickConstants.appGroupIdentifier
        ) else {
            return fallbackKey
        }
        let url = container.appendingPathComponent(fileName)
        if let existing = try? Data(contentsOf: url), existing.count == keySize {
            return existing
        }

        var generated = Data(count: keySize)
        let status = generated.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, keySize, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { return fallbackKey }

        do {
            try generated.write(to: url, options: .withoutOverwriting)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return generated
        } catch {
            guard let winner = try? Data(contentsOf: url), winner.count == keySize else {
                return fallbackKey
            }
            return winner
        }
    }
}

/// Bounded replay cache. IDs are recorded only after signature verification.
final class MessageReplayGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted: [UUID: Int64] = [:]
    private let retentionMilliseconds: Int64

    init(retentionMilliseconds: Int64 = MessageSecurity.maximumMessageAgeMilliseconds) {
        self.retentionMilliseconds = retentionMilliseconds
    }

    func accept(_ id: UUID, issuedAtMilliseconds: Int64, now: Date = .now) -> Bool {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        lock.lock()
        defer { lock.unlock() }
        accepted = accepted.filter { nowMilliseconds - $0.value <= retentionMilliseconds }
        guard accepted[id] == nil else { return false }
        accepted[id] = issuedAtMilliseconds
        return true
    }
}
