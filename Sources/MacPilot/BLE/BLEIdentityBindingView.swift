import SwiftUI

/// The user, not the scanner's display name, establishes which remote
/// identity owns the selected BLE device.
struct BLEIdentityBindingView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var ble: BLEUnlockModel
    @ObservedObject var deviceStore: RemoteDeviceStore
    let primaryUUID: String

    private var identityBinding: BLEIdentityBinding? {
        ble.settings.identityRegistry.bindings.first { $0.primaryUUID == primaryUUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(model.t("bleRemoteIdentity"), selection: Binding(
                get: { identityBinding?.clientID ?? "" },
                set: { clientID in
                    guard let uuid = UUID(uuidString: primaryUUID) else { return }
                    let fingerprint = deviceStore.pairedIdentityFingerprints[clientID]
                    ble.bindRemoteIdentity(primaryUUID: uuid, clientID: clientID.isEmpty ? nil : clientID,
                                           keyFingerprint: fingerprint)
                }
            )) {
                Text(model.t("bleRemoteIdentityNone")).tag("")
                ForEach(deviceStore.pairedDevices, id: \.id) { device in
                    Text("\(device.name) · \(device.id.prefix(8))").tag(device.id)
                        .disabled(deviceStore.pairedIdentityFingerprints[device.id] == nil)
                }
            }
            Text(model.t("bleRemoteIdentityHint")).font(.caption).foregroundStyle(.secondary)
            if let identityBinding {
                Text(model.t("bleIdentityAliasCount", identityBinding.aliases.count))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(identityBinding.aliases, id: \.uuid) { alias in
                    HStack {
                        Text(alias.uuid).font(.caption.monospaced())
                        Spacer()
                        Text(alias.lastSeenAt, style: .date).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if !identityBinding.aliases.isEmpty {
                    Button(model.t("bleIdentityClearAliases"), role: .destructive) {
                        guard let uuid = UUID(uuidString: primaryUUID) else { return }
                        ble.bindRemoteIdentity(primaryUUID: uuid, clientID: identityBinding.clientID,
                                               keyFingerprint: identityBinding.keyFingerprint)
                    }
                }
            }
        }
    }
}
