import CoreGraphics
import Foundation
import AppKit
import SwiftUI
import Testing
@preconcurrency import ScreenCaptureKit
@testable import MacPilot

/// Geometry coverage for the source-migrated Snapzy frozen-display pipeline.
struct SnapzyCaptureTests {
    @Test func interactiveDisplayCaptureIncludesMacPilotWindows() {
        #expect(!SnapzyCaptureApplicationVisibilityPolicy.excludesOwnApplicationFromDisplaySnapshot)
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

    @Test func pinShortcutCommitsTheInlineAnnotationEditorBeforePinning() {
        #expect(SnapzyInlineAnnotationShortcutRouting.shouldCommitInlineAnnotation(
            action: .pin,
            hasInlineAnnotationEditor: true
        ))
        #expect(!SnapzyInlineAnnotationShortcutRouting.shouldCommitInlineAnnotation(
            action: .pin,
            hasInlineAnnotationEditor: false
        ))
        #expect(!SnapzyInlineAnnotationShortcutRouting.shouldCommitInlineAnnotation(
            action: .copy,
            hasInlineAnnotationEditor: true
        ))
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
        #expect(pastedImage.width == sourceImage.width)
        #expect(pastedImage.height == sourceImage.height)
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
            buttons(in: bar).first(where: { $0.toolTip == "矩形标注" })
        )
        rectangleButton.performClick(nil)

        #expect(requestedAction == .annotateTool(.rectangle))
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
        var requestedAction: AreaSelectionAction?
        window.overlayView.showSelectionResult(
            screenRect: selectionRect,
            showsActions: true,
            actionHandler: { action in
                requestedAction = action
                if action == .adjustSelection {
                    window.overlayView.beginSelectionAdjustment()
                }
            }
        )

        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }
        let adjustButton = try #require(
            buttons(in: window.overlayView)
                .first(where: { $0.toolTip == "调整选区" })
        )
        adjustButton.performClick(nil)

        #expect(requestedAction == .adjustSelection)
        #expect(window.overlayView.isSelectionAdjustmentActive)
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
}
