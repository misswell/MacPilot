import CoreGraphics
import Foundation

/// The CGEvent primitives every unlock path shares.
///
/// This is the only place that synthesizes the password keystrokes. BLE
/// proximity unlock and the iPhone remote control both call it, so there is a
/// single implementation to audit and maintain.
@MainActor
struct ScreenUnlockExecutor {
    private let logHandler: (String) -> Void

    init(log: @escaping (String) -> Void = { DiagnosticLog.write("ScreenControl", $0) }) {
        self.logHandler = log
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    /// Posts the system "Lock Screen" shortcut (Control-Command-Q).
    func lockScreenShortcut() {
        postKey(0x0C, flags: [.maskControl, .maskCommand])
    }

    /// Dismisses a running screen saver so the password field can appear.
    func dismissScreensaver() {
        postKey(0x35) // Escape
    }

    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    /// Clears whatever is in the password field and types `password` followed
    /// by Return.
    func postPassword(_ password: String) async {
        log("preparing password field for key events")

        // The lock UI can recreate its secure text field while wake services
        // (Touch ID, Auto Unlock, avatar transitions) are still settling.
        // Normalize any surviving text before every retry so a late attempt
        // cannot append a second password to a partially handled first one.
        postKey(0x00, flags: .maskCommand) // Command-A
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        postKey(0x33) // Delete
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        log("posting password key events")
        let src = CGEventSource(stateID: .hidSystemState)
        let per = 20
        let utf16 = password.utf16
        var index = utf16.startIndex
        for offset in stride(from: 0, to: utf16.count, by: per) {
            let len = offset + per < utf16.count ? per : utf16.count - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = utf16[index]
                index = utf16.index(after: index)
            }
            let down = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            up?.post(tap: .cghidEventTap)
            buffer.deallocate()
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        postKey(0x24) // Return
    }
}

// MARK: - Backwards compatible free function

/// Retained for callers compiled against the old API.
@MainActor
func bleLockScreenViaShortcut() {
    ScreenUnlockExecutor().lockScreenShortcut()
}
