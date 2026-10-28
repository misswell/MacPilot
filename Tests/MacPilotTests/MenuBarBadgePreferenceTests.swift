import Foundation
import Testing
@testable import MacPilot

/// The CPU percentage beside the status icon is an interface preference, not a
/// feature of the CPU monitor: turning it off must leave the monitor running,
/// and an install that predates the switch keeps the badge.
struct MenuBarBadgePreferenceTests {
    @Test func theCPUPercentBadgeIsOnUntilTheUserTurnsItOff() {
        let name = "MenuBarBadgePreferenceTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(MenuBarBadgePreference.showsCPUPercent(in: defaults))
        MenuBarBadgePreference.setShowsCPUPercent(false, in: defaults)
        #expect(!MenuBarBadgePreference.showsCPUPercent(in: defaults))
        MenuBarBadgePreference.setShowsCPUPercent(true, in: defaults)
        #expect(MenuBarBadgePreference.showsCPUPercent(in: defaults))
    }

    @Test func thePreferenceIsPerUserDefaultsDomain() {
        let firstName = "MenuBarBadgePreferenceTests-" + UUID().uuidString
        let secondName = "MenuBarBadgePreferenceTests-" + UUID().uuidString
        let first = UserDefaults(suiteName: firstName)!
        let second = UserDefaults(suiteName: secondName)!
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        MenuBarBadgePreference.setShowsCPUPercent(false, in: first)
        #expect(MenuBarBadgePreference.showsCPUPercent(in: second))
    }

    @Test @MainActor func theBadgeOnlyAppearsWhenBothTheFeatureAndThePreferenceAllowIt() {
        #expect(MenuBarCPUPercent.title(cpuMonitorEnabled: true, preferenceEnabled: true,
                                       totalPercent: 6.4) == "6.4%")

        // Turning off the CPU monitor still removes the badge.
        #expect(MenuBarCPUPercent.title(cpuMonitorEnabled: false, preferenceEnabled: true,
                                       totalPercent: 6.4) == nil)

        // And so does hiding the number while keeping the monitor on.
        #expect(MenuBarCPUPercent.title(cpuMonitorEnabled: true, preferenceEnabled: false,
                                       totalPercent: 6.4) == nil)

        // No sample yet: never invent a zero.
        #expect(MenuBarCPUPercent.title(cpuMonitorEnabled: true, preferenceEnabled: true,
                                       totalPercent: nil) == nil)
    }

    @Test @MainActor func theNewSwitchIsTranslatedInBothLanguages() {
        for key in ["showCPUPercentInMenuBar", "showCPUPercentInMenuBarHint"] {
            let chinese = AppText.value(key, language: .simplifiedChinese)
            let english = AppText.value(key, language: .english)
            #expect(chinese != key, "\(key) 缺少中文文案")
            #expect(english != key, "\(key) is missing English copy")
            #expect(chinese != english)
        }
    }
}
