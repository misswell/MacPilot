import Foundation
import Testing

@testable import MacPilotRemoteProtocol
@testable import MacPilotRemoteTransport

/// The reverse-role link may only turn an observed address into a monitored
/// alias when the phone proves the pairing key. These tests pin that boundary:
/// a stranger's PilotNest must never authenticate, and a captured answer must
/// never authenticate a later connection.
@Suite("Proximity GATT presence")
struct ProximityGATTPresenceTests {
    private let macID = UUID(uuidString: "64C01E3E-F335-12ED-3972-1D01D3A05A84")!
    private let pairingKey = Data((0..<32).map { UInt8($0) })

    @Test("the pairing key produces the proof the Mac expects")
    func responseMatchesChallenge() {
        let challenge = RemoteBLEPresenceChallenge(macID: macID)
        let response = ProximityGATTPresence.response(for: challenge, pairingKey: pairingKey)
        #expect(response.count == RemoteBLEPresenceChallenge.responseLength)
        #expect(ProximityGATTPresence.isValidResponse(response, challenge: challenge, pairingKey: pairingKey))
    }

    @Test("a different key is rejected")
    func wrongKeyIsRejected() {
        let challenge = RemoteBLEPresenceChallenge(macID: macID)
        let response = ProximityGATTPresence.response(for: challenge, pairingKey: pairingKey)
        let strangerKey = Data((0..<32).map { UInt8($0) ^ 0xFF })
        #expect(!ProximityGATTPresence.isValidResponse(response, challenge: challenge, pairingKey: strangerKey))
    }

    @Test("a proof from another nonce is rejected")
    func replayedProofIsRejected() {
        // A captured answer must not authenticate a later connection: the Mac
        // issues a fresh nonce every read, so the old proof cannot match.
        let first = RemoteBLEPresenceChallenge(macID: macID)
        let second = RemoteBLEPresenceChallenge(macID: macID)
        let captured = ProximityGATTPresence.response(for: first, pairingKey: pairingKey)
        #expect(!ProximityGATTPresence.isValidResponse(captured, challenge: second, pairingKey: pairingKey))
    }

    @Test("a proof bound to another Mac is rejected")
    func proofForAnotherMacIsRejected() {
        // The Mac identity is inside the signed message, so one Mac's proof
        // cannot authenticate a phone to a different Mac sharing the key.
        let otherMac = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let challenge = RemoteBLEPresenceChallenge(macID: macID)
        let responseForOther = ProximityGATTPresence.response(
            for: RemoteBLEPresenceChallenge(macID: otherMac),
            pairingKey: pairingKey
        )
        #expect(!ProximityGATTPresence.isValidResponse(responseForOther, challenge: challenge, pairingKey: pairingKey))
    }

    @Test("an empty or truncated proof is rejected")
    func malformedProofIsRejected() {
        let challenge = RemoteBLEPresenceChallenge(macID: macID)
        let valid = ProximityGATTPresence.response(for: challenge, pairingKey: pairingKey)
        #expect(!ProximityGATTPresence.isValidResponse(Data(), challenge: challenge, pairingKey: pairingKey))
        #expect(!ProximityGATTPresence.isValidResponse(valid.dropLast(), challenge: challenge, pairingKey: pairingKey))
        #expect(!ProximityGATTPresence.isValidResponse(valid + Data([0]), challenge: challenge, pairingKey: pairingKey))
    }

    @Test("the presence characteristic is distinct from the round-trip ones")
    func presenceCharacteristicIsDistinct() {
        // An older phone only knows the first three; the fourth must not
        // collide with them or the echo probe would read the wrong payload.
        let uuids = [
            ProximityGATTService.macInfoCharacteristicUUID,
            ProximityGATTService.echoCharacteristicUUID,
            ProximityGATTService.responseCharacteristicUUID,
            ProximityGATTService.presenceChallengeCharacteristicUUID,
        ]
        #expect(Set(uuids.map(\.uuidString)).count == uuids.count)
        #expect(ProximityGATTService.presenceChallengeCharacteristicUUID
            != ProximityGATTService.serviceUUID)
    }

    @Test("the challenge decodes strictly before a proof is computed")
    func challengeDecodesStrictly() {
        // The Mac writes the encoded challenge into the characteristic, so the
        // phone must reject a truncated or wrong-version payload rather than
        // answering a partially understood nonce.
        let challenge = RemoteBLEPresenceChallenge(macID: macID)
        let encoded = challenge.encoded
        #expect(RemoteBLEPresenceChallenge(encoded: encoded) == challenge)
        #expect(RemoteBLEPresenceChallenge(encoded: encoded.dropLast()) == nil)
        #expect(RemoteBLEPresenceChallenge(encoded: Data()) == nil)
    }
}
