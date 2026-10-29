import Foundation
import Security

/// Pairing secrets persist only in Keychain. Main-actor lookups use memory and
/// never issue a synchronous securityd request from a Bluetooth/UI callback.
@MainActor
enum RemoteKeychain {
    private static let store = RemotePairingKeyStore(
        load: { try PairingKeychainBackend.load() },
        save: { PairingKeychainBackend.save($1, for: $0) },
        remove: { PairingKeychainBackend.remove($0) }
    )

    static var isPrepared: Bool { store.isPrepared }
    static func prepare() async -> Bool { await store.prepare() }
    static func pairingKey(for deviceID: String) -> Data? { store.key(for: deviceID) }
    static func hasPairingKey(for deviceID: String) -> Bool { store.key(for: deviceID) != nil }

    @discardableResult
    static func storePairingKey(_ key: Data, for deviceID: String) async -> Bool {
        await store.save(key, for: deviceID)
    }

    @discardableResult
    static func deletePairingKey(for deviceID: String) -> Task<Bool, Never> { store.remove(deviceID) }
}

/// Accessed exclusively by RemotePairingKeyStore's serial worker.
private enum PairingKeychainBackend {
    private static let service = "com.misswell.macpilot.remote.ios"

    static func load() throws -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw KeychainReadFailure(status: status) }
        var keys: [String: Data] = [:]
        for record in item as? [[String: Any]] ?? [] {
            guard let account = record[kSecAttrAccount as String] as? String,
                  account.hasPrefix("pairing."),
                  let data = record[kSecValueData as String] as? Data else { continue }
            keys[String(account.dropFirst("pairing.".count))] = data
        }
        return keys
    }

    static func save(_ key: Data, for id: String) -> Bool {
        let query = query(for: id)
        // A failed update must not destroy an existing valid key.
        let changes = [kSecValueData as String: key]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = "PilotNest Pairing"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ id: String) -> Bool {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func query(for id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: "pairing.\(id)",
         kSecAttrService as String: service]
    }

    private struct KeychainReadFailure: Error { let status: OSStatus }
}
