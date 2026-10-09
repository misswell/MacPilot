import XCTest

/// Reproduces the user's navigation path to the control-section ordering page.
/// Run only on a fresh, isolated iPhone simulator; this test never touches any
/// remote-control or screen-state action.
final class ControlSectionOrderUITests: XCTestCase {
    @MainActor
    func testNavigationControlsStartOffAndCanBeEnabledIndividually() {
        let app = XCUIApplication()
        app.launch()
        openControlSettings(in: app)

        let featureIDs = ["pageUp", "pageDown", "home", "end"]
        let rows = featureIDs.map { app.switches["controlToggle.\($0)"] }
        scrollUntilHittable(rows, in: app)
        for row in rows {
            XCTAssertTrue(row.exists && row.isHittable)
            XCTAssertEqual(row.value as? String, "0", "Navigation controls should start off")
        }

        let homeRow = app.switches["controlToggle.home"]
        let homeSwitch = homeRow.descendants(matching: .switch).firstMatch
        XCTAssertTrue(homeSwitch.exists && homeSwitch.isHittable)
        homeSwitch.tap()
        XCTAssertEqual(homeRow.value as? String, "1")
        for featureID in ["pageUp", "pageDown", "end"] {
            XCTAssertEqual(app.switches["controlToggle.\(featureID)"].value as? String, "0")
        }

        app.terminate()
        app.launch()
        openControlSettings(in: app)
        let persistedRows = featureIDs.map { app.switches["controlToggle.\($0)"] }
        scrollUntilHittable(persistedRows, in: app)
        let persistedHomeRow = app.switches["controlToggle.home"]
        let persistedHomeSwitch = persistedHomeRow.descendants(matching: .switch).firstMatch
        XCTAssertTrue(persistedHomeSwitch.exists && persistedHomeSwitch.isHittable)
        XCTAssertEqual(persistedHomeRow.value as? String, "1")
        for featureID in ["pageUp", "pageDown", "end"] {
            XCTAssertEqual(app.switches["controlToggle.\(featureID)"].value as? String, "0")
        }
        // Return this isolated fixture to its initial visibility state.
        persistedHomeSwitch.tap()
        XCTAssertEqual(persistedHomeRow.value as? String, "0")
    }

    @MainActor
    func testSectionOrderEntryOpensItsDestination() {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15), "Settings tab should be available")
        settingsTab.tap()

        let controlSettingsEntry = app.buttons["controlSettings"]
        XCTAssertTrue(
            controlSettingsEntry.waitForExistence(timeout: 10),
            "Control settings entry should be visible on the Settings tab"
        )
        controlSettingsEntry.tap()

        let sectionOrderLabels = ["Section order", "分区排序"]
        let sectionOrderEntry = app.buttons
            .matching(NSPredicate(format: "label IN %@", sectionOrderLabels))
            .firstMatch
        XCTAssertTrue(
            sectionOrderEntry.waitForExistence(timeout: 10),
            "Section order navigation link should be visible in control settings"
        )
        XCTAssertTrue(sectionOrderEntry.isEnabled, "Section order entry should be enabled")
        sectionOrderEntry.tap()

        let sectionOrderPageTitle = app.navigationBars.staticTexts
            .matching(NSPredicate(format: "label IN %@", sectionOrderLabels))
            .firstMatch
        XCTAssertTrue(
            sectionOrderPageTitle.waitForExistence(timeout: 5),
            "The Section order page title should appear in the navigation bar"
        )
    }

    @MainActor
    func testNavigationSectionAndFeatureOrderPersistAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openControlSettings(in: app)

        let featureIDs = ["pageUp", "pageDown", "home", "end"]
        let featureRows = featureIDs.map { app.switches["controlToggle.\($0)"] }
        scrollUntilHittable(featureRows, in: app)
        XCTAssertTrue(featureRows.allSatisfy { $0.exists && $0.isHittable },
                      "All navigation-key preference rows should be reachable")

        let initialFeatureOrder = featureRows.sorted { $0.frame.midY < $1.frame.midY }
        let movedFeature = initialFeatureOrder.last!
        let firstFeature = initialFeatureOrder.first!
        let expectedTopFeatureID = movedFeature.identifier
        dragRow(movedFeature, toY: firstFeature.frame.minY + 1, in: app)

        let featureOrderAfterMove = featureRows.sorted { $0.frame.midY < $1.frame.midY }
        XCTAssertEqual(featureOrderAfterMove.first?.identifier, expectedTopFeatureID,
                       "The navigation-key row should move within its own section")

        let groupOrderButton = app.buttons["controlGroupOrder"]
        XCTAssertTrue(groupOrderButton.waitForExistence(timeout: 5))
        groupOrderButton.tap()

        let inputGroup = app.staticTexts["controlGroup.input"]
        let screenGroup = app.staticTexts["controlGroup.screen"]
        let navigationGroup = app.staticTexts["controlGroup.navigation"]
        XCTAssertTrue(inputGroup.waitForExistence(timeout: 5))
        XCTAssertTrue(screenGroup.exists)
        XCTAssertTrue(navigationGroup.exists)

        let navigationWasFirst = navigationGroup.frame.midY < inputGroup.frame.midY
        let insertionTargetY = navigationWasFirst
            ? screenGroup.frame.minY + 1
            : inputGroup.frame.minY + 1
        dragRow(navigationGroup, toY: insertionTargetY, in: app)
        let navigationShouldBeFirstAfterMove = !navigationWasFirst
        XCTAssertEqual(navigationGroup.frame.midY < inputGroup.frame.midY,
                       navigationShouldBeFirstAfterMove,
                       "The navigation section should move independently of its feature order")

        app.terminate()
        app.launch()
        openControlSettings(in: app)
        let reopenedGroupOrderButton = app.buttons["controlGroupOrder"]
        XCTAssertTrue(reopenedGroupOrderButton.waitForExistence(timeout: 5))
        reopenedGroupOrderButton.tap()

        let persistedNavigationGroup = app.staticTexts["controlGroup.navigation"]
        let persistedInputGroup = app.staticTexts["controlGroup.input"]
        XCTAssertTrue(persistedNavigationGroup.waitForExistence(timeout: 5))
        XCTAssertTrue(persistedInputGroup.exists)
        XCTAssertEqual(persistedNavigationGroup.frame.midY < persistedInputGroup.frame.midY,
                       navigationShouldBeFirstAfterMove,
                       "Section ordering should survive relaunch")

        app.navigationBars.buttons["BackButton"].tap()
        let persistedFeatureRows = featureIDs.map { app.switches["controlToggle.\($0)"] }
        scrollUntilHittable(persistedFeatureRows, in: app)
        let persistedFeatureState = persistedFeatureRows.map {
            "\($0.identifier): exists=\($0.exists), hittable=\($0.isHittable), frame=\($0.frame)"
        }.joined(separator: "; ")
        XCTAssertTrue(persistedFeatureRows.allSatisfy { $0.exists && $0.isHittable }, persistedFeatureState)
        let persistedFeatureOrder = persistedFeatureRows
            .sorted { $0.frame.midY < $1.frame.midY }
            .map(\.identifier)
        XCTAssertEqual(persistedFeatureOrder, featureOrderAfterMove.map(\.identifier),
                       "Feature ordering should survive relaunch")
    }

    @MainActor
    private func openControlSettings(in app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()
        let controlSettingsEntry = app.buttons["controlSettings"]
        XCTAssertTrue(controlSettingsEntry.waitForExistence(timeout: 10))
        controlSettingsEntry.tap()
    }

    @MainActor
    private func scrollUntilHittable(_ rows: [XCUIElement], in app: XCUIApplication) {
        let visibleTop = app.frame.minY + 130
        let visibleBottom = app.frame.maxY - 150
        for attempt in 0..<12 {
            if rows.allSatisfy({ $0.exists && $0.isHittable }) { return }
            guard let first = rows.first, let last = rows.last else { return }
            if first.exists && first.frame.minY < visibleTop {
                app.swipeDown()
            } else if last.exists && last.frame.maxY > visibleBottom {
                app.swipeUp()
            } else if attempt.isMultiple(of: 2) {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
    }

    @MainActor
    private func dragRow(_ row: XCUIElement, toY destinationY: CGFloat, in app: XCUIApplication) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let handleX = app.frame.width * 0.9
        let from = origin.withOffset(CGVector(dx: handleX, dy: row.frame.midY))
        let to = origin.withOffset(CGVector(dx: handleX, dy: destinationY))
        from.press(forDuration: 0.8, thenDragTo: to)
    }
}
