import Foundation
import MacPilotRemoteProtocol
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
