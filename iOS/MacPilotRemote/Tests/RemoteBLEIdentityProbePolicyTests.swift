import Foundation
import Testing
@testable import PilotNest

@Suite("BLE identity probe policy")
struct RemoteBLEIdentityProbePolicyTests {
    @Test func startsOnlyForAnAuthenticatedAssociatedNetworkSessionInForeground() {
        #expect(RemoteBLEIdentityProbePolicy.shouldStart(
            isForeground: true,
            alreadyAttemptedThisForeground: false,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: true
        ))
        #expect(!RemoteBLEIdentityProbePolicy.shouldStart(
            isForeground: false,
            alreadyAttemptedThisForeground: false,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: true
        ))
        #expect(!RemoteBLEIdentityProbePolicy.shouldStart(
            isForeground: true,
            alreadyAttemptedThisForeground: false,
            hasAuthenticatedNetworkSession: false,
            serverSupportsLearning: true
        ))
        #expect(!RemoteBLEIdentityProbePolicy.shouldStart(
            isForeground: true,
            alreadyAttemptedThisForeground: false,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: false
        ))
    }

    @Test func probeCannotRestartOrAcceptChannelsOutsideItsWindow() {
        #expect(RemoteBLEIdentityProbePolicy.windowDuration == 12)
        #expect(!RemoteBLEIdentityProbePolicy.shouldStart(
            isForeground: true,
            alreadyAttemptedThisForeground: true,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: true
        ))
        #expect(RemoteBLEIdentityProbePolicy.shouldAcceptChannel(
            isForeground: true,
            isProbeWindowActive: true,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: true
        ))
        #expect(!RemoteBLEIdentityProbePolicy.shouldAcceptChannel(
            isForeground: true,
            isProbeWindowActive: false,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: true
        ))
        #expect(!RemoteBLEIdentityProbePolicy.shouldAcceptChannel(
            isForeground: false,
            isProbeWindowActive: true,
            hasAuthenticatedNetworkSession: true,
            serverSupportsLearning: true
        ))
    }
}
