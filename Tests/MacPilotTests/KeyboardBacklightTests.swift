//
//  KeyboardBacklightTests.swift
//  MacPilot
//
//  The keyboard half of "turn off screen": what goes dark, and — the part that
//  actually matters — what comes back. Every case here runs against a fake
//  backlight, because a test that drove the real one would leave the person
//  running the suite typing on a dark keyboard.
//

import Foundation
import Testing
@testable import MacPilot

/// A stand-in for the private `KeyboardBrightnessClient`: levels and light-sensor
/// state in dictionaries, with the writes recorded so a test can tell "restored"
/// apart from "never touched".
private final class FakeKeyboardBacklight: @unchecked Sendable {
    var levels: [UInt64: Float]
    var sensors: [UInt64: Bool]
    private(set) var brightnessWrites: [(UInt64, Float)] = []
    private(set) var autoWrites: [(UInt64, Bool)] = []
    /// Whether the keyboards answer at all — a machine with no controllable
    /// backlight, or a macOS that stopped shipping the client.
    var answers = true
    /// Whether every write is refused, the way a locked session can refuse one.
    var acceptsWrites = true
    /// Whether an accepted write is reflected by the next read. CoreBrightness
    /// can report success before the hardware has actually applied the value.
    var appliesWrites = true
    /// Keyboards that report no level, so there is nothing to restore to.
    var unreadable: Set<UInt64> = []

    init(_ keyboards: [UInt64: (level: Float, sensorOn: Bool)]) {
        levels = keyboards.mapValues(\.level)
        sensors = keyboards.mapValues(\.sensorOn)
    }

    var keyboardIDs: [UInt64] { answers ? Array(levels.keys).sorted() : [] }

    func controller() -> KeyboardBacklightController {
        KeyboardBacklightController(
            keyboardIDs: { self.keyboardIDs },
            brightness: { self.answers && !self.unreadable.contains($0) ? self.levels[$0] : nil },
            setBrightness: { value, keyboardID in
                self.brightnessWrites.append((keyboardID, value))
                guard self.answers, self.acceptsWrites, !self.unreadable.contains(keyboardID) else { return false }
                if self.appliesWrites {
                    self.levels[keyboardID] = value
                }
                return true
            },
            autoBrightnessEnabled: { self.answers ? self.sensors[$0] : nil },
            setAutoBrightnessEnabled: { enabled, keyboardID in
                self.autoWrites.append((keyboardID, enabled))
                guard self.answers, self.acceptsWrites else { return false }
                if self.appliesWrites {
                    self.sensors[keyboardID] = enabled
                }
                return true
            }
        )
    }
}

// MARK: - Blank and restore

struct KeyboardBacklightTests {
    /// The invariant the whole feature rests on: the keyboard comes back at the
    /// level it was at, not at some level MacPilot chose. A fixed value would be
    /// the bright-keyboard bug all over again, just in the other direction.
    @Test func blankingTakesTheKeyboardToZeroAndRestorePutBackTheLevelTheUserHad() {
        let keyboard = FakeKeyboardBacklight([1: (0.7, true)])
        let controller = keyboard.controller()

        let captured = controller.blank()
        #expect(captured == [KeyboardBacklightState(keyboardID: 1, brightness: 0.7, autoBrightnessEnabled: true)])
        #expect(keyboard.levels[1] == 0)
        // The sensor goes off first: left running, it raises the level back up a
        // moment later and the keyboard is lit under a black screen.
        #expect(keyboard.sensors[1] == false)
        #expect(keyboard.autoWrites.first?.1 == false)

        controller.restore(captured)
        #expect(keyboard.levels[1] == 0.7)
        #expect(keyboard.sensors[1] == true)
    }

    /// CoreBrightness may report both writes as accepted while the keyboard is
    /// still at zero. The captured state must remain available for a later retry,
    /// and the next read-back-confirmed pass may then consume it.
    @Test func restoreKeepsStateWhenAcceptedWritesDoNotChangeTheHardware() {
        let keyboard = FakeKeyboardBacklight([1: (0.7, true)])
        let controller = keyboard.controller()
        let captured = controller.blank()

        keyboard.appliesWrites = false
        let unresolved = controller.restore(captured)
        #expect(unresolved == captured)
        #expect(keyboard.levels[1] == 0)
        #expect(keyboard.sensors[1] == false)

        keyboard.appliesWrites = true
        #expect(controller.restore(unresolved).isEmpty)
        #expect(keyboard.levels[1] == 0.7)
        #expect(keyboard.sensors[1] == true)
    }

    /// A user who drives the keyboard by hand has no sensor to hand back over.
    /// Switching it on "to be safe" would change a setting they set themselves.
    @Test func aKeyboardOnAFixedLevelKeepsItAndItsSensorOff() {
        let keyboard = FakeKeyboardBacklight([1: (0.4, false)])
        let controller = keyboard.controller()

        let captured = controller.blank()
        #expect(keyboard.levels[1] == 0)
        #expect(keyboard.autoWrites.isEmpty)

        controller.restore(captured)
        #expect(keyboard.levels[1] == 0.4)
        #expect(keyboard.sensors[1] == false)
    }

    /// The keyboard was already off, so the keyboard stays off. MacPilot has no
    /// opinion about where a backlight belongs and must not light one up because
    /// the screen came back.
    @Test func aKeyboardThatWasAlreadyDarkStaysDark() {
        let keyboard = FakeKeyboardBacklight([1: (0, false)])
        let controller = keyboard.controller()

        let captured = controller.blank()
        #expect(captured == [KeyboardBacklightState(keyboardID: 1, brightness: 0, autoBrightnessEnabled: false)])
        controller.restore(captured)
        #expect(keyboard.levels[1] == 0)
        #expect(keyboard.sensors[1] == false)
        // Restoring a level that is already in place writes nothing, which is what
        // makes a second unblank harmless.
        #expect(keyboard.brightnessWrites.map(\.1) == [0])
        #expect(keyboard.autoWrites.isEmpty)
    }

    /// Several keyboards — a MacBook panel and an external one with a backlight —
    /// each keep their own level and their own sensor.
    @Test func everyKeyboardKeepsItsOwnStateThroughTheBlank() {
        let keyboard = FakeKeyboardBacklight([1: (0.8, true), 2: (0.2, false)])
        let controller = keyboard.controller()

        let captured = controller.blank()
        #expect(keyboard.levels[1] == 0)
        #expect(keyboard.levels[2] == 0)
        #expect(keyboard.sensors[1] == false)
        #expect(captured.map(\.keyboardID) == [1, 2])

        controller.restore(captured)
        #expect(keyboard.levels == [1: 0.8, 2: 0.2])
        #expect(keyboard.sensors == [1: true, 2: false])
    }

    // MARK: - Degradation

    /// Nothing to darken is not a failure. A desktop Mac has no backlit keyboard
    /// MacPilot can reach, and "turn off screen" has to black the display
    /// regardless — so the keyboard step hands back an empty state and stays out
    /// of the way.
    @Test func aMachineWithNoBacklitKeyboardCapturesNothing() {
        let keyboard = FakeKeyboardBacklight([:])
        #expect(keyboard.controller().blank().isEmpty)
        #expect(keyboard.brightnessWrites.isEmpty)
        #expect(keyboard.autoWrites.isEmpty)
        // And an empty restore is a no-op rather than a guess at a level.
        keyboard.controller().restore([])
        #expect(keyboard.brightnessWrites.isEmpty)
    }

    /// The shape of "CoreBrightness is gone": the client answers nothing, so there
    /// is no level to remember and no keyboard may be written to. This is the
    /// case that must never turn into a failed screen blank.
    @Test func anUnansweredClientRestoresNothingAndWritesNothing() {
        let keyboard = FakeKeyboardBacklight([1: (0.5, true)])
        keyboard.answers = false
        let controller = keyboard.controller()

        #expect(controller.captureState().isEmpty)
        #expect(controller.blank().isEmpty)
        #expect(keyboard.levels[1] == 0.5)
        #expect(keyboard.brightnessWrites.isEmpty)

        // A state captured on another machine's hardware cannot be replayed here.
        // The level is unchanged either way, which is all a user can tell.
        controller.restore([KeyboardBacklightState(keyboardID: 1, brightness: 0.5, autoBrightnessEnabled: true)])
        #expect(keyboard.levels[1] == 0.5)
        #expect(keyboard.sensors[1] == true)
    }

    /// A keyboard whose level cannot be read is left alone entirely: MacPilot has
    /// nothing to restore to, so darkening it could only cost the user a setting
    /// nobody can put back.
    @Test func aKeyboardWhoseLevelCannotBeReadIsNotDimmed() {
        let keyboard = FakeKeyboardBacklight([1: (0.5, true)])
        keyboard.unreadable = [1]
        #expect(keyboard.controller().blank().isEmpty)
        #expect(keyboard.levels[1] == 0.5)
        #expect(keyboard.sensors[1] == true)
    }

    /// A refused write does not drop the state: `blank()` reports what it captured
    /// either way, so the unblank still tries, and a keyboard that never went dark
    /// is put back at the level it already holds.
    @Test func refusedWritesStillReportTheCapturedState() {
        let keyboard = FakeKeyboardBacklight([1: (0.6, true)])
        keyboard.acceptsWrites = false
        let captured = keyboard.controller().blank()
        #expect(captured == [KeyboardBacklightState(keyboardID: 1, brightness: 0.6, autoBrightnessEnabled: true)])
        #expect(keyboard.levels[1] == 0.6)
    }
}

// MARK: - Crash recovery

extension KeyboardBacklightTests {
    private func temporaryStore() -> DisplayBlankSnapshotStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotKeyboardRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        return DisplayBlankSnapshotStore(directory: directory)
    }

    /// A session that died while holding the blank has to put the keyboard back
    /// the way the unblank would: the captured level, and the sensor MacPilot had
    /// switched off to keep the light from rising again.
    @Test func recoveryReplaysAKeyboardLeftDark() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let keyboard = FakeKeyboardBacklight([1: (0, false)])
        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: [:],
            ddcBacklight: [:],
            keyboardBacklights: [KeyboardBacklightState(keyboardID: 1, brightness: 0.65, autoBrightnessEnabled: true)]
        ))

        let restored = DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers())

        #expect(restored == 1)
        #expect(keyboard.levels[1] == 0.65)
        #expect(keyboard.sensors[1] == true)
        #expect(store.load() == nil)
    }

    /// The rule that keeps recovery from fighting the user: a keyboard already
    /// raised by its brightness keys is left at the level they chose, not dragged
    /// back to whatever the dead session captured.
    @Test func recoveryLeavesAKeyboardTheUserAlreadyRaisedAlone() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let keyboard = FakeKeyboardBacklight([1: (0.3, false)])
        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: [:],
            ddcBacklight: [:],
            keyboardBacklights: [KeyboardBacklightState(keyboardID: 1, brightness: 0.65, autoBrightnessEnabled: false)]
        ))

        #expect(DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers()) == 0)
        #expect(keyboard.brightnessWrites.isEmpty)
        #expect(keyboard.levels[1] == 0.3)
        #expect(store.load() == nil)
    }

    /// The half a level-only rule would miss: the user fixed the darkness with the
    /// brightness keys, but nothing they pressed puts the light sensor back on.
    /// That switch is MacPilot's, so recovery still makes it.
    @Test func recoverySwitchesTheSensorBackOnEvenAfterTheUserRaisedTheLevel() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let keyboard = FakeKeyboardBacklight([1: (0.3, false)])
        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: [:],
            ddcBacklight: [:],
            keyboardBacklights: [KeyboardBacklightState(keyboardID: 1, brightness: 0.65, autoBrightnessEnabled: true)]
        ))

        #expect(DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers()) == 1)
        #expect(keyboard.brightnessWrites.isEmpty)
        #expect(keyboard.levels[1] == 0.3)
        #expect(keyboard.sensors[1] == true)
    }

    /// A sensor the user keeps off is not MacPilot's to enable, and a keyboard
    /// that answers nothing is gone rather than dark — an external one unplugged
    /// since the crash. Both are left as they are.
    @Test func recoveryNeverEnablesASensorItDidNotSwitchOff() {
        #expect(DisplayBlankRecovery.autoBrightnessDecision(snapshotEnabled: false, current: false) == .leaveAsSet)
        #expect(DisplayBlankRecovery.autoBrightnessDecision(snapshotEnabled: false, current: true) == .leaveAsSet)
        #expect(DisplayBlankRecovery.autoBrightnessDecision(snapshotEnabled: true, current: true) == .leaveAsSet)
        #expect(DisplayBlankRecovery.autoBrightnessDecision(snapshotEnabled: true, current: nil) == .leaveAsSet)
        // The one case that is MacPilot's mess: on before the blank, off now.
        #expect(DisplayBlankRecovery.autoBrightnessDecision(snapshotEnabled: true, current: false) == .switchBackOn)
    }

    /// A write the machine refuses — the same locked-session refusal the display
    /// rules exist for — keeps the keyboard in the snapshot for the next launch
    /// instead of being dropped with the keyboard still dark.
    @Test func aRejectedKeyboardWriteStaysQueuedForTheNextLaunch() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let keyboard = FakeKeyboardBacklight([1: (0, false)])
        keyboard.acceptsWrites = false
        let state = KeyboardBacklightState(keyboardID: 1, brightness: 0.65, autoBrightnessEnabled: true)
        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: [:],
            ddcBacklight: [:],
            keyboardBacklights: [state]
        ))

        #expect(DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers()) == 0)
        #expect(store.load()?.keyboardStates == [state])
        // The retry re-decides from the hardware, so a second pass that succeeds
        // leaves nothing behind.
        keyboard.acceptsWrites = true
        #expect(DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers()) == 1)
        #expect(store.load() == nil)
        #expect(keyboard.levels[1] == 0.65)
    }

    /// A true write result is not enough for crash recovery either: the snapshot
    /// remains until both the brightness and sensor reads confirm the repair.
    @Test func recoveryKeepsAKeyboardQueuedWhenAcceptedWritesDoNotReadBack() {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let keyboard = FakeKeyboardBacklight([1: (0, false)])
        keyboard.appliesWrites = false
        let state = KeyboardBacklightState(keyboardID: 1, brightness: 0.65, autoBrightnessEnabled: true)
        store.save(DisplayBlankSnapshot(
            capturedAt: Date(),
            systemBacklight: [:],
            ddcBacklight: [:],
            keyboardBacklights: [state]
        ))

        #expect(DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers()) == 0)
        #expect(store.load()?.keyboardStates == [state])

        keyboard.appliesWrites = true
        #expect(DisplayBlankRecovery.recover(store: store, appliers: keyboard.appliers()) == 1)
        #expect(store.load() == nil)
        #expect(keyboard.levels[1] == 0.65)
        #expect(keyboard.sensors[1] == true)
    }

    /// Snapshots written by the release before keyboards existed carry no
    /// `keyboardBacklights` key. Refusing to read one would strand the displays
    /// that file does describe.
    @Test func anOlderSnapshotWithoutKeyboardStateStillDecodes() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let legacy = """
        {"version":2,"capturedAt":760000000,"systemBacklight":{"1":0.5},"ddcBacklight":{},"ddcPowerOff":["4"]}
        """
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: store.fileURL)

        let snapshot = try #require(store.load())
        #expect(snapshot.systemBacklight == ["1": 0.5])
        #expect(snapshot.poweredOffDisplays == ["4"])
        #expect(snapshot.keyboardStates.isEmpty)

        // Recovery of such a file still repairs the display it does describe, and
        // touches no keyboard.
        let keyboard = FakeKeyboardBacklight([1: (0, false)])
        let restored = DisplayBlankRecovery.recover(
            store: store,
            appliers: keyboard.appliers(systemLevels: [1: 0], powerModes: [4: DDCPacket.powerOff])
        )
        #expect(restored == 2)
        #expect(keyboard.brightnessWrites.isEmpty)
        #expect(keyboard.autoWrites.isEmpty)
        #expect(store.load() == nil)
    }

    /// The whole point of the file is to survive a crash, so the keyboards ride
    /// through it by their own identifiers and come back unchanged.
    @Test func keyboardStatesRoundTripThroughTheSnapshot() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let states = [
            KeyboardBacklightState(keyboardID: 95_158_913, brightness: 0.33420846, autoBrightnessEnabled: true),
            KeyboardBacklightState(keyboardID: 2, brightness: 1, autoBrightnessEnabled: false),
        ]
        let snapshot = DisplayBlankSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_789_000_000),
            systemBacklight: ["1": 0.5],
            ddcBacklight: [:],
            keyboardBacklights: states
        )
        store.save(snapshot)

        let loaded = try #require(store.load())
        #expect(loaded == snapshot)
        #expect(loaded.keyboardStates == states)
        #expect(loaded.version == DisplayBlankSnapshot.currentVersion)
    }
}

private extension FakeKeyboardBacklight {
    /// The same appliers `DisplayBlankRecovery` builds over the live drivers,
    /// pointed at this fake instead. The display seams default to "nothing
    /// answers", so a keyboard-only test sees no display work attempted.
    func appliers(
        systemLevels: [UInt32: Float] = [:],
        powerModes: [UInt32: UInt16] = [:]
    ) -> DisplayBlankRecovery.Appliers {
        DisplayBlankRecovery.Appliers(
            readSystem: { systemLevels[$0] },
            writeSystem: { _, _ in true },
            readDDC: { _ in nil },
            writeDDC: { _, _ in false },
            readPower: { powerModes[$0] },
            writePower: { _, _ in true },
            readKeyboardBrightness: { self.levels[$0] },
            writeKeyboardBrightness: { id, level in
                self.brightnessWrites.append((id, level))
                guard self.acceptsWrites else { return false }
                if self.appliesWrites {
                    self.levels[id] = level
                }
                return true
            },
            readKeyboardAuto: { self.sensors[$0] },
            writeKeyboardAuto: { id, enabled in
                self.autoWrites.append((id, enabled))
                guard self.acceptsWrites else { return false }
                if self.appliesWrites {
                    self.sensors[id] = enabled
                }
                return true
            }
        )
    }
}
