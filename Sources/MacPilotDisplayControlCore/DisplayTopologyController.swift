import CoreGraphics
import Foundation
import MacPilotDisplayBridge

public struct DisplayVirtualCreation: Equatable, Sendable {
    public let uuid: String
    public let settingsApplied: Bool
}

public protocol DisplayTopologyDriving: Sendable {
    var displayEnableAPIAvailable: Bool { get }
    var virtualDisplayAPIAvailable: Bool { get }
    func displays() -> [DisplayControlDisplay]
    func setEnabled(_ display: DisplayControlDisplay, enabled: Bool) -> Bool
    func setMain(_ display: DisplayControlDisplay) -> Bool
    func restoreLayout(_ originals: [DisplayControlDisplay]) -> Bool
    func createVirtual(_ spec: DisplayVirtualSpec, name: String) -> DisplayVirtualCreation?
    func destroyVirtual(uuid: String, now: Date) -> Bool
}

public final class DisplayTopologyController: @unchecked Sendable {
    private let store: DisplayRecoveryJournalStore
    private let overrideStore: DisplaySessionOverrideStore
    private let driver: any DisplayTopologyDriving
    private var lease = DisplayRemoteLease()
    private(set) var state: DisplayControlState = .idle
    private(set) var messageCode: DisplayControlMessageCode?
    private(set) var generation = UUID()
    private var controlHeartbeatAt: Date?
    private var controlRevocationPersistenceFailed = false
    private var emergencyHotKeyReady = false
    private var authenticationReady = false

    public init(
        store: DisplayRecoveryJournalStore = .standard,
        overrideStore: DisplaySessionOverrideStore = .standard,
        driver: any DisplayTopologyDriving = MacDisplayTopologyDriver(),
        emergencyHotKeyReady: Bool = false,
        authenticationReady: Bool = false
    ) {
        self.store = store
        self.overrideStore = overrideStore
        self.driver = driver
        self.emergencyHotKeyReady = emergencyHotKeyReady
        self.authenticationReady = authenticationReady
        do { lease.restoreOverride(try overrideStore.load()) }
        catch { messageCode = .recoveryIncomplete }
    }

    var helperReady: Bool {
        emergencyHotKeyReady
            && authenticationReady
            && driver.displayEnableAPIAvailable
            && messageCode != .recoveryIncomplete
            && DisplayRecoverySession.identifier != "display-session-unknown"
    }

    public func setEmergencyHotKeyReady(_ ready: Bool) { emergencyHotKeyReady = ready }
    public func setAuthenticationReady(_ ready: Bool) { authenticationReady = ready }

    public func response(now: Date = Date()) -> DisplayControlResponse {
        let journal = try? store.load()
        let displays = snapshot(journal: journal)
        return DisplayControlResponse(
            displays: displays,
            state: state,
            message: messageCode?.rawValue,
            generation: journal?.generation ?? generation,
            confirmationDeadline: journal?.confirmationDeadline,
            helperReady: helperReady,
            virtualDisplayUUID: journal?.virtualDisplayUUID
        )
    }

    public func recoverAtStartup() {
        do {
            guard let journal = try store.load() else { return }
            generation = journal.generation
            if journal.systemSessionID != DisplayRecoverySession.identifier {
                state = .recoveryRequired
                messageCode = .recoveryIncomplete
                return
            }
            _ = revokeControl(for: journal.remoteSessionID)
            if journal.isComplete {
                state = .recovering
                _ = finalizeRestorationIfStable(journal, now: Date())
                return
            }
            state = .recovering
            guard restore(journal: journal) else {
                state = .recoveryRequired
                messageCode = .recoveryIncomplete
                return
            }
            guard let completed = try store.load(), completed.isComplete else {
                state = .recoveryRequired
                messageCode = .recoveryIncomplete
                return
            }
            _ = finalizeRestorationIfStable(completed, now: Date())
        } catch {
            lease.clearLease()
            controlHeartbeatAt = nil
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
        }
    }

    public func handle(_ request: DisplayControlRequest, now: Date = Date()) {
        if request.command != .status, request.command != .restore,
           loadJournal() != nil {
            expireLeases(now: now)
        }
        if request.command != .status, request.command != .restore,
           let journal = loadJournal(),
           (journal.phase == .restoringDisplays || journal.isComplete || state == .recoveryRequired || state == .recovering) {
            messageCode = .recoveryIncomplete
            return
        }
        switch request.command {
        case .status:
            return
        case .heartbeat:
            handleHeartbeat(request, now: now)
        case .restore:
            if let targetUUID = request.targetUUID {
                restoreOne(targetUUID: targetUUID)
            } else {
                if request.generation != nil, let current = activeJournalGeneration(), current != request.generation {
                    messageCode = .staleGeneration
                    return
                }
                restoreAll()
            }
        case .disable:
            disableOne(request, now: now)
        case .keepOnly:
            keepOnly(request, now: now)
        case .prepareVirtual:
            prepareVirtual(request, now: now)
        case .confirmVirtual:
            confirmVirtual(request, now: now)
        case .confirmChange:
            confirmChange(request, now: now)
        }
    }

    public func expireLeases(now: Date = Date()) {
        guard let journal = loadJournal() else { return }
        if journal.isComplete {
            _ = revokeControl(for: journal.remoteSessionID)
            _ = finalizeRestorationIfStable(journal, now: now)
            return
        }
        if state == .recoveryRequired || journal.phase == .restoringDisplays {
            _ = revokeControl(for: journal.remoteSessionID ?? lease.sessionID)
            restoreAll()
            return
        }
        guard topologyIsContinuous(journal) else {
            let topologyMessage: DisplayControlMessageCode = journal.policy == .remoteVirtualOnly
                ? .virtualNotReady
                : .lastPhysicalDisplay
            state = .recovering
            restoreAll()
            if state == .idle { messageCode = topologyMessage }
            return
        }
        if let deadline = journal.confirmationDeadline, now >= deadline {
            messageCode = .confirmationExpired
            state = .recovering
            restoreAll()
            return
        }
        let remotePolicy = journal.policy == .remotePhysical || journal.policy == .remoteVirtualOnly || journal.policy == .remoteVirtualWithPhysical
        let controlLeaseIsFresh = controlHeartbeatAt.map {
            now >= $0 && now.timeIntervalSince($0) <= DisplayRemoteLease.lifetime
        } ?? false
        if remotePolicy ? !lease.isFresh(now: now) : !controlLeaseIsFresh {
            messageCode = .uuSessionRequired
            state = .recovering
            restoreAll()
        }
    }

    public func restoreAll() {
        do {
            guard let journal = try store.load() else {
                _ = revokeControl(for: lease.sessionID)
                state = .idle
                generation = UUID()
                if messageCode != .recoveryIncomplete { messageCode = .userOverride }
                return
            }
            _ = revokeControl(for: journal.remoteSessionID ?? lease.sessionID)
            state = .recovering
            if journal.isComplete {
                _ = finalizeRestorationIfStable(journal, now: Date())
                return
            }
            guard restore(journal: journal) else {
                state = .recoveryRequired
                messageCode = .recoveryIncomplete
                return
            }
            guard let completed = try store.load(), completed.isComplete else {
                state = .recoveryRequired
                messageCode = .recoveryIncomplete
                return
            }
            _ = finalizeRestorationIfStable(completed, now: Date())
            if state == .idle, messageCode != .confirmationExpired && messageCode != .uuSessionRequired {
                messageCode = .userOverride
            }
        } catch {
            lease.clearLease()
            controlHeartbeatAt = nil
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
        }
    }

    private func handleHeartbeat(_ request: DisplayControlRequest, now: Date) {
        let journal = loadJournal()
        guard request.generation == (journal?.generation ?? generation) else { messageCode = .staleGeneration; return }
        guard let journal, !journal.isComplete,
              journal.phase != .restoringDisplays,
              (state == .active || state == .awaitingKeepConfirmation || state == .awaitingVirtualConfirmation) else {
            _ = revokeControl(for: journal?.remoteSessionID)
            state = .recovering
            messageCode = .uuSessionRequired
            restoreAll()
            return
        }
        if let deadline = journal.confirmationDeadline, now >= deadline {
            messageCode = .confirmationExpired
            _ = revokeControl(for: journal.remoteSessionID)
            state = .recovering
            restoreAll()
            return
        }
        let remotePolicy = journal.policy == .remotePhysical || journal.policy == .remoteVirtualOnly || journal.policy == .remoteVirtualWithPhysical
        if remotePolicy {
            guard let session = request.remoteSessionID else {
                messageCode = .uuSessionRequired
                _ = revokeControl(for: journal.remoteSessionID)
                state = .recovering
                restoreAll()
                return
            }
            guard journal.remoteSessionID == session else {
                messageCode = .staleGeneration
                return
            }
            guard
                  lease.sessionID == session,
                  lease.isFresh(now: now),
                  journal.remoteLeaseExpiresAt.map({ now <= $0 }) == true,
                  lease.renew(sessionID: session, generation: journal.generation, now: now) else {
                messageCode = .uuSessionRequired
                _ = revokeControl(for: journal.remoteSessionID ?? request.remoteSessionID)
                state = .recovering
                restoreAll()
                return
            }
            var updated = journal
            updated.updatedAt = now
            updated.remoteLeaseExpiresAt = now.addingTimeInterval(DisplayRemoteLease.lifetime)
            do { try store.save(updated) }
            catch { messageCode = .recoveryIncomplete; _ = revokeControl(for: session); state = .recovering; restoreAll() }
            return
        }
        guard journal.remoteSessionID == nil, request.remoteSessionID == nil else {
            messageCode = .staleGeneration
            return
        }
        guard controlHeartbeatAt.map({ now >= $0 && now.timeIntervalSince($0) <= DisplayRemoteLease.lifetime }) == true else {
            messageCode = .uuSessionRequired
            _ = revokeControl(for: nil)
            state = .recovering
            restoreAll()
            return
        }
        controlHeartbeatAt = now
    }

    private func disableOne(_ request: DisplayControlRequest, now: Date) {
        guard helperReady else { messageCode = .helperUnavailable; return }
        guard let targetUUID = request.targetUUID,
              let target = snapshot().first(where: { $0.uuid == targetUUID }),
              !target.isVirtual,
              target.isUsable else { messageCode = .invalidTarget; return }
        let policy = request.policy ?? .localPhysical
        guard validateGeneration(request.generation, allowNew: true) else { return }
        guard policy != .remoteVirtualOnly,
              DisplayControlSafety.canDisable(
                targetUUID: targetUUID,
                displays: snapshot(),
                policy: policy,
                remoteSessionIsFresh: lease.isFresh(now: now),
                virtualSelectionConfirmed: false
              ) else {
            messageCode = .lastPhysicalDisplay
            return
        }
        guard var journal = prepareJournal(request: request, policy: policy, now: now) else { return }
        guard disable(target, journal: &journal, now: now) else { restoreAfterFailure(); return }
        state = .awaitingKeepConfirmation
        journal.confirmationDeadline = now.addingTimeInterval(15)
        journal.phase = .active
        journal.updatedAt = now
        do { try store.save(journal); messageCode = nil }
        catch { state = .recoveryRequired; messageCode = .recoveryIncomplete }
    }

    private func keepOnly(_ request: DisplayControlRequest, now: Date) {
        guard helperReady else { messageCode = .helperUnavailable; return }
        guard let targetUUID = request.targetUUID,
              let target = snapshot().first(where: { $0.uuid == targetUUID }) else {
            messageCode = .invalidTarget
            return
        }
        guard target.isUsable else { messageCode = target.isVirtual ? .virtualNotReady : .invalidTarget; return }
        guard validateGeneration(request.generation, allowNew: true) else { return }
        let policy = request.policy ?? .localPhysical
        let displays = snapshot()
        let remoteReady = lease.isFresh(now: now)
        guard DisplayControlSafety.canKeepOnly(
            targetUUID: targetUUID,
            displays: displays,
            policy: policy,
            remoteSessionIsFresh: remoteReady,
            virtualSelectionConfirmed: loadJournal()?.virtualSelectionConfirmed ?? false
        ) else {
            messageCode = target.isVirtual ? .virtualNotReady : .invalidTarget
            return
        }
        guard var journal = prepareJournal(request: request, policy: policy, now: now) else { return }
        if target.isVirtual {
            guard policy == .remoteVirtualOnly,
                  journal.virtualSelectionConfirmed,
                  remoteReady else { messageCode = .virtualNotReady; return }
        }

        state = .managing
        if !target.isMain {
            guard driver.setMain(target),
                  snapshot().contains(where: { $0.uuid == targetUUID && $0.isMain && $0.isUsable }) else {
                messageCode = .transactionFailed
                restoreAfterFailure()
                return
            }
        }

        let targets = displays.filter { $0.uuid != targetUUID && $0.isUsable }
        for display in targets {
            let remaining = snapshot()
            guard DisplayControlSafety.canDisable(
                targetUUID: display.uuid,
                displays: remaining,
                policy: policy,
                remoteSessionIsFresh: lease.isFresh(now: Date()),
                virtualSelectionConfirmed: journal.virtualSelectionConfirmed,
                confirmedVirtualUUID: journal.virtualDisplayUUID
            ) else {
                messageCode = .lastPhysicalDisplay
                restoreAfterFailure()
                return
            }
            guard disable(display, journal: &journal, now: Date()) else {
                restoreAfterFailure()
                return
            }
        }

        state = .awaitingKeepConfirmation
        journal.phase = .active
        journal.confirmationDeadline = now.addingTimeInterval(15)
        journal.updatedAt = now
        do { try store.save(journal); messageCode = nil }
        catch { state = .recoveryRequired; messageCode = .recoveryIncomplete }
    }

    private func prepareVirtual(_ request: DisplayControlRequest, now: Date) {
        guard helperReady, driver.virtualDisplayAPIAvailable else { messageCode = .displayAPIUnavailable; return }
        guard let spec = request.virtualSpec else { messageCode = .invalidSize; return }
        guard spec.validationError == nil else { messageCode = .invalidSize; return }
        guard request.policy == .remoteVirtualOnly || request.policy == .remoteVirtualWithPhysical,
              let session = request.remoteSessionID, !session.isEmpty,
              validateGeneration(request.generation, allowNew: true) else {
            messageCode = .uuSessionRequired
            return
        }
        // A confirmation timeout or an emergency release remembers the session
        // so the automatic rule cannot immediately undo the restored desktop.
        // `confirmed` on this command means the user explicitly re-applied.
        guard clearOverrideForExplicitRetry(request, session: session) else { return }
        guard let requestedGeneration = request.generation,
              let activeGeneration = prepareActiveGeneration(requested: requestedGeneration),
              lease.beginControl(
                sessionID: session,
                expectedGeneration: requestedGeneration,
                activeGeneration: activeGeneration,
                now: now
              ) else {
            messageCode = .uuSessionRequired
            return
        }
        guard loadJournal() == nil || loadJournal()?.phase == .complete else {
            messageCode = .recoveryIncomplete
            return
        }
        var journal = DisplayRecoveryJournal(
            generation: activeGeneration,
            policy: request.policy ?? .remoteVirtualOnly,
            originalDisplays: snapshot(),
            now: now
        )
        journal.remoteSessionID = session
        journal.remoteLeaseExpiresAt = now.addingTimeInterval(DisplayRemoteLease.lifetime)
        journal.virtualSpec = spec
        journal.phase = .creatingVirtual
        do { try store.save(journal) }
        catch { state = .recoveryRequired; messageCode = .recoveryIncomplete; return }

        state = .managing
        guard let creation = driver.createVirtual(spec, name: "MacPilot Remote Display") else {
            messageCode = .transactionFailed
            restoreAll()
            return
        }
        journal.virtualDisplayUUID = creation.uuid
        guard creation.settingsApplied else {
            messageCode = .transactionFailed
            journal.phase = .creatingVirtual
            journal.updatedAt = Date()
            do { try store.save(journal) }
            catch { messageCode = .recoveryIncomplete }
            state = .recoveryRequired
            return
        }

        guard waitForUsableDisplay(uuid: creation.uuid, timeout: 10) else {
            messageCode = .virtualNotReady
            // Keep the object alive and retain physical screens. Do not
            // rapidly destroy a display that failed to settle.
            state = .recoveryRequired
            return
        }
        guard let virtual = snapshot().first(where: { $0.uuid == creation.uuid && $0.isVirtual && $0.isUsable }) else {
            messageCode = .virtualNotReady
            state = .recoveryRequired
            return
        }
        journal.virtualDisplayUUID = virtual.uuid
        journal.phase = .awaitingVirtualConfirmation
        journal.confirmationDeadline = now.addingTimeInterval(30)
        journal.updatedAt = Date()
        do { try store.save(journal) }
        catch { state = .recoveryRequired; messageCode = .recoveryIncomplete; return }
        state = .awaitingVirtualConfirmation
        messageCode = nil
    }

    private func confirmVirtual(_ request: DisplayControlRequest, now: Date) {
        guard request.confirmed,
              var journal = loadJournal(),
              journal.phase == .awaitingVirtualConfirmation,
              journal.generation == request.generation,
              journal.remoteSessionID == request.remoteSessionID,
              lease.isFresh(now: now),
              let deadline = journal.confirmationDeadline,
              now < deadline,
              let virtualUUID = journal.virtualDisplayUUID,
              let virtual = snapshot().first(where: { $0.uuid == virtualUUID && $0.isVirtual && $0.isUsable }) else {
            messageCode = .virtualNotReady
            return
        }
        journal.virtualSelectionConfirmed = true
        journal.updatedAt = now
        do { try store.save(journal) }
        catch { messageCode = .recoveryIncomplete; return }
        state = .managing

        if journal.policy == .remoteVirtualWithPhysical {
            state = .active
            journal.phase = .active
            journal.confirmationDeadline = nil
            journal.updatedAt = Date()
            do { try store.save(journal); messageCode = nil }
            catch { state = .recoveryRequired; messageCode = .recoveryIncomplete }
            return
        }

        guard journal.policy == .remoteVirtualOnly else { messageCode = .virtualNotReady; return }
        if !virtual.isMain {
            guard driver.setMain(virtual),
                  snapshot().contains(where: { $0.uuid == virtual.uuid && $0.isMain && $0.isUsable }) else {
                messageCode = .transactionFailed
                restoreAfterFailure()
                return
            }
        }
        for physical in snapshot().filter({ !$0.isVirtual && $0.isUsable }) {
            guard DisplayControlSafety.canDisable(
                targetUUID: physical.uuid,
                displays: snapshot(),
                policy: .remoteVirtualOnly,
                remoteSessionIsFresh: lease.isFresh(now: Date()),
                virtualSelectionConfirmed: true,
                confirmedVirtualUUID: journal.virtualDisplayUUID
            ), disable(physical, journal: &journal, now: Date()) else {
                messageCode = .lastPhysicalDisplay
                restoreAfterFailure()
                return
            }
        }
        state = .awaitingKeepConfirmation
        journal.phase = .active
        journal.confirmationDeadline = now.addingTimeInterval(15)
        journal.updatedAt = Date()
        do { try store.save(journal); messageCode = nil }
        catch { state = .recoveryRequired; messageCode = .recoveryIncomplete }
    }

    private func confirmChange(_ request: DisplayControlRequest, now: Date) {
        guard request.confirmed,
              var journal = loadJournal(),
              journal.generation == request.generation,
              let deadline = journal.confirmationDeadline,
              now < deadline else {
            messageCode = .confirmationExpired
            return
        }
        if journal.policy == .remoteVirtualOnly {
            guard lease.isFresh(now: now), journal.virtualSelectionConfirmed,
                  let uuid = journal.virtualDisplayUUID,
                  snapshot().contains(where: { $0.uuid == uuid && $0.isVirtual && $0.isUsable }) else {
                messageCode = .virtualNotReady
                restoreAll()
                return
            }
        }
        journal.confirmationDeadline = nil
        journal.phase = .active
        journal.updatedAt = now
        do {
            try store.save(journal)
            state = .active
            messageCode = nil
        } catch {
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
        }
    }

    private func disable(_ target: DisplayControlDisplay, journal: inout DisplayRecoveryJournal, now: Date) -> Bool {
        guard target.isUsable else {
            messageCode = .lastPhysicalDisplay
            return false
        }
        if target.isMain {
            let replacement = snapshot().first { candidate in
                guard candidate.uuid != target.uuid, candidate.isUsable else { return false }
                if journal.policy == .remoteVirtualOnly && journal.virtualSelectionConfirmed {
                    return true
                }
                return !candidate.isVirtual
            }
            guard let replacement else { messageCode = .lastPhysicalDisplay; return false }
            guard driver.setMain(replacement),
                  snapshot().contains(where: { $0.uuid == replacement.uuid && $0.isMain && $0.isUsable }) else {
                messageCode = .transactionFailed
                return false
            }
        }
        if !journal.disabledDisplayUUIDs.contains(target.uuid) { journal.disabledDisplayUUIDs.append(target.uuid) }
        if !journal.pendingRestoreUUIDs.contains(target.uuid) { journal.pendingRestoreUUIDs.append(target.uuid) }
        journal.phase = .disablingDisplays
        journal.updatedAt = now
        do { try store.save(journal) }
        catch { messageCode = .recoveryIncomplete; return false }

        let configured = driver.setEnabled(target, enabled: false)
        let after = snapshot()
        let remainsUsable = after.contains(where: { $0.uuid == target.uuid && $0.isUsable })
        let usableSurvivors = after.filter { $0.uuid != target.uuid && $0.isUsable }
        let survivingPhysical = usableSurvivors.contains { !$0.isVirtual }
        let selectedVirtualSurvives = journal.policy == .remoteVirtualOnly
            && journal.virtualSelectionConfirmed
            && lease.isFresh(now: Date())
            && journal.virtualDisplayUUID.map { uuid in
                usableSurvivors.contains { $0.uuid == uuid && $0.isVirtual && $0.isOwned }
            } == true
        guard configured, !remainsUsable else {
            messageCode = .transactionFailed
            if remainsUsable {
                journal.disabledDisplayUUIDs.removeAll { $0 == target.uuid }
                journal.pendingRestoreUUIDs.removeAll { $0 == target.uuid }
                journal.updatedAt = Date()
                try? store.save(journal)
            }
            return false
        }
        guard survivingPhysical || selectedVirtualSurvives else {
            messageCode = .lastPhysicalDisplay
            return false
        }

        journal.pendingRestoreUUIDs.removeAll { $0 == target.uuid }
        journal.updatedAt = Date()
        do { try store.save(journal) }
        catch { messageCode = .recoveryIncomplete; return false }
        return true
    }

    private func prepareJournal(
        request: DisplayControlRequest,
        policy: DisplayControlPolicy,
        now: Date
    ) -> DisplayRecoveryJournal? {
        if let existing = loadJournal() {
            guard existing.generation == request.generation,
                  existing.policy == policy,
                  !existing.isComplete,
                  existing.systemSessionID == DisplayRecoverySession.identifier else {
                messageCode = .staleGeneration
                return nil
            }
            return existing
        }
        guard let generation = request.generation else { messageCode = .staleGeneration; return nil }
        var journal = DisplayRecoveryJournal(generation: generation, policy: policy, originalDisplays: snapshot(), now: now)
        controlHeartbeatAt = now
        if policy == .remoteVirtualOnly || policy == .remotePhysical || policy == .remoteVirtualWithPhysical {
            guard let session = request.remoteSessionID,
                  let requestedGeneration = request.generation else { messageCode = .uuSessionRequired; return nil }
            guard clearOverrideForExplicitRetry(request, session: session) else { return nil }
            if lease.sessionID == nil {
                guard lease.beginControl(
                    sessionID: session,
                    expectedGeneration: requestedGeneration,
                    activeGeneration: requestedGeneration,
                    now: now
                ) else { messageCode = .uuSessionRequired; return nil }
            }
            guard lease.sessionID == session, lease.isFresh(now: now) else {
                messageCode = .uuSessionRequired
                return nil
            }
            journal.remoteSessionID = session
            journal.remoteLeaseExpiresAt = now.addingTimeInterval(DisplayRemoteLease.lifetime)
        }
        do { try store.save(journal); self.generation = generation; return journal }
        catch { messageCode = .recoveryIncomplete; return nil }
    }

    private func validateGeneration(_ proposed: UUID?, allowNew: Bool) -> Bool {
        guard let proposed else { messageCode = .staleGeneration; return false }
        guard let current = activeJournalGeneration() else {
            guard allowNew, proposed == generation else { messageCode = .staleGeneration; return false }
            return true
        }
        guard current == proposed else { messageCode = .staleGeneration; return false }
        return true
    }

    private func prepareActiveGeneration(requested: UUID) -> UUID? {
        guard loadJournal() == nil, generation == requested else {
            messageCode = .staleGeneration
            return nil
        }
        let active = UUID()
        generation = active
        return active
    }

    private func activeJournalGeneration() -> UUID? { loadJournal()?.generation }
    private func loadJournal() -> DisplayRecoveryJournal? { try? store.load() }

    /// Only an explicit user re-apply may forget the per-session override left
    /// by a confirmation timeout or an emergency release. The automatic UU rule
    /// must keep respecting it, otherwise it would immediately undo the desktop
    /// the user just got back.
    private func clearOverrideForExplicitRetry(_ request: DisplayControlRequest, session: String) -> Bool {
        guard lease.manualOverrideSessionID == session else { return true }
        guard request.confirmed else { messageCode = .uuSessionRequired; return false }
        do { try overrideStore.clear() }
        catch { messageCode = .recoveryIncomplete; return false }
        lease.clearOverride()
        return true
    }

    private func persistOverride(for sessionID: String) throws {
        lease.beginNewSession(sessionID)
        lease.overrideCurrentSession()
        try overrideStore.save(sessionID)
    }

    @discardableResult
    private func revokeControl(for sessionID: String?) -> Bool {
        controlHeartbeatAt = nil
        let sessionToOverride = sessionID ?? lease.sessionID
        guard let sessionToOverride else {
            lease.clearLease()
            return !controlRevocationPersistenceFailed
        }
        do {
            try persistOverride(for: sessionToOverride)
            controlRevocationPersistenceFailed = false
            return true
        }
        catch {
            lease.clearLease()
            controlRevocationPersistenceFailed = true
            messageCode = .recoveryIncomplete
            return false
        }
    }

    private func restoreOne(targetUUID: String) {
        do {
            guard var journal = try store.load(),
                  journal.disabledDisplayUUIDs.contains(targetUUID),
                  journal.systemSessionID == DisplayRecoverySession.identifier,
                  let original = journal.originalDisplays.first(where: { $0.uuid == targetUUID }) else {
                messageCode = .invalidTarget
                return
            }
            journal.pendingRestoreUUIDs = Array(Set(journal.pendingRestoreUUIDs + [targetUUID])).sorted()
            journal.phase = .restoringDisplays
            journal.updatedAt = Date()
            try store.save(journal)
            guard restoreDisplay(original, journal: journal) else {
                state = .recoveryRequired
                messageCode = .recoveryIncomplete
                return
            }
            journal.pendingRestoreUUIDs.removeAll { $0 == targetUUID }
            journal.disabledDisplayUUIDs.removeAll { $0 == targetUUID }
            journal.updatedAt = Date()
            if journal.disabledDisplayUUIDs.isEmpty && journal.virtualDisplayUUID == nil {
                journal.phase = .restoringDisplays
                try store.save(journal)
                _ = revokeControl(for: journal.remoteSessionID)
                state = .recovering
                restoreAll()
            } else {
                journal.phase = .active
                try store.save(journal)
                state = .active
            }
            messageCode = nil
        } catch {
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
        }
    }

    private func restore(journal originalJournal: DisplayRecoveryJournal) -> Bool {
        guard originalJournal.systemSessionID == DisplayRecoverySession.identifier else { return false }
        var journal = originalJournal
        journal.phase = .restoringDisplays
        journal.confirmationDeadline = nil
        journal.updatedAt = Date()
        do { try store.save(journal) }
        catch { messageCode = .recoveryIncomplete; return false }

        // A prior attempt may have successfully re-enabled a display, removed
        // it from the journal, and then failed while restoring the main screen
        // or layout. If that display disappeared again, the next retry must
        // still rediscover it from the original topology.
        let online = driver.displays()
        let replacedIDs = Set(journal.originalDisplays.compactMap { original in
            online.contains(where: { $0.displayID == original.displayID && $0.uuid != original.uuid })
                ? original.displayID : nil
        })
        let mayRetryMissingOriginals = originalJournal.phase == .restoringDisplays
        let missingOriginals = journal.originalDisplays.filter { original in
            mayRetryMissingOriginals
                && original.isActive
                && !original.isVirtual
                && !replacedIDs.contains(original.displayID)
                && !online.contains(where: { $0.uuid == original.uuid && $0.isUsable })
        }
        let toRestore = Set(journal.disabledDisplayUUIDs + journal.pendingRestoreUUIDs + missingOriginals.map(\.uuid))
        for uuid in toRestore {
            guard let original = journal.originalDisplays.first(where: { $0.uuid == uuid }) else {
                messageCode = .recoveryIncomplete
                return false
            }
            if !journal.pendingRestoreUUIDs.contains(uuid) {
                journal.pendingRestoreUUIDs.append(uuid)
                if !journal.disabledDisplayUUIDs.contains(uuid) { journal.disabledDisplayUUIDs.append(uuid) }
                journal.updatedAt = Date()
                do { try store.save(journal) }
                catch { messageCode = .recoveryIncomplete; return false }
            }
            guard restoreDisplay(original, journal: journal) else { messageCode = .recoveryIncomplete; return false }
            journal.pendingRestoreUUIDs.removeAll { $0 == uuid }
            journal.disabledDisplayUUIDs.removeAll { $0 == uuid }
            journal.updatedAt = Date()
            do { try store.save(journal) }
            catch { messageCode = .recoveryIncomplete; return false }
        }

        if let virtualUUID = journal.virtualDisplayUUID {
            guard hasUsablePhysicalDisplay(), driver.destroyVirtual(uuid: virtualUUID, now: Date()) else {
                messageCode = .recoveryIncomplete
                return false
            }
        }
        if let virtualUUID = journal.virtualDisplayUUID,
           snapshot().contains(where: { $0.uuid == virtualUUID && $0.isUsable }) {
            messageCode = .recoveryIncomplete
            return false
        }

        guard restoreOriginalMainAndLayout(journal: journal) else {
            messageCode = .recoveryIncomplete
            return false
        }
        journal.phase = .complete
        journal.virtualDisplayUUID = nil
        journal.updatedAt = Date()
        do {
            try store.save(journal)
        } catch {
            messageCode = .recoveryIncomplete
            return false
        }
        return true
    }

    /// A completed journal is retained until a later helper tick verifies that
    /// the restored display identities, main screen, and layout stayed valid.
    private func finalizeRestorationIfStable(_ journal: DisplayRecoveryJournal, now: Date) -> Bool {
        guard journal.isComplete,
              journal.systemSessionID == DisplayRecoverySession.identifier else {
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
            return false
        }
        guard now >= journal.updatedAt,
              now.timeIntervalSince(journal.updatedAt) >= 1 else {
            state = .recovering
            return false
        }
        guard !controlRevocationPersistenceFailed else {
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
            return false
        }
        let current = driver.displays()
        let expected = journal.originalDisplays.filter(\.isActive)
        let identitiesMatch = expected.allSatisfy { original in
            current.contains(where: { $0.uuid == original.uuid && $0.isUsable })
                && !current.contains(where: { $0.displayID == original.displayID && $0.uuid != original.uuid })
        }
        let mainMatches = journal.originalMainDisplayUUID.map { mainUUID in
            current.contains(where: { $0.uuid == mainUUID && $0.isMain && $0.isUsable })
        } ?? true
        let layoutMatches = expected.allSatisfy { original in
            guard let actual = current.first(where: { $0.uuid == original.uuid && $0.isUsable }) else { return false }
            return abs(actual.originX - original.originX) <= 1 && abs(actual.originY - original.originY) <= 1
        }
        guard identitiesMatch, mainMatches, layoutMatches else {
            var retry = journal
            retry.phase = .restoringDisplays
            retry.updatedAt = now
            do { try store.save(retry) }
            catch { messageCode = .recoveryIncomplete }
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
            return false
        }
        do {
            try store.removeIfComplete()
            generation = UUID()
            state = .idle
            if messageCode != .confirmationExpired && messageCode != .uuSessionRequired {
                messageCode = .userOverride
            }
            return true
        } catch {
            state = .recoveryRequired
            messageCode = .recoveryIncomplete
            return false
        }
    }

    private func restoreDisplay(_ original: DisplayControlDisplay, journal: DisplayRecoveryJournal) -> Bool {
        guard journal.systemSessionID == DisplayRecoverySession.identifier else { return false }
        let online = snapshot()
        if let existing = online.first(where: { $0.uuid == original.uuid }) {
            guard original.isActive else { return true }
            if existing.isUsable { return true }
            guard driver.setEnabled(original, enabled: true) else { return false }
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.25)
                if let restored = snapshot().first(where: { $0.uuid == original.uuid }) {
                    if restored.isUsable { return true }
                } else if snapshot().contains(where: { $0.displayID == original.displayID && $0.uuid != original.uuid }) {
                    return false
                }
            }
            return false
        }
        if online.contains(where: { $0.displayID == original.displayID && $0.uuid != original.uuid }) {
            return false
        }
        guard original.isActive else { return true }
        let configured = driver.setEnabled(original, enabled: true)
        guard configured else { return false }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if let restored = snapshot().first(where: { $0.uuid == original.uuid }) {
                return restored.isUsable
            }
            if snapshot().contains(where: { $0.displayID == original.displayID && $0.uuid != original.uuid }) {
                return false
            }
        }
        return false
    }

    private func restoreOriginalMainAndLayout(journal: DisplayRecoveryJournal) -> Bool {
        guard let mainUUID = journal.originalMainDisplayUUID,
              let main = snapshot().first(where: { $0.uuid == mainUUID && $0.isUsable }) else {
            return journal.originalMainDisplayUUID == nil
        }
        guard !journal.disabledDisplayUUIDs.contains(mainUUID) else { return false }
        guard driver.setMain(main),
              snapshot().contains(where: { $0.uuid == mainUUID && $0.isMain && $0.isUsable }) else { return false }
        return driver.restoreLayout(journal.originalDisplays)
    }

    private func restoreAfterFailure() {
        let previousMessage = messageCode
        state = .recovering
        restoreAll()
        if messageCode == .userOverride { messageCode = previousMessage ?? .transactionFailed }
    }

    private func waitForUsableDisplay(uuid: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if snapshot().contains(where: { $0.uuid == uuid && $0.isVirtual && $0.isUsable }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private func snapshot(journal: DisplayRecoveryJournal? = nil) -> [DisplayControlDisplay] {
        let onlineDisplays = driver.displays()
        let trackedJournal = journal ?? loadJournal()
        let disabled = Set(trackedJournal?.disabledDisplayUUIDs ?? [])
        let onlineUUIDs = Set(onlineDisplays.map { $0.uuid })
        let disabledRows = (trackedJournal?.originalDisplays ?? []).filter { disabled.contains($0.uuid) && !onlineUUIDs.contains($0.uuid) }
            .map { original in
                DisplayControlDisplay(
                    uuid: original.uuid,
                    displayID: original.displayID,
                    name: original.name,
                    isBuiltIn: original.isBuiltIn,
                    isVirtual: original.isVirtual,
                    isOnline: false,
                    isActive: false,
                    isMain: false,
                    width: original.width,
                    height: original.height,
                    isOwned: true,
                    isAsleep: original.isAsleep,
                    vendorID: original.vendorID,
                    productID: original.productID,
                    serialNumber: original.serialNumber,
                    originX: original.originX,
                    originY: original.originY
                )
            }
        return onlineDisplays + disabledRows
    }

    private func hasUsablePhysicalDisplay() -> Bool {
        driver.displays().contains { !$0.isVirtual && $0.isUsable }
    }

    private func topologyIsContinuous(_ journal: DisplayRecoveryJournal) -> Bool {
        guard journal.phase != .prepared,
              journal.phase != .creatingVirtual,
              journal.phase != .complete else { return true }
        let onlineActive = driver.displays().filter {
            $0.isOnline && $0.isActive && $0.width > 0 && $0.height > 0
        }
        if journal.policy == .remoteVirtualOnly {
            guard let selectedUUID = journal.virtualDisplayUUID else { return true }
            return onlineActive.contains {
                $0.uuid == selectedUUID && $0.isVirtual && $0.isOwned
            }
        }
        return onlineActive.contains { !$0.isVirtual }
    }
}

public final class MacDisplayTopologyDriver: DisplayTopologyDriving, @unchecked Sendable {
    private struct VirtualDisplayHandle {
        var token: MDVirtualDisplayToken
        var createdAt: Date
    }

    private let lock = NSRecursiveLock()
    private var virtualDisplays: [String: VirtualDisplayHandle] = [:]
    private var releasedVirtualDisplays: Set<String> = []

    public init() {}

    public var displayEnableAPIAvailable: Bool { MDDisplayEnabledAPIAvailable() }
    public var virtualDisplayAPIAvailable: Bool { MDVirtualDisplayAPIAvailable() }

    public func displays() -> [DisplayControlDisplay] {
        lock.lock()
        defer { lock.unlock() }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 32 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { display(id: $0) }
    }

    public func setEnabled(_ display: DisplayControlDisplay, enabled: Bool) -> Bool {
        let current = displays()
        if let sameID = current.first(where: { $0.displayID == display.displayID }), sameID.uuid != display.uuid {
            return false
        }
        if let sameUUID = current.first(where: { $0.uuid == display.uuid }) {
            if enabled && sameUUID.isUsable { return true }
            guard enabled || sameUUID.isActive else { return false }
            guard enabled || current.contains(where: { $0.uuid != sameUUID.uuid && $0.isUsable }) else { return false }
        } else if !enabled {
            return false
        }
        var errorCode: Int32 = 0
        return MDDisplaySetEnabled(display.displayID, enabled, &errorCode)
    }

    public func setMain(_ display: DisplayControlDisplay) -> Bool {
        guard let current = displays().first(where: { $0.uuid == display.uuid && $0.isUsable }) else { return false }
        var errorCode: Int32 = 0
        return MDDisplaySetMain(current.displayID, &errorCode)
    }

    public func restoreLayout(_ originals: [DisplayControlDisplay]) -> Bool {
        let current = displays()
        let candidates = originals.filter(\.isUsable)
        let matches = candidates.compactMap { original -> (DisplayControlDisplay, DisplayControlDisplay)? in
            guard let present = current.first(where: { $0.uuid == original.uuid && $0.isUsable }) else { return nil }
            return (original, present)
        }
        guard matches.count == candidates.count else { return false }
        guard !matches.isEmpty else { return true }
        let ids = matches.map { CGDirectDisplayID($0.1.displayID) }
        let origins = matches.map { CGPoint(x: $0.0.originX, y: $0.0.originY) }
        var errorCode: Int32 = 0
        let configured = ids.withUnsafeBufferPointer { idBuffer in
            origins.withUnsafeBufferPointer { originBuffer in
                guard let idBase = idBuffer.baseAddress, let originBase = originBuffer.baseAddress else { return false }
                return MDDisplayRestoreOrigins(idBase, originBase, ids.count, &errorCode)
            }
        }
        guard configured else { return false }
        let after = displays()
        return matches.allSatisfy { original, present in
            guard let actual = after.first(where: { $0.uuid == present.uuid && $0.isUsable }) else { return false }
            return abs(actual.originX - original.originX) <= 1 && abs(actual.originY - original.originY) <= 1
        }
    }

    public func createVirtual(_ spec: DisplayVirtualSpec, name: String) -> DisplayVirtualCreation? {
        guard virtualDisplayAPIAvailable, spec.validationError == nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var displayID: CGDirectDisplayID = 0
        var settingsApplied = ObjCBool(false)
        guard let token = MDVirtualDisplayCreate(
            UInt32(spec.width),
            UInt32(spec.height),
            spec.hiDPI,
            spec.refreshRate,
            name,
            &displayID,
            &settingsApplied
        ) else { return nil }
        guard let uuid = uuid(for: displayID) else {
            // Keep the object alive. An unidentifiable virtual output must never
            // be released while the physical topology is uncertain.
            virtualDisplays["unidentified-\(displayID)"] = VirtualDisplayHandle(token: token, createdAt: Date())
            return nil
        }
        virtualDisplays[uuid] = VirtualDisplayHandle(token: token, createdAt: Date())
        releasedVirtualDisplays.remove(uuid)
        return DisplayVirtualCreation(uuid: uuid, settingsApplied: settingsApplied.boolValue)
    }

    public func destroyVirtual(uuid: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = virtualDisplays[uuid] else {
            return releasedVirtualDisplays.contains(uuid) && !displays().contains(where: { $0.uuid == uuid && $0.isUsable })
        }
        guard now.timeIntervalSince(handle.createdAt) >= 2.5 else { return false }
        guard displays().contains(where: { !$0.isVirtual && $0.isUsable }) else { return false }
        MDVirtualDisplayRelease(handle.token)
        virtualDisplays.removeValue(forKey: uuid)
        releasedVirtualDisplays.insert(uuid)
        return !displays().contains(where: { $0.uuid == uuid && $0.isUsable })
    }

    private func display(id: CGDirectDisplayID) -> DisplayControlDisplay? {
        guard let displayUUID = uuid(for: id), let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        let vendor = CGDisplayVendorNumber(id)
        let virtual = vendor == 0x5555
        let builtIn = CGDisplayIsBuiltin(id) != 0
        let mirrorID = CGDisplayMirrorsDisplay(id)
        let mirrorUUID = mirrorID == 0 ? nil : uuid(for: mirrorID)
        let bounds = CGDisplayBounds(id)
        let owned = virtualDisplays[displayUUID] != nil
        return DisplayControlDisplay(
            uuid: displayUUID,
            displayID: id,
            name: "\(virtual ? "Virtual" : (builtIn ? "Built-in" : "External")) Display · \(displayUUID.prefix(8))",
            isBuiltIn: builtIn,
            isVirtual: virtual,
            isOnline: CGDisplayIsOnline(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            width: mode.pixelWidth,
            height: mode.pixelHeight,
            isOwned: owned,
            isAsleep: CGDisplayIsAsleep(id) != 0,
            mirrorMasterUUID: mirrorUUID,
            vendorID: vendor,
            productID: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id),
            originX: Double(bounds.origin.x),
            originY: Double(bounds.origin.y)
        )
    }

    private func uuid(for id: CGDirectDisplayID) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard MDDisplayUUID(id, &buffer, buffer.count) else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
