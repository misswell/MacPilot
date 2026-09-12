import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network

/// Delegate used by `RemoteConnection` to reach the server without holding a
/// strong reference to it.
@MainActor
protocol RemoteConnectionHost: AnyObject {
    var screenControl: MacScreenControlService { get }
    var pairingManager: RemotePairingManager { get }
    var deviceStore: RemoteDeviceStore { get }

    func remoteConnection(
        _ connection: RemoteConnection,
        didAuthenticate clientID: String,
        name: String,
        address: String?
    )
    func remoteConnectionDidClose(_ connection: RemoteConnection)
    func remoteLog(_ message: String)
}

/// One iPhone <-> Mac TCP connection: length prefixed framing, the pairing and
/// authentication handshake, ChaChaPoly sealed command traffic and replay
/// protection.
@MainActor
final class RemoteConnection: Identifiable {
    let id = UUID()

    /// Serial queue for the whole server. Network callbacks hop back to the main
    /// actor, so only the raw socket work lives here.
    static let queue = DispatchQueue(label: "com.misswell.macpilot.remote.control")

    private let transport: RemoteTransport
    private weak var host: RemoteConnectionHost?
    private let router: RemoteCommandRouter

    private var buffer = Data()
    private var sessionKey: RemoteSessionKey?
    private var replayGuard = RemoteReplayGuard()

    private var clientID: String?
    private var clientName: String?
    private var clientNonce: Data?
    private var serverNonce: Data?
    private var pairingExchange: RemotePairingExchange?

    private(set) var isAuthenticated = false
    private(set) var authenticatedClientName: String?
    private(set) var isClosed = false
    private(set) var remoteAddress: String?

    private var sentSequence: UInt64 = 0
    private var handshakeStartedAt: Date?
    private var pendingFrames: [Data] = []
    private var isDraining = false

    /// Last time any byte arrived from this client. Outbound traffic does not
    /// count: the point is to notice a client that stopped talking.
    private(set) var lastActivityAt = Date()
    private var idleWatchdog: Task<Void, Never>?

    /// Test seams: the defaults come from `RemoteConnectionIdlePolicy`, and
    /// overriding them lets a test exercise the watchdog without waiting out a
    /// real heartbeat window.
    private let idleTimeoutOverride: TimeInterval?
    private let idleCheckInterval: TimeInterval

    private static let defaultIdleCheckInterval: TimeInterval = 15

    /// Every client — TCP over Wi-Fi/AWDL or BLE L2CAP — arrives as a byte
    /// stream, so only the transport differs below this line.
    init(
        transport: RemoteTransport,
        host: RemoteConnectionHost,
        idleTimeout: TimeInterval? = nil,
        idleCheckInterval: TimeInterval? = nil
    ) {
        self.transport = transport
        self.host = host
        self.router = RemoteCommandRouter(service: host.screenControl, log: host.remoteLog)
        self.remoteAddress = transport.remoteHost
        self.idleTimeoutOverride = idleTimeout
        self.idleCheckInterval = idleCheckInterval ?? Self.defaultIdleCheckInterval
    }

    convenience init(
        connection: NWConnection,
        host: RemoteConnectionHost,
        idleTimeout: TimeInterval? = nil,
        idleCheckInterval: TimeInterval? = nil
    ) {
        self.init(
            transport: NetworkRemoteTransport(connection: connection),
            host: host,
            idleTimeout: idleTimeout,
            idleCheckInterval: idleCheckInterval
        )
    }

    /// Which link carries this client, for the connection list in Settings.
    var transportKind: RemoteTransportKind { transport.kind }

    var linkDescription: String { transport.linkDescription }

    private var effectiveIdleTimeout: TimeInterval {
        idleTimeoutOverride ?? RemoteConnectionIdlePolicy.timeout(isAuthenticated: isAuthenticated)
    }

    // MARK: - Lifecycle

    func start() {
        transport.onStateChange = { [weak self] state in self?.handleTransportState(state) }
        transport.onReceive = { [weak self] data in
            guard let self, !self.isClosed else { return }
            self.lastActivityAt = Date()
            self.buffer.append(data)
            self.processBuffer()
        }
        transport.start()
        startIdleWatchdog()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        idleWatchdog?.cancel()
        idleWatchdog = nil
        transport.onStateChange = nil
        transport.onReceive = nil
        transport.cancel()
        host?.remoteConnectionDidClose(self)
    }

    /// Reaps a client whose app stopped talking while its socket stayed open.
    /// A suspended iPhone holds the connection `ESTABLISHED` indefinitely, so
    /// without this the Mac counts a frozen phone as connected forever and
    /// accumulates one such socket per app launch.
    private func startIdleWatchdog() {
        idleWatchdog?.cancel()
        let interval = idleCheckInterval
        idleWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !self.isClosed else { return }
                guard RemoteConnectionIdlePolicy.shouldReap(
                    lastActivityAt: self.lastActivityAt,
                    timeout: self.effectiveIdleTimeout
                ) else { continue }
                self.host?.remoteLog("connection idle timeout; closing silent client")
                self.close()
                return
            }
        }
    }

    private func handleTransportState(_ state: RemoteTransportState) {
        switch state {
        case .ready:
            host?.remoteLog("connection ready kind=\(transport.kind.rawValue) link=\(transport.linkDescription)")
        case let .failed(reason):
            host?.remoteLog("connection failed error=\(reason)")
            close()
        case .closed:
            if !isClosed {
                isClosed = true
                host?.remoteConnectionDidClose(self)
            }
        case .connecting, .waiting:
            break
        }
    }

    // MARK: - Framing

    private func processBuffer() {
        do {
            let frames = try RemoteFrameCodec.extractFrames(from: &buffer)
            enqueue(frames)
        } catch let error as RemoteProtocolError {
            Task { await fail(error) }
        } catch {
            Task { await fail(.invalidMessage) }
        }
    }

    /// Commands must run one at a time and in arrival order.
    private func enqueue(_ frames: [Data]) {
        guard !frames.isEmpty else { return }
        pendingFrames.append(contentsOf: frames)
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingFrames.isEmpty, !self.isClosed {
                let frame = self.pendingFrames.removeFirst()
                await self.handleFrame(frame)
            }
            self.isDraining = false
        }
    }

    private func handleFrame(_ payload: Data) async {
        do {
            if let key = sessionKey {
                try await handleSecure(payload, key: key)
            } else {
                try await handlePlaintext(payload)
            }
        } catch let error as RemoteProtocolError {
            await fail(error)
        } catch {
            await fail(.invalidMessage)
        }
    }

    // MARK: - Handshake

    private func handlePlaintext(_ payload: Data) async throws {
        let message = try RemoteFrameCodec.decodePlain(RemoteHandshakeMessage.self, from: payload)
        switch message.kind {
        case .clientHello: try handleClientHello(message)
        case .pairRequest: try handlePairRequest(message)
        case .pairConfirm: try handlePairConfirm(message)
        case .authRequest: try handleAuthRequest(message)
        default: throw RemoteProtocolError.invalidMessage
        }
    }

    private func handleClientHello(_ message: RemoteHandshakeMessage) throws {
        guard message.protocolVersion == RemoteProtocolVersion.current else {
            host?.remoteLog("handshake rejected reason=unsupportedProtocol version=\(message.protocolVersion)")
            try sendPlain(RemoteHandshakeMessage(
                kind: .failure,
                errorCode: .unsupportedProtocol,
                errorMessage: "MacPilot speaks protocol \(RemoteProtocolVersion.current)"
            ))
            close()
            throw RemoteProtocolError.unsupportedProtocol(message.protocolVersion)
        }
        guard let host, let incomingClientID = message.clientID, let nonce = message.clientNonce else {
            throw RemoteProtocolError.invalidMessage
        }

        clientID = incomingClientID.uuidString
        clientName = message.clientName ?? "iPhone"
        clientNonce = nonce
        if handshakeStartedAt == nil { handshakeStartedAt = Date() }
        let serverNonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        self.serverNonce = serverNonce

        let paired = host.deviceStore.isPaired(clientID: incomingClientID.uuidString)
        var reply = RemoteHandshakeMessage(
            kind: .serverHello,
            deviceID: host.deviceStore.deviceID,
            deviceName: host.deviceStore.deviceName,
            paired: paired,
            serverNonce: serverNonce,
            capabilities: [.lock, .displayOff, .wake, .unlock]
        )
        if !paired {
            let exchange = RemotePairingExchange(clientNonce: nonce, serverNonce: serverNonce)
            pairingExchange = exchange
            reply.publicKey = exchange.publicKeyData
        }
        host.remoteLog("client hello name=\(clientName ?? "?") paired=\(paired)")
        try sendPlain(reply)
    }

    private func handlePairRequest(_ message: RemoteHandshakeMessage) throws {
        guard let host, let exchange = pairingExchange else {
            throw RemoteProtocolError.invalidMessage
        }
        guard let clientPublicKey = message.publicKey else {
            throw RemoteProtocolError.invalidMessage
        }
        guard let code = host.pairingManager.begin(
            connectionID: id,
            clientName: clientName ?? "iPhone",
            clientPublicKey: clientPublicKey,
            exchange: exchange
        ) else {
            try sendPlain(RemoteHandshakeMessage(
                kind: .pairResult,
                errorCode: .pairingRequired,
                errorMessage: "Open the pairing window in MacPilot first."
            ))
            return
        }
        host.remoteLog("pairing code displayed digits=\(code.count)")
        // The Mac shows the code; the iPhone now prompts the user for it.
        try sendPlain(RemoteHandshakeMessage(kind: .pairResult))
    }

    private func handlePairConfirm(_ message: RemoteHandshakeMessage) throws {
        guard let host, let clientID, let clientNonce, let serverNonce else {
            throw RemoteProtocolError.invalidMessage
        }
        guard let key = host.pairingManager.confirm(connectionID: id, code: message.pairCode ?? "") else {
            try sendPlain(RemoteHandshakeMessage(
                kind: .pairResult,
                errorCode: .pairingRequired,
                errorMessage: "That code did not match."
            ))
            return
        }
        guard host.deviceStore.storePairingKey(key, for: clientID) else {
            throw RemoteProtocolError.internalError
        }
        host.deviceStore.registerPairedDevice(
            clientID: clientID,
            name: clientName ?? "iPhone",
            address: remoteAddress
        )

        sessionKey = RemoteCrypto.sessionKey(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
        isAuthenticated = true
        authenticatedClientName = clientName ?? "iPhone"
        logHandshakeLatency(event: "pairing")
        try sendPlain(RemoteHandshakeMessage(
            kind: .pairResult,
            proof: RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
        ))
        host.remoteConnection(self, didAuthenticate: clientID, name: clientName ?? "iPhone", address: remoteAddress)
    }

    private func handleAuthRequest(_ message: RemoteHandshakeMessage) throws {
        guard let host, let clientID, let clientNonce, let serverNonce else {
            throw RemoteProtocolError.invalidMessage
        }
        guard let key = host.deviceStore.pairingKey(for: clientID) else {
            host.remoteLog("auth rejected reason=pairingRequired")
            try sendPlain(RemoteHandshakeMessage(kind: .authResult, errorCode: .pairingRequired))
            close()
            throw RemoteProtocolError.notPaired
        }
        let expected = RemoteCrypto.clientProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
        guard let proof = message.proof, RemoteCrypto.constantTimeEquals(proof, expected) else {
            host.remoteLog("auth rejected reason=badProof")
            try sendPlain(RemoteHandshakeMessage(kind: .authResult, errorCode: .unauthenticated))
            close()
            throw RemoteProtocolError.authenticationFailed
        }

        sessionKey = RemoteCrypto.sessionKey(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
        isAuthenticated = true
        authenticatedClientName = clientName ?? "iPhone"
        host.deviceStore.markConnected(clientID: clientID, address: remoteAddress)
        logHandshakeLatency(event: "auth")
        try sendPlain(RemoteHandshakeMessage(
            kind: .authResult,
            proof: RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
        ))
        host.remoteConnection(self, didAuthenticate: clientID, name: clientName ?? "iPhone", address: remoteAddress)
    }

    /// Phase 7 instrumentation: how long the round trips before the session key
    /// was agreed actually took.
    private func logHandshakeLatency(event: String) {
        guard let handshakeStartedAt else { return }
        let milliseconds = Int(Date().timeIntervalSince(handshakeStartedAt) * 1000)
        host?.remoteLog("handshake complete event=\(event) latency=\(milliseconds)ms")
    }

    // MARK: - Secure traffic

    private func handleSecure(_ payload: Data, key: RemoteSessionKey) async throws {
        let (sequence, request) = try RemoteFrameCodec.decodeSecure(RemoteRequest.self, from: payload, key: key)
        do {
            try replayGuard.accept(sequence: sequence, timestampMilliseconds: request.timestamp)
        } catch {
            host?.remoteLog("frame rejected reason=replayOrStale command=\(request.command.rawValue)")
            throw RemoteProtocolError.replayDetected
        }
        host?.remoteLog("command received command=\(request.command.rawValue) requestID=\(request.requestID.uuidString)")
        let response = await router.response(for: request, isAuthenticated: isAuthenticated)
        try sendSecure(response, key: key)
    }

    // MARK: - Sending

    private func sendPlain(_ message: RemoteHandshakeMessage) throws {
        let data = try RemoteFrameCodec.encodePlain(message)
        send(data)
    }

    private func sendSecure(_ response: RemoteResponse, key: RemoteSessionKey) throws {
        sentSequence &+= 1
        let data = try RemoteFrameCodec.encodeSecure(response, key: key, sequence: sentSequence)
        send(data)
    }

    private func send(_ data: Data) {
        guard !isClosed else { return }
        transport.send(data) { [weak self] error in
            guard let error else { return }
            self?.host?.remoteLog("send failed error=\(error.localizedDescription)")
            self?.close()
        }
    }

    private func fail(_ error: RemoteProtocolError) async {
        host?.remoteLog("protocol failure code=\(error.code.rawValue)")
        if sessionKey == nil {
            try? sendPlain(RemoteHandshakeMessage(
                kind: .failure,
                errorCode: error.code,
                errorMessage: "MacPilot rejected the request."
            ))
        }
        close()
    }
}
