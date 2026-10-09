import Foundation

/// Pure policy for switching to a uniquely visible, already-paired Mac.
///
/// The app owns the cancellable deadline task; this value type owns only the
/// observation window and its generation token, so tests can advance `now`
/// without waiting or touching Bluetooth, Network, or UI state.
struct RemoteAutomaticMacSelection: Equatable {
    static let confirmationDuration: TimeInterval = 10

    enum Evaluation: Equatable {
        case none
        case waiting(targetID: String, generation: UInt64, deadline: Date)
        case switchTo(targetID: String, generation: UInt64)
    }

    private(set) var candidateID: String?
    private(set) var candidateSince: Date?
    private(set) var selectedIDForCandidate: String?
    private(set) var generation: UInt64 = 0
    private(set) var isForeground = true
    private(set) var manualSelectionDisabled = false

    init() {}

    /// Starts a new foreground-use cycle and invalidates every earlier deadline.
    mutating func resumeForeground() {
        generation &+= 1
        candidateID = nil
        candidateSince = nil
        selectedIDForCandidate = nil
        isForeground = true
        manualSelectionDisabled = false
    }

    /// Stops observation while backgrounded and clears the manual-selection latch
    /// so a later foreground cycle can observe again.
    mutating func suspendForeground() {
        generation &+= 1
        candidateID = nil
        candidateSince = nil
        selectedIDForCandidate = nil
        isForeground = false
        manualSelectionDisabled = false
    }

    /// A user-directed device choice disables automatic switching until the
    /// next foreground cycle.
    mutating func manualSelectionStarted() {
        generation &+= 1
        candidateID = nil
        candidateSince = nil
        selectedIDForCandidate = nil
        manualSelectionDisabled = true
    }

    /// Evaluates one event-driven snapshot. The selected Mac must itself be
    /// absent, there must be more than one paired identity, and exactly one
    /// other paired identity may be discovered. Unpaired Bonjour results never
    /// become candidates.
    mutating func observe(
        selectedMacID: String?,
        pairedMacIDs: Set<String>,
        discoveredMacIDs: Set<String>,
        selectedHasAuthenticatedSession: Bool,
        isPairingOrAuthenticating: Bool,
        now: Date
    ) -> Evaluation {
        guard isForeground,
              !manualSelectionDisabled,
              !isPairingOrAuthenticating,
              !selectedHasAuthenticatedSession,
              let selectedMacID,
              pairedMacIDs.count > 1,
              pairedMacIDs.contains(selectedMacID),
              !discoveredMacIDs.contains(selectedMacID) else {
            invalidateCandidate()
            return .none
        }

        var candidates = pairedMacIDs.intersection(discoveredMacIDs)
        candidates.remove(selectedMacID)
        guard candidates.count == 1, let targetID = candidates.first else {
            invalidateCandidate()
            return .none
        }

        if candidateID != nil, selectedIDForCandidate != selectedMacID {
            invalidateCandidate()
        }
        if candidateID != targetID || candidateSince == nil {
            generation &+= 1
            candidateID = targetID
            candidateSince = now
            selectedIDForCandidate = selectedMacID
        }

        guard let candidateSince else { return .none }
        let deadline = candidateSince.addingTimeInterval(Self.confirmationDuration)
        guard now >= deadline else {
            return .waiting(targetID: targetID, generation: generation, deadline: deadline)
        }
        return .switchTo(targetID: targetID, generation: generation)
    }

    /// Allows a scheduled deadline to commit only while it still belongs to the
    /// same candidate and foreground cycle. The caller re-evaluates live app
    /// state immediately before consuming it.
    mutating func consumeSwitch(targetID: String, generation expectedGeneration: UInt64) -> Bool {
        guard isCurrent(targetID: targetID, generation: expectedGeneration) else { return false }
        candidateID = nil
        candidateSince = nil
        selectedIDForCandidate = nil
        generation &+= 1
        return true
    }

    func isCurrent(targetID: String, generation expectedGeneration: UInt64) -> Bool {
        isForeground
            && !manualSelectionDisabled
            && candidateID == targetID
            && generation == expectedGeneration
    }

    private mutating func invalidateCandidate() {
        guard candidateID != nil || candidateSince != nil else { return }
        generation &+= 1
        candidateID = nil
        candidateSince = nil
        selectedIDForCandidate = nil
    }
}
