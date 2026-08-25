import Foundation
import Testing
@testable import MacPilot

private final class WindowSwitcherThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false

    func record() {
        lock.lock()
        observedMainThread = Thread.isMainThread
        lock.unlock()
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMainThread
    }
}

struct WindowSwitcherTests {
    @Test func externalWindowFocusRunsOffMainActor() async {
        let probe = WindowSwitcherThreadProbe()
        let operation = WindowSwitcherFocusExecutionPolicy.schedule(
            targetProcessID: 100,
            ownProcessID: 200
        ) {
            probe.record()
        }

        await operation.value

        #expect(!probe.ranOnMainThread)
    }

    @Test func ownWindowFocusRunsOnMainActor() async {
        let probe = WindowSwitcherThreadProbe()
        let operation = WindowSwitcherFocusExecutionPolicy.schedule(
            targetProcessID: 100,
            ownProcessID: 100
        ) {
            probe.record()
        }
        await operation.value

        #expect(probe.ranOnMainThread)
    }

    @Test func externalApplicationActivationRunsOffMainActor() async {
        let probe = WindowSwitcherThreadProbe()
        let operation = WindowSwitcherApplicationActivationPolicy.schedule(
            targetProcessID: 100,
            ownProcessID: 200
        ) {
            probe.record()
        }

        await operation.value

        #expect(!probe.ranOnMainThread)
    }

    @Test func ordinaryKeyboardEventsBypassWindowSwitcherRouting() {
        #expect(!WindowSwitcherEventTapRouting.shouldInspect(type: .keyDown, keyCode: 0))
        #expect(!WindowSwitcherEventTapRouting.shouldInspect(type: .keyUp, keyCode: 0))
        #expect(WindowSwitcherEventTapRouting.shouldInspect(type: .keyDown, keyCode: 48))
        #expect(WindowSwitcherEventTapRouting.shouldInspect(type: .keyUp, keyCode: 53))
        #expect(WindowSwitcherEventTapRouting.shouldInspect(type: .flagsChanged, keyCode: 0))
    }

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

    @Test func thumbnailCacheRetainsOnlyWindowsInTheCurrentSnapshot() {
        #expect(WindowSwitcherThumbnailCachePolicy.retainedIDs(
            currentIDs: ["window-current", "window-new"],
            cachedIDs: ["window-current", "window-removed"]
        ) == ["window-current"])
    }

    @Test func thumbnailCacheIsBoundedToThirtyWindows() {
        let currentIDs = (0..<40).map { "window-\($0)" }
        let cachedIDs = Set(currentIDs)

        #expect(WindowSwitcherThumbnailCachePolicy.retainedIDs(
            currentIDs: currentIDs,
            cachedIDs: cachedIDs
        ).count == 30)
    }

    @Test func thumbnailTaskIsReusedForTheSameWindowSetRegardlessOfOrder() {
        #expect(WindowSwitcherThumbnailTaskPolicy.canReuseTask(
            hasTask: true,
            activeWindowIDs: ["window-a", "window-b"],
            requestedWindowIDs: ["window-b", "window-a"]
        ))
        #expect(!WindowSwitcherThumbnailTaskPolicy.canReuseTask(
            hasTask: false,
            activeWindowIDs: ["window-a", "window-b"],
            requestedWindowIDs: ["window-a", "window-b"]
        ))
        #expect(!WindowSwitcherThumbnailTaskPolicy.canReuseTask(
            hasTask: true,
            activeWindowIDs: ["window-a"],
            requestedWindowIDs: ["window-a", "window-b"]
        ))
    }

    @Test func thumbnailTaskInvalidatesOnlyWhenTheWindowSetChanges() {
        #expect(!WindowSwitcherThumbnailTaskPolicy.shouldInvalidateTask(
            previousWindowIDs: ["window-a", "window-b"],
            currentWindowIDs: ["window-b", "window-a"]
        ))
        #expect(WindowSwitcherThumbnailTaskPolicy.shouldInvalidateTask(
            previousWindowIDs: ["window-a"],
            currentWindowIDs: ["window-b"]
        ))
    }

    @Test func overlayWindowDoesNotBorrowAnUnrelatedWindowServerRecord() {
        let overlayFrame = CGRect(x: 2223, y: 572, width: 777, height: 325)
        let mainWindowFrame = CGRect(x: 1017, y: 281, width: 900, height: 652)

        #expect(WindowSwitcherWindowMatching.matchingFrameIndex(
            windowFrame: overlayFrame,
            candidateFrames: [mainWindowFrame]
        ) == nil)
        #expect(WindowSwitcherWindowMatching.matchingFrameIndex(
            windowFrame: mainWindowFrame.offsetBy(dx: 1, dy: -1),
            candidateFrames: [mainWindowFrame]
        ) == 0)
        #expect(!WindowSwitcherWindowMatching.shouldIncludeAXWindow(
            hasMatchingServerRecord: false,
            isOnScreen: false,
            isMinimized: false
        ))
        #expect(!WindowSwitcherWindowMatching.shouldIncludeAXWindow(
            hasMatchingServerRecord: false,
            isOnScreen: false,
            isMinimized: true
        ))
    }

    @Test func onlyMissionControlVisibleWindowsEnterTheInventory() {
        #expect(!WindowSwitcherWindowMatching.shouldIncludeAXWindow(
            hasMatchingServerRecord: true,
            isOnScreen: false,
            isMinimized: false
        ))
        #expect(WindowSwitcherWindowMatching.shouldIncludeAXWindow(
            hasMatchingServerRecord: true,
            isOnScreen: true,
            isMinimized: false
        ))
        #expect(!WindowSwitcherWindowMatching.shouldIncludeAXWindow(
            hasMatchingServerRecord: true,
            isOnScreen: false,
            isMinimized: true
        ))
    }

    @Test func newlyOpenedWindowsSortBeforeNeverActivatedOnes() {
        // w3 was just opened and promoted to the front of recentIDs, so it sorts
        // first; w2 was never activated and goes to the end.
        let ids = ["w1", "w2", "w3"]
        #expect(WindowSwitcherOrdering.orderedIndices(ids: ids, recentIDs: ["w3", "w1"]) == [2, 0, 1])
    }

    @Test func macPilotActivationPromotesItsOnlyWindow() {
        #expect(WindowSwitcherActivationRouting.promotedWindowID(
            applicationProcessID: ProcessInfo.processInfo.processIdentifier,
            candidateWindowIDs: ["window-macpilot"],
            focusedWindowID: nil
        ) == "window-macpilot")
    }

    @Test func previewingIdeaWindowDoesNotPromoteItBeforeCommit() {
        let recentIDs = ["zed", "idea-secondary", "idea-primary"]

        #expect(WindowSwitcherRecentWindowIDs.afterPreviewSelection(
            recentIDs: recentIDs,
            windowID: "idea-primary"
        ) == recentIDs)
        #expect(WindowSwitcherRecentWindowIDs.afterCommittedSelection(
            recentIDs: recentIDs,
            windowID: "idea-primary"
        ) == ["idea-primary", "zed", "idea-secondary"])
    }

    @Test func newlySeenWindowsDoNotDisplaceCommittedRecency() {
        let afterA = WindowSwitcherRecentWindowIDs.afterCommittedSelection(
            recentIDs: ["background", "a", "e"],
            windowID: "a"
        )
        let afterInventory = WindowSwitcherRecentWindowIDs.afterInventorySnapshot(
            recentIDs: afterA,
            previousIDs: ["background", "a", "e"],
            snapshotIDs: ["background", "a", "e", "new-1", "new-2"]
        )
        let afterE = WindowSwitcherRecentWindowIDs.afterCommittedSelection(
            recentIDs: afterInventory,
            windowID: "e"
        )

        #expect(Array(afterE.prefix(2)) == ["e", "a"])
    }

    @Test func newlySeenWindowsPreserveSnapshotOrderAfterKnownRecency() {
        #expect(WindowSwitcherRecentWindowIDs.afterInventorySnapshot(
            recentIDs: ["a"],
            previousIDs: ["a"],
            snapshotIDs: ["a", "new-2", "new-1"]
        ) == ["a", "new-2", "new-1"])
    }

    @Test func recreatedDBeaverWindowRemainsSecondAfterSwitchingAnotherWindow() {
        // DBeaver can recreate its WindowServer surface while starting. The
        // same visible window then has a new ID and a slightly different title.
        let recentIDs = ["window-chatgpt", "window-11723", "window-code"]
        let frame = CGRect(x: 80, y: 120, width: 1_200, height: 760)
        let previousWindows = [
            WindowSwitcherWindowIdentity(
                id: "window-chatgpt",
                processID: 10,
                windowNumber: 10,
                title: "ChatGPT",
                frame: frame
            ),
            WindowSwitcherWindowIdentity(
                id: "window-11723",
                processID: 20,
                windowNumber: nil,
                title: "DBeaver Community",
                frame: frame
            ),
            WindowSwitcherWindowIdentity(
                id: "window-code",
                processID: 30,
                windowNumber: 30,
                title: "Code",
                frame: frame
            )
        ]
        let snapshotWindows = [
            WindowSwitcherWindowIdentity(
                id: "window-chatgpt",
                processID: 10,
                windowNumber: 10,
                title: "ChatGPT",
                frame: frame
            ),
            WindowSwitcherWindowIdentity(
                id: "window-11733",
                processID: 20,
                windowNumber: nil,
                title: "DBeaver",
                frame: frame
            ),
            WindowSwitcherWindowIdentity(
                id: "window-code",
                processID: 30,
                windowNumber: 30,
                title: "Code",
                frame: frame
            )
        ]

        #expect(WindowSwitcherRecentWindowIDs.afterInventorySnapshot(
            recentIDs: recentIDs,
            previousIDs: Set(recentIDs),
            previousWindows: previousWindows,
            snapshotWindows: snapshotWindows
        ) == ["window-chatgpt", "window-11733", "window-code"])
    }

    @Test func openingNewVSCodeWindowPromotesItAboveFinder() {
        let afterFinder = WindowSwitcherRecentWindowIDs.afterCommittedSelection(
            recentIDs: ["vscode-old", "finder"],
            windowID: "finder"
        )
        #expect(afterFinder == ["finder", "vscode-old"])

        #expect(WindowSwitcherRecentWindowIDs.afterInventorySnapshot(
            recentIDs: afterFinder,
            previousIDs: Set(afterFinder),
            snapshotIDs: ["finder", "vscode-old", "vscode-new"],
            activatedWindowID: "vscode-new"
        ) == ["vscode-new", "finder", "vscode-old"])
    }

    @Test func thumbnailWorkStartsAtTheSelectionAndFansOut() {
        #expect(WindowSwitcherThumbnailPriority.orderedIndices(count: 5, selectedIndex: 2) == [2, 3, 1, 4, 0])
        #expect(WindowSwitcherThumbnailPriority.orderedIndices(count: 0, selectedIndex: 0).isEmpty)
    }

    @Test func thumbnailPrefetchIsBoundedToThirtyWindows() {
        let indices = WindowSwitcherThumbnailPriority.prefetchedIndices(count: 40, selectedIndex: 20)

        #expect(indices.count == 30)
        #expect(indices.first == 20)
    }

    @Test func cancelledThumbnailWorkCannotRepopulateDisabledCache() {
        #expect(!WindowSwitcherThumbnailCommitPolicy.shouldStoreThumbnail(
            taskIsCancelled: true,
            revisionMatches: true,
            showThumbnails: true
        ))
        #expect(!WindowSwitcherThumbnailCommitPolicy.shouldStoreThumbnail(
            taskIsCancelled: false,
            revisionMatches: false,
            showThumbnails: true
        ))
        #expect(!WindowSwitcherThumbnailCommitPolicy.shouldStoreThumbnail(
            taskIsCancelled: false,
            revisionMatches: true,
            showThumbnails: false
        ))
        #expect(!WindowSwitcherThumbnailCommitPolicy.shouldStoreThumbnail(
            taskIsCancelled: false,
            revisionMatches: true,
            showThumbnails: true,
            showIconsOnly: true
        ))
        #expect(WindowSwitcherThumbnailCommitPolicy.shouldStoreThumbnail(
            taskIsCancelled: false,
            revisionMatches: true,
            showThumbnails: true
        ))
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

    @Test func mergedApplicationsDisplayOnlyOneRepresentativeWindow() {
        var settings = WindowSwitcherSettings()
        settings.mergeApplicationBundleIdentifiers = ["com.cmuxterm.app"]

        #expect(WindowSwitcherApplicationGrouping.displayedIndices(
            isMinimized: [false, true, true, true],
            applicationBundleIdentifier: "com.cmuxterm.app",
            settings: settings
        ) == [0])
        #expect(WindowSwitcherApplicationGrouping.displayedIndices(
            isMinimized: [true, false, true],
            applicationBundleIdentifier: "com.cmuxterm.app",
            settings: settings
        ) == [1])
        #expect(WindowSwitcherApplicationGrouping.displayedIndices(
            isMinimized: [false, true, false],
            applicationBundleIdentifier: "com.apple.Terminal",
            settings: settings
        ) == [0, 1, 2])
    }

    @Test func hiddenMinimizedWindowsStillRespectTheGlobalSettingForUnmergedApplications() {
        var settings = WindowSwitcherSettings()
        settings.includeMinimizedWindows = false

        #expect(WindowSwitcherApplicationGrouping.displayedIndices(
            isMinimized: [false, true, false],
            applicationBundleIdentifier: "com.apple.Terminal",
            settings: settings
        ) == [0, 2])
        #expect(WindowSwitcherApplicationGrouping.displayedIndices(
            isMinimized: [false, true],
            applicationBundleIdentifier: "com.cmuxterm.app",
            settings: settings
        ) == [0])
    }

    @Test func mergeApplicationListSurvivesMissingKeyDecode() throws {
        let settings = try JSONDecoder().decode(
            WindowSwitcherSettings.self,
            from: Data(#"{"isEnabled":false}"#.utf8)
        )
        #expect(settings.mergeApplicationBundleIdentifiers.isEmpty)
    }
}
