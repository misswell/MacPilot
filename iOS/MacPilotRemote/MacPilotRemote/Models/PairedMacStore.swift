import Foundation
import MacPilotRemoteTransport
#if canImport(UIKit)
import UIKit
#endif

/// Persists the paired Mac list and the iPhone's own client identity.
///
/// Only non-secret metadata lives in `UserDefaults`; pairing keys stay in the
/// Keychain via `RemoteKeychain`.
@MainActor
final class PairedMacStore: ObservableObject {
    private static let pairedKey = "MacPilotRemote.pairedMacs"
    private static let clientIDKey = "MacPilotRemote.clientID"
    private static let clientNameKey = "MacPilotRemote.clientName"
    private static let preferredKey = "MacPilotRemote.preferredMacID"
    /// Per-Mac prefix, because two Macs see different iPads and remembering one
    /// Mac's target would preselect a device the other cannot reach.
    private static let sidecarTargetPrefix = "MacPilotRemote.lastSidecarDevice."

    @Published private(set) var pairedMacs: [PairedMac] = []
    @Published var preferredMacID: String? {
        didSet { defaults.set(preferredMacID, forKey: Self.preferredKey) }
    }
    @Published var clientName: String {
        didSet { defaults.set(clientName, forKey: Self.clientNameKey) }
    }

    @Published private(set) var connectionPriority: [RemoteConnectionMethod]

    func setConnectionPriority(_ order: [RemoteConnectionMethod]) {
        connectionPriority = RemoteConnectionPriority.normalized(order.map(\.rawValue))
        defaults.set(connectionPriority.map(\.rawValue), forKey: "MacPilotRemote.connectionPriority")
    }

    let clientID: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        connectionPriority = RemoteConnectionPriority.normalized(
            defaults.stringArray(forKey: "MacPilotRemote.connectionPriority") ?? []
        )
        // Stable per install; identifies this iPhone to every Mac it pairs with.
        if let existing = defaults.string(forKey: Self.clientIDKey) {
            clientID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.clientIDKey)
            clientID = generated
        }
        clientName = defaults.string(forKey: Self.clientNameKey)
            ?? Self.defaultDeviceName()
        preferredMacID = defaults.string(forKey: Self.preferredKey)
        if let data = defaults.data(forKey: Self.pairedKey),
           let decoded = try? JSONDecoder().decode([PairedMac].self, from: data) {
            pairedMacs = decoded
        }
    }

    private static func defaultDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }

    var preferredMac: PairedMac? {
        if let preferredMacID, let match = pairedMacs.first(where: { $0.id == preferredMacID }) {
            return match
        }
        return mostRecentlyUsed
    }

    var mostRecentlyUsed: PairedMac? {
        pairedMacs.max { lhs, rhs in
            (lhs.lastConnectedAt ?? .distantPast) < (rhs.lastConnectedAt ?? .distantPast)
        }
    }

    func mac(id: UUID) -> PairedMac? {
        pairedMacs.first { $0.id == id.uuidString }
    }

    func isPaired(id: UUID) -> Bool {
        pairedMacs.contains { $0.id == id.uuidString }
    }

    /// Adds the visible device entry for a Mac whose handshake succeeded.
    ///
    /// Pairing only writes the long-term key to the Keychain, so without this
    /// the Mac never leaves the "discovered" section and keeps offering a pair
    /// button it has already satisfied.
    @discardableResult
    func ensurePaired(id: UUID, name: String) -> PairedMac {
        if let existing = mac(id: id) { return existing }
        let mac = PairedMac(id: id.uuidString, name: name)
        upsert(mac)
        return mac
    }

    func upsert(_ mac: PairedMac) {
        if let index = pairedMacs.firstIndex(where: { $0.id == mac.id }) {
            pairedMacs[index] = mac
        } else {
            pairedMacs.append(mac)
        }
        persist()
    }

    /// Records whether the Mac relies on this phone for BLE proximity. Only
    /// writes when the answer changes: `upsert` persists the whole list.
    func setWantsBLEProximity(_ wants: Bool, id: UUID) {
        guard var mac = mac(id: id), mac.wantsBLEProximity != wants else { return }
        mac.wantsBLEProximity = wants
        upsert(mac)
    }

    func markConnected(id: UUID, endpoint: NWEndpointSnapshot, name: String) {
        guard var mac = mac(id: id) else { return }
        mac.name = name
        mac.lastServiceName = endpoint.serviceName ?? mac.lastServiceName
        if let host = endpoint.host { mac.lastHost = host }
        if let port = endpoint.port { mac.lastPort = port }
        mac.lastConnectedAt = Date()
        upsert(mac)
        if preferredMacID == nil { preferredMacID = mac.id }
    }

    /// The iPad this Mac was last asked to mirror, so the Sidecar sheet can
    /// offer it first after a restart.
    func lastSidecarDeviceID(macID: String) -> String? {
        defaults.string(forKey: Self.sidecarTargetPrefix + macID)
    }

    func setLastSidecarDeviceID(_ deviceID: String?, macID: String) {
        let key = Self.sidecarTargetPrefix + macID
        if let deviceID {
            defaults.set(deviceID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Remove metadata only once the background Keychain deletion is durable.
    func remove(id: UUID) async -> Bool {
        guard await RemoteKeychain.deletePairingKey(for: id.uuidString).value else { return false }
        pairedMacs.removeAll { $0.id == id.uuidString }
        setLastSidecarDeviceID(nil, macID: id.uuidString)
        if preferredMacID == id.uuidString { preferredMacID = nil }
        persist()
        return true
    }

    func removeAll() async -> Bool {
        var success = true
        for mac in pairedMacs {
            if let id = mac.deviceID, !(await remove(id: id)) { success = false }
        }
        return success
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pairedMacs) else { return }
        defaults.set(data, forKey: Self.pairedKey)
    }
}

/// Plain value description of an endpoint, since `NWEndpoint` is not Codable and
/// cannot be persisted directly.
struct NWEndpointSnapshot {
    var host: String?
    var port: UInt16?
    var serviceName: String?
}
