import SwiftUI

/// This iPhone's identity, permission status and pairing reset.
struct RemoteSettingsView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(appModel.text("clientName"), text: Binding(
                        get: { appModel.store.clientName },
                        set: { appModel.store.clientName = $0 }
                    ))
                } header: {
                    Text(appModel.text("clientName"))
                } footer: {
                    Text(appModel.text("clientNameHint"))
                }

                Section(appModel.text("permissions")) {
                    HStack {
                        Text(appModel.text("localNetwork"))
                        Spacer()
                        Text(appModel.discovery.isPermissionDenied
                             ? appModel.text("offline")
                             : appModel.text("granted"))
                            .foregroundStyle(appModel.discovery.isPermissionDenied ? .orange : .secondary)
                    }
                }

                Section(appModel.text("settingsTitle")) {
                    HStack {
                        Text(appModel.text("clientID"))
                        Spacer()
                        Text(shortClientID)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button(appModel.text("resetPairings"), role: .destructive) {
                        showResetConfirmation = true
                    }
                    .disabled(appModel.pairedMacs.isEmpty)
                }

                Section(appModel.text("transportSection")) {
                    HStack {
                        Text(appModel.text("transportCurrent"))
                        Spacer()
                        Text(appModel.transportDescription)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(appModel.text("transportBLE"))
                        Spacer()
                        Text(bleStatus)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if appModel.metrics != RemoteMetrics() {
                    Section(appModel.text("performance")) {
                        metricRow("metricDiscovery", appModel.metrics.discoveryLatencyMs)
                        metricRow("metricConnect", appModel.metrics.connectLatencyMs)
                        metricRow("metricHandshake", appModel.metrics.handshakeLatencyMs)
                        metricRow("metricRTT", appModel.metrics.commandRTTMs)
                        metricRow("metricExecution", appModel.metrics.executionLatencyMs)
                    }
                }

                Section(appModel.text("about")) {
                    Text(appModel.text("aboutBody"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(appModel.text("settingsTitle"))
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog(
                appModel.text("resetPairings"),
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button(appModel.text("resetPairings"), role: .destructive) {
                    appModel.removeAllPairings()
                }
                Button(appModel.text("pairingCancel"), role: .cancel) {}
            } message: {
                Text(appModel.text("resetPairingsConfirm"))
            }
        }
    }

    /// Bluetooth is only interesting when it is doing something; otherwise the
    /// row would read the same on every launch.
    private var bleStatus: String {
        if appModel.bleFallbackScanning { return appModel.text("transportBLEScanning") }
        if let message = appModel.lastBLEMessage { return message }
        return appModel.text("transportBLEOff")
    }

    @ViewBuilder
    private func metricRow(_ key: String, _ value: Int?) -> some View {
        if let value {
            HStack {
                Text(appModel.text(key))
                Spacer()
                Text("\(value) ms")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortClientID: String {
        String(appModel.store.clientID.prefix(8))
    }
}
