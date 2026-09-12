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
//    proximity lock, the Awake lid policy). On a Mac whose Lock Screen setting
//    requires a password as soon as the display turns off, it also locks the
//    session — that is system policy, not this call.
//  * `turnOffScreen()` blacks every display without sleeping any of them, so
//    that policy never fires and the session stays unlocked. It is what a user
//    pressing "turn off screen" actually means, since MacPilot has a separate
//    lock action.
//

import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// `kCGAnyInputEventType` is a `#define` of `~(CGEventType)0` and has no Swift
/// member, but it is exactly what "has the user touched anything yet" needs.
private let anyInputEventType = CGEventType(rawValue: ~0)!

// MARK: - Blank plan

/// One display that is online and awake while the screen is being blacked.
struct ScreenBlankCandidate: Equatable {
    let displayID: UInt32
    let isBuiltIn: Bool

    /// Whether the private `DisplayServices` backlight call can actually drive
    /// this display. Probed with a real read rather than inferred from the
    /// display list, because both an external monitor and a MacBook panel in
    /// clamshell mode answer no.
    let canDriveBacklight: Bool

    /// Whether the display answers DDC/CI on its own I2C channel. This is what an
    /// external monitor has instead of `DisplayServices`, and it is a real
    /// backlight rather than a black cover: the panel goes dark, no pointer is
    /// left floating on it, and nothing has to sleep.
    var canDriveDDC = false
}

/// Decides how each online display gets blacked.
///
/// This is a pure function because the interesting part is the decision, not
/// the side effects: when a backlight cannot be driven the display still has to
/// go black some other way, because the only alternative left to a caller is a
/// real display sleep — and that is what quietly locks the session.
enum ScreenBlankPlanner {
    enum Action: Equatable {
        /// Drop the backlight to zero through `DisplayServices` and hold it.
        case backlight
        /// Drop the backlight to zero through the monitor's own DDC/CI control.
        case ddcBacklight
        /// Cover the display with a black window, for a panel that answers
        /// neither.
        case overlay
    }

    struct Step: Equatable {
        let displayID: UInt32
        let action: Action
    }

    /// Every candidate gets exactly one step. Built-in panels and
    /// backlight-capable displays come first, so a MacBook panel is blacked the
    /// cheap way even when an external display happens to be the main one; a
    /// black cover is the last resort, because it is the only one of the three
    /// that leaves the panel lit.
    static func steps(for candidates: [ScreenBlankCandidate]) -> [Step] {
        candidates
            .sorted { lhs, rhs in
                if lhs.canDriveBacklight != rhs.canDriveBacklight { return lhs.canDriveBacklight }
                if lhs.canDriveDDC != rhs.canDriveDDC { return lhs.canDriveDDC }
                if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
                return lhs.displayID < rhs.displayID
            }
            .map { candidate in
                let action: Action = candidate.canDriveBacklight
                    ? .backlight
                    : (candidate.canDriveDDC ? .ddcBacklight : .overlay)
                return Step(displayID: candidate.displayID, action: action)
            }
    }
}

enum DisplayPower {
    // MARK: - Real display sleep

    /// Puts the display to sleep. Keyboard or mouse input wakes it again.
    /// IODisplayWrangler's IORequestIdle registry write returns success but is
    /// silently ignored on modern macOS, so go through pmset, whose
    /// displaysleepnow still works.
    ///
    /// A held blank is released first: `turnOffScreen()` keeps the display awake
    /// on purpose, and this call exists precisely to let it idle down.
    @MainActor
    static func sleepDisplay() {
        unblankDisplay()
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

    // MARK: - Blacking without sleeping

    /// Original brightness of every display whose backlight is being held at
    /// zero, keyed by display.
    @MainActor private static var blankedDisplays: [CGDirectDisplayID: Float] = [:]
    /// Same, for external displays blacked through their own DDC/CI control.
    @MainActor private static var ddcBlankedDisplays: [CGDirectDisplayID: Double] = [:]
    /// True while black windows are covering the displays whose backlight could
    /// not be driven.
    @MainActor private static var isOverlayShowing = false
    @MainActor private static var unblankWatcher: Task<Void, Never>?
    /// Held while the screen is blacked, so macOS cannot run its own
    /// display-sleep timer underneath. On a Mac that requires a password as soon
    /// as the display turns off — the default — that timer is what eventually
    /// turns "black" into "locked".
    @MainActor private static var displaySleepAssertion: IOPMAssertionID?

    /// True while MacPilot is holding the screen black.
    @MainActor static var isBlanked: Bool {
        !blankedDisplays.isEmpty || !ddcBlankedDisplays.isEmpty || isOverlayShowing
    }

    /// Blacks every online display *without* putting any of them to sleep, so
    /// the system's "require password after the display is turned off" policy
    /// never fires.
    ///
    /// - Returns: false when there was nothing to black at all.
    @MainActor
    @discardableResult
    static func blankDisplay() -> Bool {
        if isBlanked { return true }

        let steps = ScreenBlankPlanner.steps(for: onlineCandidates())
        guard !steps.isEmpty else {
            DiagnosticLog.write("DisplayPower", "display blank failed reason=noOnlineDisplay")
            return false
        }

        // Input arriving after this point is what brings the screen back, so the
        // moment of blanking is the baseline to compare against.
        let idleAtBlank = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)

        var blanked: [CGDirectDisplayID: Float] = [:]
        var ddcBlanked: [CGDirectDisplayID: Double] = [:]
        var overlayScreens: [NSScreen] = []
        for step in steps {
            // Trust the probe, then verify: the state between the two can change
            // (a display can fall asleep mid-loop), and a failed write must not
            // leave that display uncovered.
            if step.action == .backlight,
               let driver = BrightnessDriver.shared,
               let original = driver.current(step.displayID),
               driver.apply(0, to: step.displayID) {
                blanked[step.displayID] = original
                continue
            }
            if step.action == .ddcBacklight,
               let ddc = DDCBacklight.shared,
               let original = ddc.level(step.displayID),
               ddc.setLevel(0, step.displayID) {
                // Already confirmed at zero by the read-back inside setLevel.
                ddcBlanked[step.displayID] = original
                continue
            }
            overlayScreens.append(contentsOf: screens(for: step.displayID))
        }

        guard !blanked.isEmpty || !ddcBlanked.isEmpty || !overlayScreens.isEmpty else {
            DiagnosticLog.write("DisplayPower", "display blank failed reason=noDisplayCouldBeBlacked")
            return false
        }

        blankedDisplays = blanked
        ddcBlankedDisplays = ddcBlanked
        if !overlayScreens.isEmpty {
            ScreenBlankOverlay.shared.show(covering: overlayScreens)
            isOverlayShowing = true
        }
        holdDisplaySleepAssertion()
        startUnblankWatcher(idleAtBlank: idleAtBlank)
        DiagnosticLog.write(
            "DisplayPower",
            "display blanked without sleeping backlight=\(blanked.count) ddc=\(ddcBlanked.count) overlay=\(overlayScreens.count) displays=\(steps.map(\.displayID))"
        )
        return true
    }

    /// Restores the brightness `blankDisplay()` captured and drops any overlay.
    @MainActor
    static func unblankDisplay() {
        unblankWatcher?.cancel()
        unblankWatcher = nil
        // Released even when nothing is blanked: a state that cleared
        // `blankedDisplays` on another path must not strand the assertion.
        defer { releaseDisplaySleepAssertion() }
        guard isBlanked else { return }
        if let driver = BrightnessDriver.shared {
            for (displayID, original) in blankedDisplays {
                driver.apply(original, to: displayID)
            }
        }
        blankedDisplays.removeAll()
        if let ddc = DDCBacklight.shared {
            for (displayID, original) in ddcBlankedDisplays {
                // Best effort: the level the user had before the blank is the one
                // thing worth restoring even if the monitor does not confirm it.
                _ = ddc.setLevel(original, displayID)
            }
        }
        ddcBlankedDisplays.removeAll()
        if isOverlayShowing {
            ScreenBlankOverlay.shared.hide()
            isOverlayShowing = false
        }
    }

    /// Termination teardown: stops the 400 ms wake watcher and hands the display
    /// state and its power assertion back. `willTerminate` returns straight into
    /// `exit()`, so this must be synchronous.
    @MainActor
    static func shutdown() {
        unblankDisplay()
    }

    /// What a user-initiated "turn off screen" means: black without locking.
    ///
    /// A real display sleep is deliberately *not* a fallback here. Every Mac
    /// that requires a password as soon as the display turns off — the default,
    /// and the reason this distinction exists — would turn that fallback into a
    /// lock, which is the job of MacPilot's separate lock action.
    ///
    /// - Returns: false when nothing could be blacked.
    @MainActor
    @discardableResult
    static func turnOffScreen() -> Bool {
        blankDisplay()
    }

    // MARK: - Brightness

    /// The display a brightness slider should drive.
    ///
    /// The built-in panel wins whenever its backlight can actually be driven,
    /// because that is the panel a MacBook user means by "screen brightness";
    /// falling back to any other drivable display keeps an Apple external display
    /// working, and an external monitor that speaks DDC/CI is still a backlight
    /// the slider can move. Pure, so the choice is testable without hardware.
    static func brightnessTarget(in candidates: [ScreenBlankCandidate]) -> CGDirectDisplayID? {
        candidates.first { $0.isBuiltIn && $0.canDriveBacklight }?.displayID
            ?? candidates.first { $0.canDriveBacklight }?.displayID
            ?? candidates.first { $0.canDriveDDC }?.displayID
    }

    /// Current backlight level in `0...1`, or `nil` when no online display can
    /// be driven.
    ///
    /// While the screen is held black the level the user last chose is reported
    /// rather than the held zero, so the remote slider does not jump to 0 the
    /// moment it is opened.
    @MainActor
    static func brightness() -> Double? {
        guard let displayID = brightnessTarget(in: onlineCandidates()) else { return nil }
        if let held = blankedDisplays[displayID] { return Double(held) }
        if let held = ddcBlankedDisplays[displayID] { return held }
        if let driver = BrightnessDriver.shared, let value = driver.current(displayID) {
            return Double(value)
        }
        return DDCBacklight.shared?.level(displayID)
    }

    /// Drives the target display's backlight.
    ///
    /// A brightness change is a request to *see* the screen, so a held blank is
    /// released first — otherwise the new level would be invisible.
    ///
    /// - Returns: false when no display could be driven.
    @MainActor
    @discardableResult
    static func setBrightness(_ value: Double) -> Bool {
        guard let displayID = brightnessTarget(in: onlineCandidates()) else { return false }
        if isBlanked { unblankDisplay() }
        let level = min(max(value, 0), 1)
        if let driver = BrightnessDriver.shared, driver.current(displayID) != nil {
            return driver.apply(Float(level), to: displayID)
        }
        return DDCBacklight.shared?.setLevel(level, displayID) ?? false
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

    // MARK: - Keeping the display awake

    /// A blacked screen that sleeps is a locked screen, which defeats the point
    /// of blacking it. The assertion is bounded by user activity — the first
    /// input releases it along with the blank — and by the process: IOKit drops
    /// it if MacPilot exits while one is held.
    @MainActor
    private static func holdDisplaySleepAssertion() {
        guard displaySleepAssertion == nil else { return }
        var assertionID = IOPMAssertionID()
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacPilot screen off" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            DiagnosticLog.write("DisplayPower", "display sleep assertion failed code=\(result)")
            return
        }
        displaySleepAssertion = assertionID
    }

    @MainActor
    private static func releaseDisplaySleepAssertion() {
        guard let assertionID = displaySleepAssertion else { return }
        displaySleepAssertion = nil
        IOPMAssertionRelease(assertionID)
    }

    // MARK: - Display discovery

    /// Online, awake displays with their backlight capability probed. The probe
    /// is a read, so it is free of side effects and safe to run for every display
    /// on every blank.
    @MainActor
    private static func onlineCandidates() -> [ScreenBlankCandidate] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }
        return displayIDs.prefix(Int(count)).compactMap { displayID in
            guard CGDisplayIsActive(displayID) != 0 else { return nil }
            let canDriveBacklight = BrightnessDriver.shared?.current(displayID) != nil
            // Only worth asking a display that has no `DisplayServices` backlight:
            // a built-in panel answers no to DDC anyway, and this probe is an I2C
            // round trip to the monitor.
            let canDriveDDC = !canDriveBacklight && DDCBacklight.shared?.level(displayID) != nil
            return ScreenBlankCandidate(
                displayID: displayID,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                canDriveBacklight: canDriveBacklight,
                canDriveDDC: canDriveDDC
            )
        }
    }

    @MainActor
    private static func screens(for displayID: CGDirectDisplayID) -> [NSScreen] {
        NSScreen.screens.filter { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
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
/// private framework, and every use is optional — a display it cannot drive is
/// covered by the black overlay instead of by a real display sleep.
///
/// Note that the call is per display. Asking about `CGMainDisplayID()` alone was
/// the bug behind "turn off screen" locking the Mac: with an external monitor as
/// the main display, the answer belongs to a display that has no backlight to
/// drive, so the blank failed and the caller fell back to sleeping every display.
private struct BrightnessDriver: Sendable {
    let read: @Sendable (CGDirectDisplayID) -> Float?
    let write: @Sendable (CGDirectDisplayID, Float) -> Bool

    static let shared: BrightnessDriver? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let readSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let writeSymbol = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        let get = unsafeBitCast(readSymbol, to: GetBrightnessFn.self)
        let set = unsafeBitCast(writeSymbol, to: SetBrightnessFn.self)
        return BrightnessDriver(
            read: { displayID in
                var value: Float = 0
                return get(displayID, &value) == 0 ? value : nil
            },
            write: { displayID, value in set(displayID, value) == 0 }
        )
    }()

    func current(_ displayID: CGDirectDisplayID) -> Float? { read(displayID) }
    @discardableResult func apply(_ value: Float, to displayID: CGDirectDisplayID) -> Bool {
        write(displayID, value)
    }
}
