import Foundation
import Testing
@testable import MacPilot

/// 首页开关是功能唯一的开关，详情页不再保留自己的总开关。
/// 这里守住启动时的校正：历史配置里功能级开关可能是关闭的，
/// 必须跟着首页开关打开，否则会出现「首页开着、功能却没启动」。
@MainActor
struct HomeSwitchAlignmentTests {
    private func configuration(_ json: String) throws -> MacPilotModel.StoredConfiguration {
        try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data(json.utf8))
    }

    @Test func homeSwitchesReopenFeatureSwitchesLeftOffInLegacyConfigs() throws {
        let legacy = try configuration(
            """
            {
              "version": 24,
              "enabledFeatures": ["awake", "capture"],
              "awake": { "isEnabled": false },
              "screenCapture": { "isEnabled": false, "screenshotEnabled": false }
            }
            """
        )

        let aligned = legacy.aligningHomeControlledSwitches()

        #expect(aligned.awake.isEnabled)
        #expect(aligned.screenCapture.screenshotEnabled)
    }

    @Test func captureHomeSwitchDoesNotTouchTheScheduleSubSwitch() throws {
        let legacy = try configuration(
            """
            {
              "version": 24,
              "enabledFeatures": ["capture"],
              "screenCapture": { "isEnabled": false, "screenshotEnabled": false }
            }
            """
        )

        let aligned = legacy.aligningHomeControlledSwitches()

        // 「启用定时截屏」是页内子开关，首页开关不替用户打开它。
        #expect(aligned.screenCapture.isEnabled == false)
    }

    @Test func disabledHomeSwitchesLeaveFeatureSwitchesUntouched() throws {
        let legacy = try configuration(
            """
            {
              "version": 24,
              "enabledFeatures": [],
              "awake": { "isEnabled": true }
            }
            """
        )

        let aligned = legacy.aligningHomeControlledSwitches()

        #expect(aligned.awake.isEnabled)
    }
}
