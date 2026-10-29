import Foundation
import Testing
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
@testable import PilotNest

@MainActor
@Suite("Background connection authentication")
struct RemoteConnectionHandshakeTests {
    @Test(.timeLimit(.minutes(1)))
    func stalledLocalPairingSaveHasItsOwnBoundedFailureAndCannotReopenTheLink() async throws {
        let releaseSave = DispatchSemaphore(value: 0)
        let keys = RemotePairingKeyStore(load: { [:] }, save: { _, _ in
            releaseSave.wait()
            return true
        }, remove: { _ in true })
        #expect(await keys.prepare())
        let manager = RemoteConnectionManager(pairingKeys: keys, pairingSaveTimeout: .milliseconds(10))
        let transport = HandshakeTransport()
        let (events, failed) = AsyncStream<Void>.makeStream()
        manager.onFailure = { _ in failed.yield(()) }
        manager.connect(using: transport, deviceID: nil, name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone")
        try transport.receiveUnpairedHello(deviceID: UUID())
        try transport.receiveAcceptedPairing()
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        #expect(!manager.isPersistingPairing)
        #expect(!manager.isReady)
        releaseSave.signal()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!manager.isReady)
        failed.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func verifiedPairingWaitsForLocalDurabilityInsteadOfNetworkHandshakeRetry() async throws {
        let releaseSave = DispatchSemaphore(value: 0)
        let keys = RemotePairingKeyStore(load: { [:] }, save: { _, _ in
            releaseSave.wait()
            return true
        }, remove: { _ in true })
        #expect(await keys.prepare())
        let manager = RemoteConnectionManager(pairingKeys: keys)
        let transport = HandshakeTransport()
        let (events, connected) = AsyncStream<Void>.makeStream()
        manager.onStateChange = { state in
            if state == .connected { connected.yield(()) }
        }
        manager.connect(using: transport, deviceID: nil, name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone")
        try transport.receiveUnpairedHello(deviceID: UUID())
        try transport.receiveAcceptedPairing()
        #expect(manager.isPersistingPairing)
        #expect(!manager.isReady)
        let readyAt = try #require(manager.transportReadyAt)
        #expect(!manager.shouldRetry(method: .localNetwork, startedAt: readyAt,
                                    now: readyAt.addingTimeInterval(16)))
        releaseSave.signal()
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        #expect(manager.isReady)
        #expect(!manager.isPersistingPairing)
        connected.finish()
        manager.disconnect(report: false)
    }

    @Test func disconnectWhileCredentialsLoadCannotStartARetiredTransport() async {
        var release: CheckedContinuation<Bool, Never>?
        let (events, entered) = AsyncStream<Void>.makeStream()
        let manager = RemoteConnectionManager(credentialsAreReady: { false }, prepareCredentials: {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.yield(())
            }
        })
        let transport = HandshakeTransport()
        manager.connect(using: transport, deviceID: UUID(), name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone")
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        manager.disconnect(report: false)
        release?.resume(returning: true)
        entered.finish()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.startCount == 0)
        #expect(!manager.isReady)
    }

    @Test func upgradeCannotSendPairRequestWhenMacForgetsPairing() async throws {
        #expect(await RemoteKeychain.prepare())
        let transport = HandshakeTransport()
        let manager = RemoteConnectionManager()
        let deviceID = UUID()
        var failure: RemoteConnectionError?
        manager.onFailure = { failure = $0 }
        manager.connect(using: transport, deviceID: deviceID, name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone", allowsPairing: false)
        try transport.receiveUnpairedHello(deviceID: deviceID)
        #expect(failure == .notPaired)
        #expect(try transport.sentMessages().map(\.kind) == [.clientHello])
        #expect(!manager.isReady)
    }

    @Test func firstConnectionCanStillRequestPairing() async throws {
        #expect(await RemoteKeychain.prepare())
        let transport = HandshakeTransport()
        let manager = RemoteConnectionManager()
        let deviceID = UUID()
        var failure: RemoteConnectionError?
        manager.onFailure = { failure = $0 }
        manager.connect(using: transport, deviceID: deviceID, name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone", allowsPairing: true)
        try transport.receiveUnpairedHello(deviceID: deviceID)
        #expect(failure == nil)
        #expect(try transport.sentMessages().map(\.kind) == [.clientHello, .pairRequest])
        manager.disconnect(report: false)
    }
    @Test func directAddressLearnsIdentityBeforeRequestingPairing() async throws {
        #expect(await RemoteKeychain.prepare())
        let transport = HandshakeTransport()
        let manager = RemoteConnectionManager()
        var failure: RemoteConnectionError?
        manager.onFailure = { failure = $0 }
        manager.connect(using: transport, deviceID: nil, name: "100.64.0.1",
                        clientID: UUID().uuidString, clientName: "Phone", allowsPairing: true)
        try transport.receiveUnpairedHello(deviceID: UUID())
        #expect(failure == nil)
        #expect(try transport.sentMessages().map(\.kind) == [.clientHello, .pairRequest])
        manager.disconnect(report: false)
    }

    @Test func rememberedAddressRejectsAnotherMacIdentity() async throws {
        #expect(await RemoteKeychain.prepare())
        let transport = HandshakeTransport()
        let manager = RemoteConnectionManager()
        var failure: RemoteConnectionError?
        manager.onFailure = { failure = $0 }
        manager.connect(using: transport, deviceID: UUID(), name: "Mac",
                        clientID: UUID().uuidString, clientName: "Phone", allowsPairing: false)
        try transport.receiveUnpairedHello(deviceID: UUID())
        #expect(failure == .authenticationFailed)
        #expect(!manager.isReady)
    }

}

@MainActor
private final class HandshakeTransport: RemoteTransport {
    let kind: RemoteTransportKind = .network
    let linkDescription = "en0"
    var onStateChange: (@MainActor (RemoteTransportState) -> Void)?
    var onReceive: (@MainActor (Data) -> Void)?
    var remoteHost: String? { nil }
    var remotePort: UInt16? { nil }
    var remoteServiceName: String? { nil }
    private var sent = Data()
    private var serverExchange: RemotePairingExchange?
    private var serverNonce: Data?
    private(set) var startCount = 0

    func start() {
        startCount += 1
        onStateChange?(.ready)
    }
    func cancel() {}
    func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        sent.append(data)
        completion(nil)
    }
    func sentMessages() throws -> [RemoteHandshakeMessage] {
        var buffer = sent
        return try RemoteFrameCodec.extractFrames(from: &buffer).map {
            try RemoteFrameCodec.decodePlain(RemoteHandshakeMessage.self, from: $0)
        }
    }
    func receiveUnpairedHello(deviceID: UUID) throws {
        let nonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        let hello = try #require(try sentMessages().first)
        let clientNonce = try #require(hello.clientNonce)
        let exchange = RemotePairingExchange(clientNonce: clientNonce, serverNonce: nonce)
        serverExchange = exchange
        serverNonce = nonce
        onReceive?(try RemoteFrameCodec.encodePlain(RemoteHandshakeMessage(
            kind: .serverHello, deviceID: deviceID, paired: false,
            serverNonce: nonce, publicKey: exchange.publicKeyData
        )))
    }

    func receiveAcceptedPairing() throws {
        let exchange = try #require(serverExchange)
        let nonce = try #require(serverNonce)
        let messages = try sentMessages()
        let clientNonce = try #require(messages.first?.clientNonce)
        let publicKey = try #require(messages.last(where: { $0.kind == .pairRequest })?.publicKey)
        let key = try exchange.pairingKey(withPeerPublicKey: publicKey)
        let proof = RemoteCrypto.serverProof(pairingKey: key, clientNonce: clientNonce, serverNonce: nonce)
        onReceive?(try RemoteFrameCodec.encodePlain(RemoteHandshakeMessage(kind: .pairResult, proof: proof)))
    }
}

struct ManualMacAddressTests {
    @Test func acceptsRoutedAddressesAndNormalizesWhitespace() {
        #expect(ManualMacAddress(host: " 100.64.0.1 ", port: " 43847 ")?.host == "100.64.0.1")
        #expect(ManualMacAddress(host: "mac.tailnet.ts.net", port: "65535") != nil)
        #expect(ManualMacAddress(host: "[fd7a:115c:a1e0::1]", port: "1")?.host == "fd7a:115c:a1e0::1")
    }
    @Test func rejectsURLsEmbeddedPortsAndInvalidPorts() {
        for host in ["", "https://mac", "mac:43847", "mac/path", "bad host", "-mac", "mac..net"] {
            #expect(ManualMacAddress(host: host, port: "43847") == nil)
        }
        for port in ["0", "65536", "-1", "abc", ""] {
            #expect(ManualMacAddress(host: "mac", port: port) == nil)
        }
    }
    @Test func oldPairedMacStillDecodesAndKeepsManualHostname() throws {
        let old = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Mac\"}".utf8)
        var mac = try JSONDecoder().decode(PairedMac.self, from: old)
        #expect(mac.manualEndpoint == nil)
        mac.manualHost = "mac.tailnet.ts.net"
        mac.manualPort = 43847
        mac.lastHost = "192.168.1.2"
        mac.lastPort = 43847
        let roundTrip = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(mac))
        #expect(roundTrip.manualHost == "mac.tailnet.ts.net")
        #expect(roundTrip.manualEndpoint != roundTrip.rememberedEndpoint)
    }
}
