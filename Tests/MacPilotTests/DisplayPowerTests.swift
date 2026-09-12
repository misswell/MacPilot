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
        backlight: Bool = true,
        ddc: Bool = false
    ) -> ScreenBlankCandidate {
        ScreenBlankCandidate(
            displayID: displayID,
            isBuiltIn: builtIn,
            canDriveBacklight: backlight,
            canDriveDDC: ddc
        )
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

extension DisplayPowerTests {
    /// An external monitor has no `DisplayServices` backlight but does answer
    /// DDC/CI, and that is a real backlight rather than a black cover: the panel
    /// goes dark, so nothing is left glowing behind the pointer.
    @Test func anExternalDisplayThatSpeaksDDCIsDippedRatherThanCovered() {
        #expect(ScreenBlankPlanner.steps(for: [
            candidate(2, backlight: false, ddc: true),
        ]) == [
            ScreenBlankPlanner.Step(displayID: 2, action: .ddcBacklight),
        ])
    }

    /// A display that answers nothing still has to go black, and a cover is all
    /// that is left short of a display sleep that would lock the session.
    @Test func aDisplayThatAnswersNothingIsCovered() {
        #expect(ScreenBlankPlanner.steps(for: [
            candidate(2, backlight: false, ddc: false),
        ]) == [
            ScreenBlankPlanner.Step(displayID: 2, action: .overlay),
        ])
    }

    /// Ordering matters because the covers go up last: a display MacPilot can
    /// genuinely darken should never be waiting behind one it can only cover.
    @Test func realBacklightsAreHandledBeforeCovers() {
        #expect(ScreenBlankPlanner.steps(for: [
            candidate(4, backlight: false, ddc: false),
            candidate(3, backlight: false, ddc: true),
            candidate(1, builtIn: true, backlight: true),
        ]) == [
            ScreenBlankPlanner.Step(displayID: 1, action: .backlight),
            ScreenBlankPlanner.Step(displayID: 3, action: .ddcBacklight),
            ScreenBlankPlanner.Step(displayID: 4, action: .overlay),
        ])
    }

    /// The slider follows the same preference: the built-in panel first, then a
    /// system backlight, and an external monitor's DDC channel as the last thing
    /// that is still a backlight. Without this an external-only Mac (a MacBook in
    /// clamshell mode) reports no brightness at all and the phone hides the row.
    @Test func theBrightnessSliderFallsBackToADisplayThatSpeaksDDC() {
        #expect(DisplayPower.brightnessTarget(in: [
            candidate(1, builtIn: true, backlight: false, ddc: false),
            candidate(2, backlight: false, ddc: true),
        ]) == 2)
        // The built-in panel still wins when it can be driven.
        #expect(DisplayPower.brightnessTarget(in: [
            candidate(1, builtIn: true, backlight: true, ddc: false),
            candidate(2, backlight: false, ddc: true),
        ]) == 1)
        // A cover-only display offers no backlight to move.
        #expect(DisplayPower.brightnessTarget(in: [
            candidate(2, backlight: false, ddc: false),
        ]) == nil)
    }
}
