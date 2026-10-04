import MacPilotRemoteProtocol
import SwiftUI

struct RemoteDesktopView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var desktop = RemoteDesktopState()
    @ObservedObject var trackpad: RemoteTrackpadModel
    let onClose: () -> Void
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var landscape = false
    @State private var videoZoom = RemoteVideoZoom()
    @State private var pinchBaseline = RemoteVideoZoom()
    @State private var pinchStart = CGPoint.zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Image(systemName: "chevron.down") }
                    .accessibilityLabel(appModel.text("trackpadClose"))
                Text(appModel.text("desktopTitle")).font(.headline)
                Spacer()
                if !desktop.displays.isEmpty {
                    Menu {
                        ForEach(desktop.displays) { display in
                            Button(display.name) { desktop.selectDisplay(display.id) }
                        }
                    } label: { Image(systemName: "display.2") }
                    .accessibilityLabel(appModel.text("desktopDisplay"))
                }
                Button { videoZoom = RemoteVideoZoom() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .disabled(videoZoom.scale == 1)
                    .accessibilityLabel(appModel.text("desktopResetZoom"))
                Button { showDiagnostics.toggle() } label: { Image(systemName: "waveform.path") }
                    .accessibilityLabel(appModel.text("desktopDiagnostics"))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            inputStatus
            desktopSurface
            HStack(spacing: 28) {
                Button {
                    landscape.toggle()
                    // Explicit scene rotation; no sensor-driven behavior.
                    trackpad.setOrientation(.top)
                    InterfaceOrientationController.shared.setSupported(landscape ? .landscapeRight : .portrait)
                } label: { Label(appModel.text("desktopOrientation"), systemImage: "arrow.up.and.down") }
                if appModel.controlPreferences.isEnabled(.keyboard) {
                    Button {
                        if trackpad.keyboardActive { trackpad.dismissKeyboard() }
                        else { trackpad.requestKeyboard() }
                    } label: { Label(appModel.text("desktopKeyboard"), systemImage: "keyboard") }
                    .disabled(trackpad.phase != .active)
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(appModel.text("trackpadSettings"))
            }
            .font(.subheadline).padding(14)
            RemoteKeyboardInputView(model: trackpad, usesSceneOrientation: true).frame(width: 1, height: 1).accessibilityHidden(true)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            desktop.onKeyboardFocus = { focused in
                if focused { trackpad.dismissKeyboard(); trackpad.requestKeyboard(focused: true) }
                else { trackpad.dismissKeyboard() }
            }
            desktop.open(appModel: appModel)
        }
        .onDisappear { appModel.desktopModifiers = 0; desktop.close() }
        .onChange(of: desktop.displayID) { _, _ in videoZoom = RemoteVideoZoom() }
        .onChange(of: appModel.connectionGeneration) { _, _ in desktop.connectionChanged() }
        .onChange(of: appModel.connectionState) { _, _ in desktop.connectionChanged() }
        .onChange(of: trackpad.phase) { _, phase in
            if phase == .active, desktop.keyboardFocused { trackpad.requestKeyboard(focused: true) }
        }
        .onChange(of: trackpad.keyboardActive) { _, active in
            if !active { appModel.desktopModifiers = 0 }
        }
        .onChange(of: scenePhase) { _, phase in desktop.sceneChanged(phase) }
        .sheet(isPresented: $showSettings) { TrackpadSettingsView(model: trackpad) }
    }

    @ViewBuilder
    private var inputStatus: some View {
        if let error = trackpad.beginErrorKey {
            inputBanner(appModel.text(error), retry: true)
        } else if trackpad.phase == .disconnected {
            inputBanner(appModel.text("trackpadDisconnected"), retry: true)
        } else if trackpad.phase == .entering || trackpad.phase == .reconnecting {
            inputBanner(appModel.text("stateReconnecting"), retry: false)
        }
    }

    private func inputBanner(_ message: String, retry: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption)
            Spacer(minLength: 4)
            if retry {
                Button(appModel.text("retry")) { appModel.retry() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// One continuous relative touch surface spans the video and lower area.
    /// It stays mounted when the keyboard changes so gestures share one engine.
    private var desktopSurface: some View {
        GeometryReader { geometry in
            let videoHeight = geometry.size.height * (trackpad.keyboardActive ? 0.85 : 0.45)
            let viewport = CGSize(width: geometry.size.width, height: videoHeight)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    videoArea.frame(height: videoHeight).clipped()
                    Divider()
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)

                TrackpadView(model: trackpad,
                             pinchRegion: desktop.showingVideo ? CGRect(origin: .zero, size: viewport) : nil,
                             onPinch: { state, factor, location in
                    if state == .began {
                        pinchBaseline = videoZoom
                        pinchStart = location
                    }
                    if state == .began || state == .changed {
                        videoZoom.update(from: pinchBaseline, factor: factor,
                                         start: pinchStart, location: location, viewport: viewport)
                    }
                })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(trackpad.phase.isActiveLike)
                    .accessibilityLabel(appModel.text("trackpadTitle"))

                if !desktop.showingVideo {
                    videoStatus.frame(height: videoHeight)
                }
                if trackpad.keyboardActive {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        shortcutBar.frame(height: geometry.size.height - videoHeight)
                    }
                }
            }
            .onChange(of: viewport) { _, size in videoZoom.constrain(to: size) }
        }
    }

    private var videoStatus: some View {
        VStack(spacing: 12) {
            Text(appModel.text(desktop.statusKey))
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
            if desktop.statusKey != "desktopBluetooth" {
                Button(appModel.text("retry")) { desktop.retry() }.buttonStyle(.bordered)
            }
        }
        .font(.subheadline).foregroundStyle(.white).padding(24)
    }

    private var videoArea: some View {
        RemoteVideoView(decoder: desktop.decoder)
            .scaleEffect(videoZoom.scale)
            .offset(videoZoom.offset)
            .overlay(alignment: .topLeading) {
                if showDiagnostics {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appModel.text("desktopFPS", desktop.metrics.fps))
                        if let encode = desktop.encodeMs { Text(appModel.text("desktopEncode", encode)) }
                        Text(appModel.text("desktopDecode", desktop.metrics.decodeMs))
                        Text(appModel.text("desktopNetwork", desktop.metrics.kbps))
                        Text(appModel.text("desktopDropped", desktop.metrics.dropped + desktop.sourceDropped))
                        if let rtt = appModel.latencyMs { Text(appModel.text("desktopRTT", rtt)) }
                    }
                    .font(.caption.monospaced()).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.65)).allowsHitTesting(false)
                }
            }
    }

    private var shortcutBar: some View {
        HStack(spacing: 14) {
            keyButton("ESC", key: .escape)
            keyButton("TAB", key: .tab)
            modifierButton("CTRL", bit: 1)
            modifierButton("OPTION", bit: 2)
            modifierButton("CMD", bit: 4)
            keyButton("⌫", key: .delete)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
    }

    private func keyButton(_ title: String, key: RemoteKeyRequest.Key) -> some View {
        Button(title) {
            let request = RemoteKeyRequest(key: key, modifiers: appModel.desktopModifiers)
            appModel.desktopModifiers = 0
            Task { await appModel.desktopKey(request) }
        }
    }

    private func modifierButton(_ title: String, bit: UInt8) -> some View {
        Button(title) { appModel.desktopModifiers ^= bit }
            .foregroundStyle(appModel.desktopModifiers & bit == 0 ? Color.secondary : Color.accentColor)
    }
}
