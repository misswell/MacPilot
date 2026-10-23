import Foundation
import Testing
@testable import MacPilotRemoteTransport

/// A late CoreBluetooth callback must never be charged to the challenge that
/// replaced it, and a rejected connection must never leave the phone unable to
/// reconnect on its own.
struct ReversePresenceOperationTrackerTests {
    private let firstNonce = Data(repeating: 0xAA, count: 16)
    private let secondNonce = Data(repeating: 0xBB, count: 16)

    @Test func aCallbackIsChargedToTheOperationThatWasIssuedFirst() throws {
        var tracker = ReversePresenceOperationTracker()
        tracker.begin(nonce: firstNonce)
        #expect(tracker.isBusy)
        let settledValue = tracker.settle()
        let settled = try #require(settledValue)
        #expect(settled.nonce == firstNonce)
        #expect(!settled.isInvalidated)
        #expect(!tracker.isBusy)
        #expect(tracker.outstanding.isEmpty)
    }

    @Test func aTimedOutReadIsRecognisedAsStaleEvenAfterANewChallengeArrives() throws {
        var tracker = ReversePresenceOperationTracker()
        tracker.begin(nonce: firstNonce)
        tracker.expireEarliest()
        // The read is still outstanding; it does not block the next challenge.
        #expect(!tracker.isBusy)

        tracker.begin(nonce: secondNonce)
        #expect(tracker.isBusy)

        // The old read answers first. It must be reported as invalidated and
        // must not be mistaken for the second challenge's measurement.
        let lateValue = tracker.settle()
        let late = try #require(lateValue)
        #expect(late.nonce == firstNonce)
        #expect(late.isInvalidated)

        // The second read is still outstanding and still usable.
        #expect(tracker.isBusy)
        let currentValue = tracker.settle()
        let current = try #require(currentValue)
        #expect(current.nonce == secondNonce)
        #expect(!current.isInvalidated)
        #expect(!tracker.isBusy)
    }

    @Test func aBackgroundTransitionInvalidatesEveryOutstandingOperation() throws {
        var tracker = ReversePresenceOperationTracker()
        tracker.begin(nonce: firstNonce)
        tracker.begin(nonce: secondNonce)
        tracker.invalidateAll()
        #expect(!tracker.isBusy)
        #expect(tracker.outstanding.count == 2, "Owed callbacks are still expected")

        let lateFirstValue = tracker.settle()
        let lateFirst = try #require(lateFirstValue)
        #expect(lateFirst.isInvalidated)
        let lateSecondValue = tracker.settle()
        let lateSecond = try #require(lateSecondValue)
        #expect(lateSecond.isInvalidated)
        #expect(!tracker.isBusy)
    }

    @Test func aCallbackWithoutAnOutstandingOperationIsRefused() {
        var tracker = ReversePresenceOperationTracker()
        #expect(tracker.settle() == nil)
        #expect(!tracker.isBusy)
        #expect(tracker.isSynchronised)
    }

    @Test func losingCallbacksMarksTheLinkAsOutOfSync() {
        var tracker = ReversePresenceOperationTracker()
        for _ in 0..<(ReversePresenceOperationTracker.maximumOutstanding - 1) {
            tracker.begin(nonce: firstNonce)
        }
        #expect(tracker.isSynchronised, "Fewer calls than the limit is still consistent")
        tracker.begin(nonce: firstNonce)
        #expect(!tracker.isSynchronised, "Reaching the limit means a callback was lost")
    }

    @Test func resetDiscardsEverythingOwed() {
        var tracker = ReversePresenceOperationTracker()
        tracker.begin(nonce: firstNonce)
        tracker.reset()
        #expect(tracker.outstanding.isEmpty)
        #expect(!tracker.isBusy)
        #expect(tracker.settle() == nil)
    }
}

/// The production link has to recover while the app is asleep in a pocket:
/// duplicate-filtered scanning offers each Mac once, so a rejection that does
/// not ask for a fresh scan is unrecoverable without the user opening the app.
struct ReversePresenceRecoveryPlanTests {
    @Test func aTemporaryFailureForAPairedPhoneAlwaysRetriesAndRefreshesDiscovery() {
        for reason in ReversePresenceRejection.allCases
        where reason != .macForgotten && reason != .unknownOrDeletedMac {
            let plan = ReversePresenceRecoveryPlan.plan(for: reason, hasPairingKey: true)
            #expect(plan.retriesAutomatically, "\(reason) must recover without user action")
            #expect(plan.refreshesScan, "\(reason) must not wait for a scan that will never repeat")
            #expect(plan.cooldown > 0, "\(reason) must back off rather than spin")
        }
    }

    @Test func aConnectionThatFailedBeforeIdentificationIsStillRetried() {
        // The link dropped before the Mac identity was read, so the phone
        // cannot yet know which Mac it was — but it does hold a key, and the
        // failure was in reaching the Mac, not in recognising it.
        let plan = ReversePresenceRecoveryPlan.plan(for: .connectFailed, hasPairingKey: true)
        #expect(plan.retriesAutomatically)
        #expect(plan.refreshesScan)
    }

    @Test func setupTimeoutsAndSubscriptionFailuresAreRecoverable() {
        for reason in [ReversePresenceRejection.setupTimeout,
                       .subscribeFailed,
                       .subscribeRefused,
                       .serviceMissing,
                       .characteristicsMissing,
                       .serviceInvalidated] {
            let plan = ReversePresenceRecoveryPlan.plan(for: reason, hasPairingKey: true)
            #expect(plan.retriesAutomatically, "\(reason) is a transient GATT failure")
            #expect(plan.refreshesScan)
        }
    }

    @Test func aForgottenPairingIsNotRetried() {
        let forgotten = ReversePresenceRecoveryPlan.plan(for: .macForgotten, hasPairingKey: true)
        #expect(!forgotten.retriesAutomatically)
        #expect(!forgotten.refreshesScan)

        let unknown = ReversePresenceRecoveryPlan.plan(for: .unknownOrDeletedMac, hasPairingKey: true)
        #expect(!unknown.retriesAutomatically, "No key means no retry can ever succeed")
        #expect(!unknown.refreshesScan)
    }

    @Test func withoutAnyPairingKeyNothingRetries() {
        for reason in ReversePresenceRejection.allCases {
            let plan = ReversePresenceRecoveryPlan.plan(for: reason, hasPairingKey: false)
            #expect(!plan.retriesAutomatically, "\(reason) cannot succeed without a key")
        }
    }

    @Test func unexpectedGATTContentsBackOffLongerThanADroppedLink() {
        let dropped = ReversePresenceRecoveryPlan.cooldown(for: .connectFailed)
        let rebuilding = ReversePresenceRecoveryPlan.cooldown(for: .serviceInvalidated)
        let wrongMac = ReversePresenceRecoveryPlan.cooldown(for: .characteristicsMissing)
        #expect(dropped <= rebuilding)
        #expect(rebuilding < wrongMac, "A Mac that keeps answering wrongly must not be hammered")
    }
}
