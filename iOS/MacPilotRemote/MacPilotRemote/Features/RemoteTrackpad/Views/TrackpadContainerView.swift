import SwiftUI

/// The fullscreen trackpad page: a slim status strip, the surface, and a
/// bottom row with orientation and settings.
///
/// Entering, the page scales up while rotating around Y — the card's back
/// face becomes the trackpad. The whole exit runs in reverse and only then
/// unmounts, so an in-flight drag never dies mid-gesture.
struct TrackpadContainerView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @ObservedObject var model: RemoteTrackpadModel
    let onClose: () -> Void

    @State private var appeared = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                statusBar
                banner
                TrackpadView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(model.phase.isActiveLike)
                    .accessibilityLabel(appModel.text("trackpadTitle"))
                bottomBar
            }
            .padding(.top, 6)
        }
        .opacity(appeared ? 1 : 0.05)
        .scaleEffect(appeared ? 1 : 0.55)
        .rotation3DEffect(
            .degrees(appeared ? 0 : -90),
            axis: (x: 0.0, y: 1.0, z: 0.0),
            perspective: 0.7
        )
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                appeared = true
            }
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .exiting else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                appeared = false
            }
        }
        .sheet(isPresented: $showSettings) {
            TrackpadSettingsView(model: model)
        }
    }

    // MARK: - Status strip

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .accessibilityLabel(appModel.text("trackpadClose"))

            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.activeMacName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let latency = appModel.latencyMs, model.phase.isActiveLike {
                        Text(appModel.text("latency", latency))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        switch model.phase {
        case .active: return .green
        case .entering, .reconnecting: return .orange
        case .disconnected: return .red
        case .idle, .exiting: return .secondary
        }
    }

    private var statusText: String {
        switch model.phase {
        case .entering: return appModel.text("stateConnecting")
        case .active: return appModel.text("stateConnected")
        case .reconnecting: return appModel.text("stateReconnecting")
        case .disconnected: return appModel.text("trackpadDisconnected")
        case .idle, .exiting: return appModel.text("trackpadTitle")
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banner: some View {
        if let errorKey = model.beginErrorKey {
            bannerView(appModel.text(errorKey), systemImage: "exclamationmark.triangle.fill", tint: .orange)
        } else if model.phase == .reconnecting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(appModel.text("trackpadReconnecting"))
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else if model.phase == .disconnected {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash").foregroundStyle(.red)
                Text(appModel.text("trackpadDisconnected"))
                    .font(.subheadline)
                Spacer(minLength: 0)
                Button(appModel.text("retry")) { appModel.retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else if appModel.realtimeInputLinkKind == .bluetooth, model.phase.isActiveLike {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.orange)
                Text(appModel.text("trackpadBluetoothHint"))
                    .font(.footnote)
                Spacer(minLength: 0)
                Button(appModel.text("trackpadUseWiFi")) { appModel.retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func bannerView(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Bottom controls

    private var bottomBar: some View {
        HStack(spacing: 12) {
            TrackpadOrientationPicker(model: model) { appModel.text($0) }
            Spacer(minLength: 8)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .accessibilityLabel(appModel.text("trackpadSettings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
