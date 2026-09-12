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
