import Foundation
import Security

/// Minimal abstraction over the macOS Keychain so credential handling can be
/// unit tested without touching the real Keychain (and its access prompts).
protocol SecretStore: Sendable {
    func read(service: String, account: String) -> Data?

    @discardableResult
    func write(_ data: Data, service: String, account: String, label: String) -> Bool

    func delete(service: String, account: String)
}

/// Production implementation backed by the login Keychain.
struct KeychainSecretStore: SecretStore {
    func read(service: String, account: String) -> Data? {
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
        return data
    }

    @discardableResult
    func write(_ data: Data, service: String, account: String, label: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        // Available after first unlock and never synced to iCloud.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory store used by tests.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    init() {}

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }

    func read(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(service: service, account: account)]
    }

    @discardableResult
    func write(_ data: Data, service: String, account: String, label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key(service: service, account: account)] = data
        return true
    }

    func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key(service: service, account: account))
    }
}
