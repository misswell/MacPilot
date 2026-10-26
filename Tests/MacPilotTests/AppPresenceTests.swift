import AppKit
import Testing
@testable import MacPilot

/// 两个图标开关的规则：默认都显示、至少留一个入口、关窗口收起 Dock 图标。
@MainActor
struct AppPresenceTests {
    @Test func freshInstallShowsBothIcons() {
        #expect(AppPresenceSettings.standard == AppPresenceSettings(showsDockIcon: true, showsMenuBarIcon: true))
        // 缺键的历史配置（还没有这两个开关）同样按安装默认值处理。
        let legacy = try? JSONDecoder().decode(AppPresenceSettings.self, from: Data("{}".utf8))
        #expect(legacy == .standard)
    }

    @Test func hidingBothIconsIsRefusedInEitherOrder() {
        // 菜单栏图标是唯一入口时，Dock 开关必须是关不掉的。
        let menuBarOnly = AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true)
        #expect(menuBarOnly.allowingMenuBarIconChange(to: false) == nil)
        #expect(menuBarOnly.allowingDockIconChange(to: true)?.showsDockIcon == true)

        // 反过来同样成立：只剩 Dock 图标时菜单栏开关也关不掉。
        let dockOnly = AppPresenceSettings(showsDockIcon: true, showsMenuBarIcon: false)
        #expect(dockOnly.allowingDockIconChange(to: false) == nil)
        #expect(dockOnly.allowingMenuBarIconChange(to: true)?.showsMenuBarIcon == true)
    }

    @Test func aConfigurationThatHidesBothStillLeavesAMenuBarIcon() throws {
        let decoded = try JSONDecoder().decode(
            AppPresenceSettings.self,
            from: Data(#"{"showsDockIcon":false,"showsMenuBarIcon":false}"#.utf8)
        )
        #expect(decoded.showsMenuBarIcon)
        #expect(!decoded.showsDockIcon)
    }

    @Test func dockIconFollowsTheMainWindowOnlyWhileTheMenuBarIconIsAvailable() {
        // 两个都开：Dock 图标准确跟随主窗口。
        #expect(!AppPresencePolicy.showsDockIcon(.standard, isMainWindowOpen: false))
        #expect(AppPresencePolicy.showsDockIcon(.standard, isMainWindowOpen: true))

        // 只留 Dock 图标：它是唯一入口，窗口关掉也必须继续显示。
        let dockOnly = AppPresenceSettings(showsDockIcon: true, showsMenuBarIcon: false)
        #expect(AppPresencePolicy.showsDockIcon(dockOnly, isMainWindowOpen: false))
        #expect(AppPresencePolicy.showsDockIcon(dockOnly, isMainWindowOpen: true))

        // 用户关掉了 Dock 图标：什么窗口状态都不显示。
        let menuBarOnly = AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true)
        #expect(!AppPresencePolicy.showsDockIcon(menuBarOnly, isMainWindowOpen: true))
    }

    @Test func controllerAppliesTheStoredSettingsAtLaunch() {
        let recorded = Recorder()
        let controller = AppPresenceController(
            settings: AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true),
            isMainWindowOpen: true,
            isLaunched: true,
            notificationCenter: NotificationCenter(),
            applyPolicy: { recorded.policies.append($0) }
        )
        var icons: [Bool] = []
        controller.attachMenuBarIcon { icons.append($0) }

        #expect(controller.appliedActivationPolicy == .accessory)
        #expect(recorded.policies == [.accessory])
        #expect(icons == [true])
    }

    @Test func closingTheMainWindowDropsTheDockIconAndReopeningRestoresIt() {
        let recorded = Recorder()
        let controller = AppPresenceController(
            settings: .standard,
            isMainWindowOpen: true,
            isLaunched: true,
            notificationCenter: NotificationCenter(),
            applyPolicy: { recorded.policies.append($0) }
        )

        controller.mainWindowVisibilityChanged(false)
        #expect(controller.appliedActivationPolicy == .accessory)

        controller.mainWindowVisibilityChanged(true)
        #expect(controller.appliedActivationPolicy == .regular)
        #expect(recorded.policies == [.regular, .accessory, .regular])
    }

    @Test func dockOnlyConfigurationKeepsTheIconAfterTheWindowCloses() {
        let recorded = Recorder()
        let controller = AppPresenceController(
            settings: AppPresenceSettings(showsDockIcon: true, showsMenuBarIcon: false),
            isMainWindowOpen: true,
            isLaunched: true,
            notificationCenter: NotificationCenter(),
            applyPolicy: { recorded.policies.append($0) }
        )
        var icons: [Bool] = []
        controller.attachMenuBarIcon { icons.append($0) }

        controller.mainWindowVisibilityChanged(false)

        #expect(controller.appliedActivationPolicy == .regular)
        #expect(icons == [false])
        #expect(recorded.policies == [.regular])
    }

    @Test func hidingTheMenuBarIconTurnsItOffAndShowingItAgainRestoresIt() {
        let controller = AppPresenceController(
            settings: .standard,
            isMainWindowOpen: true,
            isLaunched: true,
            notificationCenter: NotificationCenter(),
            applyPolicy: { _ in }
        )
        var icons: [Bool] = []
        controller.attachMenuBarIcon { icons.append($0) }

        controller.update(settings: AppPresenceSettings(showsDockIcon: true, showsMenuBarIcon: false))
        controller.update(settings: .standard)

        // 同一个值不重复下发，避免每帧重新装卸状态栏图标。
        #expect(icons == [true, false, true])
    }

    @Test func hidingTheDockIconSwitchesToAccessoryEvenWithTheWindowOpen() {
        let recorded = Recorder()
        let controller = AppPresenceController(
            settings: .standard,
            isMainWindowOpen: true,
            isLaunched: true,
            notificationCenter: NotificationCenter(),
            applyPolicy: { recorded.policies.append($0) }
        )

        controller.update(settings: AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true))

        #expect(controller.appliedActivationPolicy == .accessory)
        #expect(recorded.policies == [.regular, .accessory])
    }

    @Test func settingsAreNotAppliedUntilTheAppFinishesLaunching() {
        let recorded = Recorder()
        let center = NotificationCenter()
        let controller = AppPresenceController(
            settings: .standard,
            isMainWindowOpen: true,
            isLaunched: false,
            notificationCenter: center,
            applyPolicy: { recorded.policies.append($0) }
        )
        var icons: [Bool] = []
        controller.attachMenuBarIcon { icons.append($0) }

        // App.init 阶段还碰不到 NSApp；状态栏控制器此时也还不存在。
        #expect(recorded.policies.isEmpty)

        center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)

        #expect(controller.appliedActivationPolicy == .regular)
        #expect(recorded.policies == [.regular])
        #expect(icons == [true])
    }
    @Test func theModelRefusesTheSwitchThatWouldHideTheLastIcon() {
        // 与 MacPilotModel.setShowsDockIcon / setShowsMenuBarIcon 同一套规则，
        // 但用纯值类型验证：构造 MacPilotModel 会拉起整套启动流程。
        var settings = AppPresenceSettings.standard
        #expect(settings.allowingDockIconChange(to: false) != nil)
        settings = settings.allowingDockIconChange(to: false)!

        // 只剩菜单栏图标后，它不能再被关掉。
        #expect(settings.allowingMenuBarIconChange(to: false) == nil)

        // 反过来同样成立。
        var reverse = AppPresenceSettings.standard
        reverse = reverse.allowingMenuBarIconChange(to: false)!
        #expect(reverse.allowingDockIconChange(to: false) == nil)
    }

    @Test func theControllerFollowsAModelStyleSequenceOfChanges() {
        let recorded = Recorder()
        let controller = AppPresenceController(
            settings: .standard,
            isMainWindowOpen: true,
            isLaunched: true,
            notificationCenter: NotificationCenter(),
            applyPolicy: { recorded.policies.append($0) }
        )

        // 关窗口，再关 Dock 图标：两步都要落到同一条 accessory 策略上。
        controller.mainWindowVisibilityChanged(false)
        controller.update(settings: AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true))

        #expect(controller.settings.showsDockIcon == false)
        #expect(controller.isMainWindowOpen == false)
        #expect(controller.appliedActivationPolicy == .accessory)
    }
}

@MainActor
private final class Recorder {
    var policies: [NSApplication.ActivationPolicy] = []
}
