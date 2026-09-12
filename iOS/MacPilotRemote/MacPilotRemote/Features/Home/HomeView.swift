import MacPilotRemoteProtocol
import SwiftUI

/// The four remote actions. No confirmation dialogs: an authenticated, encrypted
/// connection is already in place.
struct HomeView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Binding var selectedTab: RootTab

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusHeader
                    actionGrid
                    levelsPanel
                    messageBanner
                    if !appModel.connectionState.isConnected {
                        disconnectedPanel
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(appModel.activeMacName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(appModel.text(appModel.connectionState.titleKey))
                .font(.subheadline.weight(.medium))
            if let latency = appModel.latencyMs, appModel.connectionState.isConnected {
                Text(appModel.text("latency", latency))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var statusColor: Color {
        switch appModel.connectionState {
        case .connected: return .green
        case .connecting, .authenticating, .pairing, .discovering, .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    // MARK: - Actions

    /// The four remote actions, paired by intent: the first row takes the Mac
    /// away (lock, black), the second brings it back (light the screen, wake and
    /// unlock).
    ///
    /// There is deliberately no plain "unlock" button: the Mac's unlock path
    /// wakes the display itself when it is off, so a separate action was the same
    /// thing with a second way to get it wrong.
    private var actionGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            actionButton(.lockScreen, titleKey: "actionLock", systemImage: "lock.fill", tint: .blue)
            actionButton(.displayOff, titleKey: "actionDisplayOff", systemImage: "moon.fill", tint: .indigo)
            actionButton(.wakeDisplay, titleKey: "actionWakeDisplay", systemImage: "sun.max.fill", tint: .yellow)
            actionButton(.wakeAndUnlock, titleKey: "actionWakeAndUnlock", systemImage: "sunrise.fill", tint: .orange)
        }
    }

    private func actionButton(
        _ command: RemoteCommand,
        titleKey: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        let isRunning = appModel.runningCommand == command
        let enabled = appModel.connectionState.isConnected && appModel.runningCommand == nil
        return Button {
            appModel.beginCommand(command)
            Task { await appModel.perform(command) }
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 30, weight: .semibold))
                    }
                }
                .frame(height: 34)
                Text(appModel.text(titleKey))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(enabled ? 0.28 : 0.10))
            )
            .foregroundStyle(enabled ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(appModel.text(titleKey))
    }

    // MARK: - Output levels

    /// Brightness and volume, read from the same `MacRemoteState` the rest of
    /// the screen uses.
    ///
    /// A level the Mac did not report is not shown at all: an external monitor
    /// with no controllable backlight, or a Mac with no output device, both mean
    /// a slider that cannot work. The card says so instead of offering one.
    private var levelsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appModel.text("levelsTitle"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if !appModel.connectionState.isConnected {
                hint(appModel.text("levelsNotConnected"))
            } else if appModel.macState == nil {
                // The state rides along with the first response after the
                // handshake; nothing useful to say for that one round trip.
                hint(appModel.text("levelsUnavailableShort"))
            } else if appModel.hasLevelControls {
                ForEach(RemoteLevelKind.allCases, id: \.self) { kind in
                    if let value = kind.value(in: appModel.macState) {
                        LevelSliderRow(kind: kind, value: value)
                    }
                }
            } else {
                hint(appModel.text("levelsUnavailable"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Messages

    @ViewBuilder
    private var messageBanner: some View {
        if let errorKey = appModel.errorKey {
            banner(text: appModel.text(errorKey), systemImage: "exclamationmark.triangle.fill", tint: .orange)
        } else if let infoKey = appModel.infoKey {
            banner(text: appModel.text(infoKey), systemImage: "checkmark.circle.fill", tint: .green)
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
            Button {
                appModel.clearMessages()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    // MARK: - Disconnected

    /// The Mac Bonjour can see but that has not been paired yet.
    private var unpairedMac: DiscoveredMac? {
        appModel.discoveredMacs.first { !appModel.store.isPaired(id: $0.id) }
    }

    /// Explains why no Mac is reachable. Order matters: a discovered-but-unpaired
    /// Mac is the common case and must not be reported as "not found", which
    /// made a working browse look like a broken network.
    private var disconnectedTitle: String {
        if unpairedMac != nil { return appModel.text("foundUnpaired") }
        return appModel.text("noMac")
    }

    private var disconnectedDetail: String {
        if appModel.localNetworkDenied {
            return appModel.text("localNetworkHint")
        }
        if let mac = unpairedMac {
            return appModel.text("foundUnpairedDetail", mac.name)
        }
        if appModel.unrecognizedServiceCount > 0 {
            return appModel.text("unrecognizedServiceHint")
        }
        return appModel.text("noMacDetail")
    }

    private var disconnectedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(disconnectedTitle).font(.headline)
            Text(disconnectedDetail).font(.subheadline).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if unpairedMac != nil {
                    Button(appModel.text("goToPairing")) { selectedTab = .devices }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(appModel.text("retry")) { appModel.retry() }
                        .buttonStyle(.borderedProminent)
                }
                if appModel.localNetworkDenied {
                    Button(appModel.text("openSystemSettings")) { openSystemSettings() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

extension RemoteAppModel {
    /// Title shown on the home screen.
    var activeMacName: String {
        activeMacName(store.preferredMac)
    }

    private func activeMacName(_ mac: PairedMac?) -> String {
        mac?.name ?? "MacPilot"
    }

    /// `nil` when this Mac has no mute control at all, as opposed to a device
    /// that is simply not muted.
    var volumeMuted: Bool? { macState?.volumeMuted?.boolValue }
}

/// One brightness or volume row.
///
/// The slider keeps its own draft while the finger is down: the Mac's answer
/// arrives a round trip later, and letting that value write back mid-drag would
/// fight the user. Every change is handed to the model, which coalesces the
/// drag into a single in-flight request ending on the value the user let go of.
private struct LevelSliderRow: View {
    @EnvironmentObject private var appModel: RemoteAppModel

    let kind: RemoteLevelKind
    /// The value the Mac last reported, used whenever the finger is up.
    let value: Double

    @State private var draft: Double = 0
    @State private var isEditing = false

    private var isMuted: Bool {
        kind == .volume && appModel.volumeMuted == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "speaker.slash.fill" : kind.iconName)
                    .font(.subheadline)
                    .frame(width: 20)
                    .foregroundStyle(isMuted ? Color.orange : Color.accentColor)
                Text(appModel.text(kind.labelKey))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("\(Int((draft * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if kind == .volume, appModel.volumeMuted != nil {
                    muteButton
                }
            }

            Slider(value: $draft, in: 0...1, step: 0.01) { editing in
                isEditing = editing
                // The release is sent explicitly so a drag that ends between two
                // coalesced requests still lands on its final value.
                if !editing { send(draft) }
            }
            .accessibilityLabel(appModel.text(kind.labelKey))
            .accessibilityValue("\(Int((draft * 100).rounded()))%")
        }
        .onAppear { draft = value }
        .onChange(of: draft) { _, newValue in
            guard isEditing else { return }
            send(newValue)
        }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            draft = newValue
        }
    }

    private var muteButton: some View {
        Button {
            appModel.setLevel(kind, value: draft, muted: !isMuted)
            Haptics.impact()
        } label: {
            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.subheadline)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appModel.text(isMuted ? "unmute" : "mute"))
    }

    /// Raising the volume clears mute, exactly like the Mac's own volume keys;
    /// dragging to silence leaves the mute state alone.
    private func send(_ newValue: Double) {
        let muted: Bool? = kind == .volume && newValue > 0 ? false : nil
        appModel.setLevel(kind, value: newValue, muted: muted)
    }
}
