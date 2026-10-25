import Foundation
import Testing
@testable import MacPilotDisplayControlCore

struct DisplayTopologyControllerTests {
    @Test func idleResponseAlwaysProvidesGenerationForFirstOperation() {
        let fixture = ControllerFixture(displays: [screen("one", id: 1, main: true)])
        #expect(fixture.controller.response().generation != nil)
        #expect(fixture.controller.response().helperReady)
    }

    @Test func controllerRefusesToDisableTheOnlyPhysicalOutput() {
        let only = screen("one", id: 1, main: true)
        let fixture = ControllerFixture(displays: [only])
        let generation = fixture.controller.response().generation

        fixture.controller.handle(DisplayControlRequest(
            command: .disable,
            targetUUID: only.uuid,
            generation: generation,
            policy: .localPhysical
        ))

        #expect(fixture.controller.response().message == DisplayControlMessageCode.lastPhysicalDisplay.rawValue)
        #expect(fixture.driver.disableCalls == 0)
        #expect(fixture.driver.displays().contains(where: { $0.uuid == only.uuid && $0.isUsable }))
    }

    @Test func staleGenerationCannotQueueAChangeAfterRestoreFence() {
        let fixture = ControllerFixture(displays: [
            screen("one", id: 1, main: true),
            screen("two", id: 2)
        ])
        let stale = UUID()
        fixture.controller.handle(DisplayControlRequest(command: .disable, targetUUID: "two", generation: stale))

        #expect(fixture.controller.response().message == DisplayControlMessageCode.staleGeneration.rawValue)
        #expect(fixture.driver.disableCalls == 0)
    }

    @Test func delayedHeartbeatCannotExtendAnExpiredRemoteLease() {
        let fixture = ControllerFixture(displays: [
            screen("one", id: 1, main: true),
            screen("two", id: 2)
        ])
        let now = Date(timeIntervalSince1970: 1_000)
        let generation = fixture.controller.response().generation
        fixture.controller.handle(DisplayControlRequest(
            command: .keepOnly,
            targetUUID: "one",
            generation: generation,
            remoteSessionID: "uu-session",
            policy: .remotePhysical
        ), now: now)
        let activeGeneration = fixture.controller.response().generation
        fixture.controller.handle(DisplayControlRequest(
            command: .confirmChange,
            generation: activeGeneration,
            confirmed: true
        ), now: now.addingTimeInterval(1))
        fixture.controller.handle(DisplayControlRequest(
            command: .heartbeat,
            generation: activeGeneration,
            remoteSessionID: "uu-session"
        ), now: now.addingTimeInterval(2))
        fixture.controller.expireLeases(now: now.addingTimeInterval(20))

        #expect(fixture.controller.response().state == .idle)
        #expect(fixture.driver.displays().filter { !$0.isVirtual && $0.isUsable }.count == 2)
    }

    @Test func unpluggedPhysicalTargetRestoresDisabledScreenDespiteFreshHeartbeat() throws {
        let fixture = ControllerFixture(displays: [
            screen("one", id: 1, main: true),
            screen("two", id: 2)
        ])
        let now = Date()
        let generation = fixture.controller.response().generation
        fixture.controller.handle(.init(command: .keepOnly, targetUUID: "one", generation: generation,
            remoteSessionID: "uu-session", policy: .remotePhysical), now: now)
        let activeGeneration = fixture.controller.response().generation
        fixture.controller.handle(.init(command: .confirmChange, generation: activeGeneration, confirmed: true),
            now: now.addingTimeInterval(1))
        fixture.driver.removeDisplay("one")
        fixture.controller.handle(.init(command: .heartbeat, generation: activeGeneration,
            remoteSessionID: "uu-session"), now: now.addingTimeInterval(2))

        fixture.controller.expireLeases(now: now.addingTimeInterval(3))

        #expect(fixture.controller.response().state == .recoveryRequired)
        #expect(fixture.driver.displays().contains(where: { $0.uuid == "two" && $0.isUsable }))
        #expect(try DisplayRecoveryJournalStore(fileURL: fixture.journalURL).load() != nil)
    }

    @Test func confirmedVirtualDisappearanceRestoresPhysicalOutputsDespiteFreshHeartbeat() throws {
        let fixture = ControllerFixture(displays: [
            screen("one", id: 1, main: true),
            screen("two", id: 2)
        ])
        let now = Date()
        let generation = fixture.controller.response().generation
        fixture.controller.handle(.init(command: .prepareVirtual,
            virtualSpec: DisplayVirtualSpec(width: 1920, height: 1080), generation: generation,
            remoteSessionID: "uu-session", policy: .remoteVirtualOnly), now: now)
        let prepared = fixture.controller.response()
        fixture.controller.handle(.init(command: .confirmVirtual, generation: prepared.generation,
            remoteSessionID: "uu-session", confirmed: true), now: now.addingTimeInterval(1))
        let changed = fixture.controller.response()
        fixture.controller.handle(.init(command: .confirmChange, generation: changed.generation,
            confirmed: true), now: now.addingTimeInterval(2))
        fixture.driver.removeDisplay("owned-virtual")
        fixture.controller.handle(.init(command: .heartbeat, generation: changed.generation,
            remoteSessionID: "uu-session"), now: now.addingTimeInterval(3))

        fixture.controller.expireLeases(now: now.addingTimeInterval(4))

        #expect(fixture.controller.response().state == .idle)
        #expect(fixture.driver.displays().filter { !$0.isVirtual && $0.isUsable }.count == 2)
        #expect(try DisplayRecoveryJournalStore(fileURL: fixture.journalURL).load() == nil)
    }

    @Test func asleepButOnlinePhysicalOutputDoesNotTriggerContinuityRestore() {
        let fixture = ControllerFixture(displays: [
            screen("one", id: 1, main: true),
            screen("two", id: 2)
        ])
        let now = Date()
        let generation = fixture.controller.response().generation
        fixture.controller.handle(.init(command: .keepOnly, targetUUID: "one", generation: generation), now: now)
        let activeGeneration = fixture.controller.response().generation
        fixture.controller.handle(.init(command: .confirmChange, generation: activeGeneration, confirmed: true),
            now: now.addingTimeInterval(1))
        fixture.driver.markAsleep("one")

        fixture.controller.expireLeases(now: now.addingTimeInterval(2))

        #expect(fixture.controller.response().state == .active)
        #expect(fixture.driver.displays().contains(where: { $0.uuid == "two" && !$0.isUsable }))
    }

    @Test func unconfirmedOrMissingVirtualDisplayCannotBecomeTheOnlyOutput() {
        let physical = screen("physical", id: 1, main: true)
        let inactiveVirtual = screen("virtual", id: 2, virtual: true, usable: false)
        let fixture = ControllerFixture(displays: [physical, inactiveVirtual])
        let generation = fixture.controller.response().generation

        fixture.controller.handle(DisplayControlRequest(
            command: .keepOnly,
            targetUUID: inactiveVirtual.uuid,
            generation: generation,
            remoteSessionID: "uu-session",
            policy: .remoteVirtualOnly
        ))

        #expect(fixture.controller.response().message == DisplayControlMessageCode.virtualNotReady.rawValue)
        #expect(fixture.driver.disableCalls == 0)
        #expect(fixture.driver.displays().contains(where: { $0.uuid == physical.uuid && $0.isUsable }))
    }

    @Test func disappearanceOfConfirmedVirtualCannotBeReplacedByForeignVirtual() {
        let fixture = ControllerFixture(displays: [
            screen("one", id: 1, main: true),
            screen("two", id: 2)
        ])
        fixture.driver.dropOwnedVirtualAfterFirstDisable = true
        let generation = fixture.controller.response().generation
        let now = Date()
        fixture.controller.handle(DisplayControlRequest(
            command: .prepareVirtual,
            virtualSpec: DisplayVirtualSpec(width: 1920, height: 1080),
            generation: generation,
            remoteSessionID: "uu-session",
            policy: .remoteVirtualOnly
        ), now: now)
        let prepared = fixture.controller.response()
        #expect(prepared.state == .awaitingVirtualConfirmation)
        fixture.controller.handle(DisplayControlRequest(
            command: .confirmVirtual,
            generation: prepared.generation,
            remoteSessionID: "uu-session",
            confirmed: true
        ), now: now)

        #expect(fixture.driver.disableCalls == 1)
        #expect(fixture.driver.displays().contains(where: { $0.uuid == "foreign-virtual" && $0.isUsable }))
        #expect(fixture.driver.displays().filter { !$0.isVirtual && $0.isUsable }.count == 2)
    }

    @Test func failedRestoreKeepsJournalAndRetriesOnLeaseTimer() throws {
        let original = screen("one", id: 1, main: true)
        let other = screen("two", id: 2)
        let fixture = ControllerFixture(displays: [original, other])
        let store = DisplayRecoveryJournalStore(fileURL: fixture.journalURL)
        var journal = DisplayRecoveryJournal(
            generation: UUID(),
            policy: .localPhysical,
            originalDisplays: [original, other]
        )
        journal.disabledDisplayUUIDs = [other.uuid]
        journal.pendingRestoreUUIDs = [other.uuid]
        journal.phase = .restoringDisplays
        try store.save(journal)
        #expect(fixture.driver.setEnabled(other, enabled: false))
        fixture.driver.failedEnables = 1

        fixture.controller.recoverAtStartup()
        #expect(fixture.controller.response().state == .recoveryRequired)
        #expect(try store.load() != nil)

        fixture.controller.expireLeases(now: Date().addingTimeInterval(1))
        #expect(fixture.driver.displays().contains(where: { $0.uuid == other.uuid && $0.isUsable }))
        #expect(try store.load() == nil)
    }

    private func screen(_ uuid: String, id: UInt32, virtual: Bool = false, usable: Bool = true, main: Bool = false) -> DisplayControlDisplay {
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
            height: usable ? 1080 : 0
        )
    }
}

private final class ControllerFixture {
    let journalURL: URL
    let driver: FakeDisplayTopologyDriver
    let controller: DisplayTopologyController

    init(displays: [DisplayControlDisplay]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        journalURL = root.appendingPathComponent("journal.json")
        driver = FakeDisplayTopologyDriver(displays: displays)
        controller = DisplayTopologyController(
            store: DisplayRecoveryJournalStore(fileURL: journalURL),
            overrideStore: DisplaySessionOverrideStore(fileURL: root.appendingPathComponent("override.json")),
            driver: driver,
            emergencyHotKeyReady: true,
            authenticationReady: true
        )
    }

    deinit { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
}

private final class FakeDisplayTopologyDriver: DisplayTopologyDriving, @unchecked Sendable {
    private var currentDisplays: [DisplayControlDisplay]
    var failedEnables = 0
    var dropOwnedVirtualAfterFirstDisable = false
    private(set) var disableCalls = 0

    init(displays: [DisplayControlDisplay]) { currentDisplays = displays }

    var displayEnableAPIAvailable: Bool { true }
    var virtualDisplayAPIAvailable: Bool { true }

    func displays() -> [DisplayControlDisplay] { currentDisplays }
    func removeDisplay(_ uuid: String) { currentDisplays.removeAll { $0.uuid == uuid } }
    func markAsleep(_ uuid: String) {
        guard let index = currentDisplays.firstIndex(where: { $0.uuid == uuid }) else { return }
        let value = currentDisplays[index]
        currentDisplays[index] = DisplayControlDisplay(
            uuid: value.uuid, displayID: value.displayID, name: value.name,
            isBuiltIn: value.isBuiltIn, isVirtual: value.isVirtual,
            isOnline: value.isOnline, isActive: value.isActive, isMain: value.isMain,
            width: value.width, height: value.height, isOwned: value.isOwned,
            isAsleep: true, mirrorMasterUUID: value.mirrorMasterUUID,
            vendorID: value.vendorID, productID: value.productID, serialNumber: value.serialNumber,
            originX: value.originX, originY: value.originY
        )
    }

    func setEnabled(_ display: DisplayControlDisplay, enabled: Bool) -> Bool {
        if !enabled {
            disableCalls += 1
            if dropOwnedVirtualAfterFirstDisable {
                dropOwnedVirtualAfterFirstDisable = false
                currentDisplays.removeAll { $0.uuid == "owned-virtual" }
            }
        }
        if enabled && failedEnables > 0 {
            failedEnables -= 1
            return false
        }
        guard let index = currentDisplays.firstIndex(where: { $0.uuid == display.uuid }) else { return false }
        let value = currentDisplays[index]
        currentDisplays[index] = DisplayControlDisplay(
            uuid: value.uuid,
            displayID: value.displayID,
            name: value.name,
            isBuiltIn: value.isBuiltIn,
            isVirtual: value.isVirtual,
            isOnline: enabled,
            isActive: enabled,
            isMain: value.isMain,
            width: enabled ? max(value.width, 1920) : 0,
            height: enabled ? max(value.height, 1080) : 0,
            isOwned: value.isOwned,
            isAsleep: false,
            mirrorMasterUUID: value.mirrorMasterUUID,
            vendorID: value.vendorID,
            productID: value.productID,
            serialNumber: value.serialNumber,
            originX: value.originX,
            originY: value.originY
        )
        return true
    }

    func setMain(_ display: DisplayControlDisplay) -> Bool {
        currentDisplays = currentDisplays.map { value in
            DisplayControlDisplay(
                uuid: value.uuid,
                displayID: value.displayID,
                name: value.name,
                isBuiltIn: value.isBuiltIn,
                isVirtual: value.isVirtual,
                isOnline: value.isOnline,
                isActive: value.isActive,
                isMain: value.uuid == display.uuid,
                width: value.width,
                height: value.height,
                isOwned: value.isOwned,
                isAsleep: value.isAsleep,
                mirrorMasterUUID: value.mirrorMasterUUID,
                vendorID: value.vendorID,
                productID: value.productID,
                serialNumber: value.serialNumber,
                originX: value.originX,
                originY: value.originY
            )
        }
        return true
    }
    func restoreLayout(_ originals: [DisplayControlDisplay]) -> Bool { true }
    func createVirtual(_ spec: DisplayVirtualSpec, name: String) -> DisplayVirtualCreation? {
        currentDisplays.append(DisplayControlDisplay(
            uuid: "owned-virtual", displayID: 90, name: "MacPilot virtual", isBuiltIn: false,
            isVirtual: true, isOnline: true, isActive: true, isMain: false,
            width: spec.width, height: spec.height, isOwned: true
        ))
        currentDisplays.append(DisplayControlDisplay(
            uuid: "foreign-virtual", displayID: 91, name: "Other virtual", isBuiltIn: false,
            isVirtual: true, isOnline: true, isActive: true, isMain: false,
            width: spec.width, height: spec.height, isOwned: false
        ))
        return DisplayVirtualCreation(uuid: "owned-virtual", settingsApplied: true)
    }
    func destroyVirtual(uuid: String, now: Date) -> Bool { true }
}
