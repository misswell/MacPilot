import Foundation
import Testing
@testable import PilotNest

@MainActor
struct RemoteControlPreferencesTests {
    @Test func allControlsStartEnabledAndSelectionSurvivesRelaunch() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        #expect(RemoteControlFeature.allCases.allSatisfy(preferences.isEnabled))
        preferences.setEnabled(false, for: .mediaNext)
        preferences.setEnabled(false, for: .keyboard)
        let reloaded = RemoteControlPreferences(defaults: defaults)
        #expect(!reloaded.isEnabled(.mediaNext))
        #expect(!reloaded.isEnabled(.keyboard))
        #expect(reloaded.isEnabled(.mediaPrevious))
        reloaded.setEnabled(true, for: .mediaNext)
        #expect(RemoteControlPreferences(defaults: defaults).isEnabled(.mediaNext))
    }

    @Test func hidingAllHomeControlsKeepsSettingsReachable() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        for feature in RemoteControlFeature.allCases where feature != .keyboard {
            preferences.setEnabled(false, for: feature)
        }
        #expect(!preferences.hasHomeControls)
        preferences.setEnabled(true, for: .mute)
        #expect(preferences.hasHomeControls)
        #expect(!preferences.isEnabled(.volume))
    }
}
