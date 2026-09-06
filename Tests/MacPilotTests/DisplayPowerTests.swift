import Testing
@testable import MacPilot

struct DisplayPowerTests {
    @Test func turnOffScreenMenuLabelsStayLocalizedInBothLanguages() {
        #expect(AppText.value("turnOffScreenNow", language: .simplifiedChinese) == "关闭屏幕")
        #expect(AppText.value("turnOffScreenNow", language: .english) == "Turn Off Screen")
    }
}
