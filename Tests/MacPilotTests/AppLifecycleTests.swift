import AppKit
import Testing
@testable import MacPilot

@MainActor
struct AppLifecycleTests {
    @Test func closingTheLastWindowKeepsEverySupportedAppPresenceModeRunning() {
        let delegate = AppDelegate()
        let application = NSApplication.shared
        for settings in [
            AppPresenceSettings.standard,
            AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true),
            AppPresenceSettings(showsDockIcon: true, showsMenuBarIcon: false)
        ] {
            // No activation changes, status items or actual windows in tests.
            let presence = AppPresenceController(
                settings: settings, isMainWindowOpen: true, isLaunched: true,
                notificationCenter: NotificationCenter(), applyPolicy: { _ in }
            )
            presence.mainWindowVisibilityChanged(false)
            #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
            #expect(presence.appliedActivationPolicy == (settings.showsMenuBarIcon ? .accessory : .regular))
            presence.mainWindowVisibilityChanged(true)
            #expect(presence.isMainWindowOpen)
        }
    }

    @Test func explicitQuitStillPassesTheExistingTerminationDelegate() throws {
        // Do not ever enter real display recovery from an automated test.
        try #require(DisplayControlTermination.owner == nil)
        let reply = AppDelegate().applicationShouldTerminate(NSApplication.shared)
        #expect(reply == .terminateNow)
    }
}
