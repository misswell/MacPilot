//
//  DisplayPower.swift
//  MacPilot
//
//  Shared display power helpers: blacking the display on demand and waking
//  it again.
//
//  There are two distinct things a caller can mean by "turn the screen off",
//  and they are not interchangeable:
//
//  * `sleepDisplay()` asks the system to put the display to sleep. It is the
//    right call when the machine should be allowed to idle down (the BLE
//    proximity lock). On a Mac whose Lock Screen setting requires a password as
//    soon as the display turns off, it also locks the session — that is system
//    policy, not this call.
//  * `blankDisplay()` drops the backlight to zero while leaving the display
//    awake, so that policy never fires and the session stays unlocked. It is
//    what a user pressing "turn off screen" actually means, since MacPilot has a
//    separate lock action.
//

import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// `kCGAnyInputEventType` is a `#define` of `~(CGEventType)0` and has no Swift
/// member, but it is exactly what "has the user touched anything yet" needs.
private let anyInputEventType = CGEventType(rawValue: ~0)!

enum DisplayPower {
    // MARK: - Real display sleep

    /// Puts the display to sleep. Keyboard or mouse input wakes it again.
    /// IODisplayWrangler's IORequestIdle registry write returns success but is
    /// silently ignored on modern macOS, so go through pmset, whose
    /// displaysleepnow still works.
    static func sleepDisplay() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NSLog("MacPilot: pmset displaysleepnow failed status=%d", process.terminationStatus)
                }
            } catch {
                NSLog("MacPilot: pmset displaysleepnow launch failed error=\(error.localizedDescription)")
            }
        }
    }

    /// Wakes a slept display by declaring local user activity.
    static func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("MacPilot" as CFString, kIOPMUserActiveLocal, &assertionID)
    }

    // MARK: - Blanking without sleeping

    /// True while the backlight is being held at zero.
    @MainActor private(set) static var isBlanked = false
    @MainActor private static var brightnessBeforeBlank: Float?
    @MainActor private static var unblankWatcher: Task<Void, Never>?

    /// Blacks the display *without* putting it to sleep, so the system's
    /// "require password after the display is turned off" policy never fires.
    ///
    /// - Returns: false when the backlight cannot be driven, in which case the
    ///   caller should fall back to `sleepDisplay()`.
    @MainActor
    @discardableResult
    static func blankDisplay() -> Bool {
        if isBlanked { return true }
        guard let driver = BrightnessDriver.shared, let original = driver.current() else { return false }
        // Input arriving after this point is what brings the screen back, so the
        // moment of blanking is the baseline to compare against.
        let idleAtBlank = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
        guard driver.apply(0) else { return false }
        brightnessBeforeBlank = original
        isBlanked = true
        startUnblankWatcher(idleAtBlank: idleAtBlank)
        return true
    }

    /// Restores the brightness `blankDisplay()` captured.
    @MainActor
    static func unblankDisplay() {
        unblankWatcher?.cancel()
        unblankWatcher = nil
        guard isBlanked else { return }
        isBlanked = false
        if let original = brightnessBeforeBlank {
            BrightnessDriver.shared?.apply(original)
        }
        brightnessBeforeBlank = nil
    }

    /// What a user-initiated "turn off screen" means: black without locking.
    /// Falls back to a real display sleep when the backlight cannot be driven.
    @MainActor
    static func turnOffScreen() {
        if !blankDisplay() {
            sleepDisplay()
        }
    }

    /// The display is not asleep, so nothing in the system brings the backlight
    /// back on its own — a key press would leave the screen black until someone
    /// reached for the brightness key. Idle time is polled rather than observed
    /// through an event monitor because that needs no Accessibility grant, and
    /// this must not be able to strand a user on a black screen.
    /// Whether the user has touched anything since the screen was blanked.
    ///
    /// Pulled out as a pure rule because getting it backwards would strand
    /// someone on a black screen, and that is worth a test that does not need a
    /// real key press.
    static func didUserInputOccur(idleNow: CFTimeInterval, idleAtBlank: CFTimeInterval) -> Bool {
        idleNow < idleAtBlank
    }

    @MainActor
    private static func startUnblankWatcher(idleAtBlank: CFTimeInterval) {
        unblankWatcher?.cancel()
        unblankWatcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, isBlanked else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
                if didUserInputOccur(idleNow: idle, idleAtBlank: idleAtBlank) {
                    unblankDisplay()
                    return
                }
            }
        }
    }
}

// MARK: - Backlight

private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

/// `DisplayServices` is private, and there is no public replacement: the classic
/// IOKit brightness call is inert on Apple Silicon built-in displays (its
/// `IODisplayConnect` iterator comes back empty), and this is what the
/// `brightness` command line tool drives instead.
///
/// It is resolved at runtime, so the app takes no link-time dependency on a
/// private framework, and every use is optional — if it ever goes away the
/// caller simply falls back to a real display sleep instead of failing.
private struct BrightnessDriver: Sendable {
    let read: @Sendable () -> Float?
    let write: @Sendable (Float) -> Bool

    static let shared: BrightnessDriver? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let readSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let writeSymbol = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        let get = unsafeBitCast(readSymbol, to: GetBrightnessFn.self)
        let set = unsafeBitCast(writeSymbol, to: SetBrightnessFn.self)
        return BrightnessDriver(
            read: {
                var value: Float = 0
                return get(CGMainDisplayID(), &value) == 0 ? value : nil
            },
            write: { set(CGMainDisplayID(), $0) == 0 }
        )
    }()

    func current() -> Float? { read() }
    @discardableResult func apply(_ value: Float) -> Bool { write(value) }
}
