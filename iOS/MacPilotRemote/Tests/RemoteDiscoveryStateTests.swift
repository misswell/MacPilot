import Network
import Testing
@testable import PilotNest

@MainActor
@Suite("Remote discovery state")
struct RemoteDiscoveryStateTests {
    @Test func policyDeniedWhileWaitingIsNotReportedAsAuthorized() {
        let discovery = RemoteDiscoveryService()
        discovery.handleState(.ready)
        discovery.handleState(.waiting(.dns(-65570)))

        #expect(discovery.isPermissionDenied)
        #expect(discovery.lastError != nil)
        #expect(discovery.isBrowsing)
    }

    @Test func policyDeniedFailureUsesTheDNSServicePolicyError() {
        let discovery = RemoteDiscoveryService()
        discovery.handleState(.failed(.dns(-65570)))

        #expect(discovery.isPermissionDenied)
        #expect(!discovery.isBrowsing)
    }

    @Test func transientWaitingDoesNotClaimPermissionDenial() {
        let discovery = RemoteDiscoveryService()
        discovery.handleState(.waiting(.posix(.ENETDOWN)))

        #expect(!discovery.isPermissionDenied)
        #expect(discovery.lastError != nil)
        #expect(discovery.isBrowsing)
    }

    @Test func readyClearsThePreviousPolicyDenial() {
        let discovery = RemoteDiscoveryService()
        discovery.handleState(.waiting(.dns(-65570)))
        #expect(discovery.isPermissionDenied)

        discovery.handleState(.ready)
        #expect(!discovery.isPermissionDenied)
        #expect(discovery.lastError == nil)
        #expect(discovery.isBrowsing)
    }
}
