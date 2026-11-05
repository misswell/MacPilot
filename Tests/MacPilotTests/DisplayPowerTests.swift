import Testing
@testable import MacPilot

struct DisplayPowerTests {
    @Test func turnOffScreenMenuLabelsStayLocalizedInBothLanguages() {
        #expect(AppText.value("turnOffScreenNow", language: .simplifiedChinese) == "关闭屏幕")
        #expect(AppText.value("turnOffScreenNow", language: .english) == "Turn Off Screen")
    }
}

extension DisplayPowerTests {
    @Test func anAcceptedBacklightWriteDoesNotConfirmADisplayThatRemainsLit() {
        let driver = BrightnessDriver(read: { _ in 0.75 }, write: { _, _ in true })
        let result = driver.writeAndReadBack(0, to: 1)
        #expect(result.sent)
        #expect(result.readback == 0.75)
        #expect(!result.confirms(0))
    }

    @Test func anUnreadablePanelStillRetainsTheSentWriteForRestoration() {
        let driver = BrightnessDriver(read: { _ in nil }, write: { _, _ in true })
        let result = driver.writeAndReadBack(0, to: 1)
        #expect(result.sent)
        #expect(!result.confirms(0))
    }

    @Test func aRejectedBacklightWriteCannotBeConfirmedByAPanelAlreadyAtZero() {
        let driver = BrightnessDriver(read: { _ in 0 }, write: { _, _ in false })
        let result = driver.writeAndReadBack(0, to: 1)
        #expect(!result.sent)
        #expect(!result.confirms(0))
    }

    @Test func onlyAZeroBacklightConfirmsBlanking() {
        let dark = BrightnessDriver(read: { _ in 0 }, write: { _, _ in true })
        #expect(dark.writeAndReadBack(0, to: 1).confirms(0))
        let dim = BrightnessDriver(read: { _ in 0.001 }, write: { _, _ in true })
        #expect(!dim.writeAndReadBack(0, to: 1).confirms(0))
        let invalid = BrightnessDriver(read: { _ in .nan }, write: { _, _ in true })
        #expect(!invalid.writeAndReadBack(0, to: 1).confirms(0))
    }

    @Test func unchangedAnyEventCounterDoesNotReadDetailedInputCounters() {
        var poller = DisplayInputPoller(anyEventCounter: 100, snapshot: inputSnapshot())
        var reads = 0
        let result = poller.poll(anyEventCounter: 100) {
            reads += 1
            return inputSnapshot()
        }
        #expect(result == nil)
        #expect(reads == 0)
    }

    @Test func unrelatedAnyEventChangesAreIgnoredAndRebased() {
        var poller = DisplayInputPoller(anyEventCounter: 100, snapshot: inputSnapshot())
        var next = inputSnapshot()
        #expect(poller.poll(anyEventCounter: 101) { next } == nil)
        #expect(poller.anyEventCounter == 101)
        #expect(poller.poll(anyEventCounter: 101) { Issue.record("unchanged sentinel must not read details"); return next } == nil)
        next.counters = DisplayInputCounters(keyDown: 3)
        #expect(poller.poll(anyEventCounter: 102) { next } == .keyboard)
    }

    @Test func keyboardModifierMouseButtonAndScrollCountersQualifyInput() {
        var poller = DisplayInputPoller(anyEventCounter: 10, snapshot: inputSnapshot())
        var next = inputSnapshot()
        next.counters.keyDown = 1
        #expect(poller.poll(anyEventCounter: 11) { next } == .keyboard)

        next.counters.flagsChanged = 1
        next.modifierFlags = 1 << 16 // CGEventFlags.maskAlphaShift
        #expect(poller.poll(anyEventCounter: 12) { next } == .modifier)

        next.counters.flagsChanged = 2
        #expect(poller.poll(anyEventCounter: 13) { next } == nil)

        next.counters.leftMouseDown = 1
        #expect(poller.poll(anyEventCounter: 14) { next } == .mouseButton)

        next.counters.scrollWheel = 1
        #expect(poller.poll(anyEventCounter: 15) { next } == .scroll)
    }

    @Test func pointerMovementRequiresBothCounterProgressAndChangedCursorPosition() {
        var poller = DisplayInputPoller(anyEventCounter: 10, snapshot: inputSnapshot())
        var next = inputSnapshot()
        next.counters.mouseMoved = 1
        #expect(poller.poll(anyEventCounter: 11) { next } == nil)
        next.counters.mouseMoved = 2
        next.cursor = DisplayInputCursorPosition(x: 20, y: 10)
        #expect(poller.poll(anyEventCounter: 12) { next } == .pointerMovement)
    }

    @Test func counterResetRebasesWithoutQualifyingAsInput() {
        var counters = DisplayInputCounters(keyDown: 500, scrollWheel: 500)
        var poller = DisplayInputPoller(anyEventCounter: 200, snapshot: inputSnapshot(counters: counters))
        counters.keyDown = 3
        counters.scrollWheel = 3
        let reset = inputSnapshot(counters: counters)
        #expect(poller.poll(anyEventCounter: 0) { reset } == nil)
        counters.keyDown = 4
        let subsequentKey = inputSnapshot(counters: counters)
        #expect(poller.poll(anyEventCounter: 1) { subsequentKey } == .keyboard)
    }

    @Test func counterWrapAtUInt32BoundaryQualifiesAsProgress() {
        let counters = DisplayInputCounters(keyDown: UInt32.max - 1)
        var poller = DisplayInputPoller(anyEventCounter: UInt32.max - 1, snapshot: inputSnapshot(counters: counters))
        let wrapped = inputSnapshot(counters: DisplayInputCounters(keyDown: 1))
        #expect(poller.poll(anyEventCounter: 1) { wrapped } == .keyboard)
    }

    @Test func aMissingCursorBaselineRebasesBeforeDetectingLaterMovement() {
        var poller = DisplayInputPoller(
            anyEventCounter: 20,
            snapshot: inputSnapshot(cursor: nil)
        )
        var next = inputSnapshot(cursor: DisplayInputCursorPosition(x: 10, y: 10))
        next.counters.mouseMoved = 1
        #expect(poller.poll(anyEventCounter: 21) { next } == nil)
        next.cursor = DisplayInputCursorPosition(x: 15, y: 10)
        next.counters.mouseMoved = 2
        #expect(poller.poll(anyEventCounter: 22) { next } == .pointerMovement)
    }

    private func inputSnapshot(
        counters: DisplayInputCounters = DisplayInputCounters(),
        modifierFlags: UInt64 = 0,
        cursor: DisplayInputCursorPosition? = DisplayInputCursorPosition(x: 10, y: 10)
    ) -> DisplayInputSnapshot {
        DisplayInputSnapshot(counters: counters, modifierFlags: modifierFlags, cursor: cursor)
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

// MARK: - The keyboard backlight that goes dark with the screen

extension DisplayPowerTests {
    /// A held blank has to be written down whenever *anything* it changed would be
    /// lost by a crash — not only the display backlights. The case the display-only
    /// rule missed: a MacBook blacked by the overlay keeps its panel level intact,
    /// but its keyboard is dark with its light sensor switched off, and without a
    /// snapshot the next launch has nothing left to put back.
    @Test func aKeyboardOnlyBlankStillNeedsACrashSnapshot() {
        #expect(DisplayPower.needsCrashSnapshot(
            systemBacklights: 0, ddcBacklights: 0, ddcPoweredOff: 0, keyboardBacklights: 1
        ))
        // Every display route that records a level still does.
        #expect(DisplayPower.needsCrashSnapshot(
            systemBacklights: 1, ddcBacklights: 0, ddcPoweredOff: 0, keyboardBacklights: 0
        ))
        #expect(DisplayPower.needsCrashSnapshot(
            systemBacklights: 0, ddcBacklights: 1, ddcPoweredOff: 0, keyboardBacklights: 0
        ))
        #expect(DisplayPower.needsCrashSnapshot(
            systemBacklights: 0, ddcBacklights: 0, ddcPoweredOff: 1, keyboardBacklights: 0
        ))
        // A cover over a display with no keyboard to darken loses nothing.
        #expect(!DisplayPower.needsCrashSnapshot(
            systemBacklights: 0, ddcBacklights: 0, ddcPoweredOff: 0, keyboardBacklights: 0
        ))
    }
}
