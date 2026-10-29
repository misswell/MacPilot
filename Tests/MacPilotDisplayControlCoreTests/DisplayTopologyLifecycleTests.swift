import Foundation
import Testing
@testable import MacPilotDisplayControlCore

struct DisplayTopologyLifecycleTests {
    @Test func readinessTimeoutKeepsTheCreatedUUIDAndPhysicalDisplays() throws {
        let f = LifecycleFixture(readinessTimeout: 0)
        defer { f.removeFiles() }
        f.driver.hiddenVirtual = true
        f.controller.handle(.init(command: .prepareVirtual, virtualSpec: .init(width: 1920, height: 1080),
            generation: f.generation, remoteSessionID: "tablet", policy: .remoteVirtualOnly))
        #expect(try f.store.load()?.virtualDisplayUUID == "virtual")
        #expect(try f.store.load()?.phase == .creatingVirtual)
        #expect(f.controller.response().state == .recoveryRequired)
        #expect(f.driver.current.filter { !$0.isVirtual && $0.isUsable }.count == 2)
    }

    @Test func failedUUIDCommitBlocksFurtherChangesAndRetainsTheKnownTarget() throws {
        let f = LifecycleFixture(beforeSave: { journal in
            if journal.virtualDisplayUUID != nil { throw DisplayRecoveryJournalStore.StoreError.writeVerificationFailed }
        })
        defer { f.removeFiles() }
        f.driver.allowVirtualDestruction = false
        f.controller.handle(.init(command: .prepareVirtual, virtualSpec: .init(width: 1920, height: 1080),
            generation: f.generation, remoteSessionID: "tablet", policy: .remoteVirtualOnly))
        #expect(f.controller.response().virtualDisplayUUID == "virtual")
        #expect(f.controller.response().state == .recoveryRequired)
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: f.generation))
        #expect(f.driver.current.contains { $0.uuid == "two" && $0.isUsable })
        #expect(f.controller.response().state == .recoveryRequired)
        #expect(try f.store.load()?.phase == .creatingVirtual)
    }

    @Test func aMissingDisplayDoesNotStopRestoringOtherPendingDisplays() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let originals = f.driver.current
        f.driver.current.removeAll()
        f.driver.failEnableUUID = "one"
        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .localPhysical, originalDisplays: originals)
        journal.disabledDisplayUUIDs = ["one", "two"]
        journal.pendingRestoreUUIDs = ["one", "two"]
        try f.store.save(journal)
        f.controller.recoverAtStartup()
        #expect(f.driver.current.contains { $0.uuid == "two" && $0.isUsable })
        #expect(try f.store.load()?.pendingRestoreUUIDs == ["one"])
        #expect(f.controller.response().state == .recoveryRequired)
    }

    @Test func virtualConfirmationCapturesDisplaysAttachedAfterPreparation() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .prepareVirtual, virtualSpec: .init(width: 1920, height: 1080),
            generation: f.generation, remoteSessionID: "tablet", policy: .remoteVirtualOnly), now: now)
        f.driver.current.append(.init(uuid: "three", displayID: 4, name: "three", isBuiltIn: false,
            isVirtual: false, isOnline: true, isActive: true, isMain: false, width: 1920, height: 1080))
        f.controller.handle(.init(command: .confirmVirtual, generation: f.generation,
            remoteSessionID: "tablet", confirmed: true), now: Date())
        #expect(try f.store.load()?.originalDisplays.contains { $0.uuid == "three" } == true)
        #expect(!f.driver.current.contains { $0.uuid == "three" })
        f.controller.restoreAll()
        #expect(f.driver.current.contains { $0.uuid == "three" && $0.isUsable })
    }

    @Test func virtualIdentityIsDurableBeforeReadinessIsChecked() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        var observed = false
        f.driver.afterCreationEnumeration = {
            observed = (try? f.store.load()?.virtualDisplayUUID) == "virtual"
        }
        f.controller.handle(.init(command: .prepareVirtual, virtualSpec: .init(width: 1920, height: 1080),
            generation: f.generation, remoteSessionID: "tablet", policy: .remoteVirtualWithPhysical))
        #expect(observed)
    }

    @Test func anotherSessionCannotConfirmPhysicalControl() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .keepOnly, targetUUID: "one", generation: f.generation,
            remoteSessionID: "tablet", policy: .remotePhysical), now: now)
        f.controller.handle(.init(command: .confirmChange, generation: f.generation,
            remoteSessionID: "other-tablet", confirmed: true), now: now.addingTimeInterval(1))
        #expect(f.controller.response().state == .awaitingKeepConfirmation)
        #expect(try f.store.load()?.confirmationDeadline != nil)
    }

    @Test func newlyAttachedTargetIsJournaledBeforeItIsDisabled() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: f.generation), now: now)
        f.driver.current.append(.init(uuid: "three", displayID: 3, name: "three", isBuiltIn: false,
            isVirtual: false, isOnline: true, isActive: true, isMain: false, width: 1920, height: 1080))
        f.controller.handle(.init(command: .disable, targetUUID: "three", generation: f.generation), now: now)
        #expect(!f.driver.current.contains { $0.uuid == "three" })
        #expect(try f.store.load()?.originalDisplays.contains { $0.uuid == "three" } == true)
    }

    @Test func oldSystemSessionReconcilesUsableDisplaysWithoutReusingOldNumericIDs() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .localPhysical,
            originalDisplays: f.driver.current)
        journal.systemSessionID = "previous-login"
        journal.disabledDisplayUUIDs = ["two"]
        try f.store.save(journal)
        f.controller.recoverAtStartup()
        #expect(try f.store.load()?.isComplete == true)
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        #expect(f.controller.response().state == .idle)
    }

    @Test func sessionLocalFallbackIdentityCannotAuthorizeCrossSessionRecoveryEffects() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let ambiguous = "cg-00000001-1234-5678-00000000"
        let original = DisplayControlDisplay(uuid: ambiguous, displayID: 1, name: "original panel",
            isBuiltIn: false, isVirtual: false, isOnline: true, isActive: true, isMain: true,
            width: 1920, height: 1080)
        let other = f.driver.current[1]
        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .localPhysical,
            originalDisplays: [original, other])
        journal.systemSessionID = "previous-login"
        journal.disabledDisplayUUIDs = [ambiguous]
        journal.pendingRestoreUUIDs = [ambiguous]
        try f.store.save(journal)
        // A same-model panel can reuse the fallback identity and numeric ID.
        f.driver.current = [DisplayControlDisplay(uuid: ambiguous, displayID: 1, name: "different panel",
            isBuiltIn: false, isVirtual: false, isOnline: true, isActive: false, isMain: false,
            width: 1920, height: 1080), other]
        f.controller.recoverAtStartup()
        #expect(!f.driver.enabledUUIDs.contains(ambiguous))
        #expect(!f.driver.mainUUIDs.contains(ambiguous))
        #expect(!f.driver.layoutUUIDs.contains(ambiguous))
        #expect(try f.store.load()?.pendingRestoreUUIDs.contains(ambiguous) == true)
        #expect(f.controller.response().state == .recoveryRequired)
    }

    @Test func usableSessionLocalIdentityCannotBeReboundByOtherwiseSuccessfulRecovery() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let ambiguous = "cg-00000002-1234-5678-00000000"
        let stableMain = f.driver.current[0]
        let reusedPanel = DisplayControlDisplay(uuid: ambiguous, displayID: 2, name: "reused panel",
            isBuiltIn: false, isVirtual: false, isOnline: true, isActive: true, isMain: false,
            width: 1920, height: 1080)
        f.driver.current = [stableMain, reusedPanel]
        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .localPhysical,
            originalDisplays: f.driver.current)
        journal.systemSessionID = "previous-login"
        // Nothing needs enabling: the unsafe path used to mark this journal
        // complete and replace its session binding after restoring the stable main.
        try f.store.save(journal)
        f.controller.recoverAtStartup()
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        let retained = try #require(try f.store.load())
        #expect(retained.systemSessionID == "previous-login")
        #expect(!retained.isComplete)
        #expect(f.driver.enabledUUIDs.isEmpty)
        #expect(!f.driver.mainUUIDs.contains(ambiguous))
        #expect(!f.driver.layoutUUIDs.contains(ambiguous))
        #expect(f.controller.response().state == .recoveryRequired)
    }

    @Test func unconfirmedLocalChangeRollsBackAtItsDeadline() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: f.generation), now: now)
        #expect(f.controller.response().state == .awaitingKeepConfirmation)
        #expect(!f.driver.current.contains { $0.uuid == "two" })
        f.controller.expireLeases(now: now.addingTimeInterval(16))
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        #expect(f.controller.response().state == .idle)
        #expect(f.driver.current.contains { $0.uuid == "two" && $0.isUsable })
        #expect(try f.store.load() == nil)
    }

    @Test func confirmedLocalControlStillRestoresWhenTheGUILeaseExpires() {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: f.generation), now: now)
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, confirmed: true), now: now)
        #expect(f.controller.response().state == .active)
        f.controller.expireLeases(now: now.addingTimeInterval(DisplayRemoteLease.lifetime + 1))
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        #expect(f.controller.response().state == .idle)
        #expect(f.driver.current.count == 2)
    }

    @Test func virtualOnlyRequiresTwoStagesAndRestoresPhysicalBeforeVirtualRemoval() {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .prepareVirtual, virtualSpec: .init(width: 1920, height: 1080),
            generation: f.generation, remoteSessionID: "tablet", policy: .remoteVirtualOnly), now: now)
        let prepared = f.controller.response()
        #expect(prepared.state == .awaitingVirtualConfirmation)
        #expect(f.driver.current.filter { !$0.isVirtual && $0.isUsable }.count == 2)
        f.controller.handle(.init(command: .confirmVirtual, generation: prepared.generation,
            remoteSessionID: "tablet", confirmed: true), now: now)
        let changed = f.controller.response()
        #expect(changed.state == .awaitingKeepConfirmation)
        #expect(f.driver.current.filter(\.isUsable).count == 1)
        #expect(f.driver.current.first?.isVirtual == true)
        f.controller.handle(.init(command: .restore), now: now)
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        #expect(f.controller.response().state == .idle)
        #expect(f.driver.current.filter { !$0.isVirtual && $0.isUsable }.count == 2)
        #expect(f.driver.physicalWasUsableAtVirtualDestruction)
    }

    @Test func remotePhysicalControlEstablishesAndRenewsItsOwnSessionLease() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .keepOnly, targetUUID: "one", generation: f.generation,
            remoteSessionID: "tablet", policy: .remotePhysical), now: now)
        #expect(f.controller.response().state == .awaitingKeepConfirmation)
        let journal = try #require(try f.store.load())
        #expect(journal.remoteSessionID == "tablet")
        f.controller.handle(.init(command: .heartbeat, generation: f.generation,
            remoteSessionID: "tablet"), now: now.addingTimeInterval(1))
        f.controller.expireLeases(now: now.addingTimeInterval(2))
        #expect(f.controller.response().state == .awaitingKeepConfirmation)
        f.controller.handle(.init(command: .heartbeat, generation: f.generation), now: now.addingTimeInterval(3))
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        #expect(f.controller.response().state == .idle)
    }

    @Test func lateHeartbeatAfterLeaseExpiryCannotReviveControlBeforeTimerTick() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .keepOnly, targetUUID: "one", generation: f.generation,
            remoteSessionID: "tablet", policy: .remotePhysical), now: now)
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, remoteSessionID: "tablet", confirmed: true),
            now: now.addingTimeInterval(1))
        f.controller.handle(.init(command: .heartbeat, generation: f.generation, remoteSessionID: "tablet"),
            now: now.addingTimeInterval(DisplayRemoteLease.lifetime + 1))

        #expect(f.controller.response().state == .recovering)
        #expect(try f.store.load()?.phase == .complete)
        #expect(try DisplaySessionOverrideStore(fileURL: f.root.appendingPathComponent("override.json")).load() == "tablet")
    }

    @Test func expiredLeaseRejectsOldKeepOnlyBeforeItCanChangeTopology() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.driver.current.append(.init(uuid: "three", displayID: 3, name: "three", isBuiltIn: false,
            isVirtual: false, isOnline: true, isActive: true, isMain: false,
            width: 1920, height: 1080, isOwned: false))
        f.controller.handle(.init(command: .keepOnly, targetUUID: "one", generation: f.generation,
            remoteSessionID: "tablet", policy: .remotePhysical), now: now)
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, remoteSessionID: "tablet", confirmed: true), now: now)
        f.controller.handle(.init(command: .heartbeat, generation: f.generation, remoteSessionID: "tablet"),
            now: now.addingTimeInterval(1))

        f.controller.handle(.init(command: .keepOnly, targetUUID: "two", generation: f.generation,
            remoteSessionID: "tablet", policy: .remotePhysical), now: now.addingTimeInterval(DisplayRemoteLease.lifetime + 2))

        #expect(f.controller.response().state == .recovering)
        #expect(try f.store.load()?.isComplete == true)
        #expect(f.driver.current.filter { !$0.isVirtual && $0.isUsable }.count == 3)
    }

    @Test func noJournalHeartbeatCannotAcquireControl() {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        f.controller.handle(.init(command: .heartbeat, generation: f.generation, remoteSessionID: "tablet"))
        #expect(f.controller.response().state == .idle)
        #expect(f.controller.response().message == DisplayControlMessageCode.userOverride.rawValue)
        #expect((try? f.store.load()) == nil)
    }

    @Test func recoveryRequiredHeartbeatCannotExtendTheLeaseOrReuseOldGeneration() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        let originals = f.driver.current
        f.driver.current.removeAll { $0.uuid == "two" }
        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .remotePhysical, originalDisplays: originals)
        journal.remoteSessionID = "tablet"
        journal.remoteLeaseExpiresAt = now.addingTimeInterval(30)
        journal.disabledDisplayUUIDs = ["two"]
        journal.pendingRestoreUUIDs = ["two"]
        journal.phase = .restoringDisplays
        try f.store.save(journal)
        f.driver.failEnables = true
        f.controller.recoverAtStartup()
        #expect(f.controller.response().state == .recoveryRequired)

        f.controller.handle(.init(command: .heartbeat, generation: journal.generation,
            remoteSessionID: "tablet"), now: now.addingTimeInterval(3))

        f.controller.handle(.init(command: .disable, targetUUID: "one", generation: journal.generation),
            now: now.addingTimeInterval(4))

        #expect(f.controller.response().state == .recoveryRequired)
        #expect(try f.store.load()?.remoteLeaseExpiresAt == journal.remoteLeaseExpiresAt)
        #expect(try f.store.load()?.phase == .restoringDisplays)
        #expect(!f.driver.current.contains { $0.uuid == "one" && !$0.isUsable })
        #expect(try DisplaySessionOverrideStore(fileURL: f.root.appendingPathComponent("override.json")).load() == "tablet")
    }

    @Test func completedJournalWaitsForRestoredTopologyToStayValid() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: f.generation), now: now)
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, confirmed: true), now: now)
        f.controller.handle(.init(command: .restore), now: now.addingTimeInterval(1))
        #expect(try f.store.load()?.isComplete == true)

        f.driver.current.removeAll { $0.uuid == "two" }
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))

        #expect(f.controller.response().state == .recoveryRequired)
        #expect(try f.store.load()?.phase == .restoringDisplays)
    }

    @Test func stableRestoreAcceptsTheSameDisplayUUIDAfterItsNumericIDChanges() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: f.generation), now: now)
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, confirmed: true), now: now)
        f.controller.handle(.init(command: .restore), now: now.addingTimeInterval(1))
        let originalMain = try #require(f.driver.current.first(where: { $0.uuid == "one" }))
        f.driver.current[0] = .init(uuid: originalMain.uuid, displayID: 9, name: originalMain.name,
            isBuiltIn: originalMain.isBuiltIn, isVirtual: originalMain.isVirtual,
            isOnline: originalMain.isOnline, isActive: originalMain.isActive, isMain: originalMain.isMain,
            width: originalMain.width, height: originalMain.height, isOwned: originalMain.isOwned,
            originX: originalMain.originX, originY: originalMain.originY)

        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))

        #expect(f.controller.response().state == .idle)
        #expect(try f.store.load() == nil)
    }

    @Test func failedPhysicalRestoreNeverDestroysTheSoleVirtualOutput() {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let now = Date()
        f.controller.handle(.init(command: .prepareVirtual, virtualSpec: .init(width: 1920, height: 1080),
            generation: f.generation, remoteSessionID: "tablet", policy: .remoteVirtualOnly), now: now)
        f.controller.handle(.init(command: .confirmVirtual, generation: f.generation,
            remoteSessionID: "tablet", confirmed: true), now: now)
        f.driver.failEnables = true
        f.controller.handle(.init(command: .restore), now: now)
        #expect(f.controller.response().state == .recoveryRequired)
        #expect(f.driver.current.contains { $0.isVirtual && $0.isUsable })
        #expect(f.driver.destroyCount == 0)
    }

    @Test func restoreRetriesAnOriginalActiveDisplayEvenAfterItsPendingEntryWasCleared() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let originalMain = f.driver.current[0]
        let external = f.driver.current[1]
        f.driver.current = [external]

        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .localPhysical,
            originalDisplays: [originalMain, external])
        journal.phase = .restoringDisplays
        try f.store.save(journal)

        f.controller.handle(.init(command: .restore))
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))

        #expect(f.controller.response().state == .idle)
        #expect(f.driver.current.contains { $0.uuid == originalMain.uuid && $0.isUsable && $0.isMain })
        #expect(try f.store.load() == nil)
    }

    @Test func failedRetryKeepsMissingOriginalDisplayJournaledForAnotherAttempt() throws {
        let f = LifecycleFixture()
        defer { f.removeFiles() }
        let originalMain = f.driver.current[0]
        let external = f.driver.current[1]
        f.driver.current = [external]
        f.driver.failEnables = true

        var journal = DisplayRecoveryJournal(generation: UUID(), policy: .remoteVirtualOnly,
            originalDisplays: [originalMain, external])
        journal.phase = .restoringDisplays
        journal.remoteSessionID = "tablet"
        journal.virtualDisplayUUID = "virtual"
        f.driver.current.append(.init(uuid: "virtual", displayID: 3, name: "virtual", isBuiltIn: false,
            isVirtual: true, isOnline: true, isActive: true, isMain: false,
            width: 1920, height: 1080, isOwned: true))
        try f.store.save(journal)

        f.controller.handle(.init(command: .restore))

        #expect(f.controller.response().state == .recoveryRequired)
        #expect(f.driver.current.contains { $0.uuid == "virtual" && $0.isUsable })
        #expect(f.driver.destroyCount == 0)
        let saved = try #require(try f.store.load())
        #expect(saved.disabledDisplayUUIDs.contains(originalMain.uuid))
        #expect(saved.pendingRestoreUUIDs.contains(originalMain.uuid))
        #expect(saved.pendingRestoreUUIDs.allSatisfy(saved.disabledDisplayUUIDs.contains))

        f.driver.failEnables = false
        f.controller.handle(.init(command: .restore))
        f.controller.expireLeases(now: Date().addingTimeInterval(1.1))
        #expect(f.controller.response().state == .idle)
        #expect(f.controller.response().message == DisplayControlMessageCode.userOverride.rawValue)
        #expect(try f.store.load() == nil)

        let idleGeneration = f.controller.response().generation
        f.controller.handle(.init(command: .disable, targetUUID: "two", generation: idleGeneration))
        #expect(f.controller.response().state == .awaitingKeepConfirmation)
        #expect(!f.driver.current.contains { $0.uuid == "two" && $0.isUsable })
    }
}

private final class LifecycleFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let driver = LifecycleDisplayDriver()
    let store: DisplayRecoveryJournalStore
    let controller: DisplayTopologyController
    var generation: UUID? { controller.response().generation }

    init(readinessTimeout: TimeInterval = 10, beforeSave: (@Sendable (DisplayRecoveryJournal) throws -> Void)? = nil) {
        store = DisplayRecoveryJournalStore(fileURL: root.appendingPathComponent("recovery.json"), beforeSave: beforeSave)
        controller = DisplayTopologyController(store: store,
            overrideStore: .init(fileURL: root.appendingPathComponent("override.json")),
            driver: driver, emergencyHotKeyReady: true, authenticationReady: true, virtualReadinessTimeout: readinessTimeout)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private final class LifecycleDisplayDriver: DisplayTopologyDriving, @unchecked Sendable {
    let displayEnableAPIAvailable = true
    let virtualDisplayAPIAvailable = true
    var current = [LifecycleDisplayDriver.record("one", id: 1, main: true), LifecycleDisplayDriver.record("two", id: 2)]
    var failEnables = false
    var hiddenVirtual = false
    var failEnableUUID: String?
    var allowVirtualDestruction = true
    var physicalWasUsableAtVirtualDestruction = false
    var destroyCount = 0
    var enabledUUIDs: [String] = []
    var mainUUIDs: [String] = []
    var layoutUUIDs: [String] = []

    var afterCreationEnumeration: (() -> Void)?
    private var didCreate = false
    func displays() -> [DisplayControlDisplay] {
        if didCreate { afterCreationEnumeration?() }
        return hiddenVirtual ? current.filter { !$0.isVirtual } : current
    }
    func setEnabled(_ display: DisplayControlDisplay, enabled: Bool) -> Bool {
        enabledUUIDs.append(display.uuid)
        if enabled {
            guard !failEnables, display.uuid != failEnableUUID else { return false }
            if !current.contains(where: { $0.uuid == display.uuid }) { current.append(display) }
        } else { current.removeAll { $0.uuid == display.uuid } }
        return true
    }
    func setMain(_ display: DisplayControlDisplay) -> Bool {
        mainUUIDs.append(display.uuid)
        current = current.map { d in
            Self.record(d.uuid, id: d.displayID, main: d.uuid == display.uuid, virtual: d.isVirtual)
        }
        return true
    }
    func restoreLayout(_ originals: [DisplayControlDisplay]) -> Bool {
        layoutUUIDs += originals.map(\.uuid)
        return true
    }
    func createVirtual(_ spec: DisplayVirtualSpec, name: String) -> DisplayVirtualCreation? {
        didCreate = true
        current.append(Self.record("virtual", id: 3, virtual: true))
        return .init(uuid: "virtual", settingsApplied: true)
    }
    func destroyVirtual(uuid: String, now: Date) -> Bool {
        physicalWasUsableAtVirtualDestruction = current.contains { !$0.isVirtual && $0.isUsable }
        guard physicalWasUsableAtVirtualDestruction, allowVirtualDestruction else { return false }
        current.removeAll { $0.uuid == uuid }
        destroyCount += 1
        return true
    }
    private static func record(_ uuid: String, id: UInt32, main: Bool = false, virtual: Bool = false) -> DisplayControlDisplay {
        .init(uuid: uuid, displayID: id, name: uuid, isBuiltIn: false, isVirtual: virtual,
            isOnline: true, isActive: true, isMain: main, width: 1920, height: 1080, isOwned: virtual)
    }
}
