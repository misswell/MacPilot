import SwiftUI
import MacPilotRemoteTransport

/// Independent test for the reversed BLE roles: Mac advertises, this phone
/// connects. It measures each GATT step and proves the sixteen byte echo comes
/// back unchanged. It is not wired to unlock and stores no identity.
struct ProximityGATTTestView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @ObservedObject private var central = ProximityBLECentral.shared

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(statusText)
                        .accessibilityIdentifier("proximityGATTStatus")
                    Spacer()
                    if central.isRunning {
                        Button(appModel.text("proximityGATTStop"), role: .destructive) {
                            central.stop()
                        }
                        .accessibilityIdentifier("proximityGATTStop")
                    } else {
                        Button(appModel.text("proximityGATTStart")) {
                            central.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("proximityGATTStart")
                    }
                }
            } footer: {
                Text(appModel.text("proximityGATTSubtitle"))
            }

            Section(appModel.text("proximityGATTDiagnostics")) {
                LabeledContent(appModel.text("proximityGATTLink"), value: appModel.text(central.isConnected ? "proximityGATTYes" : "proximityGATTNo"))
                LabeledContent(appModel.text("proximityGATTSubscription"), value: appModel.text(central.isSubscribed ? "proximityGATTYes" : "proximityGATTNo"))
                LabeledContent(appModel.text("proximityGATTSentBytes"), value: "\(central.probe.sentBytes)")
                LabeledContent(appModel.text("proximityGATTReceivedBytes"), value: "\(central.probe.receivedBytes)")
                LabeledContent(appModel.text("proximityGATTVerifiedCount"), value: "\(central.probe.verifiedCount)")
                    .accessibilityIdentifier("proximityGATTVerifiedCount")
                    .accessibilityValue("\(central.probe.verifiedCount)")
                dateRow("proximityGATTLastSent", central.probe.lastSentAt)
                dateRow("proximityGATTLastReceived", central.probe.lastReceivedAt)
                dateRow("proximityGATTLastVerified", central.lastVerifiedAt)
                if let error = central.lastError {
                    LabeledContent(appModel.text("proximityGATTLastError"), value: error)
                }
                Button(appModel.text("proximityGATTSendAgain")) { central.sendEcho() }
                    .accessibilityIdentifier("proximityGATTSendAgain")
                    .disabled(!central.isSubscribed || central.probe.payload != nil)
            }

            Section(appModel.text("proximityGATTProtocol")) {
                LabeledContent(appModel.text("proximityGATTServiceUUID"), value: ProximityGATTService.serviceUUID.uuidString)
                LabeledContent(appModel.text("proximityGATTEchoUUID"), value: ProximityGATTService.echoCharacteristicUUID.uuidString)
                LabeledContent(appModel.text("proximityGATTWriteUUID"), value: ProximityGATTService.responseCharacteristicUUID.uuidString)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)

            if let info = central.macInfo {
                Section(appModel.text("proximityGATTMacSection")) {
                    LabeledContent(appModel.text("proximityGATTMacID")) {
                        Text(info.deviceID?.uuidString ?? appModel.text("proximityGATTMacUnset"))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if central.timings != ProximityBLECentral.Timings() {
                Section(appModel.text("proximityGATTStages")) {
                    timingRow("proximityGATTConnectStage", central.timings.connectMs)
                    timingRow("proximityGATTDiscoverStage", central.timings.discoverMs)
                    timingRow("proximityGATTReadStage", central.timings.readMs)
                    timingRow("proximityGATTSubscribeStage", central.timings.subscribeMs)
                    timingRow("proximityGATTEchoStage", central.timings.echoMs)
                }
            }

            Section(appModel.text("proximityGATTLog")) {
                Button(appModel.text("proximityGATTClearLog")) { central.clearLog() }
                    .accessibilityIdentifier("proximityGATTClearLog")
                if central.logLines.isEmpty {
                    Text(appModel.text("proximityGATTNoEvents"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(central.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("proximityGATTLogLine")
                    }
                    ShareLink(item: central.logLines.joined(separator: "\n")) {
                        Label(appModel.text("proximityGATTShareLog"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(appModel.text("proximityGATTTitle"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func dateRow(_ key: String, _ date: Date?) -> some View {
        LabeledContent(appModel.text(key), value: date?.formatted(date: .omitted, time: .standard) ?? "—")
    }

    @ViewBuilder
    private func timingRow(_ key: String, _ milliseconds: Int?) -> some View {
        if let milliseconds {
            LabeledContent(appModel.text(key)) {
                Text("\(milliseconds) ms")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch central.status {
        case .idle: return .secondary
        case .verified: return .green
        case .failed: return .red
        default: return .orange
        }
    }

    private var statusText: String {
        switch central.status {
        case .idle:
            return appModel.text("proximityGATTStatusIdle")
        case .starting:
            return appModel.text("proximityGATTStatusStarting")
        case .scanning:
            return appModel.text("proximityGATTStatusScanning")
        case .connecting:
            return appModel.text("proximityGATTStatusConnecting")
        case .discovering:
            return appModel.text("proximityGATTStatusDiscovering")
        case .echoing:
            return appModel.text("proximityGATTStatusEchoing")
        case .verified(let roundTrip):
            return appModel.text("proximityGATTStatusVerified", roundTrip)
        case .failed(let reason):
            return appModel.text("proximityGATTStatusFailed", reason)
        }
    }
}
