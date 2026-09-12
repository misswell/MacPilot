import Foundation
import MacPilotRemoteProtocol

/// Tracks in-flight pairings and the short window during which a new iPhone is
/// allowed to pair.
///
/// Pairing is never open by default: the user has to arm a two minute window
/// from the MacPilot settings page, and the six digit code derived from the ECDH
/// handshake is displayed there for confirmation.
@MainActor
final class RemotePairingManager: ObservableObject {
    struct PendingPairing {
        let connectionID: UUID
        let clientName: String
        let clientNonce: Data
        let serverNonce: Data
        let exchange: RemotePairingExchange
        let code: String
        let pairingKey: Data
        let createdAt: Date
    }

    /// The code currently shown on the Mac, if any.
    @Published private(set) var displayedCode: String?
    @Published private(set) var displayedClientName: String?
    @Published private(set) var pairingWindowExpiresAt: Date?

    private var pending: [UUID: PendingPairing] = [:]
    private let logHandler: (String) -> Void
    private var expiryTask: Task<Void, Never>?

    /// Called when a pairing code first appears so the app can surface it.
    var onCodePresented: (@MainActor (String, String) -> Void)?

    init(log: @escaping (String) -> Void = { remoteControlLog($0) }) {
        self.logHandler = log
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    var isWindowOpen: Bool {
        guard let expiry = pairingWindowExpiresAt else { return false }
        return expiry > Date()
    }

    /// Arms the pairing window for `duration` seconds.
    func openWindow(duration: TimeInterval = 120) {
        pairingWindowExpiresAt = Date().addingTimeInterval(duration)
        log("pairing window opened duration=\(Int(duration))s")
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.closeWindow()
        }
    }

    func closeWindow() {
        pairingWindowExpiresAt = nil
        expiryTask?.cancel()
        expiryTask = nil
        clearDisplay()
        pending.removeAll()
        log("pairing window closed")
    }

    /// Derives the confirmation code for a pairing request. Returns nil when the
    /// window is closed, in which case the request must be refused.
    func begin(
        connectionID: UUID,
        clientName: String,
        clientPublicKey: Data,
        exchange: RemotePairingExchange
    ) -> String? {
        guard isWindowOpen else {
            log("pairing request refused reason=windowClosed")
            return nil
        }
        do {
            let code = try exchange.pairCode(withPeerPublicKey: clientPublicKey)
            let key = try exchange.pairingKey(withPeerPublicKey: clientPublicKey)
            let entry = PendingPairing(
                connectionID: connectionID,
                clientName: clientName,
                clientNonce: exchange.clientNonce,
                serverNonce: exchange.serverNonce,
                exchange: exchange,
                code: code,
                pairingKey: key,
                createdAt: Date()
            )
            pending[connectionID] = entry
            displayedCode = code
            displayedClientName = clientName
            log("pairing code derived for client=\(clientName)")
            onCodePresented?(code, clientName)
            return code
        } catch {
            log("pairing request failed reason=invalidPublicKey")
            return nil
        }
    }

    /// Validates the code the user typed on the iPhone. Returns the long term
    /// pairing key on success.
    func confirm(connectionID: UUID, code: String) -> Data? {
        guard let entry = pending[connectionID] else {
            log("pairing confirm refused reason=noPendingPairing")
            return nil
        }
        guard RemotePairingCode.matches(entry.code, code) else {
            log("pairing confirm refused reason=codeMismatch")
            return nil
        }
        log("pairing confirmed")
        clearDisplay()
        return entry.pairingKey
    }

    func cancel(connectionID: UUID) {
        pending.removeValue(forKey: connectionID)
        clearDisplay()
    }

    private func clearDisplay() {
        displayedCode = nil
        displayedClientName = nil
    }
}
