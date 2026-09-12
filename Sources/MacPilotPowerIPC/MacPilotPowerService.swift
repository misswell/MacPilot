import Foundation

/// Identity shared by the MacPilot app and its privileged power helper.
///
/// The helper is deliberately narrow: it can only flip the global
/// `SleepDisabled` power setting and answer questions about it. There is no
/// generic command execution surface.
public enum MacPilotPowerService {
    /// Mach service name, also used as the LaunchDaemon `Label`.
    public static let machServiceName = "com.misswell.macpilot.powerhelper"
    /// Plist name inside `Contents/Library/LaunchDaemons`.
    public static let daemonPlistName = "com.misswell.macpilot.powerhelper.plist"
    /// Only clients signed by this team are allowed to talk to the helper.
    public static let teamIdentifier = "U8U443D7ZL"
    /// Explicit allow-list of client bundle identifiers. Never derived from
    /// arbitrary input.
    public static let allowedClientBundleIdentifiers: Set<String> = [
        "com.misswell.macpilot",
        "com.misswell.octopilot"
    ]

    /// Root-owned directory holding the tiny helper runtime state file.
    public static let stateDirectoryPath = "/Library/Application Support/MacPilot"
    public static let stateFileName = "power-helper-state.json"
}

/// The complete privileged surface exposed over XPC.
///
/// Every method has a reply block so the app can surface a concrete failure
/// instead of silently doing nothing.
@objc public protocol MacPilotPowerHelperProtocol {
    /// Turns the global `SleepDisabled` setting on or off, honoring ownership:
    /// a value the user (or another tool) already set is never overwritten.
    /// The reply reports `(success, errorDescription)`.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void)

    /// Reads the *actual* system value, not a cached flag.
    /// The reply reports `(sleepDisabled, errorDescription)`.
    func getSleepDisabled(reply: @escaping @Sendable (Bool, String?) -> Void)

    /// Keeps the helper's watchdog alive while the app is running.
    /// The reply reports whether the helper currently owns the setting.
    func heartbeat(reply: @escaping @Sendable (Bool) -> Void)
}
