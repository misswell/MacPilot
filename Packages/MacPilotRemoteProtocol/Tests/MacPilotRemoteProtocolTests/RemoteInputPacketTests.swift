import Foundation
import Testing
@testable import MacPilotRemoteProtocol

@Suite("Remote input batch codec")
struct RemoteInputBatchCodecTests {
    @Test("mixed batch round trips")
    func mixedBatchRoundTrip() throws {
        let batch = RemoteInputBatch(
            timestampMilliseconds: 1_700_000_000_123,
            events: [
                .move(dx: 12.5, dy: -3.4, buttons: []),
                .click(button: .left, action: .down),
                .click(button: .left, action: .up),
                .move(dx: -100.2, dy: 200.9, buttons: [.left]),
                .scroll(dx: 0.5, dy: -40.1),
                .click(button: .right, action: .down),
                .click(button: .right, action: .up),
            ]
        )
        let decoded = try RemoteInputBatchCodec.decode(try RemoteInputBatchCodec.encode(batch))
        #expect(decoded == batch)
    }

    @Test("fixed point keeps tenth pixel resolution")
    func fixedPointResolution() throws {
        let batch = RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 0.1, dy: -0.1, buttons: [])])
        let decoded = try RemoteInputBatchCodec.decode(try RemoteInputBatchCodec.encode(batch))
        #expect(decoded.events.first == .move(dx: 0.1, dy: -0.1, buttons: []))
    }

    @Test("out of range deltas clamp instead of trapping")
    func deltaClamping() {
        #expect(RemoteInputBatchCodec.fixedPoint(9_999) == Int16.max)
        #expect(RemoteInputBatchCodec.fixedPoint(-9_999) == Int16.min)
    }

    @Test("any truncation throws, never traps")
    func truncatedInputThrows() throws {
        let encoded = try RemoteInputBatchCodec.encode(RemoteInputBatch(
            timestampMilliseconds: 42,
            events: [
                .move(dx: 1, dy: 2, buttons: []),
                .click(button: .left, action: .down),
                .scroll(dx: 3, dy: 4),
            ]
        ))
        for length in 0..<encoded.count {
            #expect(throws: RemoteProtocolError.self) {
                try RemoteInputBatchCodec.decode(encoded.prefix(length))
            }
        }
    }

    @Test("malformed content throws")
    func malformedContentThrows() throws {
        let data = try RemoteInputBatchCodec.encode(RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 1, dy: 1, buttons: [])]))

        var wrongVersion = data
        wrongVersion[0] = 7
        #expect(throws: RemoteProtocolError.self) { try RemoteInputBatchCodec.decode(wrongVersion) }

        var unknownKind = data
        unknownKind[12] = 9
        #expect(throws: RemoteProtocolError.self) { try RemoteInputBatchCodec.decode(unknownKind) }

        var countMismatch = data
        // Event count sits at bytes 2-3; a larger count without more bytes must fail.
        countMismatch[3] = 9
        #expect(throws: RemoteProtocolError.self) { try RemoteInputBatchCodec.decode(countMismatch) }
    }

    @Test("oversized event count is rejected")
    func oversizedEventCount() throws {
        var data = Data([1, 0]) + withUnsafeBytes(of: UInt16(300).bigEndian) { Data($0) }
        data.append(contentsOf: Data(repeating: 0, count: 8))
        #expect(throws: RemoteProtocolError.self) { try RemoteInputBatchCodec.decode(data) }
    }
}

@Suite("Realtime input frame")
struct RealtimeInputFrameTests {
    @Test("seal and open round trip over frame tag 0x03")
    func frameRoundTrip() throws {
        let key = RemoteSessionKey(rawBytes: RemoteCrypto.randomData(count: 32))
        let batch = RemoteInputBatch(
            timestampMilliseconds: 5,
            events: [.move(dx: 2.5, dy: 2.5, buttons: [.left]), .click(button: .left, action: .up)]
        )
        let frame = try RemoteFrameCodec.encodeRealtimeInput(batch, key: key, sequence: 9)
        // The decoder sees the frame payload only, after `extractFrames` has
        // stripped the 4-byte length prefix.
        let payload = Data(frame.dropFirst(RemoteProtocolVersion.frameHeaderLength))
        let (sequence, decoded) = try RemoteFrameCodec.decodeRealtimeInput(payload, key: key)
        #expect(sequence == 9)
        #expect(decoded == batch)
    }

    @Test("wrong key fails to open")
    func wrongKeyFails() throws {
        let key = RemoteSessionKey(rawBytes: RemoteCrypto.randomData(count: 32))
        let other = RemoteSessionKey(rawBytes: RemoteCrypto.randomData(count: 32))
        let frame = try RemoteFrameCodec.encodeRealtimeInput(
            RemoteInputBatch(timestampMilliseconds: 1, events: []),
            key: key,
            sequence: 1
        )
        let payload = Data(frame.dropFirst(RemoteProtocolVersion.frameHeaderLength))
        #expect(throws: RemoteProtocolError.self) {
            try RemoteFrameCodec.decodeRealtimeInput(payload, key: other)
        }
    }

    @Test("secure tag does not decode as realtime input")
    func tagMismatch() throws {
        let key = RemoteSessionKey(rawBytes: RemoteCrypto.randomData(count: 32))
        let frame = try RemoteFrameCodec.encodeSecure(
            RemoteResponse(requestID: UUID(), success: true),
            key: key,
            sequence: 1
        )
        let payload = Data(frame.dropFirst(RemoteProtocolVersion.frameHeaderLength))
        #expect(throws: RemoteProtocolError.self) {
            try RemoteFrameCodec.decodeRealtimeInput(payload, key: key)
        }
    }
}

@Suite("Realtime input command metadata")
struct RealtimeInputCommandTests {
    @Test("begin and end require authentication")
    func authenticationRequired() {
        #expect(RemoteCommand.beginRealtimeInput.requiresAuthentication)
        #expect(RemoteCommand.endRealtimeInput.requiresAuthentication)
    }

    @Test("realtime input capability round trips through the TXT record")
    func capabilityRoundTrip() throws {
        let info = RemoteServiceInfo(
            deviceID: UUID(),
            name: "Mac",
            version: "1",
            capabilities: [.lock, .unlock, .realtimeInput]
        )
        let decoded = try #require(RemoteServiceInfo(txtRecord: info.txtRecord()))
        #expect(decoded.capabilities == [.lock, .unlock, .realtimeInput])
    }
}
