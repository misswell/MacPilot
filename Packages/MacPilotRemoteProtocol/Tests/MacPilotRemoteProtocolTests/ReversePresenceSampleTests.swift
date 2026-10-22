import Foundation
import Testing

@testable import MacPilotRemoteProtocol
@testable import MacPilotRemoteTransport

/// A reverse presence sample is the only thing allowed to carry distance
/// evidence: the phone measured RSSI towards a specific Mac at a specific
/// moment and signed both values. Every field must be pinned down.
@Suite("Reverse presence sample")
struct ReversePresenceSampleTests {
    private let macID = UUID(uuidString: "64C01E3E-F335-12ED-3972-1D01D3A05A84")!
    private let otherMac = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let pairingKey = Data((0..<32).map { UInt8($0) })
    private let strangerKey = Data((0..<32).map { UInt8($0) ^ 0xFF })
    private let nonce = Data((0..<16).map { UInt8($0) + 1 })
    private let sampledAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_001)

    private func sample(
        macID: UUID? = nil,
        nonce: Data? = nil,
        rssi: Int = -55,
        sampledAt: Date? = nil,
        key: Data? = nil
    ) -> RemoteBLEReversePresenceSample {
        RemoteBLEReversePresenceSample(
            macID: macID ?? self.macID,
            nonce: nonce ?? self.nonce,
            rssi: rssi,
            sampledAt: sampledAt ?? self.sampledAt,
            pairingKey: key ?? pairingKey
        )!
    }

    private func accepts(_ sample: RemoteBLEReversePresenceSample, now: Date? = nil) -> Bool {
        sample.isValid(
            pairingKey: pairingKey,
            expectedMacID: macID,
            expectedNonce: nonce,
            now: now ?? self.now
        )
    }

    @Test("a freshly measured sample for the pending challenge is accepted")
    func validSampleIsAccepted() {
        let sample = sample()
        #expect(sample.encoded.count == RemoteBLEReversePresenceSample.encodedLength)
        #expect(sample.isValidSignature(pairingKey: pairingKey))
        #expect(accepts(sample))
        #expect(RemoteBLEReversePresenceSample(encoded: sample.encoded) == sample)
    }

    @Test("tampering with the RSSI invalidates the signature")
    func tamperedRSSIIsRejected() {
        var bytes = [UInt8](sample(rssi: -70).encoded)
        bytes[1 + RemoteBLEReversePresenceSample.nonceLength + 16] = UInt8(bitPattern: Int8(-20))
        let tampered = RemoteBLEReversePresenceSample(encoded: Data(bytes))
        #expect(tampered != nil)
        #expect(tampered.map { accepts($0) } == false)
    }

    @Test("tampering with the sampling timestamp invalidates the signature")
    func tamperedTimestampIsRejected() {
        var bytes = [UInt8](sample().encoded)
        let offset = 1 + RemoteBLEReversePresenceSample.nonceLength + 16 + 1
        bytes[offset + 7] = bytes[offset + 7] &+ 1
        let tampered = RemoteBLEReversePresenceSample(encoded: Data(bytes))
        #expect(tampered != nil)
        #expect(tampered.map { accepts($0) } == false)
    }

    @Test("a sample for another nonce cannot answer the pending challenge")
    func nonceMismatchIsRejected() {
        let stale = sample(nonce: Data((0..<16).map { UInt8($0) + 9 }))
        #expect(!accepts(stale))
    }

    @Test("a sample signed with another pairing key is rejected")
    func wrongKeyIsRejected() {
        let forged = sample(key: strangerKey)
        #expect(!accepts(forged))
    }

    @Test("a sample for another Mac is rejected even with the same key")
    func anotherMacIsRejected() {
        #expect(!accepts(sample(macID: otherMac)))
    }

    @Test("an expired sample is rejected")
    func expiredSampleIsRejected() {
        let sample = sample()
        #expect(!accepts(sample, now: sampledAt.addingTimeInterval(RemoteBLEReversePresenceSample.maximumAge + 1)))
        #expect(accepts(sample, now: sampledAt.addingTimeInterval(RemoteBLEReversePresenceSample.maximumAge)))
    }

    @Test("a timestamp too far in the future is rejected")
    func futureSampleIsRejected() {
        let sample = sample()
        #expect(!accepts(sample, now: sampledAt.addingTimeInterval(-RemoteBLEReversePresenceSample.maximumFutureSkew - 1)))
        #expect(accepts(sample, now: sampledAt.addingTimeInterval(-RemoteBLEReversePresenceSample.maximumFutureSkew)))
    }

    @Test("wrong lengths and versions are rejected at decode")
    func malformedPayloadIsRejected() {
        let encoded = sample().encoded
        #expect(RemoteBLEReversePresenceSample(encoded: Data()) == nil)
        #expect(RemoteBLEReversePresenceSample(encoded: encoded.dropLast()) == nil)
        #expect(RemoteBLEReversePresenceSample(encoded: encoded + Data([0])) == nil)
        var wrongVersion = [UInt8](encoded)
        wrongVersion[0] = RemoteBLEReversePresenceSample.version + 1
        #expect(RemoteBLEReversePresenceSample(encoded: Data(wrongVersion)) == nil)
    }

    @Test("an out-of-range RSSI is rejected at decode")
    func invalidRSSIIsRejected() {
        var bytes = [UInt8](sample().encoded)
        bytes[1 + RemoteBLEReversePresenceSample.nonceLength + 16] = 5
        #expect(RemoteBLEReversePresenceSample(encoded: Data(bytes)) == nil)
        #expect(RemoteBLEReversePresenceSample(macID: macID, nonce: nonce, rssi: 1, sampledAt: sampledAt, pairingKey: pairingKey) == nil)
        #expect(RemoteBLEReversePresenceSample(macID: macID, nonce: nonce, rssi: -128, sampledAt: sampledAt, pairingKey: pairingKey) == nil)
    }

    @Test("a nonce can only answer one pending challenge")
    func consumedNonceCannotBeReplayed() {
        let captured = sample()
        #expect(accepts(captured))
        // The Mac consumes the pending challenge on success. The same bytes
        // must not match a later challenge issued to the same central.
        let laterNonce = Data((0..<16).map { UInt8($0) + 33 })
        #expect(!captured.isValid(
            pairingKey: pairingKey,
            expectedMacID: macID,
            expectedNonce: laterNonce,
            now: now
        ))
    }

    @Test("the reverse proof is domain separated from the identity proof")
    func domainIsSeparatedFromLegacyProof() {
        let challenge = RemoteBLEPresenceChallenge(macID: macID, nonce: nonce)
        let identityProof = challenge.response(pairingKey: pairingKey)
        let reverseSample = sample()
        #expect(!RemoteCrypto.constantTimeEquals(identityProof, reverseSample.signature))
        #expect(!challenge.isValidResponse(reverseSample.signature, pairingKey: pairingKey))
    }
}
