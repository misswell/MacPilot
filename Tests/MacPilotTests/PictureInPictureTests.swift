import Foundation
import AppKit
import Darwin
import ObjectiveC
import ScreenCaptureKit
import CoreMedia
import Combine
import Testing
@testable import MacPilot

@Suite(.serialized)
struct PictureInPictureTests {
    @Test func defaultsSupportThePipiriStyleHotkeyWorkflow() {
        let settings = PictureInPictureSettings()

        #expect(settings.isEnabled)
        #expect(settings.triggerKey == "p")
        #expect(settings.triggerModifier == .commandOption)
        #expect(settings.triggerShortcutDescription == "⌥⌘P")
        #expect(settings.position == .bottomRight)
        #expect(settings.defaultFrameRate == 10)
        #expect(settings.quickRegionCapture == false)
        #expect(settings.frameRate(for: nil) == 10)
        #expect(settings.occlusionFixBundleIdentifiers.isEmpty)
        #expect(settings.occlusionAutoApply)
    }

    @Test func standardGlobalShortcutMatchesOnlyTheConfiguredCombination() {
        let modifier = PiPShortcutModifier.commandOption

        #expect(modifier.matches(NSEvent.ModifierFlags([.command, .option])))
        #expect(modifier.matches(NSEvent.ModifierFlags([.command, .option, .shift])))
        #expect(modifier.matches(CGEventFlags([.maskCommand, .maskAlternate])))
        #expect(modifier.matches(CGEventFlags([.maskCommand, .maskAlternate, .maskShift])))
        #expect(!modifier.matches(.function))
        #expect(!modifier.matches(.command))
        #expect(!modifier.matches(CGEventFlags([.maskSecondaryFn])))
    }

    @Test @MainActor func menuBarViewsObserveTheLivePictureInPictureModel() {
        let pictureInPicture = PictureInPictureModel()
        let dedicatedMenu = PictureInPictureMenuBarView(pictureInPicture: pictureInPicture)
        let appMenu = MenuBarView(pictureInPicture: pictureInPicture)

        #expect(dedicatedMenu.pictureInPicture === pictureInPicture)
        #expect(appMenu.pictureInPicture === pictureInPicture)

        pictureInPicture.setEnabled(false)
        #expect(!dedicatedMenu.pictureInPicture.settings.isEnabled)
        #expect(!appMenu.pictureInPicture.settings.isEnabled)
    }

    @Test func legacySettingsFallBackToTheStandardGlobalShortcut() throws {
        let data = Data(#"{"triggerKey":"p"}"#.utf8)
        let settings = try JSONDecoder().decode(PictureInPictureSettings.self, from: data)

        #expect(settings.triggerModifier == .commandOption)
        #expect(settings.triggerShortcutDescription == "⌥⌘P")
    }

    @Test func settingsClampUnsafeValuesAndNormalizeTriggerKey() {
        let settings = PictureInPictureSettings(
            triggerKey: "  PiP  ",
            blurAmount: 4,
            cornerRadius: -2,
            defaultFrameRate: 100,
            enhanceContrast: 4,
            aspectRatioLimit: 0,
            detectionThresholdSeconds: 0,
            detectionScriptTimeoutSeconds: 100,
            frameRatesByBundleIdentifier: ["com.example.App": 0]
        )

        #expect(settings.triggerKey == "p")
        #expect(settings.blurAmount == 1)
        #expect(settings.cornerRadius == 0)
        #expect(settings.enhanceContrast == 1)
        #expect(settings.defaultFrameRate == 60)
        #expect(settings.aspectRatioLimit == 1)
        #expect(settings.detectionThresholdSeconds == 1)
        #expect(settings.detectionScriptTimeoutSeconds == 60)
        #expect(settings.frameRate(for: "com.example.App") == 1)
    }

    @Test func legacyBooleanContrastSettingMigratesToARealStrength() throws {
        let data = Data("{\"enhanceContrast\":true}".utf8)
        let settings = try JSONDecoder().decode(PictureInPictureSettings.self, from: data)

        #expect(settings.enhanceContrast == 0.15)
    }

    @Test func frameDifferenceIgnoresTinyMotionUnlessSensitiveDetectionIsEnabled() {
        var base = [UInt8](repeating: 100, count: 64 * 36)
        var tinyMotion = base
        tinyMotion[200] = 130
        tinyMotion[201] = 130
        #expect(!PiPFrameDifference.hasMeaningfulChange(from: base, to: tinyMotion, sensitive: false))
        #expect(PiPFrameDifference.hasMeaningfulChange(from: base, to: tinyMotion, sensitive: true))

        for index in 200..<210 { base[index] = 140 }
        #expect(PiPFrameDifference.hasMeaningfulChange(
            from: [UInt8](repeating: 100, count: 64 * 36),
            to: base,
            sensitive: false
        ))
    }

    @Test @MainActor func manualAndHoverHidingKeepDistinctPipiriSemantics() {
        let source = PiPSource(
            windowID: 1, processID: 1, appName: "Test", bundleIdentifier: "com.example.test",
            title: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let owner = PictureInPictureModel()
        let manual = PiPSession(source: source, region: .fullWindow, settings: .init(), owner: owner)
        manual.toggleHidden()
        #expect(manual.isHidden)
        #expect(manual.hiddenReason == .manual)

        let hover = PiPSession(
            source: source, region: .fullWindow,
            settings: .init(autoHideOnHover: true), owner: owner
        )
        hover.setHovering(true)
        #expect(hover.isHidden)
        #expect(hover.hiddenReason == .hover)
    }

    @Test @MainActor func commandDragZoomsIntoTheSelectedRegion() {
        let source = PiPSource(
            windowID: 2, processID: 1, appName: "Test", bundleIdentifier: "com.example.test",
            title: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let session = PiPSession(
            source: source, region: .fullWindow, settings: .init(), owner: PictureInPictureModel()
        )
        session.beginZoomSelection(at: CGPoint(x: 200, y: 150))
        session.updateZoomSelection(to: CGPoint(x: 400, y: 300), in: CGSize(width: 800, height: 600))
        session.endZoomSelection(in: CGSize(width: 800, height: 600))

        #expect(session.zoomFactor == 4)
        #expect(session.zoomOffset == CGSize(width: 400, height: 300))
        #expect(session.zoomSelection == nil)
    }

    @Test @MainActor func scrollWheelZoomsAndCommandScrollPansThePipSession() {
        let source = PiPSource(
            windowID: 3, processID: 1, appName: "Scroll Test", bundleIdentifier: "com.example.scroll",
            title: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let session = PiPSession(
            source: source, region: .fullWindow, settings: .init(), owner: PictureInPictureModel()
        )

        session.applyScrollWheel(deltaX: 0, deltaY: 10, commandPressed: false)
        #expect(session.zoomFactor == 1.5)

        session.applyScrollWheel(deltaX: 40, deltaY: 30, commandPressed: true)
        #expect(session.zoomOffset == CGSize(width: 40, height: 30))

        session.applyScrollWheel(deltaX: -12, deltaY: 0, commandPressed: false)
        #expect(session.zoomOffset == CGSize(width: 28, height: 30))
    }

    @Test @MainActor func scrollWheelZoomKeepsThePointerContentAnchored() {
        let source = PiPSource(
            windowID: 4, processID: 1, appName: "Anchored Scroll Test", bundleIdentifier: "com.example.anchored-scroll",
            title: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let session = PiPSession(
            source: source, region: .fullWindow, settings: .init(), owner: PictureInPictureModel()
        )
        let viewportSize = CGSize(width: 800, height: 600)
        let mousePoint = CGPoint(x: 700, y: 300)

        session.applyScrollWheel(
            deltaX: 0,
            deltaY: 10,
            commandPressed: false,
            mousePoint: mousePoint,
            viewportSize: viewportSize
        )

        #expect(session.zoomFactor == 1.5)
        #expect(session.zoomOffset == CGSize(width: -150, height: 0))

        session.applyScrollWheel(
            deltaX: 0,
            deltaY: 10,
            commandPressed: false,
            mousePoint: mousePoint,
            viewportSize: viewportSize
        )

        #expect(session.zoomFactor == 2)
        #expect(session.zoomOffset == CGSize(width: -300, height: 0))
    }

    @Test @MainActor func stalledCaptureStateAppearsAfterMotionStopsAndClearsOnChange() async throws {
        let source = PiPSource(
            windowID: 0, processID: 1, appName: "Stall Test", bundleIdentifier: "com.example.stall",
            title: "Static", frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let owner = PictureInPictureModel()
        let session = PiPSession(
            source: source, region: .fullWindow, settings: .init(), owner: owner, stallThreshold: 0.1
        )
        session.start()
        defer { session.close() }
        let first = try #require(makeTestImage(gray: 0.2))
        let second = try #require(makeTestImage(gray: 0.8))
        #expect(PiPFrameDifference.hasMeaningfulChange(
            from: PiPFrameDifference.signature(for: first),
            to: PiPFrameDifference.signature(for: second),
            sensitive: false
        ))
        session.receive(image: first)
        session.receive(image: second)
        try await Task.sleep(for: .milliseconds(250))
        #expect(session.isStalled)

        session.receive(image: first)
        #expect(!session.isStalled)
    }

    @Test func mediaRemoteBridgeLoadsAndAnswersOnTheCurrentSystem() async {
        let bridge = PiPMediaRemoteBridge()

        #expect(bridge.isAvailable)
        _ = await bridge.snapshots()
    }

    @Test @MainActor func screenCaptureKitStreamsPipiriWhenItIsRunning() async throws {
        guard pipLiveScreenCaptureTestsEnabled else { return }
        _ = NSApplication.shared
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.applicationName == "Pipiri" && $0.isOnScreen
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }) else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * 2))
        configuration.height = max(1, Int(window.frame.height * 2))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let collector = PiPTestFrameCollector()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(
            collector, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.misswell.macpilot.tests.pip-frame")
        )
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(1))
        try await stream.stopCapture()

        #expect(collector.sampleCount > 0)
    }

    @Test @MainActor func pipSessionShowsCropsHidesAndRestoresARealPipiriWindow() async throws {
        guard pipLiveScreenCaptureTestsEnabled else { return }
        _ = NSApplication.shared
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.applicationName == "Pipiri" && $0.isOnScreen
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }), let application = window.owningApplication else { return }
        let source = PiPSource(
            windowID: window.windowID,
            processID: application.processID,
            appName: application.applicationName,
            bundleIdentifier: application.bundleIdentifier,
            title: window.title ?? "",
            frame: window.frame
        )
        let owner = PictureInPictureModel()
        let region = PiPRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let session = try #require(owner.createSession(source: source, region: region))
        let duplicate = try #require(owner.createSession(source: source, region: region))
        defer { owner.closeAll() }
        #expect(session === duplicate)
        #expect(owner.summaries.count == 1)
        for _ in 0..<40 where session.image == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        let image = try #require(session.image)
        #expect(abs(image.width - Int(source.frame.width)) <= 2)
        #expect(abs(image.height - Int(source.frame.height)) <= 2)
        #expect(session.panel?.isVisible == true)
        #expect(abs((session.panel?.contentAspectRatio.width ?? 0) - source.frame.width * region.width) < 0.01)

        session.toggleHidden()
        #expect(session.isHidden)
        #expect(session.hiddenReason == .manual)
        #expect(session.panel?.isVisible == false)
        session.toggleHidden()
        #expect(!session.isHidden)
        #expect(session.panel?.isVisible == true)
    }

    @Test @MainActor func pipCaptureScalesTheWindowToFillItsRequestedPixelBuffer() {
        let configuration = PiPSession.captureConfiguration(
            sourceFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            frameRate: 10
        )

        #expect(configuration.width == 1600)
        #expect(configuration.height == 1200)
        #expect(configuration.scalesToFit)
    }

    @Test @MainActor func fullWindowCaptureCapsLargeBackingStoresButKeepsRegionDetail() {
        let sourceFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let fullWindow = PiPSession.captureConfiguration(
            sourceFrame: sourceFrame,
            frameRate: 10
        )
        let region = PiPSession.captureConfiguration(
            sourceFrame: sourceFrame,
            region: PiPRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            frameRate: 10
        )

        #expect(fullWindow.width == 1_600)
        #expect(fullWindow.height == 900)
        #expect(region.width == 3_200)
        #expect(region.height == 1_800)
    }

    @Test @MainActor func repeatedMouseMovementDoesNotRepublishTheSameHoverState() {
        let source = PiPSource(
            windowID: 0,
            processID: 1,
            appName: "Hover Test",
            bundleIdentifier: "com.example.hover",
            title: "Static",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let owner = PictureInPictureModel()
        let session = PiPSession(source: source, region: .fullWindow, settings: .init(), owner: owner)
        var publicationCount = 0
        let observation = session.objectWillChange.sink { publicationCount += 1 }

        session.setHovering(false)
        #expect(publicationCount == 0)
        session.setHovering(true)
        let countAfterTransition = publicationCount
        for _ in 0..<100 { session.setHovering(true) }

        #expect(countAfterTransition > 0)
        #expect(publicationCount == countAfterTransition)
        withExtendedLifetime(observation) {}
    }

    @Test func focusedWindowSelectionSkipsTransientIconSizedWindows() {
        let orderedIDs = PiPWindowSelection.orderedCaptureWindowIDs(from: [
            PiPWindowCandidate(windowID: 11, frame: CGRect(x: 120, y: 300, width: 52, height: 20)),
            PiPWindowCandidate(windowID: 22, frame: CGRect(x: 100, y: 300, width: 920, height: 741)),
            PiPWindowCandidate(windowID: 33, frame: CGRect(x: 70, y: 270, width: 920, height: 741))
        ])

        #expect(orderedIDs == [22, 33])
    }

    @Test @MainActor func handledHoverShortcutIsSuppressedByTheEventTapHandler() async throws {
        guard pipLiveScreenCaptureTestsEnabled else { return }
        _ = NSApplication.shared
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.applicationName == "Pipiri" && $0.isOnScreen
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }), let application = window.owningApplication else { return }
        let source = PiPSource(
            windowID: window.windowID,
            processID: application.processID,
            appName: application.applicationName,
            bundleIdentifier: application.bundleIdentifier,
            title: window.title ?? "",
            frame: window.frame
        )
        let owner = PictureInPictureModel()
        let session = try #require(owner.createSession(source: source, region: .fullWindow))
        defer { owner.closeAll() }
        let originalMouseLocation = NSEvent.mouseLocation
        defer {
            let quartzPoint = PiPCoordinateSpace.quartzPoint(fromAppKit: originalMouseLocation)
            CGWarpMouseCursorPosition(quartzPoint)
        }
        let panel = try #require(session.panel)
        let target = CGPoint(x: originalMouseLocation.x - 80, y: originalMouseLocation.y - 60)
        panel.setFrame(CGRect(origin: target, size: CGSize(width: 160, height: 120)), display: true)
        let mouseTarget = CGPoint(x: target.x + 80, y: target.y + 60)
        CGWarpMouseCursorPosition(PiPCoordinateSpace.quartzPoint(fromAppKit: mouseTarget))
        try await Task.sleep(for: .milliseconds(100))

        let context = PiPEventTapContext(
            owner: Unmanaged.passUnretained(owner).toOpaque(),
            triggerKeyCode: 35
        )
        let keyDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 24, keyDown: true))
        keyDown.flags = []
        let suppressed = pictureInPictureShouldSuppressEvent(.keyDown, event: keyDown, context: context)

        #expect(suppressed)
        #expect(session.zoomFactor == 1.5)
    }

    @Test @MainActor func quickLookHoldPeeksAndEscapeLeavesThePipOpenWhenHandled() async throws {
        guard pipLiveScreenCaptureTestsEnabled else { return }
        _ = NSApplication.shared
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.applicationName == "Pipiri" && $0.isOnScreen
                && $0.frame.width >= 200 && $0.frame.height >= 120
        }), let application = window.owningApplication else { return }
        let source = PiPSource(
            windowID: window.windowID,
            processID: application.processID,
            appName: application.applicationName,
            bundleIdentifier: application.bundleIdentifier,
            title: window.title ?? "",
            frame: window.frame
        )
        let owner = PictureInPictureModel()
        let session = try #require(owner.createSession(source: source, region: .fullWindow))
        defer { owner.closeAll() }
        let panel = try #require(session.panel)
        for _ in 0..<40 where session.image == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try #require(session.image)
        let frame = panel.frame
        let mousePoint = CGPoint(x: frame.midX, y: frame.midY)
        CGWarpMouseCursorPosition(PiPCoordinateSpace.quartzPoint(fromAppKit: mousePoint))
        try await Task.sleep(for: .milliseconds(100))
        let initialWindowCount = pipTestVisibleWindowCount()

        let context = PiPEventTapContext(
            owner: Unmanaged.passUnretained(owner).toOpaque(),
            triggerKeyCode: 35
        )
        let spaceDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        let spaceUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false))
        spaceDown.flags = []
        spaceUp.flags = []
        let spaceDownSuppressed = pictureInPictureShouldSuppressEvent(.keyDown, event: spaceDown, context: context)
        #expect(spaceDownSuppressed)
        for _ in 0..<30 where pipTestVisibleWindowCount() <= initialWindowCount {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(pipTestVisibleWindowCount() > initialWindowCount)

        let escapeDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        escapeDown.flags = []
        let escapeSuppressed = pictureInPictureShouldSuppressEvent(.keyDown, event: escapeDown, context: context)
        let spaceUpSuppressed = pictureInPictureShouldSuppressEvent(.keyUp, event: spaceUp, context: context)
        try await Task.sleep(for: .milliseconds(200))
        #expect(escapeSuppressed)
        #expect(spaceUpSuppressed)
        #expect(owner.summaries.count == 1)
        #expect(pipTestVisibleWindowCount() == initialWindowCount)
    }

    @Test @MainActor func idleDetectionRunsTheConfiguredScriptWithPipiriEnvironment() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-PiP-detection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let bundleIdentifier = "com.example.detection"
        let script = "printf '%s|%s|%s' \"$PIPIRI_EVENT\" \"$PIPIRI_APP\" \"$PIPIRI_BUNDLE_ID\" > \(PiPOcclusionAppPatchService.shellQuote(outputURL.path))"
        let settings = PictureInPictureSettings(
            detectionThresholdSeconds: 1,
            detectionScript: script,
            detectionModesByBundleIdentifier: [bundleIdentifier: .idle]
        )
        let source = PiPSource(
            windowID: 77, processID: 1, appName: "Detection App",
            bundleIdentifier: bundleIdentifier, title: "Static", frame: CGRect(x: 0, y: 0, width: 8, height: 8)
        )
        let session = PiPSession(
            source: source, region: .fullWindow, settings: settings,
            owner: PictureInPictureModel()
        )
        let image = try #require(makeTestImage())
        session.receive(image: image)
        try await Task.sleep(for: .milliseconds(1_100))
        session.receive(image: image)
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: outputURL.path) {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "idle|Detection App|com.example.detection")
    }

    @Test @MainActor func bundledOcclusionLibraryActuallyInstallsItsAppKitHooksWhenAvailable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent(".build"),
            includingPropertiesForKeys: nil
        ), let libraryURL = enumerator.compactMap({ $0 as? URL }).first(where: {
            $0.lastPathComponent == "libMacPilotOcclusionPatch.dylib" && $0.path.contains("debug")
        }) else { return }
        let method = try #require(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.occlusionState)))
        let before = method_getImplementation(method)

        let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL)
        #expect(handle != nil)
        let after = method_getImplementation(method)
        #expect(before != after)
        #expect(NSApplication.shared.occlusionState.contains(.visible))
    }

    @Test func regionConvertsFromScreenCoordinatesUsingTopLeftOrigin() {
        let window = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let region = PiPRegion.fromScreenRect(CGRect(x: 100, y: 200, width: 400, height: 300), in: window)

        #expect(region != nil)
        #expect(abs((region?.x ?? 0) - 0.1) < 0.0001)
        #expect(abs((region?.y ?? 0) - 0.375) < 0.0001)
        #expect(abs((region?.width ?? 0) - 0.4) < 0.0001)
        #expect(abs((region?.height ?? 0) - 0.375) < 0.0001)
    }

    @Test func quartzWindowFrameConvertsToAppKitBottomLeftCoordinates() {
        let quartzScreen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let appKitScreen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let quartzWindow = CGRect(x: 73, y: 273, width: 920, height: 741)

        let appKitWindow = PiPCoordinateSpace.appKitRect(
            fromQuartz: quartzWindow,
            quartzScreen: quartzScreen,
            appKitScreen: appKitScreen
        )

        #expect(appKitWindow == CGRect(x: 73, y: 66, width: 920, height: 741))
    }

    @Test func appKitMousePointConvertsToQuartzTopLeftCoordinates() {
        let quartzScreen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let appKitScreen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

        let point = PiPCoordinateSpace.quartzPoint(
            fromAppKit: CGPoint(x: 400, y: 120),
            quartzScreen: quartzScreen,
            appKitScreen: appKitScreen
        )

        #expect(point == CGPoint(x: 400, y: 960))
    }

    @Test func localSelectionConvertsFromAppKitToTopLeftRegion() {
        let region = PiPRegion.fromSelectionRect(
            CGRect(x: 100, y: 200, width: 400, height: 300),
            windowSize: CGSize(width: 1_000, height: 800)
        )

        #expect(region == PiPRegion(x: 0.1, y: 0.375, width: 0.4, height: 0.375))
    }

    @Test func regionRoundTripsThroughCodable() throws {
        let original = PiPRegion(x: 0.2, y: 0.15, width: 0.5, height: 0.4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PiPRegion.self, from: data)

        #expect(decoded == original)
    }

    @Test func regionAspectRatioLimitKeepsTheSelectionCentered() {
        let original = PiPRegion(x: 0.1, y: 0.2, width: 0.8, height: 0.2)
        let limited = original.limited(aspectRatioLimit: 3)

        #expect(abs(limited.width / limited.height - 3) < 0.0001)
        #expect(abs(limited.x - 0.2) < 0.0001)
        #expect(limited.y == original.y)
    }

    @Test func nowPlayingSnapshotMatchesTheCapturedProcessOrParentBundle() {
        let source = PiPSource(
            windowID: 42,
            processID: 123,
            appName: "Browser",
            bundleIdentifier: "com.example.browser",
            title: "Video",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let sameProcess = PiPNowPlayingSnapshot(
            isPlaying: true, processIdentifier: 123, bundleIdentifier: nil, parentBundleIdentifier: nil,
            title: "Video", artist: nil, album: nil, duration: 120, elapsedTime: 10,
            timestamp: nil, playbackRate: 1
        )
        let browserHelper = PiPNowPlayingSnapshot(
            isPlaying: true, processIdentifier: 999, bundleIdentifier: "com.example.browser.helper",
            parentBundleIdentifier: "com.example.browser", title: "Video", artist: nil, album: nil,
            duration: 120, elapsedTime: 10, timestamp: nil, playbackRate: 1
        )

        #expect(sameProcess.belongs(to: source))
        #expect(browserHelper.belongs(to: source))
    }

    @Test func nowPlayingElapsedTimeAdvancesAndClampsToDuration() {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let snapshot = PiPNowPlayingSnapshot(
            isPlaying: true, processIdentifier: 1, bundleIdentifier: nil, parentBundleIdentifier: nil,
            title: nil, artist: nil, album: nil, duration: 12, elapsedTime: 10,
            timestamp: timestamp, playbackRate: 1
        )

        #expect(snapshot.liveElapsedTime(at: timestamp.addingTimeInterval(1)) == 11)
        #expect(snapshot.liveElapsedTime(at: timestamp.addingTimeInterval(10)) == 12)
    }

    @Test func occlusionSettingsRoundTripThroughCodable() throws {
        let original = PictureInPictureSettings(
            occlusionFixBundleIdentifiers: ["com.google.Chrome", "com.microsoft.VSCode"],
            occlusionAutoApply: false,
            occlusionCustomApplicationPaths: ["com.example.Custom": "/Applications/Custom.app"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PictureInPictureSettings.self, from: data)

        #expect(decoded == original)
    }

    @Test func occlusionFixSupportsKnownChromiumAndElectronApps() {
        let bundleIdentifiers = Set(PiPOcclusionController.supportedApplications.map(\.bundleIdentifier))

        #expect(bundleIdentifiers.contains("com.google.Chrome"))
        #expect(bundleIdentifiers.contains("com.microsoft.edgemac"))
        #expect(bundleIdentifiers.contains("com.microsoft.VSCode"))
        #expect(bundleIdentifiers.contains("com.tinyspeck.slackmacgap"))
    }

    @Test func customPatchIncludesKnownCompositorAppsAndQuotesPathsSafely() {
        let bundleIdentifiers = Set(PiPOcclusionAppPatchService.supportedApplications.map(\.bundleIdentifier))

        #expect(bundleIdentifiers.contains("org.mozilla.firefox"))
        #expect(bundleIdentifiers.contains("net.kovidgoyal.kitty"))
        #expect(bundleIdentifiers.contains("com.mitchellh.ghostty"))
        #expect(PiPOcclusionAppPatchService.shellQuote("/tmp/It's App.app") == "'/tmp/It'\\''s App.app'")
    }

    @Test func occlusionRelaunchUsesOnlyTheBackgroundRenderingArgument() {
        let arguments = PiPOcclusionController.launchArguments()

        #expect(arguments == ["--disable-backgrounding-occluded-windows"])
    }

    @Test @MainActor func occlusionControllerReallyLaunchesAnAppWithTheRenderingArgument() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-Launch-Argument-Audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("ArgumentRecorder.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let bundleIdentifier = "com.misswell.macpilot.tests.argument-recorder.\(UUID().uuidString)"
        let outputURL = root.appendingPathComponent("arguments.txt")
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "ArgumentRecorder",
            "CFBundleExecutable": "ArgumentRecorder",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("ArgumentRecorder")
        let script = "#!/bin/zsh\nprintf '%s\\n' \"$@\" > \(PiPOcclusionAppPatchService.shellQuote(outputURL.path))\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try signTestApplication(appURL)

        let controller = PiPOcclusionController()
        let application = PiPOcclusionApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: "ArgumentRecorder",
            applicationURL: appURL,
            isRunning: false,
            isEnabled: true
        )
        controller.relaunch(application)
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: outputURL.path) {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(try String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "--disable-backgrounding-occluded-windows")
        #expect(controller.errorMessage == nil)
    }

    @Test func machOInjectorAddsAnIdempotentLoadCommand() throws {
        let executable = syntheticMachOExecutable()
        let patched = try MachODylibInjector.injectingLoadCommand(into: executable)

        #expect(try MachODylibInjector.containsLoadCommand(in: patched))
        #expect(try MachODylibInjector.injectingLoadCommand(into: patched) == patched)
        #expect(patched.count == executable.count)
    }

    @Test func machOInjectorAcceptsAnInstalledFirefoxExecutableWhenAvailable() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox")
        guard FileManager.default.fileExists(atPath: executableURL.path) else { return }
        let executable = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let patched = try MachODylibInjector.injectingLoadCommand(into: executable)

        #expect(try MachODylibInjector.containsLoadCommand(in: patched))
        #expect(patched.count == executable.count)
    }

    @Test func customAppPatchBacksUpPatchesAndRestoresAPackagedAppWhenAvailable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let packagedApp = root.appendingPathComponent("MacPilot.app", isDirectory: true)
        let patchLibrary = packagedApp.appendingPathComponent(
            "Contents/Resources/libMacPilotOcclusionPatch.dylib"
        )
        guard FileManager.default.fileExists(atPath: patchLibrary.path) else { return }

        let temporaryRoot = root.appendingPathComponent(
            ".build/PatchIntegration-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let testApp = temporaryRoot.appendingPathComponent("MacPilot.app", isDirectory: true)
        try FileManager.default.copyItem(at: packagedApp, to: testApp)
        let executable = testApp.appendingPathComponent("Contents/MacOS/MacPilot")
        let originalData = try Data(contentsOf: executable)
        let backupRoot = temporaryRoot.appendingPathComponent("Backups", isDirectory: true)

        try PiPOcclusionAppPatchService.patch(
            applicationURL: testApp,
            expectedBundleIdentifier: "com.misswell.macpilot",
            patchLibraryURL: patchLibrary,
            backupRootURL: backupRoot
        )
        #expect(try PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))

        try PiPOcclusionAppPatchService.restore(
            applicationURL: testApp,
            expectedBundleIdentifier: "com.misswell.macpilot",
            backupRootURL: backupRoot
        )
        #expect(try !PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))
        #expect(try Data(contentsOf: executable) == originalData)
    }

    @Test @MainActor func fileSystemEventsReapplyAPatchAfterAnApplicationUpdate() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let packagedApp = root.appendingPathComponent("MacPilot.app", isDirectory: true)
        let patchLibrary = packagedApp.appendingPathComponent(
            "Contents/Resources/libMacPilotOcclusionPatch.dylib"
        )
        guard FileManager.default.fileExists(atPath: patchLibrary.path) else { return }

        let bundleIdentifier = "com.misswell.macpilot.patch-audit.\(UUID().uuidString)"
        let temporaryRoot = root.appendingPathComponent(
            ".build/FSEventsPatchIntegration-\(UUID().uuidString)", isDirectory: true
        )
        let testApp = temporaryRoot.appendingPathComponent("PatchAudit.app", isDirectory: true)
        let backup = PiPOcclusionAppPatchService.backupURL(bundleIdentifier: bundleIdentifier)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: packagedApp, to: testApp)
        let infoPlist = testApp.appendingPathComponent("Contents/Info.plist")
        var info = try #require(NSDictionary(contentsOf: infoPlist) as? [String: Any])
        info["CFBundleIdentifier"] = bundleIdentifier
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: infoPlist)
        try signTestApplication(testApp)
        try PiPOcclusionAppPatchService.patch(
            applicationURL: testApp,
            expectedBundleIdentifier: bundleIdentifier,
            patchLibraryURL: patchLibrary
        )
        #expect(try PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))

        let controller = PiPOcclusionController()
        controller.applySettings(
            enabledBundleIdentifiers: [bundleIdentifier],
            autoApply: true,
            customApplicationPaths: [bundleIdentifier: testApp.path]
        )
        controller.activate()
        defer { controller.shutdown() }

        try FileManager.default.removeItem(at: testApp)
        try FileManager.default.copyItem(at: backup, to: testApp)
        #expect(try !PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))
        for _ in 0..<80 where (try? PiPOcclusionAppPatchService.isPatched(applicationURL: testApp)) != true {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(try PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))
        #expect(controller.errorMessage == nil)
    }

    @Test func isolatedFirefoxCopyLoadsTheRealOcclusionPatchWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["MACPILOT_RUN_FIREFOX_PATCH_AUDIT"] == "1" else { return }
        let firefox = URL(fileURLWithPath: "/Applications/Firefox.app", isDirectory: true)
        let patchLibrary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MacPilot.app/Contents/Resources/libMacPilotOcclusionPatch.dylib")
        guard FileManager.default.fileExists(atPath: firefox.path),
              FileManager.default.fileExists(atPath: patchLibrary.path) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-Firefox-Patch-Audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let testApp = root.appendingPathComponent("Firefox.app", isDirectory: true)
        try FileManager.default.copyItem(at: firefox, to: testApp)
        let backupRoot = root.appendingPathComponent("Backups", isDirectory: true)

        try PiPOcclusionAppPatchService.patch(
            applicationURL: testApp,
            expectedBundleIdentifier: "org.mozilla.firefox",
            patchLibraryURL: patchLibrary,
            backupRootURL: backupRoot
        )
        #expect(try PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))
        let process = Process()
        process.executableURL = testApp.appendingPathComponent("Contents/MacOS/firefox")
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(text.localizedCaseInsensitiveContains("Firefox"))

        try PiPOcclusionAppPatchService.restore(
            applicationURL: testApp,
            expectedBundleIdentifier: "org.mozilla.firefox",
            backupRootURL: backupRoot
        )
        #expect(try !PiPOcclusionAppPatchService.isPatched(applicationURL: testApp))
    }

    private func syntheticMachOExecutable() -> Data {
        var data = Data(repeating: 0, count: 8_192)
        writeLittleEndian(0xfeedfacf, to: &data, at: 0)
        writeLittleEndian(0x0100000c, to: &data, at: 4)
        writeLittleEndian(0, to: &data, at: 8)
        writeLittleEndian(2, to: &data, at: 12)
        writeLittleEndian(1, to: &data, at: 16)
        writeLittleEndian(72, to: &data, at: 20)
        writeLittleEndian(0, to: &data, at: 24)
        writeLittleEndian(0, to: &data, at: 28)
        writeLittleEndian(0x19, to: &data, at: 32)
        writeLittleEndian(72, to: &data, at: 36)
        writeLittleEndian(4_096, to: &data, at: 72)
        return data
    }

    private func writeLittleEndian(_ value: UInt32, to data: inout Data, at offset: Int) {
        for byte in 0..<4 {
            data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8))
        }
    }

    private func makeTestImage(gray: CGFloat = 0.5) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()
    }

    private func signTestApplication(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }
}

private final class PiPTestFrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0

    var sampleCount: Int {
        lock.withLock { samples }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        lock.withLock {
            guard outputType == .screen else { return }
            samples += 1
        }
    }
}

private var pipLiveScreenCaptureTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["MACPILOT_RUN_LIVE_SCREEN_CAPTURE_TESTS"] == "1"
}

private func pipTestVisibleWindowCount() -> Int {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[CFString: Any]] else { return 0 }
    return info.reduce(into: 0) { count, window in
        guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == getpid() else { return }
        count += 1
    }
}
