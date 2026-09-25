import CoreGraphics
import Foundation
import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
@testable import MacPilot

/// Geometry coverage for the source-migrated Snapzy frozen-display pipeline.
struct SnapzyCaptureTests {
    @Test func interactiveDisplayCaptureIncludesMacPilotWindows() {
        #expect(!SnapzyCaptureApplicationVisibilityPolicy.excludesOwnApplicationFromDisplaySnapshot)
    }

    /// Window recognition must reach MacPilot's own windows while its capture
    /// chrome — which is always presented above ordinary windows — stays unlisted.
    @Test func applicationWindowTargetsAcceptMacPilotWindowsButNotItsOverlayPanels() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        func kind(windowLayer: Int, frame: CGRect) -> WindowCaptureTargetKind? {
            WindowCaptureSelectionPolicy.targetKind(
                windowLayer: windowLayer,
                frame: frame,
                visibleFrame: visibleFrame,
                alpha: 1,
                isOwnApplication: true,
                isSystemOwned: false
            )
        }

        #expect(kind(windowLayer: 0, frame: CGRect(x: 120, y: 90, width: 900, height: 620)) == .normal)
        #expect(kind(windowLayer: 1_000, frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)) == nil)
    }

    @Test @MainActor func singleFrameCaptureConfigurationKeepsOnlyOneQueuedFrame() {
        let configuration = SnapzyCaptureConfiguration.display(
            width: 1_920,
            height: 1_080,
            showsCursor: false,
            colorSpaceName: nil
        )

        #expect(configuration.queueDepth == 1)
        #expect(configuration.queueDepth == SnapzyCaptureConfiguration.singleFrameQueueDepth)
    }

    @Test func terminalActionsCommitTheInlineAnnotationSession() {
        // While the chrome-less session is live every terminal action commits:
        // pin, copy, save, OCR and upload all render and route the image.
        for action: AreaSelectionAction in [.pin, .copy, .save, .ocr, .upload, .capture] {
            #expect(
                SnapzyInlineAnnotationShortcutRouting.shouldCommitInlineAnnotation(
                    action: action,
                    hasInlineAnnotationEditor: true
                ),
                "expected \(action) to commit the live session"
            )
        }
        // Without a live session nothing is intercepted.
        #expect(!SnapzyInlineAnnotationShortcutRouting.shouldCommitInlineAnnotation(
            action: .pin,
            hasInlineAnnotationEditor: false
        ))
        // Non-terminal HUD actions never end the session.
        for action: AreaSelectionAction in [.toggleRoundedCorners, .toggleShadow, .refreshCapture, .newSelection] {
            #expect(
                !SnapzyInlineAnnotationShortcutRouting.shouldCommitInlineAnnotation(
                    action: action,
                    hasInlineAnnotationEditor: true
                ),
                "expected \(action) to keep the session alive"
            )
        }
    }

    @Test @MainActor func pinShortcutPastesClipboardWithoutStartingSelection() {
        var didInvokeClipboardPin = false
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { false },
            pinClipboardShortcutOverride: {
                didInvokeClipboardPin = true
            }
        )
        defer { controller.stop() }

        controller.handleShortcutEvent(id: 12)

        #expect(didInvokeClipboardPin)
    }

    @Test @MainActor func clipboardPinReaderAcceptsImagesAndRejectsText() throws {
        let pasteboard = NSPasteboard(name: .init("MacPilotTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("text only", forType: .string)
        #expect(SmartCaptureClipboard.image(from: pasteboard) == nil)

        let sourceImage = image(width: 4, height: 3)
        let pngData = try #require(
            NSBitmapImageRep(cgImage: sourceImage).representation(using: .png, properties: [:])
        )
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)

        let pastedImage = try #require(SmartCaptureClipboard.image(from: pasteboard))
        #expect(pastedImage.image.width == sourceImage.width)
        #expect(pastedImage.image.height == sourceImage.height)
        #expect(pastedImage.scaleFactor == 1)
    }

    @Test @MainActor func clipboardPinReaderHonoursTheDeclaredImageDensity() throws {
        // Retina 截图的 PNG 写着 144 DPI，那是 2 倍像素密度。贴图必须按声明的
        // 密度换算成点，否则一张 150x100 点的截图会以 300x200 打开 —— 小图放大。
        let sourceImage = image(width: 300, height: 200)
        let pasteboard = NSPasteboard(name: .init("MacPilotTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(
            try #require(pngData(from: sourceImage, dpi: 144)),
            forType: .png
        )

        let pasted = try #require(SmartCaptureClipboard.image(from: pasteboard))
        #expect(pasted.image.width == 300)
        #expect(pasted.scaleFactor == 2)
    }

    private func pngData(from source: CGImage, dpi: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = dpi.map {
            [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, source, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private final class InitialTargetResolverRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var observedMainThread: Bool?

        func record() {
            lock.lock()
            observedMainThread = Thread.isMainThread
            lock.unlock()
        }

        var result: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return observedMainThread
        }
    }

    private func image(width: Int, height: Int, color: CGColor = CGColor(gray: 0.5, alpha: 1)) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pngData(from image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private final class OverlaySelectionRecorder: AreaSelectionOverlayViewDelegate {
        var manualBegan: [CGPoint] = []
        var manualChanged: [CGPoint] = []
        var manualEnded: [CGPoint] = []
        var displayActivationRequests = 0

        func overlayView(
            _ view: AreaSelectionOverlayView,
            manualSelectionBeganAt point: CGPoint
        ) {
            manualBegan.append(point)
        }

        func overlayView(
            _ view: AreaSelectionOverlayView,
            manualSelectionChangedTo point: CGPoint
        ) {
            manualChanged.append(point)
        }

        func overlayView(
            _ view: AreaSelectionOverlayView,
            manualSelectionEndedAt point: CGPoint
        ) {
            manualEnded.append(point)
        }

        func overlayView(_ view: AreaSelectionOverlayView, didSelectRect rect: CGRect) {}
        func overlayView(_ view: AreaSelectionOverlayView, didSelectWindow target: WindowCaptureTarget) {}
        func overlayView(_ view: AreaSelectionOverlayView, didRequestAction action: AreaSelectionAction) {}
        func overlayView(_ view: AreaSelectionOverlayView, didChangeSelectionRect rect: CGRect) {}
        func overlayViewDidCancel(_ view: AreaSelectionOverlayView) {}
        func overlayViewDidRequestDisplayActivation(_ view: AreaSelectionOverlayView) {
            displayActivationRequests += 1
        }
        func overlayViewDidRequestImmediateManualSelection(_ view: AreaSelectionOverlayView) {}
    }

    @Test func frozenSnapshotCropUsesNativePixelScaleAndScreenCoordinates() throws {
        let snapshot = FrozenDisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            colorSpaceName: nil,
            image: image(width: 200, height: 200)
        )
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 10, y: 20, width: 30, height: 25)),
            displayID: 1,
            mode: .screenshot
        )

        let result = try session.cropImage(for: selection)
        #expect(result.image.width == 60)
        #expect(result.image.height == 50)
        #expect(result.screenRect == CGRect(x: 10, y: 20, width: 30, height: 25))
    }

    @Test func invalidatingFrozenSessionReleasesItsSnapshots() {
        let snapshot = FrozenDisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            colorSpaceName: nil,
            image: image(width: 200, height: 200)
        )
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)

        #expect(!session.allSnapshots().isEmpty)
        session.invalidate()

        #expect(session.allSnapshots().isEmpty)
        #expect(session.backdrops.isEmpty)
    }

    @Test func frozenSnapshotCompositeCropsAcrossDisplays() throws {
        let left = FrozenDisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 1,
            colorSpaceName: nil,
            image: image(width: 100, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        )
        let right = FrozenDisplaySnapshot(
            displayID: 2,
            screenFrame: CGRect(x: 100, y: 0, width: 100, height: 100),
            scaleFactor: 1,
            colorSpaceName: nil,
            image: image(width: 100, height: 100, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        )
        let session = FrozenAreaCaptureSession.fromSnapshots([left, right])
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 50, y: 10, width: 100, height: 20)),
            displayID: 1,
            mode: .screenshot,
            displayIDs: [1, 2]
        )

        let result = try session.cropCompositeImage(for: selection)
        #expect(result.image.width == 100)
        #expect(result.image.height == 20)
        #expect(result.screenRect == CGRect(x: 50, y: 10, width: 100, height: 20))
    }

    @Test @MainActor func areaSelectionWindowIsPresentedBeforeFrozenBackdropCompletes() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }

        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true }
        )
        let delayedImage = image(width: 1, height: 1)
        let delayedPreparation: @MainActor () async throws -> FrozenAreaCaptureSession = {
            try await Task.sleep(for: .milliseconds(150))
            return FrozenAreaCaptureSession.fromSnapshot(
                FrozenDisplaySnapshot(
                    displayID: NSScreen.main?.displayID ?? 1,
                    screenFrame: NSScreen.main?.frame ?? .zero,
                    scaleFactor: 1,
                    colorSpaceName: nil,
                    image: delayedImage
                )
            )
        }

        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let startedAt = Date()
        controller.startSnapzySelection(mode: .manualArea, preparation: delayedPreparation)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 0.1)
        #expect(SnapzyAreaSelectionController.shared.isPresenting)
    }

    @Test @MainActor func activeSelectionPanelUsesOneCombinedPresentationStep() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }

        let controller = SnapzyAreaSelectionController.shared
        controller.cancelSelection()
        defer { controller.cancelSelection() }

        _ = controller.startSelection { _ in }
        let pointer = NSEvent.mouseLocation
        let activeWindow = controller.testWindows.first(where: { $0.frame.contains(pointer) })
            ?? controller.testWindows.first
        let events = try #require(activeWindow?.testPresentationEvents)

        // Showing the active panel with separate orderFront + makeKey calls
        // creates an extra WindowServer composition step in the shortcut's
        // first run-loop turn and is the source of the initial screen flash.
        #expect(events.first == "makeKeyAndOrderFront")
        #expect(!events.contains("orderFrontRegardless"))
    }

    @Test @MainActor func postSelectionToolbarStaysAnchoredToTheSelectedFrame() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let selectionRect = CGRect(
            x: screen.frame.minX + screen.frame.width * 0.28,
            y: screen.frame.minY + screen.frame.height * 0.42,
            width: screen.frame.width * 0.32,
            height: screen.frame.height * 0.18
        )
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { _ in }
        )

        let toolbar = try #require(
            window.overlayView.subviews.first(where: { $0 is AreaSelectionActionBar })
        )
        let localSelection = CGRect(
            x: selectionRect.minX - screen.frame.minX,
            y: selectionRect.minY - screen.frame.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        #expect(toolbar.frame.midX == localSelection.midX)
        #expect(toolbar.frame.maxY < localSelection.minY || toolbar.frame.minY > localSelection.maxY)
    }

    @Test @MainActor func firstPostSelectionButtonStartsRectangleAnnotation() throws {
        _ = NSApplication.shared
        var requestedAction: AreaSelectionAction?
        let bar = AreaSelectionActionBar { requestedAction = $0 }

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }

        let rectangleButton = try #require(
            buttons(in: bar).first(where: {
                $0.toolTip == AppText.value("scAnnotationRectangle", language: .system)
            })
        )
        rectangleButton.performClick(nil)

        #expect(requestedAction == .annotateTool(.rectangle))
    }

    @Test @MainActor func moreMenuCarriesTheFormerSideBarCommands() throws {
        _ = NSApplication.shared
        var requestedActions: [AreaSelectionAction] = []
        let bar = AreaSelectionActionBar { requestedActions.append($0) }

        func item(_ titleKey: String) throws -> NSMenuItem {
            let title = AppText.value(titleKey, language: .system)
            return try #require(bar.makeMoreMenu().items.first { $0.title == title })
        }

        // 原右侧竖栏的命令现在都在「更多」菜单里，逐条路由到同一个动作回调。
        bar.handleMoreItem(tag: try item("scAdjustSelection").tag)
        bar.handleMoreItem(tag: try item("scToolRefresh").tag)
        bar.handleMoreItem(tag: try item("scToolReselect").tag)
        bar.handleMoreItem(tag: try item("scToolRoundedCorners").tag)
        bar.handleMoreItem(tag: try item("scToolShadow").tag)

        #expect(requestedActions == [
            .adjustSelection,
            .refreshCapture,
            .newSelection,
            .toggleRoundedCorners,
            .toggleShadow,
        ])
    }

    @Test @MainActor func moreMenuTicksTheOutputStyleStateItMirrors() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }

        func state(_ titleKey: String) throws -> NSControl.StateValue {
            let title = AppText.value(titleKey, language: .system)
            return try #require(bar.makeMoreMenu().items.first { $0.title == title }).state
        }

        #expect(try state("scToolRoundedCorners") == .off)
        #expect(try state("scToolShadow") == .off)

        bar.outputStyleState = (roundedCorners: true, shadow: false)
        #expect(try state("scToolRoundedCorners") == .on)
        #expect(try state("scToolShadow") == .off)
    }

    @Test @MainActor func moreMenuKeepsOnlyStyleTogglesDuringALiveAnnotationSession() throws {
        _ = NSApplication.shared
        var committedActions: [AreaSelectionAction] = []
        let bar = AreaSelectionActionBar { _ in }
        // The binding holds the model weakly, so the session only counts as
        // live while the test keeps the model alive.
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { action in
            committedActions.append(action)
        })

        let titles = bar.makeMoreMenu().items.map(\.title)
        let styleTitles = ["scToolRoundedCorners", "scToolShadow"].map {
            AppText.value($0, language: .system)
        }
        // 样式开关是非终止动作，标注会话中保留并走会话提交。
        for title in styleTitles {
            #expect(titles.contains(title))
        }
        // 画布接管了选区：改框/刷新/重选/裁剪在会话中没有意义，不再展示
        // （此前它们留在界面上但点了没反应）。
        for titleKey in ["scAdjustSelection", "scToolRefresh", "scToolReselect", "scAnnotationCrop"] {
            #expect(!titles.contains(AppText.value(titleKey, language: .system)))
        }

        let rounded = try #require(
            bar.makeMoreMenu().items.first { $0.title == AppText.value("scToolRoundedCorners", language: .system) }
        )
        bar.handleMoreItem(tag: rounded.tag)
        #expect(committedActions == [.toggleRoundedCorners])
    }

    /// Flattens a resolved colour to comparable integers. Layer colours are
    /// concrete `CGColor`s, so both sides have to be resolved under the same
    /// appearance before they can be compared at all.
    private func chromeComponents(_ color: CGColor?) -> [Int] {
        guard let color,
              let resolved = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [] }
        return [
            resolved.redComponent, resolved.greenComponent,
            resolved.blueComponent, resolved.alphaComponent,
        ].map { Int(($0 * 1_000).rounded()) }
    }

    /// Every Swift file that draws the pinned-screenshot surface, with comment
    /// lines stripped.  A pin may *talk about* the capture palette in a doc
    /// comment; what must not happen is it reading its geometry or colours from
    /// it, because then retuning the toolbar retunes the pin.
    private var pinSurfaceSources: [(file: String, code: String)] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/MacPilotTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repository root
                .appendingPathComponent("Sources/MacPilot/SnapzyQuickAccess")
            let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let files = (walker?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
            return try files.map { url in
                let code = try String(contentsOf: url, encoding: .utf8)
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                return (url.lastPathComponent, code)
            }
        }
    }

    @Test func pinnedSurfaceNeverDrawsFromTheCaptureToolbarPalette() throws {
        let sources = try pinSurfaceSources
        // 目录被搬走时扫描不能变成空跑。
        #expect(!sources.isEmpty)
        for source in sources {
            #expect(
                !source.code.contains("CaptureChromeStyle"),
                "\(source.file) still styles itself from the capture toolbar"
            )
        }
    }

    @Test @MainActor func selectionBarChipsComeFromCaptureChromeStyle() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        // Two passes: the bar declares its size from the rows' fitting size,
        // which is only exact once the first pass has laid the rows out.
        bar.frame = NSRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.layoutSubtreeIfNeeded()
        bar.frame = NSRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.layoutSubtreeIfNeeded()

        // 工具栏的每个圆 chip 都按同一份 token 长出来，不是各自写死的数字。
        #expect(bar.chipButtons.count >= 10)
        for chip in bar.chipButtons {
            #expect(chip.frame.width == CaptureChromeStyle.chipSide)
            #expect(chip.frame.height == CaptureChromeStyle.chipSide)
            #expect(chip.layer?.cornerRadius == CaptureChromeStyle.chipCornerRadius)
        }
        #expect(bar.layer?.cornerRadius == CaptureChromeStyle.cardCornerRadius)
    }

    @Test func pinChromeGeometryIsOneTokenSet() {
        // 贴图的控制岛属于贴图自己那套语言：hit area、玻璃高度、离图边的距离
        // 全部只由 PinnedScreenshotChromeStyle 定义，`QuickAccessPinWindowSizing`
        // 不再转发第二份数字。数值偶然相同不算解耦，
        // 「不引用 CaptureChromeStyle」由上面的源码扫描把守。
        #expect(PinnedScreenshotChromeStyle.outerInset > 0)
        #expect(PinnedScreenshotChromeStyle.controlHeight > PinnedScreenshotChromeStyle.controlSide)
        // 锁定后唯一可点的热点比画出来的控件大一圈：目标要好找，视觉要小。
        #expect(PinnedScreenshotChromeStyle.lockHotspotSide > PinnedScreenshotChromeStyle.controlHeight)
        // 胶囊与贴图外框同心：半径 = 窗口半径 - 离边距离。这条等式一旦不成立，
        // 两圈曲线就会各自为政，浮层立刻显得是贴上去的。
        #expect(PinnedScreenshotChromeStyle.controlCornerRadius
            == NSWindow.defaultCornerRadius - PinnedScreenshotChromeStyle.outerInset)
        // 浮层压在任意截图上，对比只能来自填充本身：白字要有足够暗的底撑着。
        #expect(PinnedScreenshotChromeStyle.capsuleFillOpacity >= 0.5)
    }

    @Test @MainActor func selectionBarCardFollowsTheAppearanceInsteadOfBeingPaintedBlack() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        var fills: [[Int]] = []
        for name in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            bar.appearance = appearance
            var fill: [Int] = []
            appearance.performAsCurrentDrawingAppearance {
                fill = chromeComponents(bar.layer?.backgroundColor)
                #expect(fill == chromeComponents(CaptureChromeStyle.cardFill.cgColor))
            }
            fills.append(fill)
        }
        // 浅色/深色下底色必须不同：写死黑色正是这次要拦住的回归。
        #expect(fills.count == 2)
        #expect(fills[0] != fills[1])
    }

    @Test @MainActor func onlyTheActiveToolChipIsFilledWithTheAccent() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        // The binding holds the model weakly, so the session only counts as
        // live while the test keeps the model alive.
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })

        func chip(_ tool: SmartAnnotationTool) throws -> NSButton {
            let title = AppText.value(tool.titleKey, language: .system)
            return try #require(bar.chipButtons.first { $0.toolTip == title })
        }
        func accentFills(of chips: [NSButton]) -> [Bool] {
            var result: [Bool] = []
            bar.effectiveAppearance.performAsCurrentDrawingAppearance {
                let accent = chromeComponents(NSColor.controlAccentColor.cgColor)
                result = chips.map { chromeComponents($0.layer?.backgroundColor) == accent }
            }
            return result
        }

        let rectangle = try chip(.rectangle)
        let pencil = try chip(.pencil)
        #expect(accentFills(of: [rectangle, pencil]) == [true, false])

        pencil.performClick(nil)
        #expect(accentFills(of: [rectangle, pencil]) == [false, true])
    }

    @Test @MainActor func adjustSelectionButtonEntersFrameEditingState() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }
        let selectionRect = CGRect(
            x: screen.frame.minX + 120,
            y: screen.frame.minY + 160,
            width: 320,
            height: 220
        )
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { _ in }
        )

        #expect(!window.overlayView.isSelectionAdjustmentActive)
        window.overlayView.beginSelectionAdjustment()
        #expect(window.overlayView.isSelectionAdjustmentActive)
    }

    @Test @MainActor func postSelectionHudInstallsTheOnlyActionBar() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }
        window.overlayView.showSelectionResult(
            screenRect: CGRect(
                x: screen.frame.minX + 160,
                y: screen.frame.minY + 200,
                width: 320,
                height: 220
            ),
            showsActions: true,
            actionHandler: { _ in }
        )

        // 右侧竖栏已并入「更多」菜单：浮层里只有一条操作栏。
        let bars = window.overlayView.subviews.filter { $0 is AreaSelectionActionBar }
        #expect(bars.count == 1)
    }

    @Test @MainActor func annotationEditorToolbarIsMountedOutsideTheSelectedFrame() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }
        let selectionRect = CGRect(
            x: screen.frame.minX + 180,
            y: screen.frame.minY + 200,
            width: 360,
            height: 240
        )
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { _ in }
        )
        let editor = NSView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 760,
                height: selectionRect.height + SmartAnnotationEditor.embeddedToolbarExtent
            )
        )
        window.overlayView.showEmbeddedAnnotationEditor(
            editor,
            screenRect: selectionRect,
            toolbarPlacement: .above
        )

        let expectedFrame = CGRect(
            x: selectionRect.minX - screen.frame.minX,
            y: selectionRect.minY - screen.frame.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        #expect(editor.superview === window.overlayView)
        let expectedEditorX = max(
            8,
            min(
                window.overlayView.bounds.width - editor.frame.width - 8,
                expectedFrame.midX - editor.frame.width / 2
            )
        )
        #expect(editor.frame.minX == expectedEditorX)
        #expect(editor.frame.minY == expectedFrame.minY)
        #expect(editor.frame.height > expectedFrame.height)
        #expect(editor.frame.maxY > expectedFrame.maxY)
        #expect(window.overlayView.subviews.contains { $0 is AreaSelectionActionBar } == false)
    }

    @Test @MainActor func draggingSelectionDoesNotReactivateTheOverlayWindow() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let recorder = OverlaySelectionRecorder()
        window.overlayView.delegate = recorder
        window.overlayView.setInteractionMode(.manualRegion)
        window.overlayView.setLivePassthroughInputEnabled(true)

        let start = CGPoint(
            x: screen.frame.minX + 100,
            y: screen.frame.minY + 100
        )
        window.overlayView.handleLivePassthroughMouseDown(atScreenPoint: start)
        for step in 1...5 {
            let point = CGPoint(
                x: start.x + CGFloat(step * 20),
                y: start.y + CGFloat(step * 12)
            )
            window.overlayView.handleLivePassthroughMouseMoved(atScreenPoint: point)
            window.overlayView.handleLivePassthroughMouseDragged(atScreenPoint: point)
        }
        window.overlayView.handleLivePassthroughMouseUp(atScreenPoint: CGPoint(x: start.x + 100, y: start.y + 60))

        // The selection controller activates the non-activating panel before
        // the first pointer event. Re-activating it from the first mouseDown
        // races the shortcut-start WindowServer transition and makes an
        // immediate drag flash; pointer handling must stay activation-free.
        #expect(recorder.displayActivationRequests == 0)
    }

    @Test @MainActor func lateBackdropDoesNotReplaceTheScreenDuringImmediateDrag() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        window.overlayView.setInteractionMode(.manualRegion)
        window.overlayView.setLivePassthroughInputEnabled(true)
        let start = CGPoint(x: screen.frame.minX + 100, y: screen.frame.minY + 100)
        let end = CGPoint(x: screen.frame.minX + 260, y: screen.frame.minY + 220)
        window.overlayView.handleLivePassthroughMouseDown(atScreenPoint: start)
        window.overlayView.handleLivePassthroughMouseDragged(atScreenPoint: end)

        window.overlayView.applyBackdrop(
            AreaSelectionBackdrop(
                displayID: displayID,
                image: image(width: 320, height: 240),
                scaleFactor: 1
            )
        )

        #expect(window.overlayView.isManualSelectionInProgress)
        #expect(window.overlayView.testSnapshotLayer.contents == nil)

        window.overlayView.handleLivePassthroughMouseUp(atScreenPoint: end)
        window.overlayView.showSelectionResult(
            screenRect: CGRect(x: start.x, y: start.y, width: 160, height: 120),
            showsActions: false,
            actionHandler: { _ in }
        )
        #expect(window.overlayView.testSnapshotLayer.contents == nil)
    }

    @Test @MainActor func lateBackdropDoesNotSwapTheVisibleResultState() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, let displayID = screen.displayID else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let selectionRect = CGRect(
            x: screen.frame.minX + 100,
            y: screen.frame.minY + 100,
            width: 160,
            height: 120
        )
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { _ in }
        )

        window.overlayView.applyBackdrop(
            AreaSelectionBackdrop(
                displayID: displayID,
                image: image(width: 320, height: 240),
                scaleFactor: 1
            )
        )

        // A capture that finishes after the quick drag must not replace the
        // already-visible result frame. That full-screen layer swap is the
        // remaining shortcut-start flash.
        #expect(window.overlayView.testSnapshotLayer.contents == nil)

        // The deferred frame is still available for the next selection once
        // the result state has been dismissed at a stable transition point.
        window.overlayView.hideSelectionResult()
        #expect(window.overlayView.testSnapshotLayer.contents != nil)
    }

    @Test @MainActor func embeddedAnnotationCanvasRemainsAlignedWhenToolbarIsClamped() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }
        let selectionRect = CGRect(
            x: screen.frame.minX + 180,
            y: screen.frame.minY + 200,
            width: 360,
            height: 240
        )
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { _ in }
        )

        let model = SmartAnnotationModel(initialTool: .rectangle)
        let editor = NSHostingView(rootView: SmartAnnotationEditor(
            image: image(width: 360, height: 240),
            language: .simplifiedChinese,
            model: model,
            embedded: true,
            embeddedToolbarPlacement: .above,
            embeddedCanvasSize: selectionRect.size,
            onCancel: {},
            onComplete: {}
        ))
        window.overlayView.showEmbeddedAnnotationEditor(
            editor,
            screenRect: selectionRect,
            toolbarPlacement: .above
        )

        let localSelection = CGRect(
            x: selectionRect.minX - screen.frame.minX,
            y: selectionRect.minY - screen.frame.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        let centeredCanvasX = editor.frame.minX + (editor.frame.width - localSelection.width) / 2
        let expectedOffset = localSelection.minX - centeredCanvasX

        #expect(editor.frame.height >= localSelection.height + SmartAnnotationEditor.embeddedToolbarExtent)
        #expect(editor.rootView.embeddedCanvasHorizontalOffset == expectedOffset)
    }

    @Test @MainActor func smartElementSelectionKeepsTheCrosshairCursor() throws {
        let overlay = AreaSelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var observedCursor: NSCursor?
        overlay.cursorSetEffect = { observedCursor = $0 }
        let key = PreferencesKeys.screenshotShowSelectionAreaOverlay
        let originalPreference = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let originalPreference {
                UserDefaults.standard.set(originalPreference, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        overlay.setInteractionMode(.smartElement)

        let expected = NSCursor.vectorScreenshotCrosshairLight
        let observed = try #require(observedCursor)
        #expect(pngData(from: observed.image) == pngData(from: expected.image))
        #expect(observed.hotSpot == expected.hotSpot)
    }

    @Test @MainActor func smartElementDragCommitsARectangularSelection() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let recorder = OverlaySelectionRecorder()
        window.overlayView.delegate = recorder
        window.overlayView.setElementTargetResolver { _ in nil }
        window.overlayView.setInteractionMode(.smartElement)
        window.overlayView.setLivePassthroughInputEnabled(true)

        let start = CGPoint(
            x: screen.frame.minX + 100,
            y: screen.frame.minY + 100
        )
        let end = CGPoint(
            x: screen.frame.minX + 220,
            y: screen.frame.minY + 180
        )

        window.overlayView.handleLivePassthroughMouseDown(atScreenPoint: start)
        window.overlayView.handleLivePassthroughMouseDragged(atScreenPoint: end)
        window.overlayView.handleLivePassthroughMouseUp(atScreenPoint: end)

        #expect(recorder.manualBegan == [start])
        #expect(recorder.manualEnded == [end])
        #expect(recorder.manualChanged.first == end)
    }

    @Test @MainActor func initialSmartTargetResolutionRunsOnMainActor() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }

        let recorder = InitialTargetResolverRecorder()
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true },
            initialTargetResolver: { _, _ in
                recorder.record()
                return nil
            }
        )

        defer {
            controller.stop()
        }

        controller.startSelection(mode: .smartElement)
        for _ in 0..<50 {
            if recorder.result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.result == true)
    }

    @Test @MainActor func smartElementDragRendersLiveSelectionFrame() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let recorder = OverlaySelectionRecorder()
        window.overlayView.delegate = recorder
        window.overlayView.setElementTargetResolver { _ in nil }
        window.overlayView.setInteractionMode(.smartElement)
        window.overlayView.setLivePassthroughInputEnabled(true)

        let start = CGPoint(
            x: screen.frame.minX + 100,
            y: screen.frame.minY + 100
        )
        let end = CGPoint(
            x: screen.frame.minX + 220,
            y: screen.frame.minY + 180
        )

        // Drive the F1 smart-element drag far enough that the view promotes
        // it to a manual frame drag (the same threshold the app uses).
        window.overlayView.handleLivePassthroughMouseDown(atScreenPoint: start)
        window.overlayView.handleLivePassthroughMouseDragged(atScreenPoint: end)
        #expect(recorder.manualBegan == [start])

        // Reproduce the controller's render step for manual-selection drag
        // updates (`SnapzyAreaSelectionController.manualSelectionChangedTo`).
        let expectedRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        window.overlayView.renderManualSelection(
            screenRect: expectedRect,
            currentScreenPoint: end
        )

        // The live frame box must be on screen during an F1 drag, matching
        // PixPin's drag preview (previously smartElement was excluded here).
        #expect(window.overlayView.lastRenderedManualSelectionRect == expectedRect)

        window.overlayView.handleLivePassthroughMouseUp(atScreenPoint: end)
    }

    @Test @MainActor func smartElementRecognitionCannotOverwriteManualDragFrame() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let elementRect = CGRect(
            x: screen.frame.minX + 420,
            y: screen.frame.minY + 300,
            width: 120,
            height: 90
        )
        window.overlayView.setElementTargetResolver { _ in elementRect }
        window.overlayView.setInteractionMode(.smartElement)
        window.overlayView.setLivePassthroughInputEnabled(true)

        let start = CGPoint(
            x: screen.frame.minX + 100,
            y: screen.frame.minY + 100
        )
        let end = CGPoint(
            x: screen.frame.minX + 220,
            y: screen.frame.minY + 180
        )

        // Finish the initial delayed hover resolution so the mouse-down below
        // schedules the same-element follow-up that used to race the drag.
        window.overlayView.handleLivePassthroughMouseMoved(atScreenPoint: start)
        try await Task.sleep(for: .milliseconds(120))

        window.overlayView.handleLivePassthroughMouseDown(atScreenPoint: start)
        window.overlayView.handleLivePassthroughMouseDragged(atScreenPoint: end)

        let expectedRect = CGRect(
            x: start.x - screen.frame.minX,
            y: start.y - screen.frame.minY,
            width: end.x - start.x,
            height: end.y - start.y
        )
        window.overlayView.renderManualSelection(
            screenRect: CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y),
            currentScreenPoint: end
        )
        #expect(window.overlayView.testSelectionBorderPathBounds == expectedRect)

        // The pending AX follow-up must not replace the manual frame with the
        // earlier element preview after the drag has crossed its threshold.
        try await Task.sleep(for: .milliseconds(120))
        #expect(window.overlayView.testSelectionBorderPathBounds == expectedRect)

        window.overlayView.handleLivePassthroughMouseUp(atScreenPoint: end)
    }

    @Test @MainActor func inFlightSmartElementRecognitionCannotCommitAfterManualDragBegins() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let start = CGPoint(
            x: screen.frame.minX + 100,
            y: screen.frame.minY + 100
        )
        let end = CGPoint(
            x: screen.frame.minX + 220,
            y: screen.frame.minY + 180
        )
        let staleElementRect = CGRect(
            x: screen.frame.minX + 420,
            y: screen.frame.minY + 300,
            width: 120,
            height: 90
        )
        let expectedRect = CGRect(
            x: start.x - screen.frame.minX,
            y: start.y - screen.frame.minY,
            width: end.x - start.x,
            height: end.y - start.y
        )
        var beganManualDragDuringRecognition = false

        window.overlayView.setElementTargetResolver { _ in
            if !beganManualDragDuringRecognition {
                beganManualDragDuringRecognition = true
                window.overlayView.handleLivePassthroughMouseDown(atScreenPoint: start)
                window.overlayView.handleLivePassthroughMouseDragged(atScreenPoint: end)
                window.overlayView.renderManualSelection(
                    screenRect: CGRect(
                        x: start.x,
                        y: start.y,
                        width: end.x - start.x,
                        height: end.y - start.y
                    ),
                    currentScreenPoint: end
                )
            }
            return staleElementRect
        }
        window.overlayView.setInteractionMode(.smartElement)
        window.overlayView.setLivePassthroughInputEnabled(true)

        window.overlayView.handleLivePassthroughMouseMoved(atScreenPoint: start)
        try await Task.sleep(for: .milliseconds(120))

        #expect(beganManualDragDuringRecognition)
        #expect(window.overlayView.testSelectionBorderPathBounds == expectedRect)
        window.overlayView.handleLivePassthroughMouseUp(atScreenPoint: end)
    }

    @Test @MainActor func smartElementStartupNeverPresentsAFullScreenDimFrame() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }

        let target = CGRect(
            x: screen.frame.minX + 160,
            y: screen.frame.minY + 140,
            width: 480,
            height: 320
        )
        window.overlayView.setElementTargetResolver { _ in target }
        window.overlayView.setInteractionMode(.smartElement)

        // The panel is presented before the delayed AX query runs. Its first
        // composited frame must stay transparent instead of dimming the whole
        // display with a nil mask.
        #expect(window.overlayView.testDimLayerIsHidden)
        #expect(!window.overlayView.testDimLayerHasMask)

        try await Task.sleep(for: .milliseconds(120))

        // Recognition reveals the dim layer only after its target cutout has
        // been installed, so WindowServer never sees a full-screen dark frame.
        #expect(!window.overlayView.testDimLayerIsHidden)
        #expect(window.overlayView.testDimLayerHasMask)
    }

    // MARK: - iShot-style in-place annotation session

    @Test @MainActor func chromelessAnnotationSessionKeepsTheFrameVisualsAndTheHUDToolbar() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }

        let window = AreaSelectionWindow(screen: screen, pooled: true)
        defer { window.close() }
        let selectionRect = CGRect(
            x: screen.frame.minX + 140,
            y: screen.frame.minY + 180,
            width: 320,
            height: 200
        )
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { _ in }
        )
        let model = SmartAnnotationModel(initialTool: .rectangle)
        let editor = NSHostingView(rootView: SmartAnnotationEditor(
            image: image(width: 320, height: 200),
            language: .simplifiedChinese,
            model: model,
            embedded: true,
            showsToolbar: false,
            embeddedCanvasSize: selectionRect.size,
            onCancel: {},
            onComplete: {}
        ))
        window.overlayView.showEmbeddedAnnotationEditor(
            editor,
            screenRect: selectionRect,
            toolbarPlacement: .above,
            showsToolbar: false
        )
        window.overlayView.attachAnnotationSession(model: model) { _ in }

        let localSelection = CGRect(
            x: selectionRect.minX - screen.frame.minX,
            y: selectionRect.minY - screen.frame.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        // The canvas sits exactly over the selected frame…
        #expect(editor.frame == localSelection)
        // …the HUD toolbar stays mounted for tool switching and commits…
        #expect(window.overlayView.subviews.contains { $0 is AreaSelectionActionBar })
        // …and the selection border remains visible, matching iShot.
        #expect(window.overlayView.testSelectionBorderPathBounds != nil)
        #expect(window.overlayView.isAnnotationSessionActive)
    }

    @Test @MainActor func annotationSessionToolbarSwitchesToolsWithoutEndingTheSession() throws {
        _ = NSApplication.shared
        var committedActions: [AreaSelectionAction] = []
        var startedSessions: [AreaSelectionAction] = []
        let bar = AreaSelectionActionBar { action in
            startedSessions.append(action)
        }
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { action in
            committedActions.append(action)
        })

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }

        // A tool press with a live session switches the model's tool; the
        // capture pipeline is never asked to start another session.
        let textButton = try #require(
            buttons(in: bar).first(where: {
                $0.toolTip == AppText.value("scAnnotationText", language: .system)
            })
        )
        textButton.performClick(nil)
        #expect(model.tool == .text)
        #expect(startedSessions.isEmpty)
        #expect(committedActions.isEmpty)

        // Action presses route through the session commit, not the HUD start.
        let saveButton = try #require(
            buttons(in: bar).first(where: {
                $0.toolTip == AppText.value("scToolSave", language: .system)
            })
        )
        saveButton.performClick(nil)
        #expect(committedActions == [.save])
        #expect(startedSessions.isEmpty)
    }

    @Test @MainActor func annotationOptionsRowCanBeCollapsedAndReopened() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }

        let rootStack = try #require(bar.subviews.compactMap { $0 as? NSStackView }.first)
        let optionsRow = try #require(rootStack.arrangedSubviews.last)
        let collapseButton = try #require(
            buttons(in: optionsRow).first {
                $0.toolTip == AppText.value("scAnnotationHideOptions", language: .system)
            }
        )
        #expect(!optionsRow.isHidden)

        let expandedHeight = bar.intrinsicContentSize.height
        collapseButton.performClick(nil)
        #expect(optionsRow.isHidden)
        let collapsedHeight = bar.intrinsicContentSize.height
        // 收起前后的差值 = 选项行实际内容高度 + 行间距（intrinsic 高度按真实内容计算）
        #expect(expandedHeight - collapsedHeight >= optionsRow.fittingSize.height + 8)

        let rectangleButton = try #require(
            buttons(in: bar).first {
                $0.toolTip == AppText.value("scAnnotationRectangle", language: .system)
            }
        )
        rectangleButton.performClick(nil)
        #expect(!optionsRow.isHidden)
    }

    @Test func emptyTextEntryFieldHasAnEditableTarget() {
        let size = SmartAnnotationEditor.inlineTextFieldSize(
            for: "",
            style: .default(for: .text)
        )
        #expect(size.width >= 40)
        #expect(size.height >= 28)
    }

    @Test @MainActor func bindingTheSessionRevealsTheEraserAndUndoControls() throws {
        let bar = AreaSelectionActionBar { _ in }

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }

        let eraserTooltip = AppText.value("scAnnotationEraser", language: .system)
        let undoTooltip = AppText.value("scUndo", language: .system)
        let eraserBefore = buttons(in: bar).first(where: { $0.toolTip == eraserTooltip })
        #expect(eraserBefore?.isHidden ?? true)

        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })

        let eraser = try #require(buttons(in: bar).first(where: { $0.toolTip == eraserTooltip }))
        let undo = try #require(buttons(in: bar).first(where: { $0.toolTip == undoTooltip }))
        #expect(!eraser.isHidden)
        #expect(!undo.isHidden)
        #expect(!undo.isEnabled)

        model.append(.rectangle(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        // The bar observes the model through RunLoop.main; pump it so the
        // objectWillChange delivery lands before the assertion.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(undo.isEnabled)
    }

    @Test @MainActor func eraserRemovesTheAnnotationUnderThePointerAsOneUndoableStep() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        model.append(.rectangle(CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3)))
        #expect(model.annotations.count == 2)

        model.removeAnnotation(at: 0)
        #expect(model.annotations.count == 1)

        // The eraser stroke is a single undo step, like iShot.
        model.undo()
        #expect(model.annotations.count == 2)
    }

    @Test @MainActor func removingTheLastCounterResetsTheSequence() {
        let model = SmartAnnotationModel(initialTool: .counter)
        let counter = model.nextCounter
        model.append(.counter(counter, CGPoint(x: 0.5, y: 0.5)))
        #expect(model.nextCounter == counter + 1)

        model.removeAnnotation(at: 0)
        #expect(model.nextCounter == 1)
    }

    @Test func doubleEscapeWithinWindowDismissesThePins() {
        let first = Date(timeIntervalSinceReferenceDate: 100)
        // 第一按下：仅记录时间点，不关闭任何贴图。
        #expect(!QuickAccessPinEscapeRouting.shouldDismissPins(lastEscapeAt: nil, now: first))
        // 0.8 秒窗口内的第二下：关闭全部贴图。
        #expect(QuickAccessPinEscapeRouting.shouldDismissPins(
            lastEscapeAt: first,
            now: first.addingTimeInterval(0.5)
        ))
        // 恰好在窗口边界上也算连按。
        #expect(QuickAccessPinEscapeRouting.shouldDismissPins(
            lastEscapeAt: first,
            now: first.addingTimeInterval(QuickAccessPinEscapeRouting.doublePressInterval)
        ))
        // 超出窗口：不关闭，重新开始计时。
        #expect(!QuickAccessPinEscapeRouting.shouldDismissPins(
            lastEscapeAt: first,
            now: first.addingTimeInterval(1.5)
        ))
    }

    @Test @MainActor func clipboardTextPinsGetTheirOwnUnzoomedSurface() {
        // The unified pin window hosts clipboard text as a card: it declares
        // itself unzoomable and grows with the text while keeping a floor so
        // the close/lock chrome always fits.
        let short = QuickAccessPinTextMetrics.baseSize(for: "hi")
        let long = QuickAccessPinTextMetrics.baseSize(
            for: String(repeating: "a much longer clipboard line ", count: 8)
        )
        #expect(short.width >= QuickAccessPinTextMetrics.minimumSize.width)
        #expect(short.height >= QuickAccessPinTextMetrics.minimumSize.height)
        #expect(long.height > short.height)
        #expect(long.width <= QuickAccessPinTextMetrics.maximumTextWidth + QuickAccessPinTextMetrics.horizontalPadding * 2 + 1)

        let state = QuickAccessPinWindowState(id: UUID(), text: "hi", baseSize: short)
        #expect(state.isText)
        #expect(!state.supportsZoom)
        #expect(state.applyZoomStep(0.5) == short)
    }

    @Test func barLayoutPlacesTheSingleHudBarAroundTheSelection() {
        let bounds = CGSize(width: 1_440, height: 900)
        let barSize = CGSize(width: 460, height: 38)

        func assertInsideScreen(_ frame: CGRect, name: String) {
            #expect(frame.minX >= AreaSelectionBarLayout.edgeMargin - 0.5, "\(name) minX")
            #expect(frame.minY >= AreaSelectionBarLayout.edgeMargin - 0.5, "\(name) minY")
            #expect(frame.maxX <= bounds.width - AreaSelectionBarLayout.edgeMargin + 0.5, "\(name) maxX")
            #expect(frame.maxY <= bounds.height - AreaSelectionBarLayout.edgeMargin + 0.5, "\(name) maxY")
        }

        // 屏幕中部的小选区：横栏贴在选区下方，水平居中。
        let centered = CGRect(x: 700, y: 430, width: 60, height: 40)
        let centeredBar = AreaSelectionBarLayout.resolve(
            selectionRect: centered, barSize: barSize, bounds: bounds
        )
        #expect(centeredBar.midX == centered.midX)
        #expect(centeredBar.maxY <= centered.minY)
        assertInsideScreen(centeredBar, name: "centered")

        // 贴屏幕底部：下方放不下，翻到选区上方。
        let nearBottom = CGRect(x: 700, y: 8, width: 60, height: 40)
        let above = AreaSelectionBarLayout.resolve(
            selectionRect: nearBottom, barSize: barSize, bounds: bounds
        )
        #expect(above.minY >= nearBottom.maxY)
        assertInsideScreen(above, name: "near bottom")

        // 贴屏幕右缘的小选区：水平方向夹回屏幕内。
        let rightEdge = CGRect(x: 1_380, y: 430, width: 50, height: 40)
        let clamped = AreaSelectionBarLayout.resolve(
            selectionRect: rightEdge, barSize: barSize, bounds: bounds
        )
        assertInsideScreen(clamped, name: "right edge")

        // 近全屏选区：上下都没有空间，操作栏收进选区内侧而非骑跨边框。
        let huge = CGRect(x: 8, y: 8, width: 1_424, height: 884)
        let inside = AreaSelectionBarLayout.resolve(
            selectionRect: huge, barSize: barSize, bounds: bounds
        )
        #expect(inside.minY >= huge.minY + AreaSelectionBarLayout.insideInset)
        #expect(inside.maxY <= huge.maxY)
        assertInsideScreen(inside, name: "huge")
    }

    @Test func roundedCornerOutputKeepsTheCanvasSizeWhileShadowExpandsIt() throws {
        let source = image(width: 40, height: 30)

        let rounded = try #require(SmartCaptureOutputStyling.roundedCorners(source, radius: 8))
        #expect(rounded.width == source.width)
        #expect(rounded.height == source.height)

        let styled = SmartCaptureOutputStyling.apply(
            to: source,
            style: SmartCaptureOutputStyle(roundedCorners: true, cornerRadius: 6, shadow: true),
            scaleFactor: 2
        )
        // The 18pt shadow padding at 2× expands the canvas on both axes.
        #expect(styled.width == source.width + 72)
        #expect(styled.height == source.height + 72)

        let untouched = SmartCaptureOutputStyling.apply(
            to: source,
            style: .inactive,
            scaleFactor: 2
        )
        #expect(untouched == source)
    }
}
