import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network
import Testing
@testable import PilotNest

/// An in-process stand-in for the Mac: accepts TCP, speaks the pairing and
/// authentication handshake and answers every secure request. Pairing completes
/// without user interaction by returning the server proof immediately — the
/// six digit code is only a human channel; the proof is what the phone verifies.
@MainActor
final class MockMacServer {
    let deviceID = UUID()
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    /// clientID -> long term pairing key, so reconnects can authenticate.
    private var pairedKeys: [String: Data] = [:]
    private var clients: [UUID: MockClient] = [:]
    /// Every handshake and close, in order, for failure diagnostics.
    private(set) var events: [String] = []

    private final class MockClient {
        let transport: NetworkRemoteTransport
        var buffer = Data()
        var clientID: String?
        var clientNonce: Data?
        var serverNonce: Data?
        var exchange: RemotePairingExchange?
        var sessionKey: RemoteSessionKey?
        var sentSequence: UInt64 = 0

        init(transport: NetworkRemoteTransport) {
            self.transport = transport
        }
    }

    func start() async throws {
        let listener = try NWListener(using: NWParameters.tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.misswell.macpilot.remote.mock-mac"))
        }
        guard port > 0 else {
            throw MockServerError.noPort
        }
        self.listener = listener
        self.port = port
        log("listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients.values {
            client.transport.cancel()
        }
        clients.removeAll()
    }

    enum MockServerError: Error {
        case noPort
    }

    private func accept(_ connection: NWConnection) {
        let transport = NetworkRemoteTransport(connection: connection)
        let id = UUID()
        let client = MockClient(transport: transport)
        clients[id] = client
        transport.onReceive = { [weak self] data in
            guard let self else { return }
            self.receive(data, client: client, id: id)
        }
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("connection ready")
            case .failed(let reason):
                self.log("connection failed: \(reason)")
                self.clients.removeValue(forKey: id)
            case .closed:
                self.log("connection closed")
                self.clients.removeValue(forKey: id)
            default:
                break
            }
        }
        log("incoming connection")
        transport.start()
    }

    private func receive(_ data: Data, client: MockClient, id: UUID) {
        client.buffer.append(data)
        guard let frames = try? RemoteFrameCodec.extractFrames(from: &client.buffer) else {
            log("malformed frame stream")
            close(id)
            return
        }
        for frame in frames {
            if let key = client.sessionKey {
                handleSecure(frame, key: key, client: client, id: id)
            } else if let message = try? RemoteFrameCodec.decodePlain(RemoteHandshakeMessage.self, from: frame) {
                handleHandshake(message, client: client, id: id)
            } else {
                log("undecodable plaintext frame")
                close(id)
                return
            }
        }
    }

    private func handleHandshake(_ message: RemoteHandshakeMessage, client: MockClient, id: UUID) {
        switch message.kind {
        case .clientHello:
            client.clientID = message.clientID?.uuidString
            client.clientNonce = message.clientNonce
            let nonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
            client.serverNonce = nonce
            let paired = client.clientID.map { pairedKeys[$0] != nil } ?? false
            var reply = RemoteHandshakeMessage(
                kind: .serverHello,
                deviceID: deviceID,
                deviceName: "MockMac",
                paired: paired,
                serverNonce: nonce,
                capabilities: [.lock, .displayOff, .wake, .unlock, .realtimeInput, .inputPressure, .inputPressureStream, .dockGroups]
            )
            if !paired {
                let exchange = RemotePairingExchange(
                    clientNonce: message.clientNonce ?? Data(),
                    serverNonce: nonce
                )
                client.exchange = exchange
                reply.publicKey = exchange.publicKeyData
            }
            log("clientHello client=\(client.clientID ?? "?") paired=\(paired)")
            sendPlain(reply, client)
        case .pairRequest:
            guard let exchange = client.exchange,
                  let publicKey = message.publicKey,
                  let key = try? exchange.pairingKey(withPeerPublicKey: publicKey),
                  let clientID = client.clientID,
                  let clientNonce = client.clientNonce,
                  let serverNonce = client.serverNonce else {
                log("pairRequest rejected")
                close(id)
                return
            }
            pairedKeys[clientID] = key
            client.sessionKey = RemoteCrypto.sessionKey(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
            sendPlain(RemoteHandshakeMessage(
                kind: .pairResult,
                proof: RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
            ), client)
            log("pairing completed client=\(clientID)")
        case .authRequest:
            guard let clientID = client.clientID,
                  let key = pairedKeys[clientID],
                  let clientNonce = client.clientNonce,
                  let serverNonce = client.serverNonce else {
                log("auth rejected: no stored key")
                sendPlain(RemoteHandshakeMessage(kind: .authResult, errorCode: .pairingRequired), client)
                return
            }
            guard let proof = message.proof,
                  RemoteCrypto.constantTimeEquals(proof, RemoteCrypto.clientProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)) else {
                log("auth rejected: badProof")
                sendPlain(RemoteHandshakeMessage(kind: .authResult, errorCode: .unauthenticated), client)
                return
            }
            client.sessionKey = RemoteCrypto.sessionKey(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
            sendPlain(RemoteHandshakeMessage(
                kind: .authResult,
                proof: RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce)
            ), client)
            log("auth completed client=\(clientID)")
        default:
            log("unexpected handshake message \(message.kind)")
            close(id)
        }
    }

    private func handleSecure(_ payload: Data, key: RemoteSessionKey, client: MockClient, id: UUID) {
        guard let (_, request) = try? RemoteFrameCodec.decodeSecure(RemoteRequest.self, from: payload, key: key) else {
            log("undecodable secure frame")
            close(id)
            return
        }
        let response = RemoteResponse(requestID: request.requestID, success: true)
        client.sentSequence &+= 1
        guard let frame = try? RemoteFrameCodec.encodeSecure(response, key: key, sequence: client.sentSequence) else {
            return
        }
        client.transport.send(frame) { _ in }
    }

    private func sendPlain(_ message: RemoteHandshakeMessage, _ client: MockClient) {
        guard let frame = try? RemoteFrameCodec.encodePlain(message) else { return }
        client.transport.send(frame) { _ in }
    }

    private func close(_ id: UUID) {
        clients[id]?.transport.cancel()
        clients.removeValue(forKey: id)
    }

    private func log(_ message: String) {
        events.append(String(format: "%.2f", ProcessInfo.processInfo.systemUptime) + " " + message)
    }
}

@MainActor
@Suite("Remote reconnect lifecycle")
struct RemoteReconnectLifecycleTests {

    @Test func reconnectsAfterBackgroundAndForeground() async throws {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PairedMacStore(defaults: defaults)

        let server = MockMacServer()
        try await server.start()
        defer { server.stop() }


        store.upsert(PairedMac(
            id: server.deviceID.uuidString,
            name: "MockMac",
            lastServiceName: nil,
            lastHost: "127.0.0.1",
            lastPort: server.port,
            lastConnectedAt: nil
        ))
        store.preferredMacID = server.deviceID.uuidString

        let model = RemoteAppModel(store: store, pairingKeys: RemotePairingKeyStore(
            load: { [:] }, save: { _, _ in true }, remove: { _ in true }
        ))
        await model.start()

        // First connect pairs against the mock without any user interaction.
        try await waitForConnected(model, timeout: 15, server: server, stage: "initial connect")

        // Background then foreground, the exact lifecycle the reconnect bug
        // rides on.
        model.handleScenePhase(.background)
        try await Task.sleep(for: .seconds(1))
        model.handleScenePhase(.active)

        try await waitForConnected(model, timeout: 20, server: server, stage: "reconnect after foreground")
    }

    @Test func manualAddressPairsAndReconnectsAfterLanAddressChanges() async throws {
        let suiteName = "manual-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PairedMacStore(defaults: defaults)
        let server = MockMacServer()
        try await server.start()
        defer { server.stop() }
        let model = RemoteAppModel(store: store, pairingKeys: RemotePairingKeyStore(
            load: { [:] }, save: { _, _ in true }, remove: { _ in true }
        ))
        await model.start()
        let address = try #require(ManualMacAddress(host: "localhost", port: String(server.port)))
        model.connect(to: address)
        try await waitForConnected(model, timeout: 15, server: server, stage: "manual pairing")
        var mac = try #require(store.mac(id: server.deviceID))
        #expect(mac.manualHost == "localhost")
        #expect(mac.manualPort == server.port)
        #expect(store.preferredMacID == server.deviceID.uuidString)
        model.handleScenePhase(.background)
        mac.lastHost = "127.0.0.2"
        store.upsert(mac)
        model.handleScenePhase(.active)
        try await waitForConnected(model, timeout: 15, server: server, stage: "manual reconnect")
        #expect(store.mac(id: server.deviceID)?.manualHost == "localhost")
        model.handleScenePhase(.background)
    }

    /// Fails once `connectionState` has not reached `.connected` in time, and
    /// dumps both the phone's race trace and the mock Mac's wire log so the
    /// stalled stage is visible without a debugger.
    private func waitForConnected(
        _ model: RemoteAppModel,
        timeout: TimeInterval,
        server: MockMacServer,
        stage: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.connectionState.isConnected { return }
            try await Task.sleep(for: .seconds(0.2))
        }
        Issue.record("""
        \(stage) did not reach .connected (state: \(model.connectionState), errorKey: \(model.errorKey ?? "none"))
        --- phone race trace ---
        \(model.linkDiagnostics.joined(separator: "\n"))
        --- mock Mac wire log ---
        \(server.events.joined(separator: "\n"))
        """)
    }
}
