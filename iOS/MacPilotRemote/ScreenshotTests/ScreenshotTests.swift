import XCTest
import CoreGraphics

/// Captures App Store screenshots by driving the real app in the simulator.
/// Tab selection uses indexes (home=0, devices=1, settings=2) so the test is
/// independent of the device language.
final class ScreenshotTests: XCTestCase {

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "\(name).png",
            payload: shot.pngRepresentation,
            userInfo: nil
        )
        att.lifetime = .keepAlways
        add(att)
    }

    private func launchAndSettle() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        sleep(6) // let Bonjour discovery settle so the found-Mac state renders
        return app
    }

    @MainActor
    func testScreenshotHome() {
        let app = launchAndSettle()
        capture("01-home")
        _ = app // silence unused warning when queries are adjusted per screen
    }

    @MainActor
    func testScreenKeyIconsAndCaptionsAreVisuallyCentered() throws {
        let app = launchAndSettle()
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        for name in ["displayOff", "wakeDisplay", "lockScreen", "wakeAndUnlock"] {
            let button = app.buttons["control.\(name)"]
            XCTAssertTrue(button.exists, name)
            let frame = button.frame
            let crop = try XCTUnwrap(image.cropping(to: CGRect(
                x: frame.minX * scale, y: frame.minY * scale,
                width: frame.width * scale, height: frame.height * scale
            ).integral))
            let ink = try foregroundBounds(in: crop, scale: scale)
            let offset = (ink.midY - CGFloat(crop.height) / 2) / scale
            XCTAssertLessThanOrEqual(abs(offset), 1, "\(name): visible content offset \(offset) pt")
            XCTAssertGreaterThanOrEqual(ink.width / ink.height, 1.5,
                                        "\(name): icon and caption must share the vertical center line")
        }
        capture("09-screen-key-centering")
    }

    /// Inspect rendered ink, not the invisible font or button layout bounds.
    private func foregroundBounds(in image: CGImage, scale: CGFloat) throws -> CGRect {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        XCTAssertTrue(rendered)
        let inset = max(1, Int((4 * scale).rounded()))
        let background = ((height / 2) * width + inset) * 4
        let light = (Int(pixels[background]) + Int(pixels[background + 1])
                     + Int(pixels[background + 2])) / 3 > 128
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in inset..<(height - inset) {
            for x in inset..<(width - inset) {
                let index = (y * width + x) * 4
                let r = Int(pixels[index])
                let g = Int(pixels[index + 1])
                let b = Int(pixels[index + 2])
                let average = (r + g + b) / 3
                let saturated = max(r, max(g, b)) - min(r, min(g, b)) > 50
                if (light ? average < 225 : average > 75) || saturated {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "Button must render its icon and caption")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor
    func testTouchBarAndAllHomeButtonsFitWithoutScrolling() {
        let app = launchAndSettle()
        let names = ["desktop", "trackpad", "displayOff", "wakeDisplay", "lockScreen",
                     "wakeAndUnlock", "mediaPrevious", "mediaPlayPause", "mediaNext", "mute"]
        let safeBottom = app.tabBars.firstMatch.exists
            ? app.tabBars.firstMatch.frame.minY : app.frame.maxY - 30
        for name in names {
            let button = app.buttons["control.\(name)"]
            XCTAssertTrue(button.exists, name)
            XCTAssertTrue(button.staticTexts.firstMatch.exists, "\(name): visible caption")
            // Accessibility frame conversion can round 44 points down slightly.
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44, name)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0, name)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX, name)
            XCTAssertLessThanOrEqual(button.frame.maxY, safeBottom, name)
        }
        let screenKeys = ["displayOff", "wakeDisplay", "lockScreen", "wakeAndUnlock"]
            .map { app.buttons["control.\($0)"].frame }
        XCTAssertEqual(screenKeys[0].midY, screenKeys[1].midY, accuracy: 0.1)
        XCTAssertEqual(screenKeys[2].midY, screenKeys[3].midY, accuracy: 0.1)
        XCTAssertLessThan(screenKeys[0].maxY, screenKeys[2].minY)
        for frame in screenKeys.dropFirst() {
            XCTAssertEqual(frame.height, screenKeys[0].height, accuracy: 0.1)
        }
        let previous = app.buttons["control.mediaPrevious"].frame
        let play = app.buttons["control.mediaPlayPause"].frame
        let next = app.buttons["control.mediaNext"].frame
        XCTAssertEqual(previous.midY, play.midY, accuracy: 1)
        XCTAssertEqual(play.midY, next.midY, accuracy: 1)
        XCTAssertLessThan(previous.maxX, play.minX)
        XCTAssertLessThan(play.maxX, next.minX)
        capture("08-touchbar-home")
    }

    @MainActor
    func testControlCaptionsStayInsideKeysAtLargeTextSizes() {
        let app = launchAndSettle()
        let safeBottom = app.tabBars.firstMatch.frame.minY
        for name in ["desktop", "trackpad", "displayOff", "wakeDisplay", "lockScreen",
                     "wakeAndUnlock", "mediaPrevious", "mediaPlayPause", "mediaNext", "mute"] {
            let button = app.buttons["control.\(name)"]
            for _ in 0..<12 {
                if button.exists && button.frame.maxY <= safeBottom { break }
                app.swipeUp()
            }
            XCTAssertTrue(button.exists, name)
            let caption = button.staticTexts.firstMatch
            XCTAssertTrue(caption.exists, "\(name): keep the visible caption")
            let keyFrame = button.frame
            XCTAssertGreaterThanOrEqual(keyFrame.minX, 0, name)
            XCTAssertLessThanOrEqual(keyFrame.maxX, app.frame.maxX, name)
            let textFrame = caption.frame
            XCTAssertGreaterThan(textFrame.width, 0, name)
            XCTAssertGreaterThan(textFrame.height, 0, name)
            XCTAssertGreaterThanOrEqual(textFrame.minX + 0.5, keyFrame.minX, name)
            XCTAssertLessThanOrEqual(textFrame.maxX, keyFrame.maxX + 0.5, name)
            XCTAssertGreaterThanOrEqual(textFrame.minY + 0.5, keyFrame.minY, name)
            XCTAssertLessThanOrEqual(textFrame.maxY, keyFrame.maxY + 0.5, name)
        }
        capture("10-large-text-controls")
    }

    @MainActor
    func testControlSelectionPersistsAndHomeMediaLayoutFits() {
        let app = launchAndSettle()
        selectControlTab(app, index: 2)
        app.buttons["controlSettings"].tap()
        let toggle = app.switches["controlToggle.lockScreen"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // SwiftUI exposes the entire row as a switch. Tap the physical thumb
        // at a fixed inset from the trailing edge on both iPhone and iPad.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -42, dy: 0)).tap()
        capture("06-control-features")
        app.terminate()
        app.launch()
        selectControlTab(app, index: 0)
        let hidden = !app.buttons["control.lockScreen"].exists
        let previous = app.buttons["control.mediaPrevious"]
        let playPause = app.buttons["control.mediaPlayPause"]
        let next = app.buttons["control.mediaNext"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.exists)
        XCTAssertTrue(next.exists)
        for button in [previous, playPause, next] {
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.width)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        capture("07-home-controls")
        selectControlTab(app, index: 2)
        app.buttons["controlSettings"].tap()
        app.switches["controlToggle.lockScreen"]
            .coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -42, dy: 0)).tap()
        XCTAssertTrue(hidden)
    }

    @MainActor
    private func selectControlTab(_ app: XCUIApplication, index: Int) {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons.element(boundBy: index).tap()
        } else {
            // iPad's floating tab strip is exposed as ordinary buttons.
            let title = index == 0 ? ["控制", "Control"] : ["设置", "Settings"]
            let button = app.buttons[title[0]].firstMatch
            (button.exists ? button : app.buttons[title[1]].firstMatch).tap()
        }
    }

    @MainActor
    func testScreenshotDevices() {
        let app = launchAndSettle()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(3)
        capture("02-devices")
    }

    @MainActor
    func testScreenshotPairingSheet() {
        let app = launchAndSettle()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(2)
        // The discovered row's pair button: 配对 (zh-Hans) / Pair (en).
        let pairZH = app.buttons["配对"].firstMatch
        let pairEN = app.buttons["Pair"].firstMatch
        let pair = pairZH.exists ? pairZH : pairEN
        guard pair.exists else {
            XCTFail("pair button not found; discovered list may be empty")
            return
        }
        pair.tap()
        sleep(3) // let the waiting state render
        capture("03-pairing")
        let cancelZH = app.buttons["取消"].firstMatch
        let cancelEN = app.buttons["Cancel"].firstMatch
        (cancelZH.exists ? cancelZH : cancelEN).tap()
    }

    @MainActor
    func testScreenshotSettings() {
        let app = launchAndSettle()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 2).tap()
        sleep(3)
        capture("04-settings")
    }

    @MainActor
    func testConnectionPriorityCanBeReorderedAndPersists() {
        let app = launchAndSettle()
        app.tabBars.buttons.element(boundBy: 2).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        let bluetooth = app.staticTexts["connectionPriority.bluetooth"]
        let lan = app.staticTexts["connectionPriority.localNetwork"]
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 5))
        XCTAssertTrue(lan.exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.frame.width * 0.9
        origin.withOffset(CGVector(dx: x, dy: bluetooth.frame.midY))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: x, dy: lan.frame.minY)))
        XCTAssertLessThan(bluetooth.frame.midY, lan.frame.midY)
        capture("05-connection-priority")
        app.terminate()
        app.launch()
        app.tabBars.buttons.element(boundBy: 2).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertLessThan(bluetooth.frame.midY, lan.frame.midY)
        // Restore the default order for subsequent screenshot runs.
        let awdl = app.staticTexts["connectionPriority.awdl"]
        origin.withOffset(CGVector(dx: x, dy: bluetooth.frame.midY))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: x, dy: awdl.frame.maxY + 10)))
        XCTAssertGreaterThan(bluetooth.frame.midY, awdl.frame.midY)
    }
}
