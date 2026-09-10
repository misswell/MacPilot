import CoreGraphics
import Foundation
import OSLog

/// Small helpers that measure user idle time and post a harmless no-op mouse
/// event to defer the screen saver while Awake sessions are active. Posting
/// events needs Accessibility access; without it macOS silently ignores them.
enum AwakeIdleInput {
    /// Decides whether the screen saver should be deferred right now: only
    /// while the session still blocks it (before the allowed idle window
    /// elapses) and only shortly before the system idle limit is reached.
    static func shouldDeferScreenSaver(
        idleSeconds: Double,
        allowedAfterMinutes: Int,
        systemIdleLimitSeconds: Double?
    ) -> Bool {
        guard idleSeconds >= 0 else { return false }
        let allowedAfter = Double(max(allowedAfterMinutes, 1)) * 60
        guard idleSeconds < allowedAfter else { return false }
        guard let systemIdleLimitSeconds, systemIdleLimitSeconds >= 60 else { return false }
        return idleSeconds >= systemIdleLimitSeconds - 15
    }

    /// Seconds since the last user input in the current login session.
    static func sessionIdleSeconds() -> Double {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return 0 }
        return (session["kCGSSessionIdleTime"] as? NSNumber)?.doubleValue ?? 0
    }

    /// The screen saver idle limit from System Settings, in seconds.
    /// Returns nil when the screen saver is disabled.
    static func systemScreenSaverIdleSeconds() -> Double? {
        guard let value = CFPreferencesCopyAppValue("idleTime" as CFString, "com.apple.screensaver" as CFString) else {
            return nil
        }
        let seconds = (value as? NSNumber)?.doubleValue ?? 0
        return seconds > 0 ? seconds : nil
    }

    static func postIdleDeferringMouseEvent(logger: Logger? = nil) {
        let position = CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: 0)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: position,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
        logger?.notice("Deferred the screen saver with a no-op mouse event")
    }
}
