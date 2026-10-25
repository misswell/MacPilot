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
        #expect(f.controller.response().state == .idle)
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
