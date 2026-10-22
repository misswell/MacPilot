import Foundation
import Testing
@testable import PilotNest

@MainActor
struct ReversePresenceCentralTests {
    @MainActor
    private final class Harness {
        let name = "ReversePresence-\(UUID())"
        let defaults: UserDefaults
        let macID = UUID()
        let key = Data(repeating: 0x5A, count: 32)

        init() {
            defaults = UserDefaults(suiteName: name)!
        }

        func makeCentral(keyed: Bool = true) -> ReversePresenceCentral {
            ReversePresenceCentral(
                defaults: defaults,
                pairingKeyLookup: { [macID, key, keyed] id in
                    keyed && id == macID ? key : nil
                },
                radioFactory: { nil }
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    @Test func aFreshInstallStaysOffAndDoesNotStartTheRadio() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral()
        central.resumeAtLaunch()
        #expect(!central.isEnabled)
        #expect(!central.isRunning)
        #expect(central.status == .off)
    }

    @Test func anExistingPairedUserIsMigratedOnceAndKeepsScanningIntent() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral()
        central.importPairedMacs([harness.macID])
        central.resumeAtLaunch()
        #expect(central.isEnabled)
        #expect(central.isRunning)
        #expect(harness.defaults.bool(forKey: ReversePresenceCentral.migrationKey))
        // A later launch must not resurrect the feature after an opt-out.
        central.setEnabled(false)
        central.resumeAtLaunch()
        #expect(!central.isEnabled)
        #expect(!central.isRunning)
    }

    @Test func migrationWithoutAPairingKeyDoesNotEnableAnything() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral(keyed: false)
        central.importPairedMacs([harness.macID])
        central.resumeAtLaunch()
        #expect(!central.isEnabled)
        #expect(!central.isRunning)
    }

    @Test func pairingEnablesTheFeatureUnlessTheUserOptedOut() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral()
        central.handlePairedMac(harness.macID)
        #expect(central.isEnabled)
        #expect(central.isRunning)

        central.setEnabled(false)
        central.handlePairedMac(harness.macID)
        #expect(!central.isEnabled)
        #expect(!central.isRunning)
        #expect(harness.defaults.bool(forKey: ReversePresenceCentral.userDisabledKey))
    }

    @Test func pairingWithoutAKeyOnlyWaitsForPairing() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral(keyed: false)
        central.handlePairedMac(harness.macID)
        #expect(!central.isEnabled)
        #expect(!central.isRunning)
        #expect(central.status == .off)
        #expect(!central.canAuthenticate(harness.macID))
    }

    @Test func forgettingTheLastMacReleasesTheRadioButKeepsThePreference() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral()
        central.handlePairedMac(harness.macID)
        central.forgetMac(harness.macID)
        #expect(central.isEnabled)
        #expect(!central.isRunning)
        #expect(central.status == .waitingForPairing)
        #expect(harness.defaults.stringArray(forKey: ReversePresenceCentral.knownMacIDsKey)?.isEmpty == true)
    }

    @Test func forgettingEverythingClearsTheKnownMacsAndStops() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral()
        central.handlePairedMac(harness.macID)
        central.forgetAllMacs()
        #expect(!central.isRunning)
        #expect(central.status == .waitingForPairing)
        #expect(harness.defaults.stringArray(forKey: ReversePresenceCentral.knownMacIDsKey)?.isEmpty == true)
    }

    @Test func onlyNonSecretMacIDsArePersisted() {
        let harness = Harness()
        defer { harness.cleanUp() }
        let central = harness.makeCentral()
        central.importPairedMacs([harness.macID])
        let stored = harness.defaults.stringArray(forKey: ReversePresenceCentral.knownMacIDsKey)
        #expect(stored == [harness.macID.uuidString])
        #expect(harness.defaults.data(forKey: ReversePresenceCentral.knownMacIDsKey) == nil)
    }

    @Test func stateRestorationNeedsBothIntentAndAKey() {
        #expect(ReversePresenceCentral.shouldResumeRestoration(isEnabled: true, hasPairingKey: true))
        #expect(!ReversePresenceCentral.shouldResumeRestoration(isEnabled: true, hasPairingKey: false))
        #expect(!ReversePresenceCentral.shouldResumeRestoration(isEnabled: false, hasPairingKey: true))
    }

    @Test func theProductionIntentNeverTouchesTheDiagnosticTest() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.defaults.set(true, forKey: ProximityBLECentral.enabledKey)
        let central = harness.makeCentral()
        // The diagnostic key alone must not start production.
        central.resumeAtLaunch()
        #expect(!central.isEnabled)
        #expect(!central.isRunning)
        // Production intent writes only its own keys.
        central.handlePairedMac(harness.macID)
        #expect(harness.defaults.bool(forKey: ProximityBLECentral.enabledKey))
        central.setEnabled(false)
        #expect(harness.defaults.bool(forKey: ProximityBLECentral.enabledKey))
    }

    @Test func theChallengeGateRejectsDuplicatesAndWrongLengths() {
        var gate = ReversePresenceChallengeGate()
        let nonce = Data(repeating: 0x11, count: 16)
        let short = gate.receive(Data(repeating: 0x11, count: 15))
        let long = gate.receive(Data(repeating: 0x11, count: 17))
        #expect(short == false)
        #expect(long == false)
        #expect(!gate.hasPendingNonce)
        let accepted = gate.receive(nonce)
        #expect(accepted)
        #expect(gate.hasPendingNonce)
        let duplicate = gate.receive(nonce)
        #expect(!duplicate)
        #expect(gate.takeNonce() == nonce)
        #expect(!gate.hasPendingNonce)
        let replayed = gate.receive(nonce)
        #expect(!replayed)
        let next = Data(repeating: 0x22, count: 16)
        let acceptedNext = gate.receive(next)
        #expect(acceptedNext)
        #expect(gate.takeNonce() == next)
    }

    @Test func aSuspensionDropsThePendingChallenge() {
        var gate = ReversePresenceChallengeGate()
        let nonce = Data(repeating: 0x33, count: 16)
        let accepted = gate.receive(nonce)
        #expect(accepted)
        gate.reset()
        #expect(!gate.hasPendingNonce)
        #expect(gate.takeNonce() == nil)
    }
}

struct RemoteTextReversePresenceTests {
    private let renderedKeys = [
        "reversePresenceTitle",
        "reversePresenceToggle",
        "reversePresenceFooter",
        "reversePresenceStatus",
        "reversePresenceStatusOff",
        "reversePresenceStatusWaiting",
        "reversePresenceStatusStarting",
        "reversePresenceStatusScanning",
        "reversePresenceStatusConnected",
        "reversePresenceStatusUnavailable",
        "reversePresenceLastSample",
        "reversePresenceLastRSSI",
        "reversePresenceAcceptedSamples",
        "reversePresenceLastError",
        "reversePresenceLog",
        "reversePresenceClearLog",
        "reversePresenceNoEvents",
    ]

    @Test func everyProductionPresenceStringIsWrittenInBothLocales() {
        for key in renderedKeys {
            let chinese = RemoteText.value(key, language: .simplifiedChinese)
            let english = RemoteText.value(key, language: .english)
            #expect(chinese != key, "\(key) is missing from every table")
            #expect(!english.isEmpty, "\(key) has no English wording")
            #expect(chinese != english, "\(key) has no Simplified Chinese wording")
        }
    }
}
