import Testing
@testable import PilotNest

@Suite("Home connection presentation")
struct HomeConnectionPresentationTests {
    @Test func connectionAttemptsShowTheirActualStateEvenWhenDiscoveryIsEmpty() {
        let states: [(RemoteConnectionState, String)] = [
            (.discovering, "stateDiscovering"),
            (.connecting, "stateConnecting"),
            (.pairing, "statePairing"),
            (.authenticating, "stateAuthenticating"),
            (.reconnecting, "stateReconnecting")
        ]
        for (state, titleKey) in states {
            #expect(HomeConnectionPresentation(state: state, hasUnpairedMac: false) == .inProgress(titleKey: titleKey))
            if state != .discovering {
                #expect(HomeConnectionPresentation(state: state, hasUnpairedMac: true) == .inProgress(titleKey: titleKey))
            }
            #expect(!HomeConnectionPresentation.showsSuccessBanner(state: state))
        }
    }

    @Test func failureShowsTheConnectionErrorInsteadOfClaimingNoMacWasFound() {
        #expect(HomeConnectionPresentation(state: .failed("Network error"), hasUnpairedMac: false) == .failed(detail: "Network error"))
        #expect(!HomeConnectionPresentation.showsSuccessBanner(state: .failed("Network error")))
    }

    @Test func idleDiscoveryResultsOfferPairingOrReportNoMac() {
        #expect(HomeConnectionPresentation(state: .discovering, hasUnpairedMac: true) == .unpaired)
        #expect(HomeConnectionPresentation(state: .idle, hasUnpairedMac: true) == .unpaired)
        #expect(HomeConnectionPresentation(state: .idle, hasUnpairedMac: false) == .notFound)
        #expect(!HomeConnectionPresentation.showsSuccessBanner(state: .idle))
    }

    @Test func connectedStateAllowsSuccessMessages() {
        #expect(HomeConnectionPresentation(state: .connected, hasUnpairedMac: false) == .connected)
        #expect(HomeConnectionPresentation.showsSuccessBanner(state: .connected))
    }
}
