import MacPilotRemoteProtocol
import SwiftUI

/// First-time pairing sheet: the user retypes the 6 digits MacPilot shows.
struct PairingSheetView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    let prompt: RemoteAppModel.PairingPrompt

    @State private var code = ""
    @FocusState private var isFocused: Bool

    private var isValid: Bool { RemotePairingCode.isValid(code) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(appModel.text("pairingSubtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(prompt.name)
                    .font(.headline)

                TextField(appModel.text("pairingCodePlaceholder"), text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .focused($isFocused)
                    .onChange(of: code) { _, newValue in
                        let digits = RemotePairingCode.normalize(newValue)
                        if digits.count > RemoteCrypto.pairCodeLength {
                            code = String(digits.prefix(RemoteCrypto.pairCodeLength))
                        } else if digits != newValue {
                            code = digits
                        }
                    }
                    .onSubmit(submit)

                if appModel.connectionState == .pairing {
                    Label(appModel.text("pairingWaiting"), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorKey = appModel.errorKey {
                    Text(appModel.text(errorKey))
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)

                Button(appModel.text("pairingConfirm"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!isValid)
            }
            .padding(20)
            .navigationTitle(appModel.text("pairingTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(appModel.text("pairingCancel")) { appModel.cancelPairing() }
                }
            }
            .onAppear {
                appModel.clearMessages()
                isFocused = true
            }
        }
    }

    private func submit() {
        guard isValid else { return }
        appModel.submitPairCode(code)
    }
}
