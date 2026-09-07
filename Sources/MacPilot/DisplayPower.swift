//
//  DisplayPower.swift
//  MacPilot
//
//  Shared display power helpers: blacking the display on demand and waking
//  it again. Used by the BLE proximity lock and the menu-bar "turn off
//  screen" action.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

enum DisplayPower {
    /// Blacks the display immediately. Keyboard or mouse input wakes it again.
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
}
