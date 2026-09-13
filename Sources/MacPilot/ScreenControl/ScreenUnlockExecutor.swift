import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Decision table for typing the login password without ever leaking it into
/// the user session.
///
/// A user who unlocks faster than MacPilot types — Touch ID, a watch, typing
/// the password by hand — hands the session back with the pre-lock input focus
/// intact. Any keystroke posted after that moment lands in whatever field the
/// user left focused before locking, which is how a stored password can end up
/// inside a chat draft. The gate therefore distinguishes three states:
///
/// * `.type` — the session is locked and the lock screen's password field
///   holds the keyboard. The field raises secure event input exactly there,
///   and no plain text field in the user session does, so this is the only
///   state that may receive the password.
/// * `.revealField` — locked, but the password field is not up yet (clock
///   screen, screensaver). A nudge brings it up; no password yet.
/// * `.abort` — the session is no longer locked. Nothing may be posted, not
///   even a stray Return.
enum PasswordTypingGate: Equatable {
    case type
    case revealField
    case abort

    static func command(locked: Bool, secureFieldFocused: Bool) -> PasswordTypingGate {
        guard locked else { return .abort }
        return secureFieldFocused ? .type : .revealField
    }
}

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
    ///
    /// Every stage re-reads `PasswordTypingGate` right before posting — the
    /// pre-clear, each group of characters, and the Return. Mid-typing only
    /// "no longer locked" stops the keystrokes: the lock UI can drop and
    /// re-raise its secure field while wake services settle, and that blip must
    /// not leave a half-typed password behind, because a locked session routes
    /// everything to the login window anyway and the next attempt pre-clears
    /// the field. An unlocked session stops the keystrokes instantly, which is
    /// what keeps a fast manual unlock from pasting the password into the
    /// user's own text field.
    func postPassword(_ password: String) async {
        guard await waitForPasswordField(maxWait: 1.2) else { return }

        log("preparing password field for key events")

        // The lock UI can recreate its secure text field while wake services
        // (Touch ID, Auto Unlock, avatar transitions) are still settling.
        // Normalize any surviving text before every retry so a late attempt
        // cannot append a second password to a partially handled first one.
        postKey(0x00, flags: .maskCommand) // Command-A
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, mayKeepTyping(stage: "select") else { return }
        postKey(0x33) // Delete
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, mayKeepTyping(stage: "clear") else { return }

        log("posting password key events")
        let src = CGEventSource(stateID: .hidSystemState)
        // Small groups rather than one batch: each group pays for one gate
        // check, so the window in which a fast manual unlock can still swallow
        // keystrokes is a few characters wide instead of a whole password.
        let per = 4
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
            guard !Task.isCancelled, mayKeepTyping(stage: "type") else { return }
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, mayKeepTyping(stage: "return") else { return }
        postKey(0x24) // Return
    }

    // MARK: - Typing gate

    /// Waits until the lock screen's password field can actually receive the
    /// keystrokes. While the clock screen is showing, Escape brings the field
    /// up; the wait is bounded so a caller's retry schedule keeps running.
    private func waitForPasswordField(maxWait: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        while true {
            switch typingGate() {
            case .type:
                return true
            case .abort:
                log("password typing skipped reason=sessionNotLocked")
                return false
            case .revealField:
                guard Date() < deadline, !Task.isCancelled else {
                    log("password typing skipped reason=passwordFieldNotReady")
                    return false
                }
                // The nudge is safe exactly because the field is not up: on
                // the clock screen Escape only reveals password entry.
                postKey(0x35) // Escape
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func typingGate() -> PasswordTypingGate {
        PasswordTypingGate.command(
            locked: ScreenLockStateReader.current() == .locked,
            secureFieldFocused: IsSecureEventInputEnabled()
        )
    }

    /// The gate must stay `.abort`-free to keep posting. Returns false — after
    /// logging — the moment the session is no longer locked.
    private func mayKeepTyping(stage: String) -> Bool {
        guard typingGate() != .abort else {
            log("password typing aborted stage=\(stage) reason=sessionNoLongerLocked")
            return false
        }
        return true
    }
}

// MARK: - Backwards compatible free function

/// Retained for callers compiled against the old API.
@MainActor
func bleLockScreenViaShortcut() {
    ScreenUnlockExecutor().lockScreenShortcut()
}
