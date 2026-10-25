import Foundation
import Testing
@testable import MacPilotDisplayControlCore

struct DisplayControlSafetyTests {
    private func display(
        _ uuid: String,
        id: UInt32,
        virtual: Bool = false,
        usable: Bool = true,
        main: Bool = false
    ) -> DisplayControlDisplay {
        DisplayControlDisplay(
            uuid: uuid,
            displayID: id,
            name: uuid,
            isBuiltIn: !virtual,
            isVirtual: virtual,
            isOnline: usable,
            isActive: usable,
            isMain: main,
            width: usable ? 1920 : 0,
            height: usable ? 1080 : 0,
            isOwned: virtual
        )
    }

    @Test func cannotDisableLastPhysicalDisplay() {
        let only = display("physical-1", id: 1, main: true)
        #expect(!DisplayControlSafety.canDisable(
            targetUUID: only.uuid,
            displays: [only],
            policy: .localPhysical,
            remoteSessionIsFresh: false,
            virtualSelectionConfirmed: false
        ))
        #expect(DisplayControlSafety.canKeepOnly(
            targetUUID: only.uuid,
            displays: [only],
            policy: .localPhysical,
            remoteSessionIsFresh: false,
            virtualSelectionConfirmed: false
        ))
    }

    @Test func cannotDisableScreenWhenRemainingOutputIsUnusable() {
        let active = display("physical-1", id: 1, main: true)
        let offline = display("physical-2", id: 2, usable: false)
        #expect(!DisplayControlSafety.canDisable(
            targetUUID: active.uuid,
            displays: [active, offline],
            policy: .localPhysical,
            remoteSessionIsFresh: false,
            virtualSelectionConfirmed: false
        ))
    }

    @Test func remoteVirtualOnlyRequiresFreshSessionAndExplicitConfirmation() {
        let physical = display("physical-1", id: 1, main: true)
        let virtual = display("virtual-1", id: 2, virtual: true)
        #expect(!DisplayControlSafety.canDisable(
            targetUUID: physical.uuid,
            displays: [physical, virtual],
            policy: .remoteVirtualOnly,
            remoteSessionIsFresh: false,
            virtualSelectionConfirmed: true
        ))
        #expect(!DisplayControlSafety.canDisable(
            targetUUID: physical.uuid,
            displays: [physical, virtual],
            policy: .remoteVirtualOnly,
            remoteSessionIsFresh: true,
            virtualSelectionConfirmed: false
        ))
        #expect(DisplayControlSafety.canDisable(
            targetUUID: physical.uuid,
            displays: [physical, virtual],
            policy: .remoteVirtualOnly,
            remoteSessionIsFresh: true,
            virtualSelectionConfirmed: true,
            confirmedVirtualUUID: "virtual-1"
        ))
    }

    @Test func cannotKeepOnlyAnOfflineOrUnconfirmedVirtualDisplay() {
        let offlineVirtual = display("virtual-1", id: 2, virtual: true, usable: false)
        #expect(!DisplayControlSafety.canKeepOnly(
            targetUUID: offlineVirtual.uuid,
            displays: [offlineVirtual],
            policy: .remoteVirtualOnly,
            remoteSessionIsFresh: true,
            virtualSelectionConfirmed: true
        ))

        let virtual = display("virtual-1", id: 2, virtual: true)
        #expect(!DisplayControlSafety.canKeepOnly(
            targetUUID: virtual.uuid,
            displays: [virtual],
            policy: .remoteVirtualOnly,
            remoteSessionIsFresh: true,
            virtualSelectionConfirmed: false
        ))
    }

    @Test func mirroredSurvivorDoesNotCountAsAnIndependentOutput() {
        let target = display("physical-1", id: 1, main: true)
        let mirror = DisplayControlDisplay(
            uuid: "physical-2",
            displayID: 2,
            name: "Mirror",
            isBuiltIn: false,
            isVirtual: false,
            isOnline: true,
            isActive: true,
            isMain: false,
            width: 1920,
            height: 1080,
            mirrorMasterUUID: target.uuid
        )
        #expect(!DisplayControlSafety.canDisable(
            targetUUID: target.uuid,
            displays: [target, mirror],
            policy: .localPhysical,
            remoteSessionIsFresh: false,
            virtualSelectionConfirmed: false
        ))
    }

    @Test func invalidVirtualDimensionsAreRejected() {
        #expect(DisplayVirtualSpec(width: 2559, height: 1600).validationError != nil)
        #expect(DisplayVirtualSpec(width: 2560, height: 1600).validationError == nil)
        #expect(DisplayVirtualSpec(width: 2560, height: 1600, refreshRate: .infinity).validationError != nil)
    }
}

struct DisplayRemoteLeaseTests {
    @Test func missingOrStaleHeartbeatCannotAuthorizeVirtualOnlyMode() {
        var lease = DisplayRemoteLease()
        let now = Date(timeIntervalSince1970: 1_000)
        let missingRenewal = lease.renew(sessionID: nil, generation: UUID(), now: now)
        #expect(!missingRenewal)
        #expect(!lease.isFresh(now: now))
        let freshRenewal = lease.renew(sessionID: "uu-session", generation: UUID(), now: now)
        #expect(freshRenewal)
        #expect(lease.isFresh(now: now.addingTimeInterval(2)))
        #expect(!lease.isFresh(now: now.addingTimeInterval(DisplayRemoteLease.lifetime + 1)))
    }

    @Test func manualOverrideDoesNotRenewCurrentSession() {
        var lease = DisplayRemoteLease()
        let generation = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let firstRenewal = lease.renew(sessionID: "first", generation: generation, now: now)
        #expect(firstRenewal)
        lease.overrideCurrentSession()
        let overriddenRenewal = lease.renew(sessionID: "first", generation: generation, now: now.addingTimeInterval(1))
        #expect(!overriddenRenewal)
        lease.beginNewSession("second")
        let secondRenewal = lease.renew(sessionID: "second", generation: UUID(), now: now.addingTimeInterval(2))
        #expect(secondRenewal)
    }

    @Test func heartbeatCannotChangeCurrentSessionOrGeneration() {
        var lease = DisplayRemoteLease()
        let generation = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let initialRenewal = lease.renew(sessionID: "first", generation: generation, now: now)
        let differentSessionRenewal = lease.renew(sessionID: "second", generation: generation, now: now.addingTimeInterval(1))
        let differentGenerationRenewal = lease.renew(sessionID: "first", generation: UUID(), now: now.addingTimeInterval(1))
        #expect(initialRenewal)
        #expect(!differentSessionRenewal)
        #expect(!differentGenerationRenewal)
    }
}

struct DisplayRecoveryJournalTests {
    private func fixture() -> (URL, DisplayRecoveryJournal) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physical = DisplayControlDisplay(
            uuid: "physical-1",
            displayID: 1,
            name: "Built-in",
            isBuiltIn: true,
            isVirtual: false,
            isOnline: true,
            isActive: true,
            isMain: true,
            width: 1920,
            height: 1080
        )
        let journal = DisplayRecoveryJournal(
            generation: UUID(),
            policy: .localPhysical,
            originalDisplays: [physical]
        )
        return (directory.appendingPathComponent("recovery.json"), journal)
    }

    @Test func journalRoundTripsThroughPrivateAtomicStore() throws {
        let (url, journal) = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DisplayRecoveryJournalStore(fileURL: url)
        try store.save(journal)
        #expect(try store.load() == journal)
    }

    @Test func incompleteOrOutOfScopeRecoveryEntriesAreRejected() throws {
        let (url, original) = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var journal = original
        journal.disabledDisplayUUIDs = ["foreign-display"]
        journal.pendingRestoreUUIDs = ["foreign-display"]
        #expect(throws: DisplayRecoveryJournalStore.StoreError.self) {
            try DisplayRecoveryJournalStore(fileURL: url).save(journal)
        }
    }

    @Test func incompleteJournalCannotBeRemoved() throws {
        let (url, journal) = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DisplayRecoveryJournalStore(fileURL: url)
        try store.save(journal)
        #expect(throws: DisplayRecoveryJournalStore.StoreError.recoveryPending) {
            try store.removeIfComplete()
        }
    }

    @Test func corruptJournalIsNeverSilentlyIgnored() throws {
        let (url, _) = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try DisplayRecoveryJournalStore(fileURL: url).load() }
    }
}
