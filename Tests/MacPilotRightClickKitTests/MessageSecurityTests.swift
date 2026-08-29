import Foundation
import Testing
@testable import MacPilotRightClickKit

struct MessageSecurityTests {
    private struct Payload: Codable, Equatable {
        let path: String
    }

    @Test func verifiedPayloadComesOnlyFromAuthenticatedBytes() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Payload(path: "/tmp/original")
        let signed = try MessageSecurity.sign(
            original,
            messageID: id,
            action: "click",
            issuedAt: now
        )

        let data = try #require(MessageSecurity.verifiedPayload(
            signed,
            expectedMessageID: id,
            expectedAction: "click",
            now: now
        ))
        #expect(try JSONDecoder().decode(Payload.self, from: data) == original)

        let tampered = SignedPayload(
            messageID: signed.messageID,
            action: signed.action,
            issuedAtMilliseconds: signed.issuedAtMilliseconds,
            signature: signed.signature,
            payloadData: try JSONEncoder().encode(Payload(path: "/tmp/replaced"))
        )
        #expect(MessageSecurity.verifiedPayload(
            tampered,
            expectedMessageID: id,
            expectedAction: "click",
            now: now
        ) == nil)
    }

    @Test func signatureBindsRoutingContextAndRejectsStaleMessages() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let signed = try MessageSecurity.sign(
            Payload(path: "/tmp/item"),
            messageID: id,
            action: "click",
            issuedAt: now
        )

        #expect(MessageSecurity.verifiedPayload(
            signed,
            expectedMessageID: UUID(),
            expectedAction: "click",
            now: now
        ) == nil)
        #expect(MessageSecurity.verifiedPayload(
            signed,
            expectedMessageID: id,
            expectedAction: "heartbeat",
            now: now
        ) == nil)
        #expect(MessageSecurity.verifiedPayload(
            signed,
            expectedMessageID: id,
            expectedAction: "click",
            now: now.addingTimeInterval(301)
        ) == nil)
    }

    @Test func replayGuardAcceptsAnAuthenticatedIDOnlyOnce() {
        let guardState = MessageReplayGuard(retentionMilliseconds: 300_000)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let issuedAt = Int64(now.timeIntervalSince1970 * 1_000)

        #expect(guardState.accept(id, issuedAtMilliseconds: issuedAt, now: now))
        #expect(!guardState.accept(id, issuedAtMilliseconds: issuedAt, now: now))
        #expect(guardState.accept(UUID(), issuedAtMilliseconds: issuedAt, now: now))
    }

    @Test func finderFileSystemPathsPreserveLiteralPercentSequences() {
        let path = "/tmp/MacPilot/foo%2Fbar%25.txt"
        #expect(RightClickIPCPath.fileSystemPath(path) == path)
        #expect(RightClickIPCPath.fileSystemPath(path) != path.removingPercentEncoding)
    }
}
