import SwiftUI

/// MacPilot settings page for the iPhone local-network remote control.
///
/// Follows `docs/UI_DESIGN.md`: 30pt header, `SettingsCard` groups, 36/34/30
/// page padding, 24pt card spacing, `macPilotProminentButtonStyle()` for the
/// primary action.
struct RemoteControlSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var server: RemoteControlServer
    @ObservedObject var deviceStore: RemoteDeviceStore

    @State private var deviceNameDraft = ""
    @State private var nameMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                enableCard
                if deviceStore.settings.isEnabled {
                    pairingCard
                    devicesCard
                    statusCard
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { deviceNameDraft = deviceStore.deviceName }
        .alert("MacPilot", isPresented: Binding(get: { nameMessage != nil }, set: { if !$0 { nameMessage = nil } })) {
            Button("OK", role: .cancel) { nameMessage = nil }
        } message: {
            Text(nameMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("remoteControl")).font(.system(size: 30, weight: .bold))
            Text(t("remoteControlSubtitle")).foregroundStyle(.secondary)
        }
    }

    // MARK: - Enable

    private var enableCard: some View {
        SettingsCard {
            Text(t("remoteEnableSection")).font(.headline)
            Toggle(t("remoteEnableToggle"), isOn: Binding(
                get: { deviceStore.settings.isEnabled },
                set: { setEnabled($0) }
            ))
            .toggleStyle(.switch)
            Text(t("remoteEnableHint")).font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(t("remoteDeviceName")).frame(width: 120, alignment: .leading)
                TextField("", text: $deviceNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { applyDeviceName() }
                Button(t("remoteApplyName")) { applyDeviceName() }
                    .disabled(deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == deviceStore.deviceName)
            }
            Text(t("remoteDeviceNameHint")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Pairing

    private var pairingCard: some View {
        SettingsCard {
            Text(t("remotePairingSection")).font(.headline)

            if let code = server.pairingManager.displayedCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("remotePairingCodeFor", server.pairingManager.displayedClientName ?? "iPhone"))
                        .font(.subheadline)
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(t("remotePairingCodeHint")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                )
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        if server.pairingManager.isWindowOpen {
                            Text(t("remotePairingWaiting"))
                                .foregroundStyle(.secondary)
                            if let expiry = server.pairingManager.pairingWindowExpiresAt {
                                Text(t("remotePairingWindowOpen", max(0, Int(expiry.timeIntervalSinceNow))))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button(t("remotePairingCancel")) { server.pairingManager.closeWindow() }
                                .buttonStyle(.bordered)
                        } else {
                            Button(t("remoteStartPairing")) { server.pairingManager.openWindow() }
                                .macPilotProminentButtonStyle()
                            Text(t("remotePairingOpenHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Paired devices

    private var devicesCard: some View {
        SettingsCard {
            Text(t("remotePairedDevices")).font(.headline)
            if deviceStore.pairedDevices.isEmpty {
                Text(t("remoteNoPairedDevices")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(deviceStore.pairedDevices) { device in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName).font(.body)
                            Text(lastConnectedLabel(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(t("remove")) { deviceStore.removeDevice(clientID: device.id) }
                            .buttonStyle(.bordered)
                    }
                    if device.id != deviceStore.pairedDevices.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        SettingsCard {
            Text(t("remotePermissions")).font(.headline)
            statusRow(t("remoteStatus"), value: statusText, tint: statusTint)
            statusRow(
                t("remoteAccessibility"),
                value: server.screenControl.accessibilityGranted ? t("remoteGranted") : t("remoteNotGranted"),
                tint: server.screenControl.accessibilityGranted ? .green : .orange
            )
            statusRow(
                t("remoteCredential"),
                value: server.screenControl.hasCredential ? t("remoteConfigured") : t("remoteNotConfigured"),
                tint: server.screenControl.hasCredential ? .green : .orange
            )
            statusRow(
                t("remoteLocalNetwork"),
                value: server.status.isRunning ? t("remoteAvailable") : t("remoteUnavailable"),
                tint: server.status.isRunning ? .green : .secondary
            )
            statusRow(
                t("remoteScreenState"),
                value: screenStateText,
                tint: .secondary
            )
        }
    }

    private func statusRow(_ title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 120, alignment: .leading)
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(value).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func setEnabled(_ enabled: Bool) {
        deviceStore.setEnabled(enabled)
        if enabled {
            deviceNameDraft = deviceStore.deviceName
            server.start()
        } else {
            server.stop()
        }
    }

    private func applyDeviceName() {
        deviceStore.setDeviceName(deviceNameDraft)
        deviceNameDraft = deviceStore.deviceName
        if server.isRunning { server.restart() }
    }

    private var statusText: String {
        switch server.status {
        case .stopped: return t("remoteStatusStopped")
        case .starting: return t("remoteStatusStarting")
        case .running(let port): return t("remoteStatusRunning", Int(port))
        case .failed(let message): return t("remoteStatusFailed", message)
        }
    }

    private var statusTint: Color {
        switch server.status {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var screenStateText: String {
        switch ScreenLockStateReader.current() {
        case .locked: return t("remoteScreenLocked")
        case .unlocked: return t("remoteScreenUnlocked")
        case .unknown: return t("remoteScreenUnknown")
        }
    }

    private func lastConnectedLabel(_ device: RemotePairedDevice) -> String {
        guard let date = device.lastConnectedAt else { return t("remoteNeverConnected") }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return t("remoteJustNow") }
        if interval < 3600 { return t("remoteMinutesAgo", Int(interval / 60)) }
        if interval < 86_400 { return t("remoteHoursAgo", Int(interval / 3600)) }
        return t("remoteDaysAgo", Int(interval / 86_400))
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: model.language, arguments: arguments)
    }
}
