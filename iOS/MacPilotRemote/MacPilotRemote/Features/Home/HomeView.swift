import MacPilotRemoteProtocol
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// User-selected controls, grouped by intent on the authenticated connection.
struct HomeView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Binding var selectedTab: RootTab

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // A compact control deck on phones, with a comfortable maximum width on
    // iPad. Accessibility text gets extra rows instead of smaller touch targets.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    @State private var trackpadModel: RemoteTrackpadModel?
    @State private var trackpadVisible = false
    @State private var desktopVisible = false
    /// Text key of why the trackpad entry refused a tap, shown as an alert.
    @State private var trackpadHintKey: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    deviceCard
                    ForEach(appModel.controlPreferences.homeSections, id: \.first) { features in
                        switch features.first?.group {
                        case .input: inputTools(features)
                        case .screen: actionGrid(features)
                        case .media: mediaPanel(features)
                        case .levels: levelsPanel(features)
                        case nil: EmptyView()
                        }
                    }
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
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
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
    private func inputTools(_ tools: [RemoteControlFeature]) -> some View {
        if !tools.isEmpty {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
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
                        ControlKeyLabel(title: appModel.text(feature.titleKey),
                                        icon: feature.icon, enabled: true)
                    }
                    .buttonStyle(ControlKeyStyle(prominent: false))
                    .accessibilityIdentifier("control.\(feature.rawValue)")
                }
            }
            .padding(8)
            .controlDeckCard()
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
            .controlDeckCard()
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
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    @ViewBuilder
    private func actionGrid(_ actions: [RemoteControlFeature]) -> some View {
        if !actions.isEmpty {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(actions) { feature in
                    actionButton(feature)
                }
            }
            .padding(8)
            .controlDeckCard()
        }
    }

    @ViewBuilder
    private func mediaPanel(_ actions: [RemoteControlFeature]) -> some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(actions) { feature in
                        mediaButton(feature)
                    }
                }
                .padding(8)
                .controlDeckCard()
                if appModel.connectionState.isConnected && !appModel.supportsMediaControl {
                    hint(appModel.text("mediaNeedsUpdate"))
                }
            }
        }
    }

    private func mediaButton(_ feature: RemoteControlFeature) -> some View {
        Button {
            guard let command = feature.command else { return }
            appModel.beginCommand(command)
            Task { await appModel.perform(command) }
        } label: {
            ControlKeyLabel(title: appModel.text(feature.titleKey), icon: feature.icon,
                            enabled: commandEnabled(feature),
                            running: appModel.runningCommand == feature.command,
                            showsTitle: feature != .mediaPlayPause)
        }
        .buttonStyle(ControlKeyStyle(prominent: feature == .mediaPlayPause))
        .disabled(!commandEnabled(feature))
        .accessibilityLabel(appModel.text(feature.titleKey))
        .accessibilityIdentifier("control.\(feature.rawValue)")
    }

    private func commandEnabled(_ feature: RemoteControlFeature) -> Bool {
        appModel.connectionState.isConnected && appModel.runningCommand == nil
            && (feature.group != .media || appModel.supportsMediaControl)
    }

    private func actionButton(_ feature: RemoteControlFeature) -> some View {
        let enabled = commandEnabled(feature)
        return Button {
            guard let command = feature.command else { return }
            appModel.beginCommand(command)
            Task { await appModel.perform(command) }
        } label: {
            ControlKeyLabel(title: appModel.text(feature.titleKey), icon: feature.icon,
                            enabled: enabled, running: appModel.runningCommand == feature.command)
        }
        .buttonStyle(ControlKeyStyle(prominent: false))
        .disabled(!enabled)
        .accessibilityLabel(appModel.text(feature.titleKey))
        .accessibilityIdentifier("control.\(feature.rawValue)")
    }

    // MARK: - Output levels

    /// Brightness and volume, read from the same `MacRemoteState` the rest of
    /// the screen uses.
    ///
    /// Unknown levels retain a labeled row with an unavailable indicator, never
    /// a guessed zero or an interactive slider. The deck stays stable as the
    /// first state arrives after connecting.
    private func levelsPanel(_ features: [RemoteControlFeature]) -> some View {
        VStack(spacing: 4) {
            ForEach(features) { feature in
                if feature == .mute {
                    muteControl
                } else {
                    let kind: RemoteLevelKind = feature == .brightness ? .brightness : .volume
                    LevelSliderRow(kind: kind, value: kind.value(in: appModel.macState))
                }
                if feature != features.last { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlDeckCard()
    }

    private var muteControl: some View {
        let volume = RemoteLevelKind.volume.value(in: appModel.macState)
        let available = appModel.connectionState.isConnected
            && volume != nil && appModel.volumeMuted != nil
        let isMuted = appModel.volumeMuted == true
        return Button {
            guard let volume, available else { return }
            appModel.setLevel(.volume, value: volume, muted: !isMuted)
            Haptics.impact()
        } label: {
            ControlKeyLabel(title: appModel.text(isMuted ? "unmute" : "mute"),
                            icon: isMuted ? "speaker.slash" : "speaker.wave.2",
                            enabled: available, tint: isMuted ? .orange : .accentColor)
        }
        .buttonStyle(ControlKeyStyle(prominent: false))
        .disabled(!available)
        .accessibilityIdentifier("control.mute")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(disconnectedTitle).font(.subheadline.weight(.semibold))
                    Text(disconnectedDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if unpairedMac != nil {
                    Button(appModel.text("goToPairing")) { selectedTab = .devices }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                } else {
                    Button(appModel.text("retry")) { appModel.retry() }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                }
            }
            if appModel.localNetworkDenied {
                Button(appModel.text("openSystemSettings")) { openSystemSettings() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlDeckCard()
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let kind: RemoteLevelKind
    /// The value the Mac last reported, used whenever the finger is up.
    let value: Double?

    @ScaledMetric(relativeTo: .subheadline) private var levelIconWidth: CGFloat = 20

    @State private var draft: Double = 0
    @State private var isEditing = false

    private var isMuted: Bool {
        kind == .volume && appModel.volumeMuted == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(appModel.text(kind.labelKey))
                    .font(.subheadline.weight(.medium))
            }
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "speaker.slash.fill" : kind.iconName)
                    .font(.subheadline)
                    .frame(width: levelIconWidth)
                    .foregroundStyle(isMuted ? Color.orange : Color.accentColor)
                if value != nil {
                    Slider(value: $draft, in: 0...1, step: 0.01) { editing in
                        isEditing = editing
                        if !editing { send(draft) }
                    }
                    .accessibilityLabel(appModel.text(kind.labelKey))
                    .accessibilityValue("\(Int((draft * 100).rounded()))%")
                    .accessibilityIdentifier("control.\(kind.rawValue)")
                    Text("\(Int((draft * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34, alignment: .trailing)
                } else {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(appModel.text(kind.labelKey))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("—").foregroundStyle(.tertiary)
                        .accessibilityLabel(appModel.text("levelsUnavailableShort"))
                }
            }
            .frame(minHeight: 44)
        }
        .onAppear { if let value { draft = value } }
        .onChange(of: draft) { _, newValue in
            guard isEditing else { return }
            send(newValue)
        }
        .onChange(of: value) { _, newValue in
            guard !isEditing, let newValue else { return }
            draft = newValue
        }
    }

    /// Raising the volume clears mute, exactly like the Mac's own volume keys;
    /// dragging to silence leaves the mute state alone.
    private func send(_ newValue: Double) {
        let muted: Bool? = kind == .volume && newValue > 0 ? false : nil
        appModel.setLevel(kind, value: newValue, muted: muted)
    }
}

/// Keep both the symbol and the full caption on the same center line.
/// Intrinsic text height lets larger fonts wrap without clipping the key.
private struct ControlKeyLabel: View {
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .subheadline) private var minimumHeight: CGFloat = 44

    let title: String
    let icon: String
    let enabled: Bool
    var running = false
    var showsTitle = true
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .opacity(running ? 0.35 : 1)
                if running { ProgressView() }
            }
            .frame(width: iconSize, height: iconSize)
            .foregroundStyle(enabled ? tint : .secondary)
            if showsTitle {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(enabled ? Color.primary : .secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}

/// All home control groups share one quiet, adaptive card surface.
private extension View {
    func controlDeckCard() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

/// Screen, media, input and mute keys share Touch Bar surfaces and feedback.
private struct ControlKeyStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(
                    colors: [Color(.tertiarySystemFill).opacity(0.65), Color(.tertiarySystemFill)],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .background(
                Color.accentColor.opacity(prominent && isEnabled ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.12 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(prominent ? 0.09 : 0.04), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
