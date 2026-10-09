import Foundation
import Testing
@testable import MacPilotRemoteProtocol

struct RemoteVideoTests {
    private let secret = Data(repeating: 7, count: 32)

    @Test func videoRoundTripWorksWithFragmentedAndSlicedBuffers() throws {
        var encoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var decoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        let packet = RemoteVideoPacket(frameType: .deltaFrame, payload: Data([0, 0, 0, 1, 65]))
        let wire = try encoder.encode(packet)
        var buffer = Data([99]) + wire.prefix(3)
        buffer = buffer.dropFirst()
        #expect(try RemoteVideoCodec.extractFrames(from: &buffer).isEmpty)
        buffer.append(wire.dropFirst(3))
        let bodies = try RemoteVideoCodec.extractFrames(from: &buffer)
        #expect(bodies.count == 1)
        #expect(try decoder.decode(bodies[0]) == packet)
        #expect(buffer.isEmpty)
        #expect(throws: (any Error).self) { try decoder.decode(bodies[0]) }
    }

    @Test func wrongDirectionAndWrongTicketCannotDecryptVideo() throws {
        var encoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var reflected = RemoteVideoCodec(secret: secret, serverToClient: false)
        var wrongTicket = RemoteVideoCodec(secret: Data(repeating: 8, count: 32), serverToClient: true)
        var buffer = try encoder.encode(RemoteVideoPacket(frameType: .hello))
        let body = try #require(RemoteVideoCodec.extractFrames(from: &buffer).first)
        #expect(throws: (any Error).self) { try reflected.decode(body) }
        #expect(throws: (any Error).self) { try wrongTicket.decode(body) }
    }

    @Test func tamperedPacketsDoNotAdvanceTheReplayCounter() throws {
        var encoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var decoder = RemoteVideoCodec(secret: secret, serverToClient: true)
        var buffer = try encoder.encode(RemoteVideoPacket(frameType: .hello))
        let body = try #require(RemoteVideoCodec.extractFrames(from: &buffer).first)
        var tampered = body
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try decoder.decode(tampered) }
        #expect(try decoder.decode(body).frameType == .hello)
    }

    @Test func oversizeLengthIsRejectedBeforeAllocatingTheFrame() {
        var buffer = Data([0xff, 0xff, 0xff, 0xff])
        #expect(throws: RemoteProtocolError.self) { try RemoteVideoCodec.extractFrames(from: &buffer) }
    }

    @Test func keyframesCarryParameterSetsAndRejectTruncatedNALs() throws {
        let frame = RemoteH264Frame(sps: Data([103, 1]), pps: Data([104, 1]), avcc: Data([0, 0, 0, 2, 65, 1]))
        #expect(try RemoteH264Frame.decode(frame.encoded(), keyFrame: true) == frame)
        #expect(throws: RemoteProtocolError.self) { try RemoteH264Frame.decode(Data([0, 0, 0, 0, 0, 0, 0, 20, 65]), keyFrame: false) }
        let delta = RemoteH264Frame(avcc: frame.avcc)
        #expect(throws: RemoteProtocolError.self) { try RemoteH264Frame.decode(delta.encoded(), keyFrame: true) }
    }

    @Test func oldControlResponsesStillDecodeWithoutVideoPayload() throws {
        let id = UUID()
        let data = Data("{\"version\":1,\"requestID\":\"\(id)\",\"success\":true}".utf8)
        let response = try JSONDecoder().decode(RemoteResponse.self, from: data)
        #expect(response.payload == nil)
        #expect(response.success)
    }

    @Test func legacyPhonesReceiveOnlyOriginalScreenControlCapabilities() {
        let advertised: [RemoteCapability] = [.lock, .realtimeInput, .inputPressureStream, .dockGroups, .remoteDesktop]
        #expect(RemoteCapability.negotiated(advertised, features: nil) == [.lock])
    }

    @Test func newPhonesReceiveOnlyTheFeaturesTheyDeclared() {
        let advertised: [RemoteCapability] = [.realtimeInput, .dockGroups, .remoteDesktop, .navigationKeys]
        #expect(RemoteCapability.negotiated(advertised, features: ["remoteDesktop"]) == [.realtimeInput, .remoteDesktop])
        #expect(RemoteCapability.negotiated(
            advertised,
            features: ["remoteDesktop", "dockGroups", "navigationKeys"]
        ) == advertised)
    }

    @Test func navigationKeysRequireTheirOwnExplicitCapabilityDeclaration() {
        let advertised: [RemoteCapability] = [.remoteDesktop, .navigationKeys]
        #expect(!RemoteCapability.negotiated(advertised, features: nil).contains(.navigationKeys))
        #expect(!RemoteCapability.negotiated(advertised, features: ["remoteDesktop"]).contains(.navigationKeys))
        #expect(RemoteCapability.negotiated(advertised, features: ["navigationKeys"]).contains(.navigationKeys))
    }

    @Test func bleIdentityLearningIsNegotiatedOnlyWhenDeclared() {
        #expect(!RemoteCapability.negotiated(RemoteCapability.allCases, features: ["remoteDesktop"])
            .contains(.bleIdentityLearning))
        #expect(RemoteCapability.negotiated(RemoteCapability.allCases, features: ["bleIdentityLearning"])
            .contains(.bleIdentityLearning))
        #expect(!RemoteCapability.negotiated(RemoteCapability.allCases, features: nil)
            .contains(.bleIdentityLearning))
    }

    /// Frozen vocabulary from the published 1.0/1.1 phone app, deliberately
    /// independent of today's enum so additions cannot silently weaken this test.
    private enum AppStoreCapability: String, Decodable {
        case lock, displayOff, wake, unlock
    }

    private struct AppStoreHello: Decodable {
        let kind: String
        let protocolVersion: Int
        let capabilities: [AppStoreCapability]?
    }

    @Test func unfilteredNewCapabilitiesReproducePublishedPhoneDecodeFailure() throws {
        let hello = RemoteHandshakeMessage(kind: .serverHello, capabilities: RemoteCapability.allCases)
        let data = try JSONEncoder().encode(hello)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AppStoreHello.self, from: data) }
    }

    @Test func actualServerHelloDecodesWithPublishedPhoneVocabulary() throws {
        for features: [String]? in [nil, [], ["futureUnknownFeature"]] {
            let hello = RemoteHandshakeMessage(
                kind: .serverHello,
                capabilities: RemoteCapability.negotiated(RemoteCapability.allCases, features: features)
            )
            var wire = try RemoteFrameCodec.encodePlain(hello)
            let body = try #require(RemoteFrameCodec.extractFrames(from: &wire).first)
            let oldHello = try JSONDecoder().decode(AppStoreHello.self, from: Data(body.dropFirst()))
            #expect(oldHello.kind == "serverHello")
            #expect(oldHello.protocolVersion == 1)
            #expect(oldHello.capabilities?.map(\.rawValue) == ["lock", "displayOff", "wake", "unlock"])
        }
    }

    @Test func inputCapabilitiesCanBeNegotiatedIndividually() {
        #expect(RemoteCapability.negotiated(RemoteCapability.allCases, features: ["realtimeInput"]) ==
            [.lock, .displayOff, .wake, .unlock, .realtimeInput])
        #expect(RemoteCapability.negotiated(RemoteCapability.allCases, features: ["remoteDesktop"]) ==
            RemoteCapability.allCases.filter {
                $0 != .dockGroups && $0 != .mediaControl && $0 != .bleIdentityLearning && $0 != .navigationKeys
            })
    }

    @Test func videoCapabilitiesNeverChangeExistingInputEventNumbers() {
        #expect(RemoteCommand.beginRemoteVideo.requiresAuthentication)
        #expect(RemoteCommand.remotePointer.requiresAuthentication)
        #expect(RemoteCommand.remoteKey.requiresAuthentication)
        #expect(RemoteCommand.navigationKey.requiresAuthentication)
        #expect(RemoteVideoQuality.balanced.width == 1280)
        #expect(RemoteVideoQuality.balanced.fps == 30)
        #expect(RemoteVideoQuality.balanced.bitrate == 2_000_000)
    }
}
