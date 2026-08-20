import Foundation
import Testing
@testable import MacPilot

struct WindowSwitcherTests {
    @Test func initialSelectionMovesPastTheFrontmostWindow() {
        #expect(WindowSwitcherSelection.initialIndex(count: 4, currentIndex: 0, reverse: false) == 1)
        #expect(WindowSwitcherSelection.initialIndex(count: 4, currentIndex: 0, reverse: true) == 3)
    }

    @Test func initialSelectionHasNoSelectionWhenThereIsNoFrontmostWindow() {
        #expect(WindowSwitcherSelection.initialIndex(count: 3, currentIndex: nil, reverse: false) == nil)
        #expect(WindowSwitcherSelection.initialIndex(count: 3, currentIndex: nil, reverse: true) == nil)
        #expect(WindowSwitcherSelection.initialIndex(count: 0, currentIndex: nil, reverse: false) == nil)
    }

    @Test func cyclingWrapsInBothDirections() {
        #expect(WindowSwitcherSelection.cycledIndex(current: 3, count: 4, offset: 1) == 0)
        #expect(WindowSwitcherSelection.cycledIndex(current: 0, count: 4, offset: -1) == 3)
        #expect(WindowSwitcherSelection.cycledIndex(current: 1, count: 0, offset: 1) == nil)
    }

    @Test func cachedWindowsAreReorderedWithoutRediscovery() {
        let ids = ["window-11", "window-11", "window-22", "window-33", "window-33"]

        #expect(WindowSwitcherOrdering.orderedIndices(
            ids: ids,
            recentIDs: ["window-22", "window-11"]
        ) == [2, 0, 1, 3, 4])
    }

    @Test func newlyOpenedWindowsSortBeforeNeverActivatedOnes() {
        // w3 was just opened and promoted to the front of recentIDs, so it sorts
        // first; w2 was never activated and goes to the end.
        let ids = ["w1", "w2", "w3"]
        #expect(WindowSwitcherOrdering.orderedIndices(ids: ids, recentIDs: ["w3", "w1"]) == [2, 0, 1])
    }

    @Test func thumbnailWorkStartsAtTheSelectionAndFansOut() {
        #expect(WindowSwitcherThumbnailPriority.orderedIndices(count: 5, selectedIndex: 2) == [2, 3, 1, 4, 0])
        #expect(WindowSwitcherThumbnailPriority.orderedIndices(count: 0, selectedIndex: 0).isEmpty)
    }

    @Test func settingsDecodeMissingFieldsWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(
            WindowSwitcherSettings.self,
            from: Data(#"{"isEnabled":false}"#.utf8)
        )

        #expect(!settings.isEnabled)
        #expect(settings.includeMinimizedWindows)
        #expect(!settings.includeHiddenApplications)
        #expect(settings.showThumbnails)
        #expect(settings.showWindowTitles)
        #expect(settings.autoMergeApplicationWindows)
    }

    @Test func settingsRoundTripThroughCodable() throws {
        var settings = WindowSwitcherSettings()
        settings.isEnabled = false
        settings.includeMinimizedWindows = false
        settings.includeHiddenApplications = true
        settings.showThumbnails = false
        settings.showWindowTitles = false
        settings.mergeApplicationBundleIdentifiers = ["com.apple.Safari", "com.apple.finder"]
        settings.autoMergeApplicationWindows = false

        let decoded = try JSONDecoder().decode(
            WindowSwitcherSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }

    @Test func mergedApplicationsHideMinimizedWindowsEvenWhenTheyAreNormallyIncluded() {
        var settings = WindowSwitcherSettings()
        settings.mergeApplicationBundleIdentifiers = ["com.cmuxterm.app"]

        #expect(WindowSwitcherWindowInclusion.shouldInclude(
            isMinimized: false,
            applicationBundleIdentifier: "com.cmuxterm.app",
            settings: settings
        ))
        #expect(!WindowSwitcherWindowInclusion.shouldInclude(
            isMinimized: true,
            applicationBundleIdentifier: "com.cmuxterm.app",
            settings: settings
        ))
        #expect(WindowSwitcherWindowInclusion.shouldInclude(
            isMinimized: true,
            applicationBundleIdentifier: "com.apple.Terminal",
            settings: settings
        ))
    }

    @Test func mergeCommandMatchesKnownLocalizedTitles() {
        #expect(WindowMerger.isMergeCommand("Merge All Windows"))
        #expect(WindowMerger.isMergeCommand("Merge Windows"))
        #expect(WindowMerger.isMergeCommand("合并所有窗口"))
        #expect(WindowMerger.isMergeCommand("合并窗口"))
        #expect(!WindowMerger.isMergeCommand("Close All Windows"))
        #expect(!WindowMerger.isMergeCommand("Move Window to Left Side of Screen"))
        #expect(!WindowMerger.isMergeCommand("Bring All to Front"))
        #expect(!WindowMerger.isMergeCommand("最小化窗口"))
    }

    @Test func mergeApplicationListSurvivesMissingKeyDecode() throws {
        let settings = try JSONDecoder().decode(
            WindowSwitcherSettings.self,
            from: Data(#"{"isEnabled":false}"#.utf8)
        )
        #expect(settings.mergeApplicationBundleIdentifiers.isEmpty)
    }
}
