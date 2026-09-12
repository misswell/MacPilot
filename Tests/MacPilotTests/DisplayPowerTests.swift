import Testing
@testable import MacPilot

struct DisplayPowerTests {
    @Test func turnOffScreenMenuLabelsStayLocalizedInBothLanguages() {
        #expect(AppText.value("turnOffScreenNow", language: .simplifiedChinese) == "关闭屏幕")
        #expect(AppText.value("turnOffScreenNow", language: .english) == "Turn Off Screen")
    }
}

extension DisplayPowerTests {
    /// The rule that brings the backlight back after MacPilot blanks the screen.
    /// Idle time only ever grows while nobody touches anything, so a reading
    /// smaller than the one taken at blank time can only mean fresh input — and
    /// getting this comparison backwards would leave a user staring at a black
    /// screen with no way back except the brightness keys.
    @Test func inputIsDetectedOnlyWhenTheIdleClockGoesBackwards() {
        #expect(DisplayPower.didUserInputOccur(idleNow: 0.1, idleAtBlank: 5) == true)
        #expect(DisplayPower.didUserInputOccur(idleNow: 5.4, idleAtBlank: 5) == false)
        #expect(DisplayPower.didUserInputOccur(idleNow: 5, idleAtBlank: 5) == false)
        #expect(DisplayPower.didUserInputOccur(idleNow: 900, idleAtBlank: 0.2) == false)
    }
}

// MARK: - Blank plan

extension DisplayPowerTests {
    private func candidate(
        _ displayID: UInt32,
        builtIn: Bool = false,
        backlight: Bool = true
    ) -> ScreenBlankCandidate {
        ScreenBlankCandidate(displayID: displayID, isBuiltIn: builtIn, canDriveBacklight: backlight)
    }

    /// The regression this plan exists for: with an external monitor as the main
    /// display the built-in panel is still online, but the backlight probe only
    /// answers for one of them. Picking the wrong one used to leave the caller
    /// with no way to black the screen except a real display sleep — which locks
    /// the session on any Mac that asks for a password when the display turns
    /// off.
    @Test func everyOnlineDisplayIsBlackedExactlyOnce() {
        let steps = ScreenBlankPlanner.steps(for: [
            candidate(1, builtIn: true, backlight: true),
            candidate(2, backlight: false),
        ])
        #expect(steps.count == 2)
        #expect(Set(steps.map(\.displayID)) == [1, 2])
    }

    @Test func aDisplayWithoutABacklightIsCoveredByTheOverlayInsteadOfBeingSlept() {
        let steps = ScreenBlankPlanner.steps(for: [
            candidate(7, builtIn: true, backlight: false),
        ])
        #expect(steps == [ScreenBlankPlanner.Step(displayID: 7, action: .overlay)])
    }

    @Test func backlightCapableDisplaysComeFirstAndKeepTheBacklightAction() {
        let steps = ScreenBlankPlanner.steps(for: [
            candidate(2, backlight: false),
            candidate(3, backlight: true),
            candidate(1, builtIn: true, backlight: true),
        ])
        #expect(steps == [
            ScreenBlankPlanner.Step(displayID: 1, action: .backlight),
            ScreenBlankPlanner.Step(displayID: 3, action: .backlight),
            ScreenBlankPlanner.Step(displayID: 2, action: .overlay),
        ])
    }

    @Test func noOnlineDisplayMeansThereIsNothingToBlank() {
        #expect(ScreenBlankPlanner.steps(for: []).isEmpty)
    }
}

// MARK: - Brightness target

extension DisplayPowerTests {
    /// The brightness slider drives exactly one panel, and it has to be the one
    /// whose backlight can actually be driven: with an external monitor as the
    /// main display, keying off `CGMainDisplayID()` would address a panel that
    /// has no controllable backlight.
    @Test func theBuiltInPanelWinsTheBrightnessSlider() {
        #expect(DisplayPower.brightnessTarget(in: [
            ScreenBlankCandidate(displayID: 2, isBuiltIn: false, canDriveBacklight: true),
            ScreenBlankCandidate(displayID: 1, isBuiltIn: true, canDriveBacklight: true),
        ]) == 1)
    }

    @Test func aDrivableExternalDisplayIsUsedWhenTheBuiltInPanelCannotBeDriven() {
        #expect(DisplayPower.brightnessTarget(in: [
            ScreenBlankCandidate(displayID: 1, isBuiltIn: true, canDriveBacklight: false),
            ScreenBlankCandidate(displayID: 3, isBuiltIn: false, canDriveBacklight: true),
        ]) == 3)
    }

    @Test func noDrivableDisplayMeansThereIsNoBrightnessToControl() {
        #expect(DisplayPower.brightnessTarget(in: [
            ScreenBlankCandidate(displayID: 1, isBuiltIn: true, canDriveBacklight: false),
            ScreenBlankCandidate(displayID: 2, isBuiltIn: false, canDriveBacklight: false),
        ]) == nil)
        #expect(DisplayPower.brightnessTarget(in: []) == nil)
    }
}
