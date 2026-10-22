import XCTest

/// Explicit real-radio acceptance only. Never run on a simulator or implicitly
/// as part of screenshots/CI; never touch any remote-control action or pairing.
final class ReverseGATTHardwareUITests: XCTestCase {
    @MainActor
    func testForegroundRepeatAndBackgroundRecovery() throws {
        guard ProcessInfo.processInfo.environment["MACPILOT_GATT_HARDWARE"] == "1" else {
            throw XCTSkip("Enable only with the isolated production Peripheral host and a real iPhone")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator cannot establish a physical BLE link")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let tab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        let entry = app.buttons["proximityGATT"]
        for _ in 0..<12 {
            if entry.exists && entry.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        defer {
            if app.state != .runningForeground { app.activate() }
            for _ in 0..<16 {
                if app.buttons["proximityGATTStop"].isHittable { break }
                app.swipeDown()
            }
            if app.buttons["proximityGATTStop"].isHittable { app.buttons["proximityGATTStop"].tap() }
        }
        if app.buttons["proximityGATTStop"].exists { app.buttons["proximityGATTStop"].tap() }
        app.buttons["proximityGATTStart"].tap()
        waitForVerified(in: app, timeout: 60)
        attachScreen("foreground-verified")
        let repeatButton = app.buttons["proximityGATTSendAgain"]
        for _ in 0..<6 {
            if repeatButton.exists && repeatButton.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(repeatButton.isHittable)
        let count = app.descendants(matching: .any).matching(identifier: "proximityGATTVerifiedCount").firstMatch
        let beforeRepeat = try XCTUnwrap(Int(count.value as? String ?? ""))
        repeatButton.tap()
        let increased = NSPredicate(format: "value.intValue > %d", beforeRepeat)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: increased, object: count)], timeout: 30), .completed)
        for _ in 0..<10 {
            if app.staticTexts["proximityGATTStatus"].isHittable { break }
            app.swipeDown()
        }
        waitForVerified(in: app, timeout: 60)
        NSLog("GATT_HARDWARE_BACKGROUND_BEGIN")
        XCUIDevice.shared.press(.home)
        let duration = Double(ProcessInfo.processInfo.environment["MACPILOT_GATT_BACKGROUND_SECONDS"] ?? "65") ?? 65
        // The host cycles only its test service while the phone is backgrounded.
        // The controller must make a new verified probe before foregrounding.
        Thread.sleep(forTimeInterval: min(180, max(35, duration)))
        NSLog("GATT_HARDWARE_BACKGROUND_END")
        app.activate()
        waitForVerified(in: app, timeout: 60)
        attachScreen("after-background")
        app.buttons["proximityGATTStop"].tap()
        let lines = collectLog(in: app)
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "reverse-gatt-device-events"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let background = lines.lastIndex(where: { $0.contains("app background;") }),
              let foreground = lines[(background + 1)...].firstIndex(where: { $0.contains("app foreground") }) else {
            XCTFail("Missing background/foreground interval in the captured log")
            return
        }
        XCTAssertTrue(lines[(background + 1)..<foreground].contains(where: { $0.contains("round-trip verified") }),
                      "A foreground refresh cannot stand in for a real background round trip")
        #endif
    }

    @MainActor
    private func waitForVerified(in app: XCUIApplication, timeout: TimeInterval) {
        let status = app.staticTexts["proximityGATTStatus"]
        let predicate = NSPredicate(format: "label CONTAINS '回环成功' OR label CONTAINS[c] 'echo verified'")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, "No fresh verified echo: \(status.exists ? status.label : "missing status")")
    }

    @MainActor
    private func collectLog(in app: XCUIApplication) -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        var unchanged = 0
        for _ in 0..<30 {
            let before = lines.count
            for element in app.staticTexts.matching(identifier: "proximityGATTLogLine").allElementsBoundByIndex {
                if seen.insert(element.label).inserted { lines.append(element.label) }
            }
            unchanged = lines.count == before ? unchanged + 1 : 0
            if unchanged >= 4, app.buttons["导出日志"].exists || app.buttons["Export log"].exists { break }
            app.swipeUp()
        }
        return lines
    }

    @MainActor
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
