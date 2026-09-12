import Foundation
import MacPilotRemoteProtocol

/// Owns the persistent MacPilot remote identity, the paired device list and the
/// Keychain stored long term pairing keys.
///
/// Only device *metadata* is persisted to `config.json`; every secret lives in
/// the Keychain and is removed the moment the user removes a device.
@MainActor
final class RemoteDeviceStore: ObservableObject {
    @Published private(set) var settings: RemoteControlSettings

    private let keychainService: String
    private let secretStore: SecretStore
    private let persistHandler: () -> Void
    private let logHandler: (String) -> Void

    init(
        settings: RemoteControlSettings = RemoteControlSettings(),
        keychainService: String? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        persist: @escaping () -> Void = {},
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.settings = settings
        self.keychainService = keychainService
            ?? "\((Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)).remote"
        self.secretStore = secretStore
        self.persistHandler = persist
        self.logHandler = log
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    // MARK: - Settings

    func applyLoadedSettings(_ loaded: RemoteControlSettings) {
        settings = loaded
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled { _ = ensureDeviceIdentity() }
        persistHandler()
    }

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.deviceName != trimmed else { return }
        settings.deviceName = trimmed
        persistHandler()
    }

    /// Permanent device UUID, generated on first use and then kept forever.
    @discardableResult
    func ensureDeviceIdentity() -> UUID {
        if let raw = settings.deviceID, let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let uuid = UUID()
        settings.deviceID = uuid.uuidString
        log("device identity created id=\(uuid.uuidString)")
        persistHandler()
        return uuid
    }

    var deviceID: UUID { ensureDeviceIdentity() }

    var deviceName: String {
        get { settings.resolvedDeviceName }
        set { setDeviceName(newValue) }
    }

    var pairedDevices: [RemotePairedDevice] {
        settings.pairedDevices.sorted { lhs, rhs in
            (lhs.lastConnectedAt ?? lhs.createdAt) > (rhs.lastConnectedAt ?? rhs.createdAt)
        }
    }

    // MARK: - Paired devices

    func registerPairedDevice(clientID: String, name: String, address: String?) {
        if let index = settings.pairedDevices.firstIndex(where: { $0.id == clientID }) {
            settings.pairedDevices[index].name = name
            settings.pairedDevices[index].lastConnectedAt = Date()
            settings.pairedDevices[index].lastAddress = address
        } else {
            settings.pairedDevices.append(
                RemotePairedDevice(
                    id: clientID,
                    name: name,
                    createdAt: Date(),
                    lastConnectedAt: Date(),
                    lastAddress: address
                )
            )
            log("paired device registered")
        }
        persistHandler()
    }

    func markConnected(clientID: String, address: String?) {
        guard let index = settings.pairedDevices.firstIndex(where: { $0.id == clientID }) else { return }
        settings.pairedDevices[index].lastConnectedAt = Date()
        settings.pairedDevices[index].lastAddress = address
        persistHandler()
    }

    /// Removes the device and immediately deletes its Keychain pairing key, so
    /// the old iPhone can never connect again.
    func removeDevice(clientID: String) {
        settings.pairedDevices.removeAll { $0.id == clientID }
        deletePairingKey(for: clientID)
        log("paired device removed; keychain key deleted")
        persistHandler()
    }

    func removeAllDevices() {
        for device in settings.pairedDevices {
            deletePairingKey(for: device.id)
        }
        settings.pairedDevices.removeAll()
        persistHandler()
    }

    func isPaired(clientID: String) -> Bool {
        pairingKey(for: clientID) != nil
    }

    // MARK: - Pairing keys (Keychain)

    func pairingKey(for clientID: String) -> Data? {
        secretStore.read(service: keychainService, account: Self.account(clientID))
    }

    @discardableResult
    func storePairingKey(_ key: Data, for clientID: String) -> Bool {
        let success = secretStore.write(
            key,
            service: keychainService,
            account: Self.account(clientID),
            label: "MacPilot Remote Pairing"
        )
        log("pairing key stored success=\(success)")
        return success
    }

    private func deletePairingKey(for clientID: String) {
        secretStore.delete(service: keychainService, account: Self.account(clientID))
    }

    private static func account(_ clientID: String) -> String {
        "pairing.\(clientID)"
    }
}
