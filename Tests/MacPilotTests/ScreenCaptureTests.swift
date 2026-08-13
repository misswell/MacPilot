import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import Testing
@testable import MacPilot

struct ScreenCaptureTests {

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

    @Test func shortcutEventRoutingFindsTheConfiguredAreaBinding() {
        let bindings = [
            SmartCaptureShortcutEventBinding(
                id: 3,
                binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])
            ),
            SmartCaptureShortcutEventBinding(
                id: 4,
                binding: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .shift])
            )
        ]

        #expect(SmartCaptureShortcutRouting.matchingID(
            keyCode: UInt16(kVK_ANSI_4),
            flags: [.maskCommand, .maskShift],
            isRepeat: false,
            bindings: bindings
        ) == 3)
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
        #expect(ScreenCaptureShortcutKind.area.defaultBinding.displayName == "⇧⌘4")
        #expect(ScreenCaptureShortcutKind.fullscreen.defaultBinding.displayName == "⇧⌘3")
        #expect(ScreenCaptureShortcutKind.activeWindow.defaultBinding.displayName == "⇧⌘9")
        #expect(ScreenCaptureShortcutKind.areaAnnotate.defaultBinding.displayName == "⇧⌘7")
        #expect(ScreenCaptureShortcutKind.ocr.defaultBinding.displayName == "⇧⌘2")

        let settings = ScreenCaptureSettings(
            areaCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_6), modifiers: [.command, .option]),
            fullscreenCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_F8), modifiers: [.control]),
            activeWindowCaptureShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option, .command]),
            areaAnnotateShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .shift]),
            ocrShortcut: SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command, .shift])
        )
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.areaCaptureShortcut == settings.areaCaptureShortcut)
        #expect(decoded.fullscreenCaptureShortcut == settings.fullscreenCaptureShortcut)
        #expect(decoded.activeWindowCaptureShortcut == settings.activeWindowCaptureShortcut)
        #expect(decoded.areaAnnotateShortcut == settings.areaAnnotateShortcut)
        #expect(decoded.ocrShortcut == settings.ocrShortcut)
    }

    @Test @MainActor func screenCaptureModelAppliesAndPersistsEveryShortcutKind() {
        let model = ScreenCaptureModel()
        model.setSmartCaptureEnabled(false)
        var didPersist = false
        model.persist = { didPersist = true }

        let bindings: [(ScreenCaptureShortcutKind, SmartCaptureShortcutBinding)] = [
            (.smartElement, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_F8), modifiers: [])),
            (.area, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option])),
            (.fullscreen, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command, .shift])),
            (.activeWindow, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])),
            (.areaAnnotate, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.control, .shift])),
            (.ocr, SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .control]))
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
        #expect(decoded.fullscreenCaptureShortcut == ScreenCaptureShortcutKind.fullscreen.defaultBinding)
        #expect(decoded.activeWindowCaptureShortcut == ScreenCaptureShortcutKind.activeWindow.defaultBinding)
        #expect(decoded.areaAnnotateShortcut == ScreenCaptureShortcutKind.areaAnnotate.defaultBinding)
        #expect(decoded.ocrShortcut == ScreenCaptureShortcutKind.ocr.defaultBinding)
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
        #expect(settings.fullscreenCaptureShortcut == ScreenCaptureShortcutKind.fullscreen.defaultBinding)
        #expect(settings.activeWindowCaptureShortcut == ScreenCaptureShortcutKind.activeWindow.defaultBinding)
        #expect(settings.areaAnnotateShortcut == ScreenCaptureShortcutKind.areaAnnotate.defaultBinding)
        #expect(settings.ocrShortcut == ScreenCaptureShortcutKind.ocr.defaultBinding)
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
        #expect(decoded.busyIntervalMinutes == 10)
        #expect(decoded.imageFormat == .heic)
        #expect(decoded.quality == 0.7)
        #expect(decoded.smartCaptureEnabled == true)
        #expect(decoded.smartCaptureShortcut == .default)
    }

    @Test func smartCaptureSettingsRoundTripWhenDisabled() throws {
        let original = ScreenCaptureSettings(smartCaptureEnabled: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenCaptureSettings.self, from: data)

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
