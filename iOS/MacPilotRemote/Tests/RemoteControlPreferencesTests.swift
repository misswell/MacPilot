import Foundation
import Testing
@testable import PilotNest

@MainActor
struct RemoteControlPreferencesTests {
    private func withPreferences(_ body: (RemoteControlPreferences, UserDefaults) throws -> Void) throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(RemoteControlPreferences(defaults: defaults), defaults)
    }

    @Test func visibilitySurvivesRelaunchAndHiddenControlsKeepTheirPositions() throws {
        try withPreferences { preferences, defaults in
            #expect(RemoteControlFeature.allCases.allSatisfy(preferences.isEnabled))
            preferences.setEnabled(false, for: .mediaPrevious)
            preferences.setEnabled(false, for: .keyboard)
            preferences.moveFeatures(in: .media, fromOffsets: IndexSet(integer: 2), toOffset: 0)
            let reloaded = RemoteControlPreferences(defaults: defaults)
            #expect(!reloaded.isEnabled(.keyboard))
            #expect(reloaded.features(in: .media) == [.mediaNext, .mediaPrevious, .mediaPlayPause])
            #expect(reloaded.homeSections[2] == [.mediaNext, .mediaPlayPause])
            reloaded.setEnabled(true, for: .mediaPrevious)
            #expect(reloaded.homeSections[2] == [.mediaNext, .mediaPrevious, .mediaPlayPause])
        }
    }

    @Test func hidingAllHomeControlsKeepsSettingsReachable() throws {
        try withPreferences { preferences, _ in
            for feature in RemoteControlFeature.allCases where feature != .keyboard {
                preferences.setEnabled(false, for: feature)
            }
            #expect(!preferences.hasHomeControls)
            #expect(preferences.homeSections.isEmpty)
            preferences.setEnabled(true, for: .mute)
            #expect(preferences.hasHomeControls)
            #expect(preferences.homeSections == [[.mute]])
        }
    }

    @Test func defaultOrderRetainsTheFourSections() throws {
        try withPreferences { preferences, _ in
            #expect(preferences.orderedGroups == RemoteControlFeature.Group.allCases)
            #expect(preferences.homeSections == [
                [.desktop, .trackpad], [.displayOff, .wakeDisplay, .lockScreen, .wakeAndUnlock],
                [.mediaPrevious, .mediaPlayPause, .mediaNext], [.brightness, .volume, .mute]
            ])
        }
    }

    @Test func sectionMovesPersistWithoutChangingOrderWithinSections() throws {
        try withPreferences { preferences, defaults in
            preferences.moveGroups(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            let reloaded = RemoteControlPreferences(defaults: defaults)
            #expect(reloaded.orderedGroups == [.media, .input, .screen, .levels])
            #expect(reloaded.homeSections.first == [.mediaPrevious, .mediaPlayPause, .mediaNext])
            reloaded.moveFeatures(in: .screen, fromOffsets: IndexSet(integer: 0), toOffset: 4)
            #expect(reloaded.orderedGroups == [.media, .input, .screen, .levels])
            #expect(reloaded.features(in: .input) == [.desktop, .trackpad, .keyboard])
        }
    }

    @Test func malformedOrdersNormalizeAndFutureKeysSurviveSaves() throws {
        try withPreferences { _, defaults in
            defaults.set(["volume", "futureControl", "volume", "desktop"], forKey: "remoteControl.featureOrder")
            defaults.set(["media", "futureGroup", "media"], forKey: "remoteControl.groupOrder")
            defaults.set(["futureHidden"], forKey: "remoteControl.hiddenFeatures")
            let preferences = RemoteControlPreferences(defaults: defaults)
            #expect(Set(preferences.orderedFeatures) == Set(RemoteControlFeature.allCases))
            #expect(preferences.orderedFeatures.count == RemoteControlFeature.allCases.count)
            #expect(preferences.orderedGroups == [.media, .input, .screen, .levels])
            preferences.moveFeatures(in: .input, fromOffsets: IndexSet(integer: 0), toOffset: 2)
            preferences.moveGroups(fromOffsets: IndexSet(integer: 0), toOffset: 4)
            preferences.setEnabled(false, for: .mute)
            #expect(defaults.stringArray(forKey: "remoteControl.featureOrder")?.contains("futureControl") == true)
            #expect(defaults.stringArray(forKey: "remoteControl.groupOrder")?.contains("futureGroup") == true)
            #expect(defaults.stringArray(forKey: "remoteControl.hiddenFeatures")?.contains("futureHidden") == true)
        }
    }

    @Test func legacyMixedOrderMigratesToWholeSections() throws {
        try withPreferences { _, defaults in
            defaults.set(["mediaNext", "volume", "desktop", "mediaPrevious", "mute", "brightness"],
                         forKey: "remoteControl.featureOrder")
            let preferences = RemoteControlPreferences(defaults: defaults)
            #expect(preferences.orderedGroups == [.media, .levels, .input, .screen])
            #expect(preferences.features(in: .media) == [.mediaNext, .mediaPrevious, .mediaPlayPause])
            #expect(preferences.features(in: .levels) == [.volume, .brightness, .mute])
            #expect(preferences.homeSections.count == 4)
            preferences.moveFeatures(in: .input, fromOffsets: IndexSet(integer: 0), toOffset: 2)
            #expect(RemoteControlPreferences(defaults: defaults).orderedGroups == [.media, .levels, .input, .screen])
        }
    }

    @Test func nativeListMovesAndInvalidMovesRespectSectionBoundaries() throws {
        try withPreferences { preferences, defaults in
            for offsets in [IndexSet(), IndexSet(integer: 100)] {
                preferences.moveFeatures(in: .input, fromOffsets: offsets, toOffset: 0)
                preferences.moveGroups(fromOffsets: offsets, toOffset: 0)
            }
            for destination in [-1, 100] {
                preferences.moveFeatures(in: .input, fromOffsets: IndexSet(integer: 0), toOffset: destination)
                preferences.moveGroups(fromOffsets: IndexSet(integer: 0), toOffset: destination)
            }
            #expect(defaults.object(forKey: "remoteControl.featureOrder") == nil)
            #expect(defaults.object(forKey: "remoteControl.groupOrder") == nil)
            preferences.moveFeatures(in: .screen, fromOffsets: IndexSet([0, 2]), toOffset: 4)
            #expect(preferences.features(in: .screen) == [.wakeDisplay, .wakeAndUnlock, .displayOff, .lockScreen])
            preferences.moveFeatures(in: .screen, fromOffsets: IndexSet([2, 3]), toOffset: 0)
            #expect(preferences.features(in: .screen) == [.displayOff, .lockScreen, .wakeDisplay, .wakeAndUnlock])
        }
    }

    @Test func muteStaysAttachedToVolumeAndCannotMoveIndependently() throws {
        try withPreferences { preferences, _ in
            preferences.moveFeatures(in: .levels, fromOffsets: IndexSet(integer: 2), toOffset: 0)
            #expect(preferences.features(in: .levels) == [.brightness, .volume, .mute])
            preferences.moveFeatures(in: .levels, fromOffsets: IndexSet(integer: 1), toOffset: 0)
            #expect(preferences.features(in: .levels) == [.volume, .brightness, .mute])
            preferences.setEnabled(false, for: .volume)
            #expect(preferences.homeSections.last == [.brightness, .mute])
            #expect(!preferences.homeSections.flatMap { $0 }.contains(.keyboard))
        }
    }
}
