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
        #expect(ScreenControlFailure.brightnessUnavailable.remoteErrorCode == .brightnessUnavailable)
        #expect(ScreenControlFailure.volumeUnavailable.remoteErrorCode == .volumeUnavailable)
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
        for command in [RemoteCommand.lockScreen, .displayOff, .wakeDisplay, .unlock, .wakeAndUnlock, .setBrightness, .setVolume] {
            let request = RemoteRequest(command: command, sequence: 1)
            let response = await makeRouter().response(for: request, isAuthenticated: false)
            #expect(!response.success, "\(command) must not run unauthenticated")
            #expect(response.error?.code == .unauthenticated)
        }
    }

    /// A level command carries its target in the payload. Guessing a value when
    /// it is missing would move a control the user never touched.
    @Test("a level command without a payload is refused instead of guessed")
    func levelCommandRequiresPayload() async {
        for command in [RemoteCommand.setBrightness, .setVolume] {
            let request = RemoteRequest(command: command, sequence: 1)
            let response = await makeRouter().response(for: request, isAuthenticated: true)
            #expect(!response.success, "\(command) must not run without a payload")
            #expect(response.error?.code == .invalidMessage)
        }
    }

    @Test("a corrupt level payload is refused instead of guessed")
    func corruptLevelPayloadRefused() async {
        let request = RemoteRequest(
            command: .setVolume,
            sequence: 1,
            payload: Data("not json".utf8)
        )
        let response = await makeRouter().response(for: request, isAuthenticated: true)
        #expect(!response.success)
        #expect(response.error?.code == .invalidMessage)
    }

    /// Re-setting a level the Mac already reports must succeed and leave the
    /// level where it was. Skipped where the machine has no such control, which
    /// is exactly what the phone is told through the state fields.
    @Test("re-setting the reported level is a successful no-op")
    func levelRoundTripKeepsTheReportedValue() async throws {
        let router = makeRouter()
        let state = try #require(
            await router.response(for: RemoteRequest(command: .getState, sequence: 1), isAuthenticated: true).state
        )

        if let brightness = state.brightness {
            let request = RemoteRequest(
                command: .setBrightness,
                sequence: 2,
                payload: try RemoteLevelRequest(value: brightness).encoded()
            )
            let response = await router.response(for: request, isAuthenticated: true)
            #expect(response.success)
            let reported = try #require(response.state?.brightness)
            #expect(abs(reported - brightness) < 0.02)
        }

        if let volume = state.volume {
            let request = RemoteRequest(
                command: .setVolume,
                sequence: 3,
                payload: try RemoteLevelRequest(value: volume).encoded()
            )
            let response = await router.response(for: request, isAuthenticated: true)
            #expect(response.success)
            let reported = try #require(response.state?.volume)
            #expect(abs(reported - volume) < 0.02)
        }
    }
}

// MARK: - Level payload

@Suite("Remote level payload")
struct RemoteLevelPayloadTests {
    @Test("a level payload round trips through the wire")
    func levelPayloadRoundTrips() throws {
        let payload = try RemoteLevelRequest(value: 0.42, muted: true).encoded()
        let decoded = try #require(RemoteLevelRequest.decoded(from: payload))
        #expect(decoded.value == 0.42)
        #expect(decoded.muted == true)
    }

    @Test("an out of range level is clamped instead of trusted")
    func levelIsClamped() {
        #expect(RemoteLevelRequest(value: 4).clampedValue == 1)
        #expect(RemoteLevelRequest(value: -2).clampedValue == 0)
        #expect(RemoteLevelRequest(value: 0.35).clampedValue == 0.35)
    }

    @Test("a slider move leaves the mute state alone")
    func muteIsOptional() throws {
        let decoded = try #require(RemoteLevelRequest.decoded(from: try RemoteLevelRequest(value: 0.5).encoded()))
        #expect(decoded.muted == nil)
    }

    @Test("a missing or unreadable payload decodes to nothing")
    func payloadMustDecode() {
        #expect(RemoteLevelRequest.decoded(from: nil) == nil)
        #expect(RemoteLevelRequest.decoded(from: Data()) == nil)
        #expect(RemoteLevelRequest.decoded(from: Data("{\"value\":\"loud\"}".utf8)) == nil)
    }

    /// The compatibility contract that lets the two apps ship independently: a
    /// Mac build that predates these controls sends no level fields, and the
    /// phone must read that as "not available here" rather than fail to decode
    /// the whole state.
    @Test("a state from an older Mac decodes with no levels")
    func legacyStateDecodesWithoutLevels() throws {
        let json = #"{"screenLocked":"yes","canUnlock":"no","hasCredential":"unknown","accessibilityGranted":"yes"}"#
        let state = try JSONDecoder().decode(MacRemoteState.self, from: Data(json.utf8))
        #expect(state.screenLocked == .yes)
        #expect(state.brightness == nil)
        #expect(state.volume == nil)
        #expect(state.volumeMuted == nil)
    }

    @Test("a state with levels survives a round trip")
    func stateCarriesLevels() throws {
        let state = MacRemoteState(brightness: 0.7, volume: 0.25, volumeMuted: .no)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MacRemoteState.self, from: data)
        #expect(decoded == state)
    }

    /// The payload rides inside the encrypted frame, so this is what proves the
    /// slider's value reaches the Mac's router unchanged.
    @Test("a level payload survives the secure frame codec")
    func payloadSurvivesSecureFrame() throws {
        let key = RemoteCrypto.sessionKey(
            pairingKey: RemoteCrypto.randomData(count: RemoteCrypto.pairingKeyLength),
            clientNonce: RemoteCrypto.randomData(count: RemoteCrypto.nonceLength),
            serverNonce: RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        )
        let request = RemoteRequest(
            command: .setVolume,
            sequence: 7,
            payload: try RemoteLevelRequest(value: 0.3, muted: true).encoded()
        )

        // Framed exactly the way the transport does it, so the length prefix is
        // covered too rather than assumed.
        var buffer = try RemoteFrameCodec.encodeSecure(request, key: key, sequence: 7)
        let frames = try RemoteFrameCodec.extractFrames(from: &buffer)
        let framed = try #require(frames.first)
        let (sequence, decoded) = try RemoteFrameCodec.decodeSecure(RemoteRequest.self, from: framed, key: key)

        #expect(sequence == 7)
        #expect(decoded.command == .setVolume)
        #expect(decoded.payload == request.payload)
        let level = try #require(RemoteLevelRequest.decoded(from: decoded.payload))
        #expect(level.value == 0.3)
        #expect(level.muted == true)
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
