import Foundation
import Security

/// Keychain access for the iPhone side.
///
/// The pairing keys are the only secrets stored here. The Mac login password is
/// never requested, received or stored by this app.
enum RemoteKeychain {
    private static let service = "com.misswell.macpilot.remote.ios"

    static func pairingKey(for deviceID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(deviceID),
            kSecAttrService as String: service,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    /// Whether a long-term pairing key is stored for this Mac, without reading
    /// the secret itself. This is the real proof of pairing; `PairedMacStore`
    /// only caches display metadata and can be empty while the key survives.
    static func hasPairingKey(for deviceID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(deviceID),
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func storePairingKey(_ key: Data, for deviceID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(deviceID),
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = "MacPilot Remote Pairing"
        // This device only: pairing is per iPhone and never syncs.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deletePairingKey(for deviceID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(deviceID),
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func readString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func writeString(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func account(_ deviceID: String) -> String {
        "pairing.\(deviceID)"
    }
}
