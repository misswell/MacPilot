//
//  ScreenshotPopupWindowProbe.swift
//  MacPilot
//
//  Is another application's popup on screen right now?
//
//  A capture shortcut must not present the selection overlay before the frozen
//  backdrop is taken while a menu-bar menu, a combobox dropdown, a context menu
//  or a popover is open.  Presenting the overlay takes key window status, which
//  ends that popup's tracking session and removes the dropdown from the screen;
//  the frozen frame taken afterwards then misses the very thing the user wanted
//  to photograph.  This probe is what lets the shortcut pick the capture-first
//  order for that case while the ordinary case keeps presenting immediately.
//
//  The walk of the window server's on-screen list runs once per shortcut press,
//  never per pointer event.
//

import AppKit
import CoreGraphics

nonisolated enum ScreenshotPopupWindowProbe {
    /// Layers at or above this one draw popup surfaces: `NSMenu` windows —
    /// menu-bar menus, combobox dropdowns, context menus — sit at
    /// `kCGPopUpMenuWindowLevel` (101), tooltips above it.  The menu bar itself
    /// (`kCGMainMenuWindowLevel` = 24) and the Dock's full-display container
    /// window (`kCGDockWindowLevel` = 20) stay below it, so an idle desktop never
    /// reads as an open popup.  Dock *menus* ride at popup levels and still count.
    static let popupLayerFloor = Int(CGWindowLevelForKey(.popUpMenuWindow))

    @MainActor
    static func hasOpenPopup() -> Bool {
        hasOpenPopup(
            in: liveWindowInfo(),
            ownPID: getpid(),
            dockPID: NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.processIdentifier
        )
    }

    static func liveWindowInfo() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// Split out from `hasOpenPopup` so the verdict can be exercised with
    /// window-server-shaped entries instead of the live list.
    static func hasOpenPopup(
        in info: [[String: Any]],
        ownPID: pid_t,
        dockPID: pid_t?
    ) -> Bool {
        info.contains { entry in
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            // An invisible surface is not on screen.
            guard alpha > 0 else { return false }
            guard layer >= popupLayerFloor else { return false }
            // Our own status-item menu and our own windows are not the other
            // application's popup this check is about.
            guard ownerPID != ownPID else { return false }
            // The Dock keeps one container window spanning the whole display for
            // its strip; nothing at or below the Dock level is a popup (menus it
            // opens sit at popup levels and are counted above).
            if let dockPID, ownerPID == dockPID,
               layer <= Int(CGWindowLevelForKey(.dockWindow)) {
                return false
            }
            return true
        }
    }
}
