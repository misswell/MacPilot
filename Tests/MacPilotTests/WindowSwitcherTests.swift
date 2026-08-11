import Foundation
import Testing
@testable import MacPilot

struct WindowSwitcherTests {
    @Test func initialSelectionMovesPastTheFrontmostWindow() {
        #expect(WindowSwitcherSelection.initialIndex(count: 4, currentIndex: 0, reverse: false) == 1)
        #expect(WindowSwitcherSelection.initialIndex(count: 4, currentIndex: 0, reverse: true) == 3)
    }

    @Test func initialSelectionFallsBackToTheFirstWindowWhenThereIsNoFrontmostWindow() {
        #expect(WindowSwitcherSelection.initialIndex(count: 3, currentIndex: nil, reverse: false) == 0)
        #expect(WindowSwitcherSelection.initialIndex(count: 3, currentIndex: nil, reverse: true) == 2)
        #expect(WindowSwitcherSelection.initialIndex(count: 0, currentIndex: nil, reverse: false) == nil)
    }

    @Test func cyclingWrapsInBothDirections() {
        #expect(WindowSwitcherSelection.cycledIndex(current: 3, count: 4, offset: 1) == 0)
        #expect(WindowSwitcherSelection.cycledIndex(current: 0, count: 4, offset: -1) == 3)
        #expect(WindowSwitcherSelection.cycledIndex(current: 1, count: 0, offset: 1) == nil)
    }

    @Test func cachedWindowsAreReorderedWithoutRediscovery() {
        let processIDs: [pid_t] = [11, 11, 22, 33, 33]

        #expect(WindowSwitcherOrdering.orderedIndices(
            processIDs: processIDs,
            frontmostProcessID: 33,
            recentProcessIDs: [22, 11]
        ) == [3, 4, 2, 0, 1])
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
    }

    @Test func settingsRoundTripThroughCodable() throws {
        var settings = WindowSwitcherSettings()
        settings.isEnabled = false
        settings.includeMinimizedWindows = false
        settings.includeHiddenApplications = true
        settings.showThumbnails = false
        settings.showWindowTitles = false

        let decoded = try JSONDecoder().decode(
            WindowSwitcherSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }
}
