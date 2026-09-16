import Foundation

/// The launch policy used after an update replaces the running app bundle.
/// Launching the bundle executable directly avoids relying on a stale
/// LaunchServices record for the path that was just replaced. Keeping this in
/// the shared target makes the updater's relaunch contract directly testable
/// without launching a real application from a test.
public enum UpdaterLaunchPlan {
    public static func directExecutableURL(
        for application: URL,
        executableName: String = "MacPilot"
    ) -> URL {
        application
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }
}
