//
//  ScreenBlankOverlay.swift
//  MacPilot
//
//  Black windows for the displays whose backlight cannot be driven.
//

import AppKit

/// Covers a display with black when its backlight cannot be dropped to zero —
/// an external monitor, or a MacBook panel that is inactive because the lid is
/// closed.
///
/// A window is the fallback for a plain reason: the alternative is a real
/// display sleep, and macOS locks the session when the display sleeps if the
/// user requires a password for that. A black window keeps the session
/// unlocked, exactly like the backlight path does.
@MainActor
final class ScreenBlankOverlay {
    static let shared = ScreenBlankOverlay()

    private var panels: [NSPanel] = []

    var isShowing: Bool { !panels.isEmpty }

    func show(covering screens: [NSScreen]) {
        guard !screens.isEmpty else { return }
        hide()
        panels = screens.map(makePanel(for:))
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = ScreenBlankPanel(
            contentRect: screen.frame,
            // `.nonactivatingPanel` is what keeps a dismissal click from
            // activating MacPilot and pulling the user out of whatever they were
            // doing; the panel still takes the click.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.isFloatingPanel = false
        // Panels hide themselves when their app deactivates by default, which is
        // the opposite of what a screen cover wants.
        panel.hidesOnDeactivate = false
        // Above the menu bar and the Dock, and present on every Space so that
        // switching desktops cannot reveal the desktop underneath.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.orderFrontRegardless()
        return panel
    }
}

/// A borderless window cannot become key by default, which would let the
/// keystroke that dismisses the cover reach the hidden app underneath.
private final class ScreenBlankPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
