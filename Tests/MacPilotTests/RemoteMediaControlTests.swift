import AppKit
import Foundation
import MacPilotRemoteProtocol
import Testing
@testable import MacPilot

@Suite("Remote media controls")
@MainActor
struct RemoteMediaControlTests {
    @Test func mediaKeysRequireExplicitCapabilityNegotiation() {
        let advertised: [RemoteCapability] = [.lock, .mediaControl]
        for features: [String]? in [nil, [], ["remoteDesktop"]] {
            #expect(RemoteCapability.negotiated(advertised, features: features) == [.lock])
        }
        #expect(RemoteCapability.negotiated(advertised, features: ["mediaControl"]) == advertised)
    }

    @Test func mediaEventsContainMatchingDownAndUpForTheRequestedKey() throws {
        for (command, key) in [(RemoteCommand.mediaPrevious, 18), (.mediaPlayPause, 16), (.mediaNext, 17)] {
            #expect(command.requiresAuthentication)
            let events = RemoteMediaControl.events(for: command)
            #expect(events.count == 2)
            let down = try #require(events.first)
            let up = try #require(events.last)
            #expect(down.type == .systemDefined)
            #expect(down.subtype.rawValue == 8)
            #expect(down.data1 == (key << 16) | 0xA00)
            #expect(up.data1 == (key << 16) | 0xB00)
            #expect(events.allSatisfy { $0.cgEvent != nil })
        }
        #expect(RemoteMediaControl.events(for: .lockScreen).isEmpty)
    }

    @Test func routerRefusesUnauthenticatedMediaAndForwardsAuthenticatedKeys() async {
        var sent: [RemoteCommand] = []
        let router = RemoteCommandRouter(
            service: MacScreenControlService(
                credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }),
                log: { _ in }
            ),
            mediaControl: { sent.append($0); return nil },
            log: { _ in }
        )
        for command in [RemoteCommand.mediaPrevious, .mediaPlayPause, .mediaNext] {
            let request = RemoteRequest(command: command, sequence: 1)
            let refused = await router.response(for: request, isAuthenticated: false)
            #expect(refused.error?.code == .unauthenticated)
            #expect(sent.isEmpty)
        }
        for command in [RemoteCommand.mediaPrevious, .mediaPlayPause, .mediaNext] {
            let request = RemoteRequest(command: command, sequence: 2)
            let response = await router.response(for: request, isAuthenticated: true)
            #expect(response.success)
            #expect(response.requestID == request.requestID)
        }
        #expect(sent == [.mediaPrevious, .mediaPlayPause, .mediaNext])
    }

    @Test func routerReportsMediaPermissionFailure() async {
        let router = RemoteCommandRouter(
            service: MacScreenControlService(
                credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }),
                log: { _ in }
            ),
            mediaControl: { _ in .accessibilityPermissionRequired },
            log: { _ in }
        )
        let response = await router.response(
            for: RemoteRequest(command: .mediaPlayPause, sequence: 1), isAuthenticated: true
        )
        #expect(!response.success)
        #expect(response.error?.code == .accessibilityPermissionRequired)
    }
}
