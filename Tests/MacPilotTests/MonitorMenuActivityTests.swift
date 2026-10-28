import AppKit
import Testing
@testable import MacPilot

@MainActor
struct MonitorMenuActivityTests {
    @Test func duplicateBeginAndUnknownEndDoNotCorruptTrackingState() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)
        let menu = NSMenu(title: "tracked")
        let unknownMenu = NSMenu(title: "unknown")

        activity.register(rootMenu: menu)
        #expect(!activity.isTracking)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: unknownMenu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!activity.isTracking)
    }

    @Test func nestedMenusKeepTrackingUntilEveryMenuEnds() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)
        let firstMenu = NSMenu(title: "first")
        let secondMenu = NSMenu(title: "second")
        let item = NSMenuItem(title: "child", action: nil, keyEquivalent: "")
        firstMenu.addItem(item)
        item.submenu = secondMenu
        activity.register(rootMenu: firstMenu)

        center.post(name: NSMenu.didBeginTrackingNotification, object: firstMenu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: secondMenu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: firstMenu)
        #expect(activity.isTracking)

        center.post(name: NSMenu.didEndTrackingNotification, object: secondMenu)
        #expect(!activity.isTracking)
    }

    @Test func notificationsForAnUntrackedObjectDoNotStartTracking() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)

        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu(title: "never began"))
        #expect(!activity.isTracking)
    }
    @Test func unrelatedMenusNeverAuthorizeResourceScans() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)
        let owned = NSMenu(title: "status menu")
        let unrelated = NSMenu(title: "clipboard context menu")
        activity.register(rootMenu: owned)
        for _ in 0..<100 {
            center.post(name: NSMenu.didBeginTrackingNotification, object: unrelated)
            #expect(!activity.isTracking)
            center.post(name: NSMenu.didEndTrackingNotification, object: unrelated)
        }
        center.post(name: NSMenu.didBeginTrackingNotification, object: owned)
        #expect(activity.isTracking)
        center.post(name: NSMenu.didBeginTrackingNotification, object: unrelated)
        center.post(name: NSMenu.didEndTrackingNotification, object: owned)
        #expect(!activity.isTracking)
    }

    @Test func legacyMatcherOnlyAdoptsTheMatchingRootAndItsSubmenus() {
        let center = NotificationCenter()
        let activity = MonitorMenuActivity(notificationCenter: center)
        let root = NSMenu(title: "owned legacy root")
        let child = NSMenu(title: "monitor")
        let item = NSMenuItem(title: "child", action: nil, keyEquivalent: "")
        root.addItem(item)
        item.submenu = child
        activity.setLegacyRootMatcher { $0 === root }
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu(title: "other"))
        #expect(!activity.isTracking)
        center.post(name: NSMenu.didBeginTrackingNotification, object: child)
        #expect(activity.isTracking)
        center.post(name: NSMenu.didEndTrackingNotification, object: child)
        #expect(!activity.isTracking)
    }

}
