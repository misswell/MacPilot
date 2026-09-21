//
//  DisplayBlankRecovery.swift
//  MacPilot
//
//  Crash safety net for the held-black state. `blankDisplay()` drives real
//  backlights to zero and remembers the originals in memory only, so a force
//  quit or a crash while blank would leave the panel dark with no way back
//  except the brightness keys. The captured levels are therefore persisted
//  for as long as the blank is held and replayed on the next launch.
//
//  The keyboard backlight rides along in the same file, for the same reason and
//  one of its own: blanking switches the keyboard's automatic control off so the
//  light sensor cannot raise the level back up, and a session that never came
//  back would otherwise leave that setting off for good.
//

import Foundation

/// The captured pre-blank state of everything MacPilot was holding dark when a
/// session died: displays, keyed by CoreGraphics display ID, and keyboards,
/// keyed by the private framework's own identifier.
struct DisplayBlankSnapshot: Codable, Equatable {
    var version: Int = Self.currentVersion
    var capturedAt: Date
    /// Originals captured through `DisplayServices` (built-in panels).
    var systemBacklight: [String: Float]
    /// Originals captured through DDC/CI (external monitors).
    var ddcBacklight: [String: Double]
    /// Displays MacPilot switched off through DDC power mode. Their brightness was
    /// never touched, so recovery only has to power them back on — but it has to,
    /// because a monitor left in soft-off stays dark until something tells it
    /// otherwise. Optional so that a snapshot written before this field existed
    /// still decodes: a default value alone would make the key required.
    var ddcPowerOff: [String]?
    /// The keyboards whose backlight MacPilot was holding at zero, with the
    /// automatic control it had switched off. Same reasoning as the displays — and
    /// the automatic control is the reason this cannot wait for the user to notice:
    /// a keyboard left with its sensor switched off by MacPilot stays that way
    /// however many times the brightness keys are pressed. Optional, and so a
    /// snapshot written before keyboards existed still decodes.
    var keyboardBacklights: [KeyboardBacklightState]?

    /// The displays recorded as switched off.
    var poweredOffDisplays: [String] { ddcPowerOff ?? [] }

    /// The keyboards recorded as darkened.
    var keyboardStates: [KeyboardBacklightState] { keyboardBacklights ?? [] }

    static let currentVersion = 3
}

/// Reads and writes the snapshot file. Every operation is best effort: the
/// snapshot only has to survive a crash, and persistence must never be able
/// to break blanking or unblanking.
struct DisplayBlankSnapshotStore {
    let fileURL: URL

    static let fileName = "DisplayBlankRecovery.json"

    /// The live store, next to the app's other persisted state.
    static let standard = DisplayBlankSnapshotStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.configurationDirectoryName, isDirectory: true)
    )

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    func save(_ snapshot: DisplayBlankSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticLog.write("DisplayPower", "blank snapshot save failed error=\(error.localizedDescription)")
        }
    }

    func load() -> DisplayBlankSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DisplayBlankSnapshot.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// What to do with one recorded backlight during recovery. Pure, so the
/// decision is testable without hardware.
enum DisplayBlankRecoveryDecision: Equatable {
    /// The panel is still dark: replay the captured level.
    case restore
    /// The backlight is no longer at zero — the user (or a brightness key)
    /// already took care of it. Replaying the old value would clobber that.
    case alreadyRepaired
    /// The device cannot be read now (disconnected, or no driver answers).
    case undrivable
}

/// Replays a snapshot left behind by a session that died while holding a
/// blank. Runs once at launch, before anything else touches the displays.
enum DisplayBlankRecovery {
    /// The seams recovery drives, injectable so tests can run the whole flow
    /// without a display or a keyboard attached. Rebuilt per call: the closures
    /// are stateless views over the shared drivers.
    struct Appliers {
        let readSystem: (UInt32) -> Float?
        let writeSystem: (UInt32, Float) -> Bool
        let readDDC: (UInt32) -> Double?
        let writeDDC: (UInt32, Double) -> Bool
        let readPower: (UInt32) -> UInt16?
        let writePower: (UInt32, UInt16) -> Bool
        let readKeyboardBrightness: (UInt64) -> Float?
        let writeKeyboardBrightness: (UInt64, Float) -> Bool
        let readKeyboardAuto: (UInt64) -> Bool?
        let writeKeyboardAuto: (UInt64, Bool) -> Bool

        /// The keyboard seams default to "nothing answers", which is what a Mac
        /// without a controllable keyboard backlight looks like to recovery: every
        /// keyboard entry is then skipped rather than guessed at.
        init(
            readSystem: @escaping (UInt32) -> Float?,
            writeSystem: @escaping (UInt32, Float) -> Bool,
            readDDC: @escaping (UInt32) -> Double?,
            writeDDC: @escaping (UInt32, Double) -> Bool,
            readPower: @escaping (UInt32) -> UInt16?,
            writePower: @escaping (UInt32, UInt16) -> Bool,
            readKeyboardBrightness: @escaping (UInt64) -> Float? = { _ in nil },
            writeKeyboardBrightness: @escaping (UInt64, Float) -> Bool = { _, _ in false },
            readKeyboardAuto: @escaping (UInt64) -> Bool? = { _ in nil },
            writeKeyboardAuto: @escaping (UInt64, Bool) -> Bool = { _, _ in false }
        ) {
            self.readSystem = readSystem
            self.writeSystem = writeSystem
            self.readDDC = readDDC
            self.writeDDC = writeDDC
            self.readPower = readPower
            self.writePower = writePower
            self.readKeyboardBrightness = readKeyboardBrightness
            self.writeKeyboardBrightness = writeKeyboardBrightness
            self.readKeyboardAuto = readKeyboardAuto
            self.writeKeyboardAuto = writeKeyboardAuto
        }

        static var live: Appliers {
            Appliers(
                readSystem: { BrightnessDriver.shared?.current($0) },
                writeSystem: { id, level in BrightnessDriver.shared?.apply(level, to: id) ?? false },
                readDDC: { DDCBacklight.shared?.level($0) },
                writeDDC: { id, level in DDCBacklight.shared?.setLevel(level, id) ?? false },
                readPower: { DDCBacklight.shared?.powerMode($0) },
                writePower: { id, mode in DDCBacklight.shared?.setPowerMode(mode, id).didConfirm ?? false },
                readKeyboardBrightness: { KeyboardBacklightController.shared?.brightness(for: $0) },
                writeKeyboardBrightness: { id, level in KeyboardBacklightController.shared?.setBrightness(level, for: id) ?? false },
                readKeyboardAuto: { KeyboardBacklightController.shared?.isAutoBrightnessEnabled(for: $0) },
                writeKeyboardAuto: { id, enabled in KeyboardBacklightController.shared?.setAutoBrightnessEnabled(enabled, for: id) ?? false }
            )
        }
    }

    static func decision(current: Double?) -> DisplayBlankRecoveryDecision {
        guard let current else { return .undrivable }
        return current <= 0 ? .restore : .alreadyRepaired
    }

    /// Power mode is a state rather than a level, so "still dark" means the
    /// monitor reports *any* of the dark DPMS states — not only the soft-off byte
    /// MacPilot happened to write. A monitor is not obliged to echo it: the
    /// `SSN-24` here answers a soft-off with standby (`0x02`), and insisting on
    /// the written value would declare that panel repaired and leave it dark. A
    /// display that reports anything else — including one switched back on by
    /// hand or by its own power button — is left alone.
    static func powerDecision(current: UInt16?) -> DisplayBlankRecoveryDecision {
        guard let current else { return .undrivable }
        return DDCPacket.isPoweredDown(current) ? .restore : .alreadyRepaired
    }

    /// What to do with one keyboard's automatic brightness during recovery. Pure,
    /// like the display rules above.
    enum KeyboardAutoBacklightDecision: Equatable {
        /// The sensor was on when the blank took it off, and it is still off:
        /// that interruption is MacPilot's, so undo it.
        case switchBackOn
        /// Nothing to undo — it was off to begin with, it is already on, the user
        /// has since set it themselves, or the keyboard no longer answers.
        case leaveAsSet
    }

    /// Only MacPilot's own interruption is undone. A snapshot that says the sensor
    /// was on and a keyboard that now says it is off can only mean the blank that
    /// darkened it never came back, so it goes back on. Anything else is left as
    /// the user set it — including a sensor they switched off in the meantime,
    /// which recovery has no business re-enabling.
    static func autoBrightnessDecision(
        snapshotEnabled: Bool,
        current: Bool?
    ) -> KeyboardAutoBacklightDecision {
        guard snapshotEnabled, current == false else { return .leaveAsSet }
        return .switchBackOn
    }

    /// Restores every recorded display and keyboard that is still dark and reports
    /// how many were touched.
    ///
    /// Each item is checked before it is written: a backlight that is no
    /// longer at zero was already raised by the user, and replaying the old
    /// value would clobber their choice. A write that the display does not
    /// confirm stays in the snapshot — a locked session can refuse it, and the
    /// next launch retries; one that succeeded is dropped. A crash mid-recovery
    /// leaves the file intact, and the already-repaired decisions above make a
    /// second pass idempotent.
    @discardableResult
    static func recover(
        store: DisplayBlankSnapshotStore,
        appliers: Appliers = .live
    ) -> Int {
        guard var snapshot = store.load() else { return 0 }
        var restored = 0
        var unresolvedSystem: [String: Float] = [:]
        var unresolvedDDC: [String: Double] = [:]
        var unresolvedPower: [String] = []
        var unresolvedKeyboard: [KeyboardBacklightState] = []

        for (key, original) in snapshot.systemBacklight {
            guard let id = UInt32(key) else { continue }
            guard decision(current: appliers.readSystem(id).map(Double.init)) == .restore else { continue }
            restored += 1
            if !appliers.writeSystem(id, original) {
                unresolvedSystem[key] = original
            }
        }
        for (key, original) in snapshot.ddcBacklight {
            guard let id = UInt32(key) else { continue }
            guard decision(current: appliers.readDDC(id)) == .restore else { continue }
            restored += 1
            if !appliers.writeDDC(id, original) {
                unresolvedDDC[key] = original
            }
        }
        for key in snapshot.poweredOffDisplays {
            guard let id = UInt32(key) else { continue }
            guard powerDecision(current: appliers.readPower(id)) == .restore else { continue }
            restored += 1
            if !appliers.writePower(id, DDCPacket.powerOn) {
                unresolvedPower.append(key)
            }
        }

        for state in snapshot.keyboardStates {
            // Level and sensor are decided apart: a user who raised the keyboard
            // with its brightness keys has not switched the automatic control
            // back on, and that is still MacPilot's mess to clean up.
            var touched = false
            var needsAnotherLaunch = false
            switch decision(current: appliers.readKeyboardBrightness(state.keyboardID).map(Double.init)) {
            case .restore:
                touched = true
                _ = appliers.writeKeyboardBrightness(state.keyboardID, state.brightness)
                let actual = appliers.readKeyboardBrightness(state.keyboardID)
                if !keyboardBrightnessMatches(actual, target: state.brightness) {
                    needsAnotherLaunch = true
                }
            case .alreadyRepaired, .undrivable:
                break
            }
            if autoBrightnessDecision(
                snapshotEnabled: state.autoBrightnessEnabled,
                current: appliers.readKeyboardAuto(state.keyboardID)
            ) == .switchBackOn {
                touched = true
                _ = appliers.writeKeyboardAuto(state.keyboardID, true)
                if appliers.readKeyboardAuto(state.keyboardID) != true {
                    needsAnotherLaunch = true
                }
            }
            if needsAnotherLaunch {
                unresolvedKeyboard.append(state)
            } else if touched {
                restored += 1
            }
        }

        if unresolvedSystem.isEmpty, unresolvedDDC.isEmpty, unresolvedPower.isEmpty, unresolvedKeyboard.isEmpty {
            store.clear()
        } else {
            snapshot.systemBacklight = unresolvedSystem
            snapshot.ddcBacklight = unresolvedDDC
            snapshot.ddcPowerOff = unresolvedPower
            snapshot.keyboardBacklights = unresolvedKeyboard
            store.save(snapshot)
        }
        if restored > 0 {
            DiagnosticLog.write("DisplayPower", "blank snapshot restored items=\(restored) capturedAt=\(snapshot.capturedAt)")
        }
        return restored
    }

    private static func keyboardBrightnessMatches(_ current: Float?, target: Float) -> Bool {
        guard let current else { return false }
        return abs(current - target) <= 0.01
    }
}
