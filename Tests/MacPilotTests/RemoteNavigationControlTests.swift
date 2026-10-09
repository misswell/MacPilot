import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol
import Testing
@testable import MacPilot

@Suite("Remote navigation keys")
@MainActor
struct RemoteNavigationControlTests {
    private func makeRouter(
        navigationControl: @escaping (RemoteNavigationKey) -> RemoteErrorCode?
    ) -> RemoteCommandRouter {
        RemoteCommandRouter(
            service: MacScreenControlService(
                credentials: ScreenCredentialStore(secretStore: InMemorySecretStore(), log: { _ in }),
                log: { _ in }
            ),
            navigationControl: navigationControl,
            log: { _ in }
        )
    }

    @Test func keyCodesMapToCarbonPageAndHomeEndKeys() {
        #expect(RemoteNavigationControl.keyCode(for: .pageUp) == CGKeyCode(kVK_PageUp))
        #expect(RemoteNavigationControl.keyCode(for: .pageDown) == CGKeyCode(kVK_PageDown))
        #expect(RemoteNavigationControl.keyCode(for: .home) == CGKeyCode(kVK_Home))
        #expect(RemoteNavigationControl.keyCode(for: .end) == CGKeyCode(kVK_End))
    }

    @Test func eventsAreUnmodifiedDownUpPairsAndAreNotPostedByConstruction() throws {
        let cases: [(RemoteNavigationKey, CGKeyCode)] = [
            (.pageUp, CGKeyCode(kVK_PageUp)),
            (.pageDown, CGKeyCode(kVK_PageDown)),
            (.home, CGKeyCode(kVK_Home)),
            (.end, CGKeyCode(kVK_End))
        ]

        for (key, keyCode) in cases {
            let events = try #require(RemoteNavigationControl.events(for: key))
            #expect(events.count == 2)
            #expect(events[0].type == .keyDown)
            #expect(events[1].type == .keyUp)
            #expect(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) })
            #expect(events.allSatisfy { $0.flags.rawValue == 0 })
        }
    }

    @Test func sendChecksAccessibilityAndUsesOnlyTheInjectedEventSink() throws {
        var posted: [CGEvent] = []
        let denied = RemoteNavigationControl.send(
            .home,
            isAccessibilityTrusted: { false },
            postEvent: { posted.append($0) }
        )
        #expect(denied == .accessibilityPermissionRequired)
        #expect(posted.isEmpty)

        let accepted = RemoteNavigationControl.send(
            .home,
            isAccessibilityTrusted: { true },
            postEvent: { posted.append($0) }
        )
        #expect(accepted == nil)
        #expect(posted.count == 2)
        #expect(posted.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Home) })
    }

    @Test func routerRequiresAuthenticationAndRejectsMalformedPayloads() async {
        var sent: [RemoteNavigationKey] = []
        let router = makeRouter { sent.append($0); return nil }
        let payload = RemoteNavigationKey.pageDown.encoded()

        let unauthenticated = await router.response(
            for: RemoteRequest(command: .navigationKey, sequence: 1, payload: payload),
            isAuthenticated: false
        )
        #expect(unauthenticated.error?.code == .unauthenticated)
        #expect(sent.isEmpty)

        let malformed = await router.response(
            for: RemoteRequest(command: .navigationKey, sequence: 2, payload: Data([255])),
            isAuthenticated: true
        )
        #expect(malformed.error?.code == .invalidMessage)
        #expect(sent.isEmpty)

        let accepted = await router.response(
            for: RemoteRequest(command: .navigationKey, sequence: 3, payload: payload),
            isAuthenticated: true
        )
        #expect(accepted.success)
        #expect(accepted.payload == nil)
        #expect(sent == [.pageDown])
    }

    @Test func routerSurfacesAccessibilityFailureWithoutClaimingSuccess() async {
        let router = makeRouter { _ in .accessibilityPermissionRequired }
        let response = await router.response(
            for: RemoteRequest(command: .navigationKey, sequence: 1, payload: RemoteNavigationKey.end.encoded()),
            isAuthenticated: true
        )
        #expect(!response.success)
        #expect(response.error?.code == .accessibilityPermissionRequired)
    }
}
