import SwiftUI

/// Paired Macs plus whatever Bonjour currently sees on this network.
struct DevicesView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @State private var pendingRemoval: PairedMac?

    var body: some View {
        NavigationStack {
            List {
                pairedSection
                discoveredSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(appModel.text("devicesTitle"))
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog(
                appModel.text("forgetConfirmTitle"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(appModel.text("forget"), role: .destructive) {
                    if let mac = pendingRemoval { appModel.forget(mac) }
                    pendingRemoval = nil
                }
                Button(appModel.text("pairingCancel"), role: .cancel) { pendingRemoval = nil }
            } message: {
                Text(appModel.text("forgetConfirmMessage"))
            }
        }
    }

    private var pairedSection: some View {
        Section {
            if appModel.pairedMacs.isEmpty {
                Text(appModel.text("noPaired"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.pairedMacs) { mac in
                    pairedRow(mac)
                }
            }
        } header: {
            Text(appModel.text("pairedSection"))
        } footer: {
            Text(appModel.text("devicesSubtitle"))
        }
    }

    private func pairedRow(_ mac: PairedMac) -> some View {
        let presence = appModel.status(for: mac)
        return HStack(spacing: 12) {
            Circle()
                .fill(color(for: presence))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mac.name).font(.body)
                    if appModel.isDefault(mac) {
                        Text(appModel.text("defaultMac"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(label(for: presence))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if presence != .connected {
                Button(appModel.text("setDefault")) { appModel.connect(to: mac) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .swipeActions {
            Button(appModel.text("forget"), role: .destructive) { pendingRemoval = mac }
        }
    }

    private var discoveredSection: some View {
        Section(appModel.text("discoveredSection")) {
            let unpaired = appModel.discoveredMacs.filter { !appModel.store.isPaired(id: $0.id) }
            if unpaired.isEmpty {
                Text(appModel.text("noMac"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(unpaired) { mac in
                    HStack(spacing: 12) {
                        Circle().fill(.blue).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mac.name).font(.body)
                            Text(mac.version.isEmpty ? appModel.text("online") : "v\(mac.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(appModel.text("pairingConfirm")) { appModel.pair(with: mac) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func color(for presence: RemoteAppModel.MacPresence) -> Color {
        switch presence {
        case .connected: return .green
        case .online: return .blue
        case .offline: return .secondary
        }
    }

    private func label(for presence: RemoteAppModel.MacPresence) -> String {
        switch presence {
        case .connected: return appModel.text("connectedLabel")
        case .online: return appModel.text("online")
        case .offline: return appModel.text("offline")
        }
    }
}
