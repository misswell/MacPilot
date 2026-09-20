//
//  KeyboardBacklightController.swift
//  MacPilot
//
//  The keyboard half of "turn off screen".
//
//  A real display sleep dims the keyboard backlight with the panel, so a user
//  who turns the screen off expects a dark desk. MacPilot blacks the displays
//  *without* sleeping them — a sleep would lock the session — so nothing else
//  dims the keyboard and it has to be driven here: take what the user had, drop
//  it to zero, and put those exact values back when the screen comes back. Not
//  a fixed level: the keyboard had better be where the user left it, which for
//  someone who keeps it off means it stays off.
//
//  `KeyboardBrightnessClient` is private and has no public replacement, so it is
//  resolved at runtime exactly like `DisplayServices` is: no link-time
//  dependency, and every call optional. It must never be able to fail a screen
//  blank, and it never is — a machine without a backlit keyboard, or without the
//  framework, simply gets nothing.
//

import Foundation
import ObjectiveC

/// What one keyboard looked like before MacPilot took it dark: the level to
/// restore, and whether its automatic brightness was switched on — because
/// leaving the automatic control running is how a keyboard that was switched off
/// comes back lit on its own.
struct KeyboardBacklightState: Codable, Equatable, Sendable {
    let keyboardID: UInt64
    let brightness: Float
    let autoBrightnessEnabled: Bool
}

/// Reads and writes the keyboard backlights, and owns the blank/restore rules.
///
/// The hardware calls are injected seams, so the rules are testable without a
/// keyboard attached — and a test that ran against the real one would darken the
/// user's keyboard.
final class KeyboardBacklightController: Sendable {
    let keyboardIDsProvider: @Sendable () -> [UInt64]
    let brightnessReader: @Sendable (UInt64) -> Float?
    let brightnessWriter: @Sendable (Float, UInt64) -> Bool
    let autoReader: @Sendable (UInt64) -> Bool?
    let autoWriter: @Sendable (Bool, UInt64) -> Bool

    /// `nil` when this machine cannot drive a keyboard backlight at all.
    static let shared: KeyboardBacklightController? = KeyboardBacklightIO.controller()

    init(
        keyboardIDs: @escaping @Sendable () -> [UInt64],
        brightness: @escaping @Sendable (UInt64) -> Float?,
        setBrightness: @escaping @Sendable (Float, UInt64) -> Bool,
        autoBrightnessEnabled: @escaping @Sendable (UInt64) -> Bool?,
        setAutoBrightnessEnabled: @escaping @Sendable (Bool, UInt64) -> Bool
    ) {
        keyboardIDsProvider = keyboardIDs
        brightnessReader = brightness
        brightnessWriter = setBrightness
        autoReader = autoBrightnessEnabled
        autoWriter = setAutoBrightnessEnabled
    }

    // MARK: - Single keyboards

    func keyboardIDs() -> [UInt64] { keyboardIDsProvider() }

    /// Current level in `0...1`, or `nil` when this keyboard does not answer.
    func brightness(for keyboardID: UInt64) -> Float? { brightnessReader(keyboardID) }

    @discardableResult
    func setBrightness(_ value: Float, for keyboardID: UInt64) -> Bool {
        guard brightnessWriter(min(max(value, 0), 1), keyboardID) else {
            DiagnosticLog.write("KeyboardBacklight", "brightness write failed keyboard=\(keyboardID)")
            return false
        }
        return true
    }

    /// Whether the keyboard's own light sensor drives its brightness.
    func isAutoBrightnessEnabled(for keyboardID: UInt64) -> Bool? { autoReader(keyboardID) }

    @discardableResult
    func setAutoBrightnessEnabled(_ enabled: Bool, for keyboardID: UInt64) -> Bool {
        guard autoWriter(enabled, keyboardID) else {
            DiagnosticLog.write("KeyboardBacklight", "auto write failed keyboard=\(keyboardID) enabled=\(enabled)")
            return false
        }
        return true
    }

    // MARK: - Blank and restore

    /// The state to put back after a blank: one entry per keyboard that answers,
    /// which means one entry per keyboard MacPilot may go on to darken.
    ///
    /// A keyboard whose level cannot be read is left out entirely — with nothing
    /// to restore, darkening it could only cost the user their setting. A
    /// keyboard that reports no automatic control is recorded as `false`, which
    /// is what it is: nothing here claims to switch back on a setting it never
    /// switched off.
    func captureState() -> [KeyboardBacklightState] {
        keyboardIDs().compactMap { keyboardID in
            guard let brightness = brightness(for: keyboardID) else { return nil }
            return KeyboardBacklightState(
                keyboardID: keyboardID,
                brightness: brightness,
                autoBrightnessEnabled: isAutoBrightnessEnabled(for: keyboardID) ?? false
            )
        }
    }

    /// Takes every keyboard dark and returns what a later `restore(_:)` needs.
    ///
    /// Automatic brightness is switched off *first*: it is the one thing that
    /// can raise the level back up on its own a moment after it was zeroed, which
    /// would leave a lit keyboard under a black screen.
    ///
    /// - Returns: the pre-blank state, empty when there is nothing to darken.
    @discardableResult
    func blank() -> [KeyboardBacklightState] {
        let states = captureState()
        if states.isEmpty {
            // The two ways this happens are worth telling apart from the log: a
            // Mac with no backlit keyboard is nothing to investigate, while one
            // that lists keyboards and then answers none of them is the private
            // framework misbehaving.
            let listed = keyboardIDs().count
            DiagnosticLog.write("KeyboardBacklight", listed == 0
                ? "keyboard backlight unavailable reason=noBacklitKeyboard"
                : "keyboard backlight unavailable reason=noAnswer keyboards=\(listed)")
            return []
        }
        for state in states {
            if state.autoBrightnessEnabled {
                _ = setAutoBrightnessEnabled(false, for: state.keyboardID)
            }
            _ = setBrightness(0, for: state.keyboardID)
        }
        DiagnosticLog.write("KeyboardBacklight", "keyboard backlight blanked keyboards=\(states.count)")
        return states
    }

    /// Puts back exactly what `blank()` captured.
    ///
    /// The level goes first and the automatic control after it, so a keyboard the
    /// user runs from its sensor ends up driven by the sensor again rather than
    /// pinned to the captured number. A value already in place is not rewritten:
    /// the whole pass is then idempotent, which matters because an unblank can be
    /// reached twice (the wake watcher and the user's own brightness change).
    func restore(_ states: [KeyboardBacklightState]) {
        guard !states.isEmpty else { return }
        var restored = 0
        for state in states {
            if brightness(for: state.keyboardID) != state.brightness,
               setBrightness(state.brightness, for: state.keyboardID) {
                restored += 1
            }
            if isAutoBrightnessEnabled(for: state.keyboardID) != state.autoBrightnessEnabled {
                _ = setAutoBrightnessEnabled(state.autoBrightnessEnabled, for: state.keyboardID)
            }
        }
        DiagnosticLog.write(
            "KeyboardBacklight",
            "keyboard backlight restored keyboards=\(states.count) levels=\(restored)"
        )
    }
}

// MARK: - Private framework access

/// The `CoreBrightness` half, kept apart so the rules above stay testable
/// without a keyboard attached.
///
/// Nothing here is a link-time dependency: the framework is opened at runtime and
/// every symbol is optional, so a macOS that stops shipping `KeyboardBrightnessClient`
/// — or one of its five methods — costs the keyboard backlight and nothing else.
private enum KeyboardBacklightIO {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private static let className = "KeyboardBrightnessClient"

    private static let keyboardIDsSelector = "copyKeyboardBacklightIDs"
    private static let readSelector = "brightnessForKeyboard:"
    private static let writeSelector = "setBrightness:forKeyboard:"
    private static let autoReadSelector = "isAutoBrightnessEnabledForKeyboard:"
    private static let autoWriteSelector = "enableAutoBrightness:forKeyboard:"

    /// The keyboard backlight id is an `unsigned long long` in every signature.
    typealias KeyboardIDsCall = @convention(c) (AnyObject, Selector) -> Unmanaged<CFArray>?
    typealias BrightnessRead = @convention(c) (AnyObject, Selector, UInt64) -> Float
    typealias BrightnessWrite = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    typealias AutoRead = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    typealias AutoWrite = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    /// The client object plus the calls resolved against its class.
    ///
    /// `KeyboardBrightnessClient` is an undocumented IPC client with no promise
    /// about being used from more than one thread, and MacPilot can be asked for
    /// display state from several, so every call through it is serialised. The
    /// object lives for the rest of the process, which is why a plain reference
    /// rather than a per-call allocation is fine here.
    private final class Client: @unchecked Sendable {
        private let lock = NSLock()
        private let object: AnyObject
        private let keyboardIDs: KeyboardIDsCall
        private let read: BrightnessRead
        private let write: BrightnessWrite
        private let autoRead: AutoRead
        private let autoWrite: AutoWrite

        init(
            object: AnyObject,
            keyboardIDs: KeyboardIDsCall,
            read: BrightnessRead,
            write: BrightnessWrite,
            autoRead: AutoRead,
            autoWrite: AutoWrite
        ) {
            self.object = object
            self.keyboardIDs = keyboardIDs
            self.read = read
            self.write = write
            self.autoRead = autoRead
            self.autoWrite = autoWrite
        }

        private func call<T>(_ body: (AnyObject) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(object)
        }

        func currentKeyboardIDs() -> [UInt64] {
            call { object in
                // `copy...` hands back a +1 reference, which is why this one is
                // taken as `Unmanaged` rather than as a plain object.
                guard let result = keyboardIDs(object, Selector(keyboardIDsSelector)) else { return [] }
                let ids = result.takeRetainedValue() as NSArray
                return (0..<ids.count).compactMap { (ids.object(at: $0) as? NSNumber)?.uint64Value }
            }
        }

        func brightness(for keyboardID: UInt64) -> Float? {
            call { read($0, Selector(readSelector), keyboardID) }
        }

        func setBrightness(_ value: Float, for keyboardID: UInt64) -> Bool {
            call { write($0, Selector(writeSelector), value, keyboardID) }
        }

        func autoBrightnessEnabled(for keyboardID: UInt64) -> Bool? {
            call { autoRead($0, Selector(autoReadSelector), keyboardID) }
        }

        func setAutoBrightnessEnabled(_ enabled: Bool, for keyboardID: UInt64) -> Bool {
            call { autoWrite($0, Selector(autoWriteSelector), enabled, keyboardID) }
        }
    }

    /// A method is only usable if the class actually implements it. Calling one
    /// it does not answer would return whatever happens to be in a register, so a
    /// missing method costs the keyboard backlight rather than corrupting it.
    private static func function<Signature>(
        named selector: String,
        on cls: AnyClass,
        as: Signature.Type
    ) -> Signature? {
        guard cls.instancesRespond(to: Selector(selector)),
              let method = class_getInstanceMethod(cls, Selector(selector))
        else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Signature.self)
    }

    static func controller() -> KeyboardBacklightController? {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString(className) as? NSObject.Type
        else {
            DiagnosticLog.write("KeyboardBacklight", "keyboard backlight unavailable reason=CoreBrightness")
            return nil
        }
        guard let keyboardIDs = function(named: keyboardIDsSelector, on: cls, as: KeyboardIDsCall.self),
              let read = function(named: readSelector, on: cls, as: BrightnessRead.self),
              let write = function(named: writeSelector, on: cls, as: BrightnessWrite.self),
              let autoRead = function(named: autoReadSelector, on: cls, as: AutoRead.self),
              let autoWrite = function(named: autoWriteSelector, on: cls, as: AutoWrite.self)
        else {
            DiagnosticLog.write("KeyboardBacklight", "keyboard backlight unavailable reason=selectors")
            return nil
        }
        let client: AnyObject = cls.init()
        let api = Client(
            object: client,
            keyboardIDs: keyboardIDs,
            read: read,
            write: write,
            autoRead: autoRead,
            autoWrite: autoWrite
        )
        return KeyboardBacklightController(
            keyboardIDs: { api.currentKeyboardIDs() },
            brightness: { api.brightness(for: $0) },
            setBrightness: { api.setBrightness($0, for: $1) },
            autoBrightnessEnabled: { api.autoBrightnessEnabled(for: $0) },
            setAutoBrightnessEnabled: { api.setAutoBrightnessEnabled($0, for: $1) }
        )
    }
}
