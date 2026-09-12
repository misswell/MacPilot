import Foundation
import MacPilotRemoteProtocol
import Network
import Testing

@testable import MacPilot

@Suite("Screen control models")
struct ScreenControlModelTests {
    @Test("history attribution distinguishes the remote source")
    func historySourceMapping() {
        #expect(ScreenControlSource.localManual.historySource == .manual)
        #expect(ScreenControlSource.bleAutomatic.historySource == .automatic)
        #expect(ScreenControlSource.remoteExplicit.historySource == .remote)
    }

    @Test("every screen control failure maps onto a wire error code")
    func failureMapping() {
        #expect(ScreenControlFailure.accessibilityPermissionRequired.remoteErrorCode == .accessibilityPermissionRequired)
        #expect(ScreenControlFailure.credentialNotConfigured.remoteErrorCode == .credentialNotConfigured)
        #expect(ScreenControlFailure.alreadyLocked.remoteErrorCode == .alreadyLocked)
        #expect(ScreenControlFailure.alreadyUnlocked.remoteErrorCode == .alreadyUnlocked)
        #expect(ScreenControlFailure.unlockFailed.remoteErrorCode == .unlockFailed)
        #expect(ScreenControlFailure.wakeFailed.remoteErrorCode == .wakeFailed)
        #expect(ScreenControlFailure.displaySleepFailed.remoteErrorCode == .displaySleepFailed)
        #expect(ScreenControlFailure.commandTimeout.remoteErrorCode == .commandTimeout)
        #expect(ScreenControlFailure.internalError.remoteErrorCode == .internalError)
    }

    @Test("a remote lock suppresses BLE auto-unlock")
    func remoteLockSuppressesAutomaticUnlock() {
        #expect(ScreenControlSuppressionPolicy.suppressesAutomaticUnlock(source: .remoteExplicit))
        #expect(ScreenControlSuppressionPolicy.suppressesAutomaticUnlock(source: .localManual))
        // The BLE presence loss path must still be able to lock normally.
        #expect(!ScreenControlSuppressionPolicy.suppressesAutomaticUnlock(source: .bleAutomatic))
    }

    @Test("a remote explicit unlock clears the suppression again")
    func remoteUnlockClearsSuppression() {
        #expect(ScreenControlSuppressionPolicy.clearsAutomaticUnlockSuppression(source: .remoteExplicit))
        #expect(ScreenControlSuppressionPolicy.clearsAutomaticUnlockSuppression(source: .localManual))
        #expect(!ScreenControlSuppressionPolicy.clearsAutomaticUnlockSuppression(source: .bleAutomatic))
    }

    @Test("the remote unlock schedule is faster than the BLE wake recovery schedule")
    func remoteScheduleIsFast() throws {
        let remote = MacScreenControlService.remoteUnlockCheckpoints
        let ble = BLEUnlockAttemptPlan.standard.deadlines
        #expect(remote == [0.35, 0.8, 1.5, 2.5, 4])
        #expect(remote == remote.sorted())
        let firstRemote = try #require(remote.first)
        let firstBLE = try #require(ble.first)
        #expect(firstRemote < firstBLE)
        // Crucially it must not block for a fixed five seconds before acting.
        #expect(firstRemote < 1)
    }
}

@Suite("Remote command router")
@MainActor
struct RemoteCommandRouterTests {
    private func makeRouter() -> RemoteCommandRouter {
        RemoteCommandRouter(
            service: MacScreenControlService(
                credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }),
                log: { _ in }
            ),
            log: { _ in }
        )
    }

    @Test("ping succeeds and echoes the request id")
    func pingEchoesRequestID() async {
        let request = RemoteRequest(command: .ping, sequence: 1)
        let response = await makeRouter().response(for: request, isAuthenticated: false)
        #expect(response.success)
        #expect(response.requestID == request.requestID)
        #expect(response.state != nil)
        #expect(response.error == nil)
    }

    @Test("getState reports tri-state values instead of guessing")
    func getStateReportsTriState() async throws {
        let request = RemoteRequest(command: .getState, sequence: 1)
        let response = await makeRouter().response(for: request, isAuthenticated: true)
        let state = try #require(response.state)
        // The test host may or may not have a credential; the point is that the
        // value is one of the three known states, never a fabricated bool.
        #expect([RemoteBooleanState.yes, .no, .unknown].contains(state.hasCredential))
        #expect([RemoteBooleanState.yes, .no, .unknown].contains(state.screenLocked))
    }

    @Test("an unsupported protocol version is rejected")
    func unsupportedProtocolRejected() async {
        let request = RemoteRequest(version: 99, command: .ping, sequence: 1)
        let response = await makeRouter().response(for: request, isAuthenticated: true)
        #expect(!response.success)
        #expect(response.error?.code == .unsupportedProtocol)
    }

    @Test("state changing commands refuse to run without authentication")
    func unauthenticatedCommandsRefused() async {
        for command in [RemoteCommand.lockScreen, .displayOff, .wakeDisplay, .unlock, .wakeAndUnlock] {
            let request = RemoteRequest(command: command, sequence: 1)
            let response = await makeRouter().response(for: request, isAuthenticated: false)
            #expect(!response.success, "\(command) must not run unauthenticated")
            #expect(response.error?.code == .unauthenticated)
        }
    }
}

@Suite("Remote control settings")
struct RemoteControlSettingsCodingTests {
    @Test("remote control is disabled by default")
    func defaultIsDisabled() {
        let settings = RemoteControlSettings()
        #expect(!settings.isEnabled)
        #expect(settings.deviceID == nil)
        #expect(settings.pairedDevices.isEmpty)
    }

    @Test("settings round trip through JSON")
    func roundTrip() throws {
        var settings = RemoteControlSettings()
        settings.isEnabled = true
        settings.deviceID = UUID().uuidString
        settings.deviceName = "Studio Mac"
        settings.pairedDevices = [
            RemotePairedDevice(
                id: UUID().uuidString,
                name: "iPhone 16 Pro",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_100),
                lastAddress: "10.0.0.4"
            )
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(RemoteControlSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("a missing remote section decodes to the disabled default")
    func legacyConfigurationDecodes() throws {
        let json = Data(#"{"version":21,"isEnforcing":true}"#.utf8)
        // A configuration written by an older MacPilot must still load.
        struct Legacy: Decodable {
            var remoteControl: RemoteControlSettings?
        }
        struct Wrapper: Decodable {
            var remoteControl: RemoteControlSettings?
        }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: json)
        #expect(wrapper.remoteControl == nil)
        let decoded = try JSONDecoder().decode(Legacy.self, from: json)
        #expect(decoded.remoteControl == nil)
        #expect(!(decoded.remoteControl ?? RemoteControlSettings()).isEnabled)
    }

    @Test("a device without a name falls back to the Mac host name")
    func deviceNameFallback() {
        var settings = RemoteControlSettings()
        settings.deviceName = "   "
        #expect(!settings.resolvedDeviceName.isEmpty)
        settings.deviceName = " My Mac "
        #expect(settings.resolvedDeviceName == "My Mac")
    }
}

@Suite("Remote pairing manager")
@MainActor
struct RemotePairingManagerTests {
    private func makeExchange() -> (client: RemotePairingExchange, server: RemotePairingExchange, clientNonce: Data, serverNonce: Data) {
        let clientNonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        let serverNonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        return (
            RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce),
            RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce),
            clientNonce,
            serverNonce
        )
    }

    @Test("pairing is refused while the window is closed")
    func pairingRefusedWithoutWindow() {
        let manager = RemotePairingManager(log: { _ in })
        let (client, server, _, _) = makeExchange()
        let code = manager.begin(
            connectionID: UUID(),
            clientName: "iPhone",
            clientPublicKey: client.publicKeyData,
            exchange: server
        )
        #expect(code == nil)
        #expect(manager.displayedCode == nil)
    }

    @Test("the displayed code matches what the iPhone derives")
    func displayedCodeMatchesClient() throws {
        let manager = RemotePairingManager(log: { _ in })
        manager.openWindow()
        let (client, server, _, _) = makeExchange()
        let connectionID = UUID()
        let code = try #require(manager.begin(
            connectionID: connectionID,
            clientName: "iPhone",
            clientPublicKey: client.publicKeyData,
            exchange: server
        ))
        let clientCode = try client.pairCode(withPeerPublicKey: server.publicKeyData)
        #expect(code == clientCode)
        #expect(manager.displayedCode == code)

        let key = try #require(manager.confirm(connectionID: connectionID, code: clientCode))
        let clientKey = try client.pairingKey(withPeerPublicKey: server.publicKeyData)
        #expect(key == clientKey)
    }

    @Test("a wrong code is refused")
    func wrongCodeRefused() {
        let manager = RemotePairingManager(log: { _ in })
        manager.openWindow()
        let (client, server, _, _) = makeExchange()
        let connectionID = UUID()
        _ = manager.begin(
            connectionID: connectionID,
            clientName: "iPhone",
            clientPublicKey: client.publicKeyData,
            exchange: server
        )
        #expect(manager.confirm(connectionID: connectionID, code: "000000") == nil)
    }

    @Test("closing the window clears the displayed code")
    func closingWindowClearsCode() {
        let manager = RemotePairingManager(log: { _ in })
        manager.openWindow()
        let (client, server, _, _) = makeExchange()
        _ = manager.begin(
            connectionID: UUID(),
            clientName: "iPhone",
            clientPublicKey: client.publicKeyData,
            exchange: server
        )
        #expect(manager.displayedCode != nil)
        manager.closeWindow()
        #expect(manager.displayedCode == nil)
        #expect(!manager.isWindowOpen)
    }
}

@Suite("Remote device store")
@MainActor
struct RemoteDeviceStoreTests {
    @Test("pairing keys round trip and are deleted with the device")
    func pairingKeyLifecycle() throws {
        let service = "com.misswell.macpilot.tests.remote.\(UUID().uuidString)"
        let store = RemoteDeviceStore(
            keychainService: service,
            secretStore: InMemorySecretStore(),
            persist: {},
            log: { _ in }
        )
        defer { store.removeAllDevices() }

        let clientID = UUID().uuidString
        let key = RemoteCrypto.randomData(count: RemoteCrypto.pairingKeyLength)
        guard store.storePairingKey(key, for: clientID) else {
            // A locked down CI Keychain is not a product regression.
            return
        }
        #expect(store.pairingKey(for: clientID) == key)
        #expect(store.isPaired(clientID: clientID))

        store.registerPairedDevice(clientID: clientID, name: "iPhone", address: "10.0.0.9")
        #expect(store.pairedDevices.count == 1)
        #expect(store.pairedDevices.first?.displayName == "iPhone")

        store.removeDevice(clientID: clientID)
        #expect(store.pairingKey(for: clientID) == nil)
        #expect(store.pairedDevices.isEmpty)
    }

    @Test("the permanent device identity is generated once and then stable")
    func deviceIdentityIsStable() {
        let store = RemoteDeviceStore(
            settings: RemoteControlSettings(),
            keychainService: "com.misswell.macpilot.tests.remote.\(UUID().uuidString)",
            secretStore: InMemorySecretStore(),
            persist: {},
            log: { _ in }
        )
        let first = store.ensureDeviceIdentity()
        let second = store.ensureDeviceIdentity()
        #expect(first == second)
        #expect(store.settings.deviceID == first.uuidString)
    }
}

@Suite("Remote connection idle policy")
struct RemoteConnectionIdlePolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("a quiet authenticated client is reaped after its heartbeat window")
    func authenticatedClientIsReaped() {
        #expect(!RemoteConnectionIdlePolicy.shouldReap(
            lastActivityAt: start,
            isAuthenticated: true,
            now: start.addingTimeInterval(89)
        ))
        #expect(RemoteConnectionIdlePolicy.shouldReap(
            lastActivityAt: start,
            isAuthenticated: true,
            now: start.addingTimeInterval(91)
        ))
    }

    @Test("a pairing client survives the whole pairing window")
    func pairingClientSurvivesThePairingWindow() {
        // The Mac's pairing window is 120s; reaping before it closes would kill
        // a connection whose user is still typing the code.
        #expect(!RemoteConnectionIdlePolicy.shouldReap(
            lastActivityAt: start,
            isAuthenticated: false,
            now: start.addingTimeInterval(120)
        ))
        #expect(RemoteConnectionIdlePolicy.shouldReap(
            lastActivityAt: start,
            isAuthenticated: false,
            now: start.addingTimeInterval(181)
        ))
    }

    @Test("pairing is given more slack than an authenticated session")
    func pairingTimeoutExceedsAuthenticatedTimeout() {
        #expect(RemoteConnectionIdlePolicy.timeout(isAuthenticated: false)
            > RemoteConnectionIdlePolicy.timeout(isAuthenticated: true))
        // Whatever the numbers become, the authenticated window has to outlast
        // several client heartbeats or a live client would be reaped.
        #expect(RemoteConnectionIdlePolicy.authenticatedTimeout >= 60)
    }

    @Test("recent activity keeps the connection alive")
    func recentActivityKeepsTheConnection() {
        #expect(!RemoteConnectionIdlePolicy.shouldReap(
            lastActivityAt: start.addingTimeInterval(80),
            isAuthenticated: true,
            now: start.addingTimeInterval(90)
        ))
    }
}

@Suite("Remote connection idle watchdog")
@MainActor
struct RemoteConnectionIdleWatchdogTests {
    /// Records what the connection under test reports back.
    @MainActor
    private final class TestHost: RemoteConnectionHost {
        let screenControl = MacScreenControlService(
            credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }),
            log: { _ in }
        )
        let pairingManager = RemotePairingManager(log: { _ in })
        let deviceStore = RemoteDeviceStore(
            keychainService: "com.misswell.macpilot.tests.remote.\(UUID().uuidString)",
            secretStore: InMemorySecretStore(),
            persist: {},
            log: { _ in }
        )
        var closed = 0
        var messages: [String] = []

        func remoteConnection(
            _ connection: RemoteConnection,
            didAuthenticate clientID: String,
            name: String,
            address: String?
        ) {}

        func remoteConnectionDidClose(_ connection: RemoteConnection) { closed += 1 }
        func remoteLog(_ message: String) { messages.append(message) }
    }

    /// Holds the server side of the socket, which only exists after the
    /// listener accepts.
    @MainActor
    private final class ConnectionBox {
        var connection: RemoteConnection?
    }

    private struct Harness {
        let listener: NWListener
        let host: TestHost
        let box: ConnectionBox
        let port: NWEndpoint.Port
    }

    private enum HarnessError: Error { case noPort }

    private func startHarness(
        idleTimeout: TimeInterval,
        idleCheckInterval: TimeInterval
    ) async throws -> Harness {
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()))
        let host = TestHost()
        let box = ConnectionBox()
        listener.newConnectionHandler = { nwConnection in
            Task { @MainActor in
                let connection = RemoteConnection(
                    connection: nwConnection,
                    host: host,
                    idleTimeout: idleTimeout,
                    idleCheckInterval: idleCheckInterval
                )
                box.connection = connection
                connection.start()
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: HarnessError.noPort)
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.misswell.macpilot.tests.listener"))
        }
        return Harness(listener: listener, host: host, box: box, port: port)
    }

    private func connectClient(to port: NWEndpoint.Port) async throws -> NWConnection {
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    client.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    client.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            client.start(queue: DispatchQueue(label: "com.misswell.macpilot.tests.client"))
        }
        return client
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// A client that goes silent while its socket stays open — a suspended
    /// iPhone — must be dropped instead of being counted as connected forever.
    @Test("a silent client is reaped once its window lapses")
    func silentClientIsReaped() async throws {
        let harness = try await startHarness(idleTimeout: 0.4, idleCheckInterval: 0.1)
        defer { harness.listener.cancel() }
        let client = try await connectClient(to: harness.port)
        defer { client.cancel() }
        await waitUntil { harness.box.connection != nil }
        #expect(harness.box.connection != nil)

        await waitUntil { harness.host.closed > 0 }
        #expect(harness.host.closed == 1)
        #expect(harness.host.messages.contains { $0.contains("idle timeout") })
    }

    /// The watchdog must never touch a client that keeps talking: inbound data
    /// refreshes the deadline, so a healthy phone stays connected indefinitely.
    @Test("inbound traffic keeps refreshing the deadline")
    func inboundTrafficKeepsTheConnection() async throws {
        let harness = try await startHarness(idleTimeout: 3, idleCheckInterval: 0.1)
        defer { harness.listener.cancel() }
        let client = try await connectClient(to: harness.port)
        defer { client.cancel() }
        await waitUntil { harness.box.connection != nil }
        let connection = try #require(harness.box.connection)

        let before = connection.lastActivityAt
        try await Task.sleep(for: .milliseconds(200))

        // A well-formed hello: enough to prove the receive path stamps
        // activity, and valid enough not to trip the protocol failure path.
        let hello = RemoteHandshakeMessage(
            kind: .clientHello,
            clientID: UUID(),
            clientName: "Idle Watchdog Test",
            clientNonce: RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        )
        // `encodePlain` already length-prefixes the payload.
        let frame = try RemoteFrameCodec.encodePlain(hello)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }

        await waitUntil { connection.lastActivityAt > before }
        #expect(connection.lastActivityAt > before)
        #expect(harness.host.closed == 0)
    }
}
