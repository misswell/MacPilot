//
//  DisplayPower.swift
//  MacPilot
//
//  Shared display power helpers: blacking the display on demand and waking
//  it again. Used by the BLE proximity lock and the menu-bar "turn off
//  screen" action.
//

import IOKit
import IOKit.pwr_mgt

enum DisplayPower {
    /// Blacks the display immediately by asking IODisplayWrangler to idle.
    /// Any keyboard or mouse input wakes it again; no privacy permission is
    /// required for the registry write.
    static func sleepDisplay() {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard entry != 0 else { return }
        IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanTrue)
        IOObjectRelease(entry)
    }

    /// Wakes a slept display by declaring local user activity.
    static func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("MacPilot" as CFString, kIOPMUserActiveLocal, &assertionID)
    }
}
