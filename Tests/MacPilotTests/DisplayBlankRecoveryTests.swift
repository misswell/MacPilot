import Foundation
import Testing
@testable import MacPilot

struct DisplayBlankRecoveryTests {
    // MARK: - Snapshot store

    private func temporaryStore() -> DisplayBlankSnapshotStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        return DisplayBlankSnapshotStore(directory: directory)
    }

    /// The snapshot only has to survive a crash, so the round trip through the
    /// file — including the string-keyed display IDs JSON forces on us — has to
    /// come back exactly as it went in.
    @Test func snapshotRoundTripsThroughTheStore() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

        let capturedAt = Date(timeIntervalSince1970: 1_789_000_000)
        let snapshot = DisplayBlankSnapshot(
            capturedAt: capturedAt,
            systemBacklight: ["1": 0.75, "7": 1.0],
            ddcBacklight: ["2": 42]
        )
        store.save(snapshot)

        let loaded = try #require(store.load())
        #expect(loaded == snapshot)
        #expect(loaded.version == DisplayBlankSnapshot.currentVersion)
    }

    /// Clearing is what a successful unblank does; afterwards there must be
    /// nothing left for the next launch to replay.
    @Test func clearingTheStoreLeavesNothingToRecover() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

        store.save(DisplayBlankSnapshot(capturedAt: Date(), systemBacklight: ["1": 0.5], ddcBacklight: [:]))
        #expect(store.load() != nil)
        store.clear()
        #expect(store.load() == nil)
        // Clearing an empty store stays a no-op, never an error path.
        store.clear()
        #expect(store.load() == nil)
    }

    // MARK: - Recovery decision

    /// The decision is the difference between repairing a stranded dark panel
    /// and clobbering a brightness the user already raised themselves.
    @Test func aDisplayThatIsStillDarkIsRestoredAndOneAlreadyRaisedIsLeftAlone() {
        #expect(DisplayBlankRecovery.decision(current: 0) == .restore)
        #expect(DisplayBlankRecovery.decision(current: 0.4) == .alreadyRepaired)
        #expect(DisplayBlankRecovery.decision(current: 1.0) == .alreadyRepaired)
        #expect(DisplayBlankRecovery.decision(current: nil) == .undrivable)
    }

    // MARK: - Full recovery flow

    /// The whole flow against fake drivers: the display still held dark gets
    /// its captured level back, the one the user already repaired is untouched,
    /// the disconnected one is skipped, and a fully successful pass clears the
    /// file so no later launch replays anything.
    @Test func recoveryReplaysOnlyTheDisplaysThatAreStillDark() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

        var systemLevels: [UInt32: Float] = [
            1: 0,    // still dark: the crash stranded it
            3: 0.9,  // the user already raised it themselves
        ]
        var ddcLevels: [UInt32: Double] = [
            2: 0,    // still dark external monitor
        ]
        var powerModes: [UInt32: UInt16] = [
            4: DDCPacket.powerOff,  // still switched off
            5: DDCPacket.powerOn,   // the user pressed the monitor's own button
        ]
        var systemWrites: [(UInt32, Float)] = []
        var ddcWrites: [(UInt32, Double)] = []
        var powerWrites: [(UInt32, UInt16)] = []
        let appliers = DisplayBlankRecovery.Appliers(
            readSystem: { systemLevels[$0] },
            writeSystem: { id, level in
                systemWrites.append((id, level))
                systemLevels[id] = level
                return true
            },
            readDDC: { ddcLevels[$0] },
            writeDDC: { id, level in
                ddcWrites.append((id, level))
                ddcLevels[id] = level
                return true
            },
            readPower: { powerModes[$0] },
            writePower: { id, mode in
                powerWrites.append((id, mode))
                powerModes[id] = mode
                return true
            }
        )

        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: ["1": 0.5, "3": 0.8],
            ddcBacklight: ["2": 40, "9": 55],
            ddcPowerOff: ["4", "5"]
        ))

        let restored = DisplayBlankRecovery.recover(store: store, appliers: appliers)

        #expect(restored == 3)
        #expect(systemWrites.count == 1)
        #expect(systemWrites.first?.0 == 1)
        #expect(systemWrites.first?.1 == 0.5)
        #expect(ddcWrites.count == 1)
        #expect(ddcWrites.first?.0 == 2)
        #expect(ddcWrites.first?.1 == 40)
        #expect(systemLevels[1] == 0.5)
        #expect(systemLevels[3] == 0.9)
        #expect(ddcLevels[2] == 40)
        // Only the display still switched off is powered on; the one already on
        // stays untouched, so a manual power-on is not fought over.
        #expect(powerWrites.count == 1)
        #expect(powerWrites.first?.0 == 4)
        #expect(powerWrites.first?.1 == DDCPacket.powerOn)
        #expect(powerModes[5] == DDCPacket.powerOn)
        // Fully successful: nothing may survive for a second launch to replay.
        #expect(store.load() == nil)
    }

    /// A write the display does not confirm — a locked session can refuse one —
    /// has to stay in the snapshot for the next launch instead of being dropped
    /// silently with the panel still dark.
    @Test func aRejectedWriteStaysQueuedForTheNextLaunch() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

        let appliers = DisplayBlankRecovery.Appliers(
            readSystem: { _ in 0 },
            writeSystem: { _, _ in false },
            readDDC: { _ in 0 },
            writeDDC: { _, _ in false },
            readPower: { _ in DDCPacket.powerOff },
            writePower: { _, _ in false }
        )
        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: ["1": 0.5],
            ddcBacklight: ["2": 40],
            ddcPowerOff: ["4"]
        ))

        #expect(DisplayBlankRecovery.recover(store: store, appliers: appliers) == 3)

        let remaining = store.load()
        #expect(remaining?.systemBacklight == ["1": 0.5])
        #expect(remaining?.ddcBacklight == ["2": 40])
        #expect(remaining?.poweredOffDisplays == ["4"])
    }
}

extension DisplayBlankRecoveryTests {
    /// Recovery of a switched-off display is decided by state, not by level. Any
    /// dark DPMS state counts as "still MacPilot's blank", because a monitor is
    /// free to answer a soft-off with standby — the `SSN-24` here does — and
    /// insisting on the written byte would declare that panel repaired while it
    /// is still dark.
    @Test func aDisplayStillReportingADarkStateIsPoweredBackOn() {
        #expect(DisplayBlankRecovery.powerDecision(current: DDCPacket.powerStandby) == .restore)
        #expect(DisplayBlankRecovery.powerDecision(current: DDCPacket.powerSuspend) == .restore)
        #expect(DisplayBlankRecovery.powerDecision(current: DDCPacket.powerOff) == .restore)
        #expect(DisplayBlankRecovery.powerDecision(current: DDCPacket.powerHardOff) == .restore)
        // Already on, or reporting a code that says nothing: leave it alone
        // rather than fight a power-on the user did themselves.
        #expect(DisplayBlankRecovery.powerDecision(current: DDCPacket.powerOn) == .alreadyRepaired)
        #expect(DisplayBlankRecovery.powerDecision(current: 0) == .alreadyRepaired)
        #expect(DisplayBlankRecovery.powerDecision(current: nil) == .undrivable)
    }

    /// A snapshot written before power mode existed has no `ddcPowerOff` key, and
    /// must still decode: refusing it would strand whichever panels it does
    /// describe.
    @Test func anOlderSnapshotWithoutPowerStateStillDecodes() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let legacy = """
        {"version":1,"capturedAt":760000000,"systemBacklight":{"1":0.5},"ddcBacklight":{"2":40}}
        """
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: store.fileURL)

        let snapshot = try #require(store.load())
        #expect(snapshot.systemBacklight == ["1": 0.5])
        #expect(snapshot.poweredOffDisplays.isEmpty)
    }
}
