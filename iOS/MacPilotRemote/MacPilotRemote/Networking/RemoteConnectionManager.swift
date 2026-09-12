import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network

/// Owns the single long lived link to the Mac.
///
/// Responsibilities: framing, the pairing/authentication handshake, the session
/// key, replay safe sequencing, request/response correlation and the 15 second
/// keep alive ping. UI state is pushed out through the callbacks so the
/// `RemoteAppModel` remains the single source of truth for the views.
///
/// The link itself is a `RemoteTransport`, so TCP over Wi-Fi/AWDL and BLE L2CAP
/// both arrive here as the same byte stream and everything above is shared.
@MainActor
final class RemoteConnectionManager {
    /// Snapshot of where the Mac was actually reached, used for the next fast
    /// path connection.
    struct ResolvedEndpoint {
        var host: String?
        var port: UInt16?
        var serviceName: String?
    }

    private enum Phase {
        case idle
        case connecting
        case handshaking
        case authenticating
        case pairing
        case ready
        case closed
    }

    // Callbacks
    var onStateChange: (@MainActor (RemoteConnectionState) -> Void)?
    var onDeviceResolved: (@MainActor (UUID, String, ResolvedEndpoint) -> Void)?
    var onMacState: (@MainActor (MacRemoteState) -> Void)?
    var onPairingPrompt: (@MainActor (UUID, String) -> Void)?
    var onLatency: (@MainActor (Int) -> Void)?
    var onFailure: (@MainActor (RemoteConnectionError) -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    /// (connect latency ms, handshake latency ms) measured once per session.
    var onMetrics: (@MainActor (Int?, Int?) -> Void)?

    private var transport: RemoteTransport?
    private var buffer = Data()
    private var phase: Phase = .idle

    /// Which link currently carries the session, and through which interface.
    /// Surfaced in Settings so the transport can be verified on a real network.
    private(set) var transportKind: RemoteTransportKind?
    var linkDescription: String { transport?.linkDescription ?? "—" }

    private var sessionKey: RemoteSessionKey?
    private var sentSequence: UInt64 = 0
    private var pendingRequests: [UUID: CheckedContinuation<RemoteResponse, Error>] = [:]

    private var clientID: String = ""
    private var clientName: String = "iPhone"
    private var clientNonce: Data?
    private var serverNonce: Data?
    private var pairingExchange: RemotePairingExchange?
    /// The Mac's ephemeral P-256 public key from `serverHello`, needed to derive
    /// the confirmation code and the long term key.
    private var serverPairingPublicKey: Data?
    private var targetDeviceID: UUID?
    private var targetName: String = ""
    private var resolvedEndpoint = ResolvedEndpoint()

    private var pingTask: Task<Void, Never>?
    private var didReportDisconnect = false
    private var connectStartedAt: Date?
    private var transportReadyAt: Date?

    var isReady: Bool { phase == .ready }
    var isPairing: Bool { phase == .pairing }
    /// True once the link is up, even if the handshake is still running.
    private(set) var isTransportReady = false
    /// Device currently being connected to, so discovery does not race itself.
    private(set) var connectingDeviceID: UUID?

    /// True from the moment a link starts being dialled until it is torn down.
    ///
    /// `connectingDeviceID` cannot answer this on its own: a BLE channel has no
    /// device ID until the Mac identifies itself in the handshake, so anything
    /// guarding on the ID alone would happily cancel a live BLE attempt.
    var hasActiveAttempt: Bool { transport != nil }

    // MARK: - Connect

    func connect(
        to endpoint: NWEndpoint,
        deviceID: UUID?,
        name: String,
        clientID: String,
        clientName: String
    ) {
        connect(
            using: NetworkRemoteTransport(to: endpoint),
            deviceID: deviceID,
            name: name,
            clientID: clientID,
            clientName: clientName
        )
    }

    /// Connects over any link. The caller picks the transport; everything from
    /// the handshake down is identical, which is the whole point of the split.
    func connect(
        using transport: RemoteTransport,
        deviceID: UUID?,
        name: String,
        clientID: String,
        clientName: String
    ) {
        disconnect(report: false)
        self.clientID = clientID
        self.clientName = clientName
        self.targetDeviceID = deviceID
        self.connectingDeviceID = deviceID
        self.targetName = name
        self.resolvedEndpoint = ResolvedEndpoint()
        self.buffer = Data()
        self.didReportDisconnect = false
        self.phase = .connecting
        self.transportKind = transport.kind
        transport.onStateChange = { [weak self] state in self?.handleTransportState(state) }
        transport.onReceive = { [weak self] data in
            guard let self else { return }
            self.buffer.append(data)
            self.processBuffer()
        }
        self.transport = transport
        onStateChange?(.connecting)
        transport.start()
    }

    func disconnect(report: Bool = true) {
        cancelPing()
        failPendingRequests(RemoteConnectionError.network("disconnected"))
        transport?.onStateChange = nil
        transport?.onReceive = nil
        transport?.cancel()
        transport = nil
        transportKind = nil
        sessionKey = nil
        pairingExchange = nil
        serverPairingPublicKey = nil
        connectingDeviceID = nil
        isTransportReady = false
        sentSequence = 0
        buffer = Data()
        let wasActive = phase != .idle && phase != .closed
        phase = .idle
        if report, wasActive, !didReportDisconnect {
            didReportDisconnect = true
            onDisconnected?()
        }
    }

    // MARK: - Pairing

    /// Sends the code the user read off the Mac.
    func submitPairCode(_ code: String) {
        guard phase == .pairing else { return }
        let normalized = RemotePairingCode.normalize(code)
        guard RemotePairingCode.isValid(normalized) else {
            onFailure?(.invalidPairCode)
            return
        }
        try? sendPlain(RemoteHandshakeMessage(kind: .pairConfirm, pairCode: normalized))
    }

    func cancelPairing() {
        disconnect()
    }

    // MARK: - Commands

    func send(_ command: RemoteCommand, payload: Data? = nil, timeout: TimeInterval = 10) async throws -> RemoteResponse {
        guard let sessionKey, phase == .ready else {
            throw RemoteConnectionError.notPaired
        }
        sentSequence &+= 1
        let request = RemoteRequest(command: command, sequence: sentSequence, payload: payload)
        let framed = try RemoteFrameCodec.encodeSecure(request, key: sessionKey, sequence: sentSequence)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[request.requestID] = continuation
            sendRaw(framed)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let pending = self.pendingRequests.removeValue(forKey: request.requestID) else { return }
                pending.resume(throwing: RemoteConnectionError.server(.commandTimeout))
            }
        }
    }

    // MARK: - Connection state

    private func handleTransportState(_ state: RemoteTransportState) {
        switch state {
        case .ready:
            isTransportReady = true
            transportReadyAt = Date()
            captureResolvedEndpoint()
            startHandshake()
        case .connecting, .waiting:
            // Bonjour resolution, BLE channel setup and Wi-Fi settling can park
            // the link here for a moment; stay in `connecting` instead of
            // alarming the user.
            break
        case .failed, .closed:
            disconnect()
        }
    }

    private func captureResolvedEndpoint() {
        guard let transport else { return }
        if let host = transport.remoteHost { resolvedEndpoint.host = host }
        if let port = transport.remotePort { resolvedEndpoint.port = port }
        if let service = transport.remoteServiceName { resolvedEndpoint.serviceName = service }
    }

    // MARK: - Handshake

    private func startHandshake() {
        phase = .handshaking
        let nonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        clientNonce = nonce
        let hello = RemoteHandshakeMessage(
            kind: .clientHello,
            clientID: UUID(uuidString: clientID),
            clientName: clientName,
            clientNonce: nonce
        )
        try? sendPlain(hello)
    }

    private func handlePlaintext(_ message: RemoteHandshakeMessage) {
        switch message.kind {
        case .serverHello:
            handleServerHello(message)
        case .pairResult:
            handlePairResult(message)
        case .authResult:
            handleAuthResult(message)
        case .failure:
            if message.errorCode == .unsupportedProtocol {
                fail(.unsupportedProtocol)
            } else {
                fail(.server(message.errorCode ?? .internalError))
            }
        default:
            fail(.network("unexpected handshake message"))
        }
    }

    private func handleServerHello(_ message: RemoteHandshakeMessage) {
        guard message.protocolVersion == RemoteProtocolVersion.current else {
            fail(.unsupportedProtocol)
            return
        }
        guard let deviceID = message.deviceID, let nonce = message.serverNonce, let clientNonce else {
            fail(.network("incomplete server hello"))
            return
        }
        serverNonce = nonce
        targetDeviceID = deviceID
        if let name = message.deviceName, !name.isEmpty { targetName = name }
        resolvedEndpoint.serviceName = resolvedServiceName()

        let paired = message.paired == true
        let storedKey = RemoteKeychain.pairingKey(for: deviceID.uuidString)

        if paired, let storedKey {
            phase = .authenticating
            onStateChange?(.authenticating)
            let proof = RemoteCrypto.clientProof(pairingKey: storedKey, clientNonce: clientNonce, serverNonce: nonce)
            try? sendPlain(RemoteHandshakeMessage(kind: .authRequest, proof: proof))
            return
        }

        // Not paired (or the key is gone): run the ECDH pairing exchange.
        guard let serverPublicKey = message.publicKey else {
            fail(.notPaired)
            return
        }
        serverPairingPublicKey = serverPublicKey
        let exchange = RemotePairingExchange(clientNonce: clientNonce, serverNonce: nonce)
        pairingExchange = exchange
        try? sendPlain(RemoteHandshakeMessage(kind: .pairRequest, publicKey: exchange.publicKeyData))
    }

    private func handlePairResult(_ message: RemoteHandshakeMessage) {
        if let errorCode = message.errorCode {
            switch errorCode {
            case .pairingRequired:
                fail(.pairingWindowClosed)
            case .unauthenticated:
                fail(.authenticationFailed)
            default:
                fail(.server(errorCode))
            }
            return
        }

        guard let deviceID = targetDeviceID, let clientNonce, let serverNonce else {
            fail(.network("pairing state lost"))
            return
        }

        if let proof = message.proof {
            // Pairing accepted: derive the long term key from the ECDH secret and
            // verify the Mac proved it holds the same key.
            guard let exchange = pairingExchange,
                  let serverPublicKey = serverPairingPublicKey,
                  let key = try? exchange.pairingKey(withPeerPublicKey: serverPublicKey) else {
                fail(.authenticationFailed)
                return
            }
            let expected = RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
            guard RemoteCrypto.constantTimeEquals(proof, expected) else {
                fail(.authenticationFailed)
                return
            }
            RemoteKeychain.storePairingKey(key, for: deviceID.uuidString)
            establishSession(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce, deviceID: deviceID)
            return
        }

        // The Mac is showing a code; ask the user for it.
        phase = .pairing
        onStateChange?(.pairing)
        onPairingPrompt?(deviceID, targetName)
    }

    private func handleAuthResult(_ message: RemoteHandshakeMessage) {
        if let errorCode = message.errorCode {
            if errorCode == .pairingRequired {
                fail(.notPaired)
            } else {
                fail(.authenticationFailed)
            }
            return
        }
        guard let deviceID = targetDeviceID,
              let clientNonce, let serverNonce,
              let key = RemoteKeychain.pairingKey(for: deviceID.uuidString),
              let proof = message.proof else {
            fail(.notPaired)
            return
        }
        let expected = RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
        guard RemoteCrypto.constantTimeEquals(proof, expected) else {
            fail(.authenticationFailed)
            return
        }
        establishSession(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce, deviceID: deviceID)
    }

    private func establishSession(
        pairingKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        deviceID: UUID
    ) {
        sessionKey = RemoteCrypto.sessionKey(pairingKey: pairingKey, clientNonce: clientNonce, serverNonce: serverNonce)
        phase = .ready
        reportMetrics()
        onDeviceResolved?(deviceID, targetName, resolvedEndpoint)
        onStateChange?(.connected)
        startPing()
        Task { @MainActor in
            if let response = try? await self.send(.getState) {
                if let state = response.state { self.onMacState?(state) }
            }
        }
    }

    /// Phase 7 instrumentation: how long the transport took separately from the
    /// cryptographic handshake, so a slow Bonjour resolve is distinguishable
    /// from slow pairing.
    private func reportMetrics() {
        let now = Date()
        let connect = transportReadyAt.map { Int($0.timeIntervalSince(connectStartedAt ?? $0) * 1000) }
        let handshake = transportReadyAt.map { Int(now.timeIntervalSince($0) * 1000) }
        onMetrics?(connect, handshake)
    }

    private func resolvedServiceName() -> String? {
        transport?.remoteServiceName
    }

    // MARK: - Secure traffic

    private func handleSecure(_ payload: Data, key: RemoteSessionKey) {
        guard let (_, response) = try? RemoteFrameCodec.decodeSecure(RemoteResponse.self, from: payload, key: key) else {
            fail(.network("could not decode a response"))
            return
        }
        if let state = response.state { onMacState?(state) }
        guard let continuation = pendingRequests.removeValue(forKey: response.requestID) else { return }
        continuation.resume(returning: response)
    }

    // MARK: - Receive / send

    private func processBuffer() {
        guard let frames = try? RemoteFrameCodec.extractFrames(from: &buffer) else {
            fail(.network("malformed frame"))
            return
        }
        for frame in frames {
            if let key = sessionKey {
                handleSecure(frame, key: key)
            } else if let message = try? RemoteFrameCodec.decodePlain(RemoteHandshakeMessage.self, from: frame) {
                handlePlaintext(message)
            } else {
                fail(.network("malformed handshake"))
                return
            }
            if transport == nil { return }
        }
    }

    private func sendPlain(_ message: RemoteHandshakeMessage) throws {
        sendRaw(try RemoteFrameCodec.encodePlain(message))
    }

    private func sendRaw(_ data: Data) {
        transport?.send(data) { _ in }
    }

    // MARK: - Keep alive

    private func startPing() {
        cancelPing()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.phase == .ready else { return }
                let started = Date()
                if let response = try? await self.send(.ping, timeout: 5), response.success {
                    let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                    self.onLatency?(milliseconds)
                }
            }
        }
    }

    /// Ends the connection without triggering the reconnect path: the app model
    /// decides whether a failure is worth retrying.
    private func fail(_ error: RemoteConnectionError) {
        onFailure?(error)
        disconnect(report: false)
    }

    private func cancelPing() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func failPendingRequests(_ error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}
