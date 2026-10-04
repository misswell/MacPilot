import MacPilotRemoteProtocol
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// User-selected controls, grouped by intent on the authenticated connection.
struct HomeView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Binding var selectedTab: RootTab

    /// Adaptive so the action grid fills an iPad's width instead of
    /// stretching two columns across it; on a phone it still lands on two.
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    @State private var trackpadModel: RemoteTrackpadModel?
    @State private var trackpadVisible = false
    @State private var desktopVisible = false
    /// Text key of why the trackpad entry refused a tap, shown as an alert.
    @State private var trackpadHintKey: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    deviceCard
                    inputTools
                    actionGrid
                    mediaPanel
                    if hasEnabledLevels { levelsPanel }
                    if !appModel.controlPreferences.hasHomeControls {
                        VStack(spacing: 12) {
                            hint(appModel.text("controlsEmpty"))
                            Button(appModel.text("controlsSettings")) { selectedTab = .settings }
                                .buttonStyle(.bordered)
                        }
                        .padding(16)
                    }
                    messageBanner
                    if !appModel.connectionState.isConnected {
                        disconnectedPanel
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            // The trackpad page must own the whole screen: while it is up the
            // tab bar goes away, otherwise it floats over the touch surface.
            .toolbar((trackpadVisible || desktopVisible) ? .hidden : .visible, for: .tabBar)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(appModel.text("tabHome"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay {
            // The trackpad page lives above everything and flips out of the
            // device card; it stays mounted through the exit animation so the
            // end command and the reverse flip both finish. The background
            // inside extends under the system chrome; the content itself
            // respects the safe areas.
            if trackpadVisible, let trackpadModel {
                if desktopVisible {
                    RemoteDesktopView(trackpad: trackpadModel, onClose: closeTrackpad)
                } else {
                    TrackpadContainerView(model: trackpadModel, onClose: closeTrackpad)
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: appModel.connectionGeneration) { _, _ in
            trackpadModel?.connectionReplaced()
        }
        .onChange(of: appModel.connectionState) { _, _ in
            trackpadModel?.connectionStateChanged(appModel.connectionState)
        }
        .alert(
            appModel.text("trackpadEntry"),
            isPresented: Binding(
                get: { trackpadHintKey != nil },
                set: { if !$0 { trackpadHintKey = nil } }
            ),
            actions: {
                Button(appModel.text("trackpadDone")) { trackpadHintKey = nil }
            },
            message: {
                Text(trackpadHintKey.map { appModel.text($0) } ?? "")
            }
        )
    }

    @ViewBuilder
    private var inputTools: some View {
        let tools = [RemoteControlFeature.desktop, .trackpad].filter(isEnabled)
        if !tools.isEmpty {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tools) { feature in
                    Button {
                        if feature == .desktop {
                            guard trackpadReady else {
                                trackpadHintKey = !appModel.connectionState.isConnected
                                    ? "trackpadNotConnected" : "trackpadNeedsMacUpdate"
                                return
                            }
                            desktopVisible = true
                            openTrackpad()
                        } else {
                            handleTrackpadTap()
                        }
                    } label: {
                        controlLabel(feature, running: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("control.\(feature.rawValue)")
                }
            }
        }
    }

    // MARK: - Trackpad

    private func openTrackpad() {
        guard trackpadModel == nil else { return }
        guard appModel.connectionState.isConnected else { return }
        let model = RemoteTrackpadModel()
        trackpadModel = model
        trackpadVisible = true
        model.open(appModel: appModel)
    }

    private func closeTrackpad() {
        trackpadModel?.close()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.34))
            desktopVisible = false
            trackpadVisible = false
            trackpadModel = nil
        }
    }

    // MARK: - Device card

    /// Device identity has its own row so long names do not squeeze the tools.
    private var deviceCard: some View {
        deviceSwitcher
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var deviceSwitcher: some View {
        Menu {
            ForEach(appModel.pairedMacs) { mac in
                Button {
                    appModel.connect(to: mac)
                } label: {
                    Label(
                        "\(mac.name) · \(presenceLabel(for: mac))",
                        systemImage: appModel.selectedMacID == mac.id ? "checkmark.circle.fill" : "desktopcomputer"
                    )
                }
            }
            if !appModel.pairedMacs.isEmpty { Divider() }
            Button {
                selectedTab = .devices
            } label: {
                Label(appModel.text("manageMacs"), systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "desktopcomputer")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appModel.pairedMacs.isEmpty ? appModel.text("chooseMac") : appModel.activeMacName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(appModel.text(appModel.connectionState.titleKey))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(appModel.text("switchMacAccessibility", appModel.activeMacName))
    }

    private func handleTrackpadTap() {
        guard trackpadReady else {
            trackpadHintKey = !appModel.connectionState.isConnected
                ? "trackpadNotConnected" : "trackpadNeedsMacUpdate"
            return
        }
        openTrackpad()
    }

    private var trackpadReady: Bool {
        appModel.connectionState.isConnected && appModel.supportsRealtimeInput
    }

    private func presenceLabel(for mac: PairedMac) -> String {
        switch appModel.status(for: mac) {
        case .connected: appModel.text("connectedLabel")
        case .online: appModel.text("online")
        case .offline: appModel.text("offline")
        }
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

    private func isEnabled(_ feature: RemoteControlFeature) -> Bool {
        appModel.controlPreferences.isEnabled(feature)
    }

    @ViewBuilder
    private var actionGrid: some View {
        let actions = RemoteControlFeature.Group.screen.features.filter(isEnabled)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("controlsGroupScreen")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(actions) { feature in
                        actionButton(feature)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mediaPanel: some View {
        let actions = RemoteControlFeature.Group.media.features.filter(isEnabled)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("controlsGroupMedia")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
                    ForEach(actions) { feature in
                        actionButton(feature)
                    }
                }
                if appModel.connectionState.isConnected && !appModel.supportsMediaControl {
                    hint(appModel.text("mediaNeedsUpdate"))
                }
            }
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(appModel.text(key))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func controlLabel(_ feature: RemoteControlFeature, running: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                if running { ProgressView() }
                else { Image(systemName: feature.icon).font(.title3.weight(.semibold)) }
            }
            .frame(height: 24)
            Text(appModel.text(feature.titleKey))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    private func actionButton(_ feature: RemoteControlFeature) -> some View {
        let command = feature.command!
        let enabled = appModel.connectionState.isConnected && appModel.runningCommand == nil
            && (feature.group != .media || appModel.supportsMediaControl)
        return Button {
            appModel.beginCommand(command)
            Task { await appModel.perform(command) }
        } label: {
            controlLabel(feature, running: appModel.runningCommand == command)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(appModel.text(feature.titleKey))
        .accessibilityIdentifier("control.\(feature.rawValue)")
    }

    // MARK: - Output levels

    /// Brightness and volume, read from the same `MacRemoteState` the rest of
    /// the screen uses.
    ///
    /// A level the Mac did not report is not shown at all: an external monitor
    /// with no controllable backlight, or a Mac with no output device, both mean
    /// a slider that cannot work. The card says so instead of offering one.
    private var enabledLevelKinds: [RemoteLevelKind] {
        RemoteLevelKind.allCases.filter { kind in
            kind == .volume ? (isEnabled(.volume) || isEnabled(.mute)) : isEnabled(.brightness)
        }
    }

    private var hasEnabledLevels: Bool { !enabledLevelKinds.isEmpty }

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
            } else if enabledLevelKinds.contains(where: { $0.value(in: appModel.macState) != nil }) {
                ForEach(enabledLevelKinds, id: \.self) { kind in
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
            banner(text: infoText(infoKey), systemImage: "checkmark.circle.fill", tint: .green)
        }
    }

    /// The missing-apps info carries the failed names with it, so it reads like
    /// a sentence instead of a bare "done".
    private func infoText(_ key: String) -> String {
        if key == "dockGroupLaunchMissing", !appModel.dockGroupsMissingApps.isEmpty {
            return appModel.text(key, appModel.dockGroupsMissingApps.joined(separator: "、"))
        }
        return appModel.text(key)
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
                if kind == .volume, appModel.volumeMuted != nil, appModel.controlPreferences.isEnabled(.mute) {
                    muteButton
                }
            }

            if kind != .volume || appModel.controlPreferences.isEnabled(.volume) {
                Slider(value: $draft, in: 0...1, step: 0.01) { editing in
                    isEditing = editing
                    // The release is sent explicitly so a drag that ends between two
                    // coalesced requests still lands on its final value.
                    if !editing { send(draft) }
                }
                .accessibilityLabel(appModel.text(kind.labelKey))
                .accessibilityValue("\(Int((draft * 100).rounded()))%")
            }
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
