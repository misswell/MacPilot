import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import Testing
@testable import MacPilot

struct ScreenCaptureTests {

    @Test @MainActor func smartSelectionPresentsOverlayBeforeInitialAXQueryCompletes() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }

        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true },
            initialTargetResolver: { _, _ in
                Thread.sleep(forTimeInterval: 0.15)
                return nil
            }
        )
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let startedAt = Date()
        controller.startSelection(mode: .smartElement)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 0.1)
        #expect(controller.testOverlayCount == NSScreen.screens.count)
    }

    @Test func smartCapturePrefersTheSmallestMeaningfulElement() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 700)
        let chain = [
            SmartCaptureElement(role: "AXButton", frame: CGRect(x: 180, y: 160, width: 120, height: 36)),
            SmartCaptureElement(role: "AXGroup", frame: CGRect(x: 150, y: 140, width: 500, height: 300))
        ]

        #expect(SmartCaptureTargetResolver.resolve(elementChain: chain, windowFrame: window) == chain[0].frame)
    }

    @Test func smartCaptureSkipsTinyAndWindowSizedElements() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 700)
        let expected = CGRect(x: 160, y: 140, width: 420, height: 260)
        let chain = [
            SmartCaptureElement(role: "AXImage", frame: CGRect(x: 170, y: 150, width: 7, height: 7)),
            SmartCaptureElement(role: "AXGroup", frame: expected),
            SmartCaptureElement(role: "AXScrollArea", frame: CGRect(x: 105, y: 105, width: 890, height: 690))
        ]

        #expect(SmartCaptureTargetResolver.resolve(elementChain: chain, windowFrame: window) == expected)
    }

    @Test func smartCaptureFallsBackToTheWindow() {
        let window = CGRect(x: -700, y: 80, width: 640, height: 520)
        let chain = [SmartCaptureElement(role: "AXApplication", frame: window)]

        #expect(SmartCaptureTargetResolver.resolve(elementChain: chain, windowFrame: window) == window)
    }

    @Test func smartCaptureShortcutMatchesPlainF1Only() {
        #expect(SmartCaptureShortcut.matches(keyCode: 122, flags: CGEventFlags(), isRepeat: false))
        #expect(!SmartCaptureShortcut.matches(keyCode: 120, flags: CGEventFlags(), isRepeat: false))
        #expect(!SmartCaptureShortcut.matches(keyCode: 122, flags: [.maskCommand], isRepeat: false))
        #expect(!SmartCaptureShortcut.matches(keyCode: 122, flags: CGEventFlags(), isRepeat: true))
    }

    @Test func smartCaptureShortcutMatchesCustomKeyAndModifiers() {
        let binding = SmartCaptureShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        #expect(binding.displayName == "⌥⌘A")
        #expect(binding.matches(keyCode: 0, flags: [.maskCommand, .maskAlternate], isRepeat: false))
        #expect(!binding.matches(keyCode: 0, flags: [.maskCommand], isRepeat: false))
        #expect(!binding.matches(keyCode: 1, flags: [.maskCommand, .maskAlternate], isRepeat: false))
    }

    @Test @MainActor func startupShortcutRegistrationRetriesTransientFailure() async throws {
        var attempts = 0
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            shortcutRegistrationAttempt: {
                attempts += 1
                return attempts == 1 ? .registrationFailed : nil
            }
        )
        defer { controller.stop() }

        controller.start()
        try await Task.sleep(for: .milliseconds(150))

        #expect(attempts >= 2)
        #expect(controller.testShortcutRegistrationAttemptCount == 2)
    }

    @Test func shortcutEventRoutingFindsTheConfiguredAreaBinding() {
        let bindings = [
            SmartCaptureShortcutEventBinding(
                id: 3,
                binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])
            ),
            SmartCaptureShortcutEventBinding(
                id: 10,
                binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.control, .command, .shift])
            ),
            SmartCaptureShortcutEventBinding(
                id: 11,
                binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .command])
            )
        ]

        #expect(SmartCaptureShortcutRouting.matchingID(
            keyCode: UInt16(kVK_ANSI_4),
            flags: [.maskCommand, .maskShift],
            isRepeat: false,
            bindings: bindings
        ) == 3)
        #expect(SmartCaptureShortcutRouting.matchingID(
            keyCode: UInt16(kVK_ANSI_4),
            flags: [.maskControl, .maskCommand, .maskShift],
            isRepeat: false,
            bindings: bindings
        ) == 10)
        #expect(SmartCaptureShortcutRouting.matchingID(
            keyCode: UInt16(kVK_ANSI_A),
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            bindings: bindings
        ) == 11)
    }

    @Test func shortcutEventRoutingIgnoresRepeatsAndUnconfiguredCombinations() {
        let binding = SmartCaptureShortcutEventBinding(
            id: 3,
            binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])
        )

        #expect(SmartCaptureShortcutRouting.matchingID(
            keyCode: UInt16(kVK_ANSI_4),
            flags: [.maskCommand, .maskShift],
            isRepeat: true,
            bindings: [binding]
        ) == nil)
        #expect(SmartCaptureShortcutRouting.matchingID(
            keyCode: UInt16(kVK_ANSI_5),
            flags: [.maskCommand, .maskShift],
            isRepeat: false,
            bindings: [binding]
        ) == nil)
    }

    @Test func systemScreenshotShortcutDetectorFindsEnabledAreaConflict() {
        let hotkeys: [String: Any] = [
            "28": [
                "enabled": true,
                "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: kVK_ANSI_4), NSNumber(value: 1179648)]]
            ],
            "30": [
                "enabled": false,
                "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: kVK_ANSI_3), NSNumber(value: 1179648)]]
            ]
        ]
        let binding = SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])
        #expect(SmartCaptureSystemShortcutDetector.conflicts(for: binding, hotkeys: hotkeys) == [.area])
    }

    @Test func systemScreenshotShortcutConflictIsARejectedShortcutError() {
        let hotkeys: [String: Any] = [
            "28": [
                "enabled": true,
                "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: kVK_ANSI_4), NSNumber(value: 1179648)]]
            ]
        ]
        let binding = SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])
        #expect(SmartCaptureSystemShortcutDetector.conflicts(for: binding, hotkeys: hotkeys) == [.area])
        #expect(SmartCaptureShortcutError.systemShortcutConflict.messageKey == "scShortcutSystemConflict")
    }

    @Test func smartCaptureShortcutBindingRoundTripsThroughCodable() throws {
        let binding = SmartCaptureShortcutBinding(keyCode: 18, modifiers: [.control, .shift])
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(SmartCaptureShortcutBinding.self, from: data) == binding)
    }

    @Test func smartCaptureShortcutRejectsUnmodifiedRegularKeysButAllowsFunctionKeys() {
        #expect(SmartCaptureShortcutBinding(keyCode: UInt16(kVK_F1), modifiers: []).isValid)
        #expect(!SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: []).isValid)
        #expect(SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command]).isValid)
        #expect(!SmartCaptureShortcutBinding(keyCode: UInt16(kVK_Escape), modifiers: []).isValid)
        #expect(!SmartCaptureShortcutBinding(keyCode: UInt16(kVK_Escape), modifiers: [.command, .shift]).isValid)
    }

    @Test func snapzyStyleScreenshotShortcutDefaultsAreConfigurableAndPersisted() throws {
        #expect(ScreenCaptureShortcutKind.area.defaultBinding.displayName == "⌥⌘4")
        #expect(ScreenCaptureShortcutKind.repeatArea.defaultBinding.displayName == "⌥⇧⌘4")
        #expect(ScreenCaptureShortcutKind.applicationWindow.defaultBinding.displayName == "⌃⌘A")
        #expect(ScreenCaptureShortcutKind.fullscreen.defaultBinding.displayName == "⌥⌘3")
        #expect(ScreenCaptureShortcutKind.activeWindow.defaultBinding.displayName == "⇧⌘9")
        #expect(ScreenCaptureShortcutKind.areaAnnotate.defaultBinding.displayName == "⇧⌘7")
        #expect(ScreenCaptureShortcutKind.ocr.defaultBinding.displayName == "⇧⌘2")
        #expect(ScreenCaptureShortcutKind.scrolling.defaultBinding.displayName == "⇧⌘6")
        #expect(ScreenCaptureShortcutKind.objectCutout.defaultBinding.displayName == "⇧⌘1")

        let settings = ScreenCaptureSettings(
            areaCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_6), modifiers: [.command, .option]),
            repeatAreaCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .command]),
            applicationWindowCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option, .command]),
            fullscreenCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_F8), modifiers: [.control]),
            activeWindowCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_X), modifiers: [.option, .command]),
            areaAnnotateShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .shift]),
            ocrShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command, .shift]),
            scrollingCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_6), modifiers: [.control, .shift]),
            objectCutoutShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: [.option, .shift])
        )
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.areaCaptureShortcut == settings.areaCaptureShortcut)
        #expect(decoded.repeatAreaCaptureShortcut == settings.repeatAreaCaptureShortcut)
        #expect(decoded.applicationWindowCaptureShortcut == settings.applicationWindowCaptureShortcut)
        #expect(decoded.fullscreenCaptureShortcut == settings.fullscreenCaptureShortcut)
        #expect(decoded.activeWindowCaptureShortcut == settings.activeWindowCaptureShortcut)
        #expect(decoded.areaAnnotateShortcut == settings.areaAnnotateShortcut)
        #expect(decoded.ocrShortcut == settings.ocrShortcut)
        #expect(decoded.scrollingCaptureShortcut == settings.scrollingCaptureShortcut)
        #expect(decoded.objectCutoutShortcut == settings.objectCutoutShortcut)
    }

    @Test func postCapturePreferencesDefaultToCopyAndQuickAccess() throws {
        let defaults = ScreenCaptureSettings()
        #expect(defaults.copyAfterCapture)
        #expect(defaults.showQuickAccess)
        #expect(!defaults.pinAfterCapture)

        let customized = ScreenCaptureSettings(
            copyAfterCapture: false,
            showQuickAccess: false,
            pinAfterCapture: true
        )
        let decoded = try JSONDecoder().decode(
            ScreenCaptureSettings.self,
            from: JSONEncoder().encode(customized)
        )
        #expect(decoded.copyAfterCapture == false)
        #expect(decoded.showQuickAccess == false)
        #expect(decoded.pinAfterCapture)
    }

    @Test func quickAccessStackKeepsTheFiveNewestItemsInOrder() {
        var stack = SmartQuickAccessStackState()
        let ids = (0..<6).map { _ in UUID() }

        for id in ids.prefix(5) {
            #expect(stack.insert(id) == nil)
        }
        #expect(stack.ids == Array(ids.prefix(5).reversed()))

        #expect(stack.insert(ids[5]) == ids[0])
        #expect(stack.ids == Array(ids.dropFirst().reversed()))

        stack.remove(ids[3])
        #expect(!stack.ids.contains(ids[3]))
        #expect(stack.ids.count == 4)

        #expect(stack.insert(ids[4]) == nil)
        #expect(stack.ids.first == ids[4])
        #expect(stack.ids.count == 4)
    }

    @Test @MainActor func screenCaptureModelAppliesAndPersistsEveryShortcutKind() {
        let model = ScreenCaptureModel()
        model.setSmartCaptureEnabled(false)
        var didPersist = false
        model.persist = { didPersist = true }

        let bindings: [(ScreenCaptureShortcutKind, SmartCaptureShortcutBinding)] = [
            (.smartElement, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_F8), modifiers: [])),
            (.area, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option])),
            (.repeatArea, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .command])),
            (.applicationWindow, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command, .option])),
            (.fullscreen, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command, .shift])),
            (.activeWindow, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])),
            (.areaAnnotate, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.control, .shift])),
            (.ocr, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .control])),
            (.scrolling, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command, .control])),
            (.objectCutout, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .control]))
        ]

        for (kind, binding) in bindings {
            #expect(model.setShortcut(kind, binding: binding))
            #expect(model.shortcutBinding(for: kind) == binding)
        }
        #expect(didPersist)
    }

    @Test @MainActor func screenCaptureModelRejectsDuplicateAndInvalidShortcuts() {
        let model = ScreenCaptureModel()
        model.setSmartCaptureEnabled(false)
        let originalArea = model.shortcutBinding(for: .area)

        #expect(!model.setShortcut(.area, binding: model.shortcutBinding(for: .smartElement)))
        #expect(model.shortcutBinding(for: .area) == originalArea)
        #expect(!model.setShortcut(
            .fullscreen,
            binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])
        ))
        #expect(model.shortcutBinding(for: .fullscreen) == ScreenCaptureShortcutKind.fullscreen.defaultBinding)
    }

    @Test func legacyScreenCaptureSettingsUseSnapzyStyleShortcutDefaults() throws {
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: Data("{}".utf8))
        #expect(decoded.areaCaptureShortcut == ScreenCaptureShortcutKind.area.defaultBinding)
        #expect(decoded.repeatAreaCaptureShortcut == ScreenCaptureShortcutKind.repeatArea.defaultBinding)
        #expect(decoded.applicationWindowCaptureShortcut == ScreenCaptureShortcutKind.applicationWindow.defaultBinding)
        #expect(decoded.fullscreenCaptureShortcut == ScreenCaptureShortcutKind.fullscreen.defaultBinding)
        #expect(decoded.activeWindowCaptureShortcut == ScreenCaptureShortcutKind.activeWindow.defaultBinding)
        #expect(decoded.areaAnnotateShortcut == ScreenCaptureShortcutKind.areaAnnotate.defaultBinding)
        #expect(decoded.ocrShortcut == ScreenCaptureShortcutKind.ocr.defaultBinding)
        #expect(decoded.scrollingCaptureShortcut == ScreenCaptureShortcutKind.scrolling.defaultBinding)
        #expect(decoded.objectCutoutShortcut == ScreenCaptureShortcutKind.objectCutout.defaultBinding)
    }

    @Test func legacyMacOSScreenshotDefaultsMigrateToWorkingMacPilotShortcuts() throws {
        let legacyJSON = """
        {
          "areaCaptureShortcut": { "keyCode": 21, "modifiers": 9 },
          "repeatAreaCaptureShortcut": { "keyCode": 21, "modifiers": 11 },
          "fullscreenCaptureShortcut": { "keyCode": 20, "modifiers": 9 }
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(ScreenCaptureSettings.self, from: legacyJSON)

        #expect(legacy.areaCaptureShortcut == ScreenCaptureShortcutKind.area.defaultBinding)
        #expect(legacy.repeatAreaCaptureShortcut == ScreenCaptureShortcutKind.repeatArea.defaultBinding)
        #expect(legacy.fullscreenCaptureShortcut == ScreenCaptureShortcutKind.fullscreen.defaultBinding)

        let intermediateJSON = """
        {
          "areaCaptureShortcut": { "keyCode": 21, "modifiers": 14 },
          "repeatAreaCaptureShortcut": { "keyCode": 21, "modifiers": 15 },
          "fullscreenCaptureShortcut": { "keyCode": 20, "modifiers": 14 }
        }
        """.data(using: .utf8)!
        let intermediate = try JSONDecoder().decode(ScreenCaptureSettings.self, from: intermediateJSON)
        #expect(intermediate.areaCaptureShortcut == ScreenCaptureShortcutKind.area.defaultBinding)
        #expect(intermediate.repeatAreaCaptureShortcut == ScreenCaptureShortcutKind.repeatArea.defaultBinding)
        #expect(intermediate.fullscreenCaptureShortcut == ScreenCaptureShortcutKind.fullscreen.defaultBinding)
    }

    @Test func settingsReplaceAnUnsafePersistedShortcutWithF1() {
        let settings = ScreenCaptureSettings(
            smartCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])
        )
        #expect(settings.smartCaptureShortcut == .default)
    }

    @Test func storedSmartCaptureRectRoundTripsAndRejectsInvalidSizes() throws {
        let stored = SmartCaptureStoredRect(CGRect(x: -20, y: 42, width: 320, height: 180))
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(SmartCaptureStoredRect.self, from: data)
        #expect(decoded == stored)
        #expect(decoded.isValid)
        #expect(!SmartCaptureStoredRect(CGRect(x: 0, y: 0, width: 3, height: 20)).isValid)
    }

    @Test func smartCaptureClipboardCopiesAnImageAsPNG() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let pasteboard = NSPasteboard(name: .init("MacPilotTests-\(UUID().uuidString)"))
        SmartCaptureClipboard.copy(image: try #require(context.makeImage()), to: pasteboard)
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test func displaySnapshotCropUsesRetinaScaleAndFlippedCoordinates() throws {
        let image = try #require(makeTestImage(width: 200, height: 100, color: .systemBlue))
        let screenFrame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let selection = CGRect(x: 10, y: 5, width: 20, height: 10)

        #expect(SmartDisplaySnapshotCrop.pixelCropRect(
            image: image,
            screenFrame: screenFrame,
            selection: selection
        ) == CGRect(x: 20, y: 70, width: 40, height: 20))

        let cropped = try #require(SmartDisplaySnapshotCrop.crop(
            image: image,
            screenFrame: screenFrame,
            selection: selection
        ))
        #expect(cropped.width == 40)
        #expect(cropped.height == 20)
    }

    @Test func displaySnapshotCropClampsSelectionToDisplayBounds() throws {
        let image = try #require(makeTestImage(width: 100, height: 50, color: .systemRed))
        let cropped = try #require(SmartDisplaySnapshotCrop.crop(
            image: image,
            screenFrame: CGRect(x: 100, y: 200, width: 100, height: 50),
            selection: CGRect(x: 180, y: 230, width: 60, height: 40)
        ))

        #expect(cropped.width == 20)
        #expect(cropped.height == 20)
    }

    @Test func displaySnapshotCropComposesAcrossDisplays() throws {
        let left = try #require(makeTestImage(width: 100, height: 100, color: .systemRed))
        let right = try #require(makeTestImage(width: 100, height: 100, color: .systemBlue))
        let snapshots = [
            SmartDisplaySnapshot(image: left, screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            SmartDisplaySnapshot(image: right, screenFrame: CGRect(x: 100, y: 0, width: 100, height: 100))
        ]

        let composite = try #require(SmartDisplaySnapshotCrop.composite(
            snapshots: snapshots,
            selection: CGRect(x: 50, y: 20, width: 100, height: 40)
        ))
        #expect(composite.width == 100)
        #expect(composite.height == 40)
        let bitmap = NSBitmapImageRep(cgImage: composite)
        let leftPixel = try #require(bitmap.colorAt(x: 0, y: 20)?.usingColorSpace(.deviceRGB))
        let rightPixel = try #require(bitmap.colorAt(x: 99, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(leftPixel.redComponent > 0.8)
        #expect(rightPixel.blueComponent > 0.8)
    }

    @Test func scrollingStitcherFindsStableVerticalOverlap() throws {
        let first = try #require(makeTestImage(width: 40, height: 80, color: .systemBlue))
        let second = try #require(makeTestImage(width: 40, height: 80, color: .systemBlue))
        #expect(ScreenCaptureVerticalStitcher.bestOverlap(previous: first, current: second, minimumOverlap: 8, tolerance: 1) == 79)
    }

    @Test func scrollingStitcherRejectsDifferentWidths() throws {
        let first = try #require(makeTestImage(width: 20, height: 20, color: .systemBlue))
        let second = try #require(makeTestImage(width: 21, height: 20, color: .systemBlue))
        #expect(ScreenCaptureVerticalStitcher.stitch([first, second]) == nil)
    }

    @Test func scrollingStitcherReturnsSingleFrameUnchanged() throws {
        let image = try #require(makeTestImage(width: 20, height: 20, color: .systemRed))
        #expect(ScreenCaptureVerticalStitcher.stitch([image]) === image)
    }

    @Test func historyStoreTrimsAndRemovesMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacPilotHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.png")
        try Data([1, 2, 3]).write(to: url)
        let suiteName = "MacPilotHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = SmartCaptureHistoryItem(url: url, width: 10, height: 20, byteCount: 3)
        SmartCaptureHistoryStore.save([item], defaults: defaults)
        #expect(SmartCaptureHistoryStore.load(defaults: defaults) == [item])
        try FileManager.default.removeItem(at: url)
        #expect(SmartCaptureHistoryStore.load(defaults: defaults).isEmpty)
    }

    @Test func legacyHistoryDefaultsMissingKindToScreenshot() throws {
        let data = Data(#"{"path":"/tmp/legacy-capture.png","width":10,"height":20,"byteCount":3}"#.utf8)
        let item = try JSONDecoder().decode(SmartCaptureHistoryItem.self, from: data)
        #expect(item.kind == .screenshot)
        #expect(item.duration == nil)
    }

    @Test func mediaHistoryRoundTripsKindAndDuration() throws {
        let item = SmartCaptureHistoryItem(
            url: URL(fileURLWithPath: "/tmp/recording.mp4"),
            date: Date(timeIntervalSince1970: 123),
            width: 1920,
            height: 1080,
            byteCount: 456,
            kind: .video,
            duration: 12.5
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SmartCaptureHistoryItem.self, from: data)
        #expect(decoded == item)
        #expect(decoded.kind == .video)
        #expect(decoded.duration == 12.5)
    }

    @Test func mediaHistoryIsSortedAndCappedAtSixtyItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacPilotMediaHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "MacPilotMediaHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let items = try (0..<61).map { index -> SmartCaptureHistoryItem in
            let url = directory.appendingPathComponent("recording-\(index).mp4")
            try Data([UInt8(index & 0xff)]).write(to: url)
            return SmartCaptureHistoryItem(
                url: url,
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                width: 640,
                height: 360,
                byteCount: 1,
                kind: .video,
                duration: TimeInterval(index)
            )
        }
        SmartCaptureHistoryStore.save(items, defaults: defaults)
        let loaded = SmartCaptureHistoryStore.load(defaults: defaults)
        #expect(loaded.count == 60)
        #expect(loaded.first?.duration == 60)
        #expect(loaded.last?.duration == 1)
        #expect(loaded.allSatisfy { $0.kind == .video })
    }

    private func makeTestImage(width: Int, height: Int, color: NSColor) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    @Test func selectionGeometryNormalizesBothDragDirections() {
        #expect(SmartCaptureSelectionGeometry.rect(from: CGPoint(x: 40, y: 80), to: CGPoint(x: 10, y: 20)) == CGRect(x: 10, y: 20, width: 30, height: 60))
        #expect(SmartCaptureSelectionGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 4, height: 4)))
        #expect(!SmartCaptureSelectionGeometry.isMeaningful(CGRect(x: 0, y: 0, width: 3.9, height: 20)))
    }

    @Test func areaSelectionStateCommitsDraggedRectangle() {
        var state = SmartCaptureSelectionState()
        #expect(state.pointerDown(at: CGPoint(x: 240, y: 180), target: nil) == .selectionChanged(.zero))
        #expect(state.pointerDragged(to: CGPoint(x: 80, y: 40)) == .selectionChanged(CGRect(x: 80, y: 40, width: 160, height: 140)))
        #expect(state.pointerUp(at: CGPoint(x: 80, y: 40)) == .commit(CGRect(x: 80, y: 40, width: 160, height: 140)))
        #expect(!state.isDragging)
    }

    @Test func areaSelectionStateSupportsSpaceMoveAndArrowNudge() {
        var state = SmartCaptureSelectionState()
        _ = state.pointerDown(at: CGPoint(x: 100, y: 100), target: nil)
        _ = state.pointerDragged(to: CGPoint(x: 200, y: 180))
        #expect(state.keyDown(keyCode: UInt16(kVK_RightArrow)) == .selectionChanged(CGRect(x: 101, y: 100, width: 100, height: 80)))
        #expect(state.keyDown(keyCode: UInt16(kVK_DownArrow), modifiers: [.shift]) == .selectionChanged(CGRect(x: 101, y: 90, width: 100, height: 80)))
        #expect(state.pointerUp(at: CGPoint(x: 200, y: 180)) == .commit(CGRect(x: 101, y: 90, width: 100, height: 80)))

        var moved = SmartCaptureSelectionState()
        _ = moved.pointerDown(at: CGPoint(x: 100, y: 100), target: nil)
        _ = moved.pointerDragged(to: CGPoint(x: 200, y: 180))
        #expect(moved.keyDown(keyCode: UInt16(kVK_Space)) == .none)
        #expect(moved.pointerDragged(to: CGPoint(x: 220, y: 200)) == .selectionChanged(CGRect(x: 120, y: 120, width: 100, height: 80)))
        moved.keyUp(keyCode: UInt16(kVK_Space))
        #expect(moved.pointerUp(at: CGPoint(x: 220, y: 200)) == .commit(CGRect(x: 120, y: 120, width: 100, height: 80)))
    }

    @Test func areaSelectionStateTogglesApplicationModeAndCommitsWindowTarget() {
        var state = SmartCaptureSelectionState()
        #expect(state.keyDown(keyCode: UInt16(kVK_ANSI_A)) == .modeChanged(.applicationWindow))
        #expect(state.mode == .applicationWindow)
        #expect(state.pointerDown(at: CGPoint(x: 200, y: 200), target: CGRect(x: 40, y: 60, width: 500, height: 300)) == .selectionChanged(.zero))
        #expect(state.pointerUp(at: CGPoint(x: 200, y: 200)) == .commit(CGRect(x: 40, y: 60, width: 500, height: 300)))
    }

    @Test func areaSelectionStateEscapeCancelsAndReturnRequestsRepeat() {
        var state = SmartCaptureSelectionState()
        #expect(state.keyDown(keyCode: UInt16(kVK_Escape)) == .cancel)
        #expect(state.keyDown(keyCode: UInt16(kVK_Return)) == .repeatLastArea)
    }

    @Test func smartAnnotationRendererBurnsRedShapesIntoTheImage() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 200,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let source = try #require(context.makeImage())

        let rendered = try #require(SmartAnnotationRenderer.render(
            image: source,
            annotations: [.rectangle(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))]
        ))
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.75,
                   color.redComponent > color.greenComponent * 1.7,
                   color.redComponent > color.blueComponent * 1.7 {
                    redPixels += 1
                }
            }
        }

        #expect(redPixels > 300)
    }

    @Test func smartAnnotationRendererSupportsSnapzyToolsAndCrop() throws {
        let source = try #require(makeTestImage(width: 200, height: 120, color: .white))
        let rendered = try #require(SmartAnnotationRenderer.render(
            image: source,
            annotations: [
                .ellipse(CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2)),
                .line(CGPoint(x: 0.1, y: 0.3), CGPoint(x: 0.8, y: 0.3)),
                .filledRectangle(CGRect(x: 0.3, y: 0.05, width: 0.2, height: 0.2)),
                .blur(CGRect(x: 0.55, y: 0.05, width: 0.2, height: 0.2)),
                .spotlight(CGRect(x: 0.1, y: 0.45, width: 0.5, height: 0.35)),
                .counter(3, CGPoint(x: 0.75, y: 0.75)),
                .highlighter(CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.8, y: 0.9)),
                .pencil([
                    CGPoint(x: 0.1, y: 0.8),
                    CGPoint(x: 0.2, y: 0.75),
                    CGPoint(x: 0.3, y: 0.8)
                ]),
                .watermark("MacPilot", CGPoint(x: 0.55, y: 0.75))
            ]
        ))
        #expect(rendered.width == source.width)
        #expect(rendered.height == source.height)

        let cropped = try #require(SmartAnnotationRenderer.render(
            image: source,
            annotations: [.crop(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))]
        ))
        #expect(cropped.width == 160)
        #expect(cropped.height == 96)
    }

    @Test func smartAnnotationHistorySupportsUndoAndRedo() {
        var history = SmartAnnotationHistory()
        let rectangle = SmartAnnotation.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let arrow = SmartAnnotation.arrow(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8))

        history.append(rectangle)
        history.append(arrow)
        #expect(history.annotations == [rectangle, arrow])
        #expect(history.undo() == arrow)
        #expect(history.annotations == [rectangle])
        #expect(history.redo() == arrow)
        #expect(history.annotations == [rectangle, arrow])
    }

    @Test func screenCaptureResetUsesCurrentBundleIdentifier() {
        let command = ScreenCaptureResetCommand(bundleIdentifier: "com.misswell.macpilot")

        #expect(command.executableURL == URL(fileURLWithPath: "/usr/bin/tccutil"))
        #expect(command.arguments == ["reset", "ScreenCapture", "com.misswell.macpilot"])
    }

    // MARK: - Busy/idle hour detection

    @Test func normalRangeDetectsBusyHours() {
        let settings = ScreenCaptureSettings(busyStartHour: 9, busyEndHour: 18)
        #expect(settings.isBusyHour(9) == true)
        #expect(settings.isBusyHour(12) == true)
        #expect(settings.isBusyHour(17) == true)
        #expect(settings.isBusyHour(18) == false)
        #expect(settings.isBusyHour(8) == false)
        #expect(settings.isBusyHour(23) == false)
        #expect(settings.isBusyHour(0) == false)
    }

    @Test func wrapAroundMidnightDetectsBusyHours() {
        let settings = ScreenCaptureSettings(busyStartHour: 22, busyEndHour: 6)
        #expect(settings.isBusyHour(22) == true)
        #expect(settings.isBusyHour(23) == true)
        #expect(settings.isBusyHour(0) == true)
        #expect(settings.isBusyHour(3) == true)
        #expect(settings.isBusyHour(5) == true)
        #expect(settings.isBusyHour(6) == false)
        #expect(settings.isBusyHour(12) == false)
        #expect(settings.isBusyHour(21) == false)
    }

    @Test func equalStartAndEndMeansNoBusyPeriod() {
        let settings = ScreenCaptureSettings(busyStartHour: 9, busyEndHour: 9)
        for hour in 0..<24 {
            #expect(settings.isBusyHour(hour) == false, "Hour \(hour) should not be busy when start == end")
        }
    }

    // MARK: - Interval selection

    @Test func busyIntervalUsedDuringBusyHours() {
        let settings = ScreenCaptureSettings(
            busyStartHour: 9, busyEndHour: 18,
            busyIntervalMinutes: 5, idleIntervalMinutes: 30
        )
        let calendar = Calendar.current
        var busyDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        #expect(settings.currentIntervalMinutes(at: busyDate) == 5)

        busyDate = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!
        #expect(settings.currentIntervalMinutes(at: busyDate) == 5)
    }

    @Test func idleIntervalUsedDuringIdleHours() {
        let settings = ScreenCaptureSettings(
            busyStartHour: 9, busyEndHour: 18,
            busyIntervalMinutes: 5, idleIntervalMinutes: 30
        )
        let calendar = Calendar.current
        let idleDate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        #expect(settings.currentIntervalMinutes(at: idleDate) == 30)
    }

    @Test func idleIntervalUsedAtBoundaryEnd() {
        let settings = ScreenCaptureSettings(
            busyStartHour: 9, busyEndHour: 18,
            busyIntervalMinutes: 5, idleIntervalMinutes: 30
        )
        let calendar = Calendar.current
        let boundaryDate = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
        // 18:00 is the first idle hour (busy range is [9, 18))
        #expect(settings.currentIntervalMinutes(at: boundaryDate) == 30)
    }

    // MARK: - Defaults

    @Test func defaultsAreSensible() {
        let settings = ScreenCaptureSettings()
        #expect(settings.isEnabled == false)
        #expect(settings.screenshotEnabled == true)
        #expect(settings.outputFolder == "")
        #expect(settings.busyIntervalMinutes == 10)
        #expect(settings.idleIntervalMinutes == 30)
        #expect(settings.imageFormat == .heic)
        #expect(settings.quality == 0.7)
        #expect(settings.maxRetentionDays == 30)
        #expect(settings.captureAllDisplays == false)
        #expect(settings.showsCursor == true)
        #expect(settings.smartCaptureEnabled == true)
        #expect(settings.smartCaptureShortcut == .default)
        #expect(settings.areaCaptureShortcut == ScreenCaptureShortcutKind.area.defaultBinding)
        #expect(settings.repeatAreaCaptureShortcut == ScreenCaptureShortcutKind.repeatArea.defaultBinding)
        #expect(settings.applicationWindowCaptureShortcut == ScreenCaptureShortcutKind.applicationWindow.defaultBinding)
        #expect(settings.fullscreenCaptureShortcut == ScreenCaptureShortcutKind.fullscreen.defaultBinding)
        #expect(settings.activeWindowCaptureShortcut == ScreenCaptureShortcutKind.activeWindow.defaultBinding)
        #expect(settings.areaAnnotateShortcut == ScreenCaptureShortcutKind.areaAnnotate.defaultBinding)
        #expect(settings.ocrShortcut == ScreenCaptureShortcutKind.ocr.defaultBinding)
        #expect(settings.scrollingCaptureShortcut == ScreenCaptureShortcutKind.scrolling.defaultBinding)
        #expect(settings.objectCutoutShortcut == ScreenCaptureShortcutKind.objectCutout.defaultBinding)
    }

    @Test func qualityIsClampedToValidRange() {
        let high = ScreenCaptureSettings(quality: 2.0)
        #expect(high.quality == 1.0)
        let low = ScreenCaptureSettings(quality: -1.0)
        #expect(low.quality == 0.05)
    }

    @Test func hoursAreClampedToValidRange() {
        let settings = ScreenCaptureSettings(busyStartHour: 30, busyEndHour: -5)
        #expect(settings.busyStartHour == 23)
        #expect(settings.busyEndHour == 0)
    }

    @Test func intervalsAreAtLeastOneMinute() {
        let settings = ScreenCaptureSettings(busyIntervalMinutes: 0, idleIntervalMinutes: -10)
        #expect(settings.busyIntervalMinutes == 1)
        #expect(settings.idleIntervalMinutes == 1)
    }

    // MARK: - Codable round-trip

    @Test func settingsRoundTripThroughCodable() throws {
        let original = ScreenCaptureSettings(
            isEnabled: true,
            outputFolder: "/tmp/screenshots",
            busyStartHour: 8,
            busyEndHour: 20,
            busyIntervalMinutes: 15,
            idleIntervalMinutes: 60,
            imageFormat: .jpeg,
            quality: 0.85,
            maxRetentionDays: 7,
            captureAllDisplays: true,
            showsCursor: false,
            smartCaptureShortcut: SmartCaptureShortcutBinding(keyCode: 0, modifiers: [.command, .shift]),
            areaCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_6), modifiers: [.command, .shift]),
            repeatAreaCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .command]),
            applicationWindowCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option, .command]),
            fullscreenCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_F8), modifiers: [.control]),
            ocrShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_O), modifiers: [.option, .shift])
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ScreenCaptureSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func settingsDecodeFromMinimalJSON() throws {
        // Simulates loading a config written before screen capture existed (all fields absent).
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: json)
        #expect(decoded.isEnabled == false)
        #expect(decoded.screenshotEnabled == true)
        #expect(decoded.busyIntervalMinutes == 10)
        #expect(decoded.imageFormat == .heic)
        #expect(decoded.quality == 0.7)
        #expect(decoded.smartCaptureEnabled == true)
        #expect(decoded.smartCaptureShortcut == .default)
    }

    @Test func smartCaptureSettingsRoundTripWhenDisabled() throws {
        let original = ScreenCaptureSettings(screenshotEnabled: false, smartCaptureEnabled: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: data)

        #expect(decoded.screenshotEnabled == false)
        #expect(decoded.smartCaptureEnabled == false)
    }

    // MARK: - Output folder validation

    @Test func emptyFolderIsInvalid() {
        let settings = ScreenCaptureSettings(outputFolder: "")
        #expect(settings.isOutputFolderValid == false)
    }

    @Test func whitespaceOnlyFolderIsInvalid() {
        let settings = ScreenCaptureSettings(outputFolder: "   ")
        #expect(settings.isOutputFolderValid == false)
    }

    @Test func nonexistentFolderIsInvalid() {
        let settings = ScreenCaptureSettings(outputFolder: "/this/path/should/not/exist/abcdef12345")
        #expect(settings.isOutputFolderValid == false)
    }

    @Test func tempFolderIsValid() {
        let settings = ScreenCaptureSettings(outputFolder: NSTemporaryDirectory())
        #expect(settings.isOutputFolderValid == true)
    }
}
