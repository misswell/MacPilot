import Foundation

/// The launch policy used after an update replaces the running app bundle.
/// `-n` prevents LaunchServices from reusing a stale instance record and `-g`
/// keeps a menu-bar app restart from stealing focus. Keeping this in the shared
/// target makes the updater's relaunch contract directly testable without
/// launching a real application from a test.
public enum UpdaterLaunchPlan {
    public static let executablePath = "/usr/bin/open"

    public static func arguments(for application: URL) -> [String] {
        ["-n", "-g", application.path]
    }
}
