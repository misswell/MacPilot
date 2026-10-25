import Foundation
import Testing
@testable import MacPilot

struct UUSessionUncertaintyTests {
    @Test func positiveUUIndicatorsWithoutRowsNeverClaimADisconnectionOrAuthorizeAutomation() {
        for observation in [
            UUSessionEvidence.observation(controllers: [], announcedCount: 1),
            UUSessionEvidence.observation(controllers: [], overlay: true)
        ] {
            #expect(observation.status == .unknown)
            #expect(observation.uncertainty == .controllerUnconfirmed)
        }
        #expect(UUSessionEvidence.observation(controllers: []).status == .disconnected)
    }

    @Test func aSecondAnnouncedControllerPausesAutomationEvenWhenOnlyOneRowIsReadable() {
        let observation = UUSessionEvidence.observation(controllers: ["one"], announcedCount: 2)
        #expect(observation.status == .ambiguous)
    }

    @Test func unreadableUIIsDistinctFromDisconnectionAndValidRowsRemainRecognized() {
        #expect(UUSessionEvidence.observation(controllers: [], readFailed: true).uncertainty == .interfaceUnreadable)
        #expect(UUSessionEvidence.observation(controllers: ["one"], readFailed: true).status == .connected)
    }

    @Test(arguments: UUSessionObservation.Uncertainty.allCases)
    func unreadableEvidenceKeepsIdentityWithoutClaimingAConnection(
        reason: UUSessionObservation.Uncertainty
    ) {
        var gate = UUSessionGate()
        let now = Date(timeIntervalSince1970: 1_000)
        gate.update(.init(status: .connected, controllers: ["controller"]), now: now)
        let session = gate.sessionID
        gate.update(.init(status: .unknown, uncertainty: reason), now: now.addingTimeInterval(30))
        #expect(gate.sessionID == session)
        #expect(gate.observation.status == .unknown)
        #expect(gate.observation.uncertainty == reason)
        gate.update(.init(status: .connected, controllers: ["controller"]), now: now.addingTimeInterval(31))
        #expect(gate.sessionID == session)
        #expect(gate.observation.uncertainty == nil)
    }

    @Test(arguments: UUSessionObservation.Uncertainty.allCases)
    func eachUncertaintyHasSpecificChineseAndEnglishText(
        reason: UUSessionObservation.Uncertainty
    ) {
        let observation = UUSessionObservation(status: .unknown, uncertainty: reason)
        let key = observation.statusTextKey
        #expect(key == "displayUUUnknown_" + reason.rawValue)
        for language in [AppLanguage.simplifiedChinese, .english] {
            let text = AppText.value(key, language: language)
            #expect(text != key)
            #expect(text != AppText.value("displayUUState_unknown", language: language))
        }
    }

    @Test func knownStatesUseTheirOwnTextEvenIfAnOldReasonIsPresent() {
        for status in [UUSessionObservation.Status.connected, .disconnected, .ambiguous] {
            #expect(UUSessionObservation(status: status, uncertainty: .readTimeout).statusTextKey
                    == "displayUUState_" + status.rawValue)
        }
    }
}
