import MacPilotDisplayControlCore
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

    private func physical(_ uuid: String, id: UInt32, main: Bool) -> DisplayControlDisplay {
        DisplayControlDisplay(
            uuid: uuid, displayID: id, name: uuid, isBuiltIn: main, isVirtual: false,
            isOnline: true, isActive: true, isMain: main, width: 1920, height: 1080
        )
    }
}
