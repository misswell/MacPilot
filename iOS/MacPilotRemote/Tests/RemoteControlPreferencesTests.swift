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

    @Test func defaultOrderMatchesTheExistingControls() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        #expect(preferences.orderedFeatures == RemoteControlFeature.allCases)
        #expect(preferences.homeSections.flatMap { $0 }
                == RemoteControlFeature.allCases.filter { $0 != .keyboard })
    }

    @Test func movingAcrossCategoriesPersistsWithoutChangingVisibility() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        preferences.setEnabled(false, for: .mediaPrevious)
        let index = try #require(preferences.orderedFeatures.firstIndex(of: .mediaNext))
        preferences.moveFeatures(fromOffsets: IndexSet(integer: index), toOffset: 0)
        let reloaded = RemoteControlPreferences(defaults: defaults)
        #expect(reloaded.orderedFeatures.first == .mediaNext)
        #expect(!reloaded.isEnabled(.mediaPrevious))
        #expect(reloaded.orderedFeatures.contains(.mediaPrevious))
        #expect(reloaded.homeSections.first == [.mediaNext])
        #expect(reloaded.homeSections.flatMap { $0 }
                == reloaded.orderedFeatures.filter { $0 != .keyboard && reloaded.isEnabled($0) })
        reloaded.setEnabled(true, for: .mediaPrevious)
        #expect(reloaded.orderedFeatures == preferences.orderedFeatures)
    }

    @Test func malformedOrderKeepsEveryKnownControlOnceAndPreservesFutureKeys() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["volume", "futureControl", "volume", "desktop"], forKey: "remoteControl.featureOrder")
        defaults.set(["futureHidden"], forKey: "remoteControl.hiddenFeatures")
        let preferences = RemoteControlPreferences(defaults: defaults)
        #expect(Array(preferences.orderedFeatures.prefix(2)) == [.volume, .desktop])
        #expect(preferences.orderedFeatures.count == RemoteControlFeature.allCases.count)
        #expect(Set(preferences.orderedFeatures) == Set(RemoteControlFeature.allCases))
        preferences.moveFeatures(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(defaults.stringArray(forKey: "remoteControl.featureOrder")?.contains("futureControl") == true)
        preferences.setEnabled(false, for: .mute)
        #expect(defaults.stringArray(forKey: "remoteControl.hiddenFeatures")?.contains("futureHidden") == true)
    }

    @Test func multiRowMovesUseListDestinationSemanticsInBothDirections() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        let original = preferences.orderedFeatures
        preferences.moveFeatures(fromOffsets: IndexSet([0, 2]), toOffset: original.count)
        #expect(Array(preferences.orderedFeatures.suffix(2)) == [.desktop, .keyboard])
        preferences.moveFeatures(fromOffsets: IndexSet([original.count - 2, original.count - 1]), toOffset: 0)
        #expect(Array(preferences.orderedFeatures.prefix(3)) == [.desktop, .keyboard, .trackpad])
        let reordered = preferences.orderedFeatures
        preferences.moveFeatures(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(preferences.orderedFeatures == reordered)
    }

    @Test func invalidMovesDoNotChangeTheStoredOrder() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        preferences.moveFeatures(fromOffsets: IndexSet(), toOffset: 0)
        preferences.moveFeatures(fromOffsets: IndexSet(integer: 100), toOffset: 0)
        preferences.moveFeatures(fromOffsets: IndexSet(integer: 0), toOffset: -1)
        preferences.moveFeatures(fromOffsets: IndexSet(integer: 0), toOffset: 100)
        #expect(preferences.orderedFeatures == RemoteControlFeature.allCases)
        #expect(defaults.object(forKey: "remoteControl.featureOrder") == nil)
    }

    @Test func muteCanMoveIndependentlyOfVolumeAndHiddenKeyboardDoesNotSplitCards() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteControlPreferences(defaults: defaults)
        let muteIndex = try #require(preferences.orderedFeatures.firstIndex(of: .mute))
        preferences.moveFeatures(fromOffsets: IndexSet(integer: muteIndex), toOffset: 0)
        preferences.setEnabled(false, for: .volume)
        #expect(preferences.homeSections.first == [.mute])
        #expect(preferences.homeSections.contains([.desktop, .trackpad]))
        #expect(!preferences.homeSections.flatMap { $0 }.contains(.volume))
        #expect(!preferences.homeSections.flatMap { $0 }.contains(.keyboard))
    }
}
