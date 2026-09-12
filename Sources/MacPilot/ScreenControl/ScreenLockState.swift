import CoreGraphics
import Foundation

/// Lock state of the current login session.
enum ScreenLockState: String, Equatable, Sendable {
    case locked
    case unlocked
    case unknown
}

/// The BLE feature has always used this name; the type now lives with the rest
/// of the screen control code so both callers share one definition.
typealias BLEScreenLockState = ScreenLockState

/// Pure decision table for the session dictionary. Kept free of CoreGraphics so
/// it stays directly unit testable.
enum ScreenLockStateResolver {
    static func resolve(
        locked: Bool?,
        loginDone: Bool?,
        sessionUserName: String?,
        currentUserName: String
    ) -> ScreenLockState {
        if let locked {
            return locked ? .locked : .unlocked
        }
        if loginDone == true, sessionUserName == currentUserName {
            return .unlocked
        }
        return .unknown
    }
}

typealias BLEScreenLockStateResolver = ScreenLockStateResolver

/// Reads the live lock and display power state from the system.
enum ScreenLockStateReader {
    static func current() -> ScreenLockState {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return .unknown
        }
        return ScreenLockStateResolver.resolve(
            locked: boolean(dict["CGSSessionScreenIsLocked"]),
            loginDone: boolean(dict["kCGSessionLoginDoneKey"]),
            sessionUserName: dict["kCGSSessionUserNameKey"] as? String,
            currentUserName: NSUserName()
        )
    }

    /// The authoritative check for "is the display asleep right now". The
    /// notification derived flag can go stale when a key press wakes the Mac.
    static func displayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? Int { return value != 0 }
        return nil
    }
}
