import AppKit
import MacPilotDisplayControlCore
import SwiftUI
import Testing
@testable import MacPilot

@MainActor
struct DisplayControlMenuTests {
    @Test func lastUsablePhysicalDisplayCannotBeDisabledFromMenu() {
        let display = physical("built-in", id: 7, main: true)

        #expect(!DisplayControlMenuPolicy.canDisable(display, displays: [display]))
    }

    @Test func physicalDisplaysKeepTheExpectedDisableAndKeepOnlyOptions() {
        let builtIn = physical("built-in", id: 7, main: true)
        let external = physical("external", id: 8, main: false)

        #expect(DisplayControlMenuPolicy.canDisable(external, displays: [builtIn, external]))
        #expect(DisplayControlMenuPolicy.canKeepOnly(external, displays: [builtIn, external]))
        #expect(DisplayControlMenuPolicy.canKeepOnly(builtIn, displays: [builtIn]))
        #expect(!DisplayControlMenuPolicy.canDisable(builtIn, displays: [builtIn]))
    }

    @Test func virtualDisplayCannotBeKeptAsTheOnlyOutputFromLocalMenu() {
        let virtual = DisplayControlDisplay(
            uuid: "owned-virtual", displayID: 9, name: "Virtual", isBuiltIn: false,
            isVirtual: true, isOnline: true, isActive: true, isMain: false,
            width: 1920, height: 1080, isOwned: true
        )

        #expect(!DisplayControlMenuPolicy.canKeepOnly(virtual, displays: [virtual]))
    }

    @Test func aForeignVirtualSurvivorDoesNotAuthorizeDisablingTheLastPhysicalDisplay() {
        let physical = physical("built-in", id: 7, main: true)
        let virtual = DisplayControlDisplay(
            uuid: "foreign-virtual", displayID: 9, name: "Virtual", isBuiltIn: false,
            isVirtual: true, isOnline: true, isActive: true, isMain: false,
            width: 1920, height: 1080, isOwned: false
        )

        #expect(!DisplayControlMenuPolicy.canDisable(physical, displays: [physical, virtual]))
    }

    @Test func missingUUIDNeverFallsBackToMainOrAReusedDisplayID() {
        let replacement = physical("replacement-uuid", id: 7, main: true)

        #expect(DisplayControlMenuPolicy.target(uuid: nil, displays: [replacement]) == nil)
        #expect(DisplayControlMenuPolicy.target(uuid: "removed-uuid", displays: [replacement]) == nil)
        #expect(!DisplayControlMenuPolicy.canDisable(nil, displays: [replacement]))
    }

    @Test func frozenUUIDSelectsOnlyThatDisplayEvenIfAnotherIsMain() {
        let main = physical("main", id: 7, main: true)
        let external = physical("external", id: 8, main: false)
        let displays = [main, external]
        let menuTargetUUID = "external"

        #expect(DisplayControlMenuPolicy.target(uuid: menuTargetUUID, displays: displays)?.uuid == "external")
        #expect(DisplayControlMenuPolicy.target(uuid: menuTargetUUID, displays: displays)?.uuid != "main")
    }

    @Test func menuCopyHasChineseAndEnglishLabels() {
        for key in ["displayMenuCurrentScreen", "displayMenuUnknownScreen",
                    "displayMenuDisableCurrent", "displayMenuKeepCurrent"] {
            #expect(AppText.displayControlChinese[key] != nil)
            #expect(AppText.displayControlEnglish[key] != nil)
            #expect(AppText.value(key, language: .simplifiedChinese) != key)
            #expect(AppText.value(key, language: .english) != key)
        }
    }

    @Test func releaseRowIsNestedInsideTheEnabledDisplayControlSubmenu() throws {
        guard #available(macOS 14.4, *) else { return }
        _ = NSApplication.shared
        let control = DisplayControlModel(
            showsConfirmation: false,
            prepareVisibleOutputs: { true },
            controlStateChanged: { _ in },
            terminationOwnerRegistration: { _ in }
        )
        let controller = makeController()
        defer { controller.stop() }

        let menu = NSHostingMenu(rootView: DisplayControlMenuSection(
            control: control,
            context: controller,
            isFeatureEnabled: true
        ))
        refresh(menu)

        let release = control.t("displayRestoreAll")
        #expect(!menu.items.contains { $0.title == release })
        let submenuItem = try #require(menu.items.first { $0.submenu != nil })
        #expect(submenuItem.title == control.t("displayMenuCurrentScreen"))
        let submenu = try #require(submenuItem.submenu)
        #expect(submenu.items.contains { $0.title == release })
    }

    @Test func disabledDisplayControlSectionLeavesNoMenuRowOrDivider() {
        guard #available(macOS 14.4, *) else { return }
        _ = NSApplication.shared
        let control = DisplayControlModel(
            showsConfirmation: false,
            prepareVisibleOutputs: { true },
            controlStateChanged: { _ in },
            terminationOwnerRegistration: { _ in }
        )
        let controller = makeController()
        defer { controller.stop() }

        let menu = NSHostingMenu(rootView: DisplayControlMenuSection(
            control: control,
            context: controller,
            isFeatureEnabled: false
        ))
        refresh(menu)

        #expect(menu.items.isEmpty)
    }

    private func makeController() -> MenuBarDisplayController {
        MenuBarDisplayController(
            notificationCenter: NotificationCenter(),
            screens: { [] },
            pointer: { .zero },
            menuFactory: { _ in NSMenu() }
        )
    }

    private func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items {
            if let submenu = item.submenu { refresh(submenu) }
        }
    }

    private func physical(_ uuid: String, id: UInt32, main: Bool) -> DisplayControlDisplay {
        DisplayControlDisplay(
            uuid: uuid, displayID: id, name: uuid, isBuiltIn: main, isVirtual: false,
            isOnline: true, isActive: true, isMain: main, width: 1920, height: 1080
        )
    }
}
