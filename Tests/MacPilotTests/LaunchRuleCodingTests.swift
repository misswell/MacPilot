import Foundation
import Testing
@testable import MacPilot

struct LaunchRuleCodingTests {
    @Test func closeWindowsModeUsesBehaviorBasedName() {
        #expect(AppText.value("launchModeCloseWindows", language: .simplifiedChinese) == "关闭窗口，保留后台")
        #expect(AppText.value("launchModeCloseWindows", language: .english) == "Close windows, keep running")
    }

    @Test func formatsLocalizedAppVersion() {
        let info = AppVersionInfo(version: "1.2.3", build: "45")

        #expect(info.localizedDescription(language: .simplifiedChinese) == "版本 1.2.3（构建 45）")
        #expect(info.localizedDescription(language: .english) == "Version 1.2.3 (Build 45)")
    }

    @Test func accessibilityResetUsesCurrentBundleIdentifier() {
        let command = AccessibilityResetCommand(bundleIdentifier: "com.misswell.macpilot")

        #expect(command.executableURL == URL(fileURLWithPath: "/usr/bin/tccutil"))
        #expect(command.arguments == ["reset", "Accessibility", "com.misswell.macpilot"])
    }

    @Test func legacyAccessibilityRecoveryRequestIsClearedWithoutRescheduling() throws {
        let suiteName = "MacPilotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "MacPilot.requestAccessibilityAfterReset")

        #expect(AccessibilityRecoveryRequest.consume(from: defaults, legacyDefaults: nil))
        #expect(!AccessibilityRecoveryRequest.consume(from: defaults, legacyDefaults: nil))
    }

    @Test func onlyCloseWindowsModeRequiresAccessibility() {
        #expect(!LaunchVisibilityMode.foreground.requiresAccessibility)
        #expect(!LaunchVisibilityMode.hidden.requiresAccessibility)
        #expect(LaunchVisibilityMode.closeWindows.requiresAccessibility)
    }

    @Test func migratesLegacyForegroundMode() throws {
        let rule = try decodeLegacy(activateOnLaunch: true)
        #expect(rule.visibilityMode == .foreground)
    }

    @Test func migratesLegacyHiddenMode() throws {
        let rule = try decodeLegacy(activateOnLaunch: false)
        #expect(rule.visibilityMode == .hidden)
    }

    @Test func roundTripsCloseWindowsMode() throws {
        let rule = LaunchRule(
            appName: "Example",
            bundleIdentifier: "com.example.app",
            bundlePath: "/Applications/Example.app",
            visibilityMode: .closeWindows
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(LaunchRule.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded.visibilityMode == .closeWindows)
        #expect(object["visibilityMode"] as? String == "closeWindows")
        #expect(object["activateOnLaunch"] as? Bool == false)
    }

    private func decodeLegacy(activateOnLaunch: Bool) throws -> LaunchRule {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "appName": "Example",
          "bundleIdentifier": "com.example.app",
          "bundlePath": "/Applications/Example.app",
          "delaySeconds": 30,
          "isEnabled": true,
          "activateOnLaunch": \(activateOnLaunch)
        }
        """
        return try JSONDecoder().decode(LaunchRule.self, from: Data(json.utf8))
    }
}
