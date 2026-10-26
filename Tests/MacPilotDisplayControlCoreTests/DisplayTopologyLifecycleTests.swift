import Foundation
import Testing
@testable import MacPilotDisplayControlCore

struct DisplayTopologyLifecycleTests {
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
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, confirmed: true),
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
        f.controller.handle(.init(command: .confirmChange, generation: f.generation, confirmed: true), now: now)
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

    init() {
        store = DisplayRecoveryJournalStore(fileURL: root.appendingPathComponent("recovery.json"))
        controller = DisplayTopologyController(store: store,
            overrideStore: .init(fileURL: root.appendingPathComponent("override.json")),
            driver: driver, emergencyHotKeyReady: true, authenticationReady: true)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private final class LifecycleDisplayDriver: DisplayTopologyDriving, @unchecked Sendable {
    let displayEnableAPIAvailable = true
    let virtualDisplayAPIAvailable = true
    var current = [LifecycleDisplayDriver.record("one", id: 1, main: true), LifecycleDisplayDriver.record("two", id: 2)]
    var failEnables = false
    var physicalWasUsableAtVirtualDestruction = false
    var destroyCount = 0

    func displays() -> [DisplayControlDisplay] { current }
    func setEnabled(_ display: DisplayControlDisplay, enabled: Bool) -> Bool {
        if enabled {
            guard !failEnables else { return false }
            if !current.contains(where: { $0.uuid == display.uuid }) { current.append(display) }
        } else { current.removeAll { $0.uuid == display.uuid } }
        return true
    }
    func setMain(_ display: DisplayControlDisplay) -> Bool {
        current = current.map { d in
            Self.record(d.uuid, id: d.displayID, main: d.uuid == display.uuid, virtual: d.isVirtual)
        }
        return true
    }
    func restoreLayout(_ originals: [DisplayControlDisplay]) -> Bool { true }
    func createVirtual(_ spec: DisplayVirtualSpec, name: String) -> DisplayVirtualCreation? {
        current.append(Self.record("virtual", id: 3, virtual: true))
        return .init(uuid: "virtual", settingsApplied: true)
    }
    func destroyVirtual(uuid: String, now: Date) -> Bool {
        physicalWasUsableAtVirtualDestruction = current.contains { !$0.isVirtual && $0.isUsable }
        guard physicalWasUsableAtVirtualDestruction else { return false }
        current.removeAll { $0.uuid == uuid }
        destroyCount += 1
        return true
    }
    private static func record(_ uuid: String, id: UInt32, main: Bool = false, virtual: Bool = false) -> DisplayControlDisplay {
        .init(uuid: uuid, displayID: id, name: uuid, isBuiltIn: false, isVirtual: virtual,
            isOnline: true, isActive: true, isMain: main, width: 1920, height: 1080, isOwned: virtual)
    }
}
