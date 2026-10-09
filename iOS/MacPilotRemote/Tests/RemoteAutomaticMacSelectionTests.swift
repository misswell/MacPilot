import Foundation
import Testing
#if canImport(PilotNest)
@testable import PilotNest
#elseif canImport(MacPilot)
@testable import MacPilot
#endif

struct RemoteAutomaticMacSelectionTests {
    private let selected = "selected-mac"
    private let firstCandidate = "first-candidate"
    private let secondCandidate = "second-candidate"
    private let unpairedCandidate = "unpaired-candidate"
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func switchesAfterOnePairedMacStaysDiscoverableForTenSeconds() {
        var selection = RemoteAutomaticMacSelection()
        let paired = [selected, firstCandidate, secondCandidate]

        let initial = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: Set(paired),
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case let .waiting(targetID, generation, deadline) = initial else {
            Issue.record("Expected a ten-second observation window")
            return
        }
        #expect(targetID == firstCandidate)
        #expect(deadline == start.addingTimeInterval(10))

        let beforeDeadline = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: Set(paired),
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(9.999)
        )
        guard case .waiting(_, _, _) = beforeDeadline else {
            Issue.record("The candidate must remain pending before ten seconds")
            return
        }

        let atDeadline = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: Set(paired),
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(10)
        )
        #expect(atDeadline == .switchTo(targetID: firstCandidate, generation: generation))
        let consumed = selection.consumeSwitch(targetID: firstCandidate, generation: generation)
        #expect(consumed)
    }

    @Test func multipleDiscoveredPairedMacsResetTheObservationWindow() {
        var selection = RemoteAutomaticMacSelection()
        let paired: Set<String> = [selected, firstCandidate, secondCandidate]

        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case .waiting(_, _, _) = first else {
            Issue.record("Expected the first candidate to start a window")
            return
        }

        let ambiguous = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate, secondCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(5)
        )
        #expect(ambiguous == .none)

        let uniqueAgain = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(10)
        )
        guard case let .waiting(targetID, _, deadline) = uniqueAgain else {
            Issue.record("A newly unique candidate must begin a fresh window")
            return
        }
        #expect(targetID == firstCandidate)
        #expect(deadline == start.addingTimeInterval(20))
    }

    @Test func manualSelectionBlocksAutomaticSwitchUntilForegroundResumes() {
        var selection = RemoteAutomaticMacSelection()
        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case let .waiting(_, generation, _) = first else {
            Issue.record("Expected a deadline before the manual selection")
            return
        }

        selection.manualSelectionStarted()
        let staleCommit = selection.consumeSwitch(targetID: firstCandidate, generation: generation)
        #expect(!staleCommit)

        let blocked = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        #expect(blocked == .none)

        selection.resumeForeground()
        let resumed = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(20)
        )
        guard case let .waiting(targetID, _, deadline) = resumed else {
            Issue.record("A fresh foreground cycle should resume observation")
            return
        }
        #expect(targetID == firstCandidate)
        #expect(deadline == start.addingTimeInterval(30))
    }

    @Test func changingTheSelectedMacRestartsTheObservationWindow() {
        var selection = RemoteAutomaticMacSelection()
        let paired: Set<String> = [selected, firstCandidate, secondCandidate]
        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case .waiting(_, _, _) = first else {
            Issue.record("Expected the first candidate to start a deadline")
            return
        }

        let selectedChanged = selection.observe(
            selectedMacID: secondCandidate,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(5)
        )
        guard case let .waiting(_, _, deadline) = selectedChanged else {
            Issue.record("A changed selection must restart the observation window")
            return
        }
        #expect(deadline == start.addingTimeInterval(15))
    }

    @Test func candidateDisappearanceAndRediscoveryRequiresAnotherTenSeconds() {
        var selection = RemoteAutomaticMacSelection()
        let paired: Set<String> = [selected, firstCandidate]
        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case let .waiting(_, oldGeneration, _) = first else {
            Issue.record("Expected the candidate to start a deadline")
            return
        }

        let disappeared = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(5)
        )
        #expect(disappeared == .none)

        let rediscovered = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(6)
        )
        guard case let .waiting(targetID, newGeneration, deadline) = rediscovered else {
            Issue.record("Rediscovery must start a fresh deadline")
            return
        }
        #expect(targetID == firstCandidate)
        #expect(newGeneration != oldGeneration)
        #expect(deadline == start.addingTimeInterval(16))

        let beforeNewDeadline = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(15.999)
        )
        guard case .waiting(_, _, _) = beforeNewDeadline else {
            Issue.record("The old deadline must not survive disappearance")
            return
        }
        let atNewDeadline = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(16)
        )
        #expect(atNewDeadline == .switchTo(targetID: firstCandidate, generation: newGeneration))
    }

    @Test func handshakeAndLiveAuthenticationInvalidateExistingDeadlines() {
        var selection = RemoteAutomaticMacSelection()
        let paired: Set<String> = [selected, firstCandidate]
        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case let .waiting(_, firstGeneration, _) = first else {
            Issue.record("Expected the first deadline")
            return
        }

        let authenticating = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: true,
            now: start.addingTimeInterval(4)
        )
        #expect(authenticating == .none)
        let oldHandshakeDeadline = selection.consumeSwitch(
            targetID: firstCandidate,
            generation: firstGeneration
        )
        #expect(!oldHandshakeDeadline)

        let afterHandshake = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(5)
        )
        guard case let .waiting(_, secondGeneration, secondDeadline) = afterHandshake else {
            Issue.record("An ended handshake must begin a new window")
            return
        }
        #expect(secondGeneration != firstGeneration)
        #expect(secondDeadline == start.addingTimeInterval(15))

        let liveSession = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: true,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(8)
        )
        #expect(liveSession == .none)
        let oldLiveSessionDeadline = selection.consumeSwitch(
            targetID: firstCandidate,
            generation: secondGeneration
        )
        #expect(!oldLiveSessionDeadline)

        let afterDisconnect = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: paired,
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(9)
        )
        guard case let .waiting(_, thirdGeneration, thirdDeadline) = afterDisconnect else {
            Issue.record("A disconnected selection must start observing afresh")
            return
        }
        #expect(thirdGeneration != secondGeneration)
        #expect(thirdDeadline == start.addingTimeInterval(19))
    }

    @Test func staleDeadlineCannotSwitchAfterCandidateChanges() {
        var selection = RemoteAutomaticMacSelection()
        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate, secondCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case let .waiting(_, staleGeneration, _) = first else {
            Issue.record("Expected the first candidate to start a deadline")
            return
        }

        let changed = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate, secondCandidate],
            discoveredMacIDs: [secondCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(4)
        )
        guard case let .waiting(targetID, currentGeneration, _) = changed else {
            Issue.record("The replacement candidate should get its own deadline")
            return
        }
        #expect(targetID == secondCandidate)
        #expect(currentGeneration != staleGeneration)
        let staleCommit = selection.consumeSwitch(targetID: firstCandidate, generation: staleGeneration)
        #expect(!staleCommit)
    }

    @Test func backgroundAndForegroundResetCandidateAge() {
        var selection = RemoteAutomaticMacSelection()
        let first = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        guard case .waiting(_, _, _) = first else {
            Issue.record("Expected the first candidate to start a deadline")
            return
        }

        selection.suspendForeground()
        selection.resumeForeground()
        let afterResume = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(8)
        )
        guard case let .waiting(_, _, deadline) = afterResume else {
            Issue.record("Foreground return must start a fresh candidate window")
            return
        }
        #expect(deadline == start.addingTimeInterval(18))
    }

    @Test func authenticatedSessionAndHandshakePreventSwitching() {
        var selection = RemoteAutomaticMacSelection()
        let authenticated = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: true,
            isPairingOrAuthenticating: false,
            now: start
        )
        #expect(authenticated == .none)

        let handshaking = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: true,
            now: start.addingTimeInterval(20)
        )
        #expect(handshaking == .none)
    }

    @Test func onlyDiscoveredPairedMacsCanBeCandidates() {
        var selection = RemoteAutomaticMacSelection()
        let onlyPairedMac = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected],
            discoveredMacIDs: [],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        #expect(onlyPairedMac == .none)

        let noSelectedMac = selection.observe(
            selectedMacID: nil,
            pairedMacIDs: [firstCandidate, secondCandidate],
            discoveredMacIDs: [firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        #expect(noSelectedMac == .none)

        let unpaired = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [unpairedCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start
        )
        #expect(unpaired == .none)

        let selectedStillVisible = selection.observe(
            selectedMacID: selected,
            pairedMacIDs: [selected, firstCandidate],
            discoveredMacIDs: [selected, firstCandidate],
            selectedHasAuthenticatedSession: false,
            isPairingOrAuthenticating: false,
            now: start.addingTimeInterval(20)
        )
        #expect(selectedStillVisible == .none)
    }
}
