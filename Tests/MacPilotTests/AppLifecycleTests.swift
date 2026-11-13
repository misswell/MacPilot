import AppKit
import Combine
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
    @Test func deepLinksDeliveredBeforeServicesAreBufferedAndDrainedOnce() {
        let delegate = AppDelegate()
        let url = URL(string: "macpilot://settings")!
        delegate.application(NSApplication.shared, open: [url])
        #expect(delegate.takePendingDeepLinks() == [url])
        #expect(delegate.takePendingDeepLinks().isEmpty)
        delegate.application(NSApplication.shared, open: [url])
        #expect(delegate.takePendingDeepLinks().isEmpty)
    }

    private final class StartupValue: ObservableObject {
        @Published var revision = 0
    }

    @Test func permissionUsingModelsAreNotConstructedBeforeAppKitFinishesLaunching() {
        let center = NotificationCenter()
        var turns: [@MainActor () -> Void] = []
        var constructions = 0
        let startup = AppLaunchBootstrap(
            center: center, isLaunched: false, schedule: { turns.append($0) },
            makeValue: { constructions += 1; return StartupValue() }
        )
        #expect(constructions == 0)
        #expect(startup.value == nil)
        center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
        #expect(turns.isEmpty)
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        #expect(constructions == 0)
        #expect(turns.count == 1)
        turns.removeFirst()()
        #expect(constructions == 1)
        #expect(startup.value != nil)
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        #expect(turns.isEmpty)
        startup.stop()
    }

    @Test func lateBootstrapStartsOnceAndForwardsItsServicesChanges() throws {
        var turns: [@MainActor () -> Void] = []
        let startup = AppLaunchBootstrap(
            center: NotificationCenter(), isLaunched: true,
            schedule: { turns.append($0) }, makeValue: { StartupValue() }
        )
        #expect(startup.value == nil)
        #expect(turns.count == 1)
        turns.removeFirst()()
        let value = try #require(startup.value)
        var changes = 0
        let observation = startup.objectWillChange.sink { changes += 1 }
        value.revision += 1
        #expect(changes == 1)
        withExtendedLifetime(observation) {}
        startup.stop()
    }

    @Test func terminationBeforeTheLaunchTurnCannotResurrectFeatures() {
        let center = NotificationCenter()
        var turn: (@MainActor () -> Void)?
        var constructions = 0
        let startup = AppLaunchBootstrap(
            center: center, isLaunched: false, schedule: { turn = $0 },
            makeValue: { constructions += 1; return StartupValue() }
        )
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        turn?()
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        #expect(constructions == 0)
        #expect(startup.value == nil)
    }

    @Test func releasingTheBootstrapCancelsItsQueuedConstruction() {
        let center = NotificationCenter()
        var turn: (@MainActor () -> Void)?
        var constructions = 0
        var startup: AppLaunchBootstrap<StartupValue>? = AppLaunchBootstrap(
            center: center, isLaunched: false, schedule: { turn = $0 },
            makeValue: { constructions += 1; return StartupValue() }
        )
        weak var released = startup
        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
        startup = nil
        turn?()
        #expect(released == nil)
        #expect(constructions == 0)
    }

}
