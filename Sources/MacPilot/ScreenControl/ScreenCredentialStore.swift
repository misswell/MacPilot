import Foundation

/// Keychain backed storage for the Mac login password used by both the BLE
/// proximity unlock and the iPhone remote unlock.
///
/// The password never leaves this Mac: the remote protocol only ever carries a
/// command name, and this store is only read locally right before the unlock
/// key events are posted.
@MainActor
final class ScreenCredentialStore {
    /// Human readable Keychain item label.
    static let itemLabel = "MacPilot Unlock Password"

    private let secretStore: SecretStore
    private var hasPasswordCache: Bool?
    private var logHandler: (String) -> Void

    init(
        secretStore: SecretStore = KeychainSecretStore(),
        log: @escaping (String) -> Void = { DiagnosticLog.write("ScreenControl", $0) }
    ) {
        self.secretStore = secretStore
        self.logHandler = log
    }

    func setLogHandler(_ handler: @escaping (String) -> Void) {
        logHandler = handler
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    private var keychainService: String {
        Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
    }

    private var keychainAccount: String { NSUserName() }

    /// Current service first, then the identifiers used by older releases so an
    /// existing install keeps working after the bundle id changed.
    private var keychainServices: [String] {
        var services = [keychainService]
        for service in AppIdentity.knownBundleIdentifiers where !services.contains(service) {
            services.append(service)
        }
        return services
    }

    var hasCredential: Bool {
        if let hasPasswordCache { return hasPasswordCache }
        return loadPassword() != nil
    }

    @discardableResult
    func storePassword(_ password: String) -> Bool {
        let data = password.data(using: .utf8) ?? Data()
        let success = secretStore.write(
            data,
            service: keychainService,
            account: keychainAccount,
            label: Self.itemLabel
        )
        log("password stored in keychain success=\(success)")
        hasPasswordCache = success
        return success
    }

    func removePassword() {
        for service in keychainServices {
            secretStore.delete(service: service, account: keychainAccount)
        }
        hasPasswordCache = false
        log("password removed from keychain")
    }

    func loadPassword(warn: Bool = false) -> String? {
        if warn {
            log("keychain password lookup started services=\(keychainServices.joined(separator: ","))")
        }
        for service in keychainServices {
            guard let data = secretStore.read(service: service, account: keychainAccount) else {
                continue
            }
            guard let password = String(data: data, encoding: .utf8) else { continue }
            if service != keychainService {
                _ = secretStore.write(
                    data,
                    service: keychainService,
                    account: keychainAccount,
                    label: Self.itemLabel
                )
            }
            hasPasswordCache = true
            if warn {
                log("keychain password lookup succeeded service=\(service)")
            }
            return password
        }
        hasPasswordCache = false
        if warn {
            log("keychain password lookup failed reason=notFoundOrInaccessible")
        }
        return nil
    }
}
