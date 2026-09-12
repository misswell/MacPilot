import CryptoKit
import Foundation
import Testing

@testable import MacPilotRemoteProtocol

@Suite("Remote protocol framing")
struct RemoteFrameCodecTests {
    @Test("request and response round trip through the plaintext codec")
    func requestRoundTrips() throws {
        let request = RemoteRequest(command: .unlock, sequence: 7, payload: Data([1, 2, 3]))
        let framed = try RemoteFrameCodec.encodePlain(request)
        var buffer = framed
        let frames = try RemoteFrameCodec.extractFrames(from: &buffer)
        #expect(frames.count == 1)
        #expect(buffer.isEmpty)
        let decoded = try RemoteFrameCodec.decodePlain(RemoteRequest.self, from: frames[0])
        #expect(decoded == request)
    }

    @Test("partial frames stay buffered until the payload arrives")
    func partialFrameIsBuffered() throws {
        let framed = try RemoteFrameCodec.encodePlain(RemoteHandshakeMessage(kind: .clientHello))
        var buffer = framed.prefix(framed.count - 1)
        #expect(try RemoteFrameCodec.extractFrames(from: &buffer).isEmpty)
        buffer.append(framed.last!)
        #expect(try RemoteFrameCodec.extractFrames(from: &buffer).count == 1)
    }

    @Test("two frames in one read are split")
    func multipleFramesAreSplit() throws {
        var buffer = try RemoteFrameCodec.encodePlain(RemoteHandshakeMessage(kind: .clientHello))
        buffer.append(try RemoteFrameCodec.encodePlain(RemoteHandshakeMessage(kind: .authRequest)))
        let frames = try RemoteFrameCodec.extractFrames(from: &buffer)
        #expect(frames.count == 2)
        #expect(buffer.isEmpty)
    }

    @Test("an oversized length prefix is rejected instead of buffered")
    func oversizedFrameIsRejected() {
        var buffer = Data([0x7F, 0xFF, 0xFF, 0xFF, 0x00])
        #expect(throws: RemoteProtocolError.oversizedFrame) {
            _ = try RemoteFrameCodec.extractFrames(from: &buffer)
        }
    }

    @Test("a frame with the wrong tag fails to decode")
    func malformedFrameIsRejected() throws {
        var buffer = Data([0x09, 0x09])
        let framed = RemoteFrameCodec.frame(buffer)
        buffer = framed
        let frames = try RemoteFrameCodec.extractFrames(from: &buffer)
        #expect(throws: RemoteProtocolError.malformedFrame) {
            _ = try RemoteFrameCodec.decodePlain(RemoteHandshakeMessage.self, from: frames[0])
        }
    }

    @Test("unknown command names fail with a decode error")
    func unknownCommandIsRejected() throws {
        let json = Data(#"{"version":1,"requestID":"5C4A0E8B-0000-4000-8000-000000000000","command":"selfDestruct","timestamp":0,"sequence":1}"#.utf8)
        var payload = Data([RemoteFrameCodec.plaintextTag])
        payload.append(json)
        #expect(throws: RemoteProtocolError.invalidMessage) {
            _ = try RemoteFrameCodec.decodePlain(RemoteRequest.self, from: payload)
        }
    }
}

@Suite("Remote crypto")
struct RemoteCryptoTests {
    private func makeKey(_ byte: UInt8 = 1) -> RemoteSessionKey {
        RemoteSessionKey(rawBytes: Data(repeating: byte, count: 32))
    }

    @Test("a sealed frame opens with the matching key and sequence")
    func sealRoundTrip() throws {
        let key = makeKey()
        let message = RemoteRequest(command: .lockScreen, sequence: 3)
        let framed = try RemoteFrameCodec.encodeSecure(message, key: key, sequence: 3)
        var buffer = framed
        let payload = try #require(try RemoteFrameCodec.extractFrames(from: &buffer).first)
        let (sequence, decoded) = try RemoteFrameCodec.decodeSecure(RemoteRequest.self, from: payload, key: key)
        #expect(sequence == 3)
        #expect(decoded == message)
    }

    @Test("a different key cannot open the frame")
    func wrongKeyFails() throws {
        let framed = try RemoteFrameCodec.encodeSecure(
            RemoteRequest(command: .unlock, sequence: 1),
            key: makeKey(1),
            sequence: 1
        )
        var buffer = framed
        let payload = try #require(try RemoteFrameCodec.extractFrames(from: &buffer).first)
        #expect(throws: RemoteProtocolError.decryptionFailed) {
            _ = try RemoteFrameCodec.decodeSecure(RemoteRequest.self, from: payload, key: makeKey(2))
        }
    }

    @Test("a modified ciphertext is rejected by the authentication tag")
    func modifiedCiphertextFails() throws {
        let key = makeKey()
        var framed = try RemoteFrameCodec.encodeSecure(
            RemoteRequest(command: .unlock, sequence: 1),
            key: key,
            sequence: 1
        )
        // Flip a byte inside the sealed box, past the length prefix and tags.
        framed[framed.count - 4] ^= 0xFF
        var buffer = framed
        let payload = try #require(try RemoteFrameCodec.extractFrames(from: &buffer).first)
        #expect(throws: RemoteProtocolError.decryptionFailed) {
            _ = try RemoteFrameCodec.decodeSecure(RemoteRequest.self, from: payload, key: key)
        }
    }

    @Test("session keys differ per nonce pair")
    func sessionKeyDependsOnNonces() {
        let pairingKey = Data(repeating: 9, count: 32)
        let first = RemoteCrypto.sessionKey(pairingKey: pairingKey, clientNonce: Data([1]), serverNonce: Data([2]))
        let second = RemoteCrypto.sessionKey(pairingKey: pairingKey, clientNonce: Data([1]), serverNonce: Data([3]))
        #expect(first != second)
    }

    @Test("constant time comparison matches Data equality")
    func constantTimeComparison() {
        #expect(RemoteCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!RemoteCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!RemoteCrypto.constantTimeEquals(Data([1, 2]), Data([1, 2, 3])))
    }
}

@Suite("Remote replay protection")
struct RemoteReplayProtectionTests {
    @Test("a repeated sequence is rejected")
    func duplicateSequenceRejected() throws {
        var guardrail = RemoteReplayGuard()
        let now = Date()
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        try guardrail.accept(sequence: 1, timestampMilliseconds: stamp, now: now)
        #expect(throws: RemoteReplayGuard.Rejection.replayedSequence) {
            try guardrail.accept(sequence: 1, timestampMilliseconds: stamp, now: now)
        }
    }

    @Test("a lower sequence arriving after a higher one is rejected")
    func outOfOrderRejected() throws {
        var guardrail = RemoteReplayGuard()
        let now = Date()
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        try guardrail.accept(sequence: 10, timestampMilliseconds: stamp, now: now)
        #expect(throws: RemoteReplayGuard.Rejection.replayedSequence) {
            try guardrail.accept(sequence: 9, timestampMilliseconds: stamp, now: now)
        }
    }

    @Test("a stale timestamp is rejected")
    func expiredMessageRejected() {
        var guardrail = RemoteReplayGuard(maximumClockSkew: 30)
        let now = Date()
        let stale = Int64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        #expect(throws: RemoteReplayGuard.Rejection.staleTimestamp) {
            try guardrail.accept(sequence: 1, timestampMilliseconds: stale, now: now)
        }
    }

    @Test("a fresh increasing sequence is accepted")
    func freshSequenceAccepted() throws {
        var guardrail = RemoteReplayGuard()
        let now = Date()
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        try guardrail.accept(sequence: 1, timestampMilliseconds: stamp, now: now)
        try guardrail.accept(sequence: 2, timestampMilliseconds: stamp, now: now)
        #expect(guardrail.lastAcceptedSequence == 2)
    }
}

@Suite("Remote pairing")
struct RemotePairingTests {
    @Test("both peers derive the same code and pairing key")
    func bothPeersAgree() throws {
        let clientNonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        let serverNonce = RemoteCrypto.randomData(count: RemoteCrypto.nonceLength)
        let client = RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce)
        let server = RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce)

        let clientCode = try client.pairCode(withPeerPublicKey: server.publicKeyData)
        let serverCode = try server.pairCode(withPeerPublicKey: client.publicKeyData)
        #expect(clientCode == serverCode)
        #expect(clientCode.count == 6)
        #expect(Int(clientCode) != nil)

        let clientKey = try client.pairingKey(withPeerPublicKey: server.publicKeyData)
        let serverKey = try server.pairingKey(withPeerPublicKey: client.publicKeyData)
        #expect(clientKey == serverKey)
        #expect(clientKey.count == RemoteCrypto.pairingKeyLength)
        // The long term key must not be the confirmation code.
        #expect(clientKey != Data(clientCode.utf8))
    }

    @Test("a third party derives a different code")
    func manInTheMiddleSeesDifferentCode() throws {
        let clientNonce = RemoteCrypto.randomData(count: 8)
        let serverNonce = RemoteCrypto.randomData(count: 8)
        let client = RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce)
        let server = RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce)
        let attacker = RemotePairingExchange(clientNonce: clientNonce, serverNonce: serverNonce)

        let clientCode = try client.pairCode(withPeerPublicKey: server.publicKeyData)
        let attackerCode = try attacker.pairCode(withPeerPublicKey: server.publicKeyData)
        #expect(clientCode != attackerCode)
    }

    @Test("code normalization keeps digits only")
    func codeNormalization() {
        #expect(RemotePairingCode.normalize(" 83-42 71 ") == "834271")
        #expect(RemotePairingCode.isValid("834271"))
        #expect(!RemotePairingCode.isValid("83427"))
        #expect(RemotePairingCode.matches("834271", " 834271 "))
    }

    @Test("a malformed peer public key is rejected")
    func malformedPublicKey() {
        let exchange = RemotePairingExchange(clientNonce: Data([1]), serverNonce: Data([2]))
        #expect(throws: RemoteProtocolError.invalidMessage) {
            _ = try exchange.pairCode(withPeerPublicKey: Data([0, 1, 2]))
        }
    }
}

@Suite("Bonjour TXT record")
struct RemoteServiceInfoTests {
    @Test("the record round trips without carrying secrets")
    func txtRecordRoundTrip() throws {
        let id = UUID()
        let info = RemoteServiceInfo(
            deviceID: id,
            name: "MacBook Pro",
            version: "1.2.3",
            capabilities: [.lock, .unlock, .wake]
        )
        let txt = info.txtRecord()
        #expect(txt["id"] == id.uuidString)
        #expect(txt["name"] == "MacBook Pro")
        #expect(txt["proto"] == "1")
        // No key-ish field may appear in a broadcast record.
        for key in txt.keys {
            #expect(!key.lowercased().contains("key"))
            #expect(!key.lowercased().contains("token"))
            #expect(!key.lowercased().contains("secret"))
        }
        let decoded = try #require(RemoteServiceInfo(txtRecord: txt))
        #expect(decoded == info)
    }

    @Test("a record without an id is rejected")
    func missingIDRejected() {
        #expect(RemoteServiceInfo(txtRecord: ["name": "Mac"]) == nil)
    }

    @Test("capabilities survive the round trip")
    func capabilitiesRoundTrip() throws {
        let info = RemoteServiceInfo(
            deviceID: UUID(),
            name: "Mac mini",
            version: "1",
            capabilities: Set(RemoteCapability.allCases)
        )
        let decoded = try #require(RemoteServiceInfo(txtRecord: info.txtRecord()))
        #expect(decoded.capabilities == Set(RemoteCapability.allCases))
    }
}

@Suite("Remote command metadata")
struct RemoteCommandTests {
    @Test("system changing commands require authentication")
    func authenticationRequirements() {
        #expect(!RemoteCommand.ping.requiresAuthentication)
        #expect(!RemoteCommand.getState.requiresAuthentication)
        for command in [RemoteCommand.lockScreen, .displayOff, .wakeDisplay, .unlock, .wakeAndUnlock] {
            #expect(command.requiresAuthentication, "\(command) must require auth")
        }
    }

    @Test("state never fabricates false")
    func triStateFromOptional() {
        #expect(RemoteBooleanState(nil) == .unknown)
        #expect(RemoteBooleanState(true) == .yes)
        #expect(RemoteBooleanState(false) == .no)
        #expect(RemoteBooleanState.unknown.boolValue == nil)
    }
}
