import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

/// Interaction parity with Snapzy's annotation flow:
/// - every tool is a direct, always-visible button;
/// - Undo/Redo are real history stacks (not `annotations.isEmpty`);
/// - toolbar clicks, keyboard shortcuts and model changes share one router;
/// - Copy / Copy & Close semantics are per surface and never lose an edit on
///   a failed clipboard write.
@Suite(.serialized)
@MainActor
struct AnnotationInteractionParityTests {
    /// Isolated pasteboard: these tests exercise the real clipboard writer and
    /// lease path, but must never clear or overwrite the user's clipboard.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("MacPilot.AnnotationParity.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    private func image(width: Int = 64, height: Int = 64) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    // MARK: - Model history

    @Test func erasingTheLastAnnotationLeavesUndoEnabled() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        #expect(model.canUndo)
        model.removeAnnotation(at: 0)
        #expect(model.annotations.isEmpty)
        #expect(model.canUndo, "the erase snapshot is still undoable")
        model.undo()
        #expect(model.annotations.count == 1)
        #expect(model.canRedo)
        model.redo()
        #expect(model.annotations.isEmpty)
    }

    @Test func clearingAllAnnotationsIsUndoable() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        model.append(.ellipse(CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)))
        model.removeAll()
        #expect(model.annotations.isEmpty)
        #expect(model.canUndo)
        model.undo()
        #expect(model.annotations.count == 2)
        #expect(model.nextCounter == 1)
    }

    @Test func aNewEditClearsTheRedoStack() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        model.undo()
        #expect(model.canRedo)
        model.append(.ellipse(CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)))
        #expect(!model.canRedo)
    }

    @Test func styleChangesOnASelectedAnnotationAreUndoable() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        model.selectAnnotation(0)
        let originalColor = model.currentStyle.color
        let originalWidth = model.currentStyle.lineWidth
        model.setColor(.presets[2])
        model.endStyleEditing()
        model.setLineWidth(originalWidth + 6)
        model.endStyleEditing()
        model.setFillEnabled(true)
        model.endStyleEditing()

        #expect(model.style(at: 0).fillEnabled)
        model.undo()
        #expect(!model.style(at: 0).fillEnabled)
        model.undo()
        #expect(model.style(at: 0).lineWidth == originalWidth)
        model.undo()
        #expect(model.style(at: 0).color == originalColor)
        #expect(model.canRedo)
        model.redo()
        #expect(model.style(at: 0).color == .presets[2])
    }

    @Test func undoingAStyleChangeRestoresThePropertyRowAndToolDefaults() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        model.selectAnnotation(0)
        let original = model.currentStyle
        model.setColor(.presets[2])
        model.endStyleEditing()
        #expect(model.currentStyle.color == .presets[2])

        model.undo()
        #expect(model.style(at: 0).color == original.color)
        #expect(
            model.currentStyle.color == original.color,
            "the property row must show the restored value, not the discarded one"
        )
        // The per-tool default was part of the same document snapshot.
        model.selectTool(.ellipse)
        model.selectTool(.rectangle)
        #expect(model.currentStyle.color == original.color)
    }

    @Test func everyImplementedToolHasOneDirectButtonAndStartsItsExactTool() throws {
        _ = NSApplication.shared
        var started: [AreaSelectionAction] = []
        let bar = AreaSelectionActionBar { started.append($0) }
        let expected: [(String, AreaSelectionAnnotationTool)] = [
            ("scAnnotationRectangle", .rectangle),
            ("scAnnotationFilledRectangle", .filledRectangle),
            ("scAnnotationEllipse", .ellipse),
            ("scAnnotationArrow", .arrow),
            ("scAnnotationLine", .line),
            ("scAnnotationPencil", .pencil),
            ("scAnnotationHighlighter", .highlighter),
            ("scAnnotationText", .text),
            ("scAnnotationWatermark", .watermark),
            ("scAnnotationCounter", .counter),
            ("scAnnotationBlur", .blur),
            ("scAnnotationSpotlight", .spotlight),
            ("scAnnotationEraser", .eraser),
        ]
        for (key, tool) in expected {
            let button = try #require(
                bar.chipButtons.first { $0.toolTip == AppText.value(key, language: .system) }
            )
            #expect(!button.isHiddenOrHasHiddenAncestor, "\(key) must be directly visible")
            button.performClick(nil)
            #expect(
                started.last == .annotateTool(tool),
                "\(key) must start a session with \(tool), not a sibling variant"
            )
        }
    }

    @Test func theShapePropertyRowKeepsTheFilledRectangleTool() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        let model = SmartAnnotationModel(initialTool: .filledRectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })

        func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            for subview in view.subviews {
                if let control = segmentedControl(in: subview) { return control }
            }
            return nil
        }
        let control = try #require(segmentedControl(in: bar))
        #expect(control.selectedSegment == 1, "the filled variant is its own segment")

        control.selectedSegment = 2
        control.sendAction(control.action, to: control.target)
        #expect(model.tool == .ellipse)

        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        #expect(model.tool == .filledRectangle)
    }

    @Test func everyNewAnnotationSessionStartsWithThePropertiesExpanded() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { subview in
                (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
            }
        }
        func optionsRow() throws -> NSView {
            let rootStack = try #require(bar.subviews.compactMap { $0 as? NSStackView }.first)
            let hideTooltip = AppText.value("scAnnotationHideOptions", language: .system)
            return try #require(
                rootStack.arrangedSubviews.first { view in
                    buttons(in: view).contains { $0.toolTip == hideTooltip }
                }
            )
        }

        let firstModel = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: firstModel) { _ in })
        let collapse = try #require(
            buttons(in: try optionsRow()).first {
                $0.toolTip == AppText.value("scAnnotationHideOptions", language: .system)
            }
        )
        collapse.performClick(nil)
        #expect((try optionsRow()).isHidden)

        bar.bindAnnotationSession(nil)
        let secondModel = SmartAnnotationModel(initialTool: .ellipse)
        bar.bindAnnotationSession(.init(model: secondModel) { _ in })
        #expect(
            !(try optionsRow()).isHidden,
            "a new capture starts expanded; the previous session's collapse must not leak"
        )
    }

    @Test func aContinuousSliderDragIsOneUndoStep() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        model.selectAnnotation(0)
        let original = model.currentStyle.lineWidth
        // Simulate a drag: many values, no endStyleEditing until release.
        for value in stride(from: original + 1, through: original + 10, by: 1) {
            model.setLineWidth(value)
        }
        model.endStyleEditing()
        model.undo()
        #expect(model.style(at: 0).lineWidth == original, "one drag = one undo step")
    }

    @Test func aMoveOrResizeGestureIsOneUndoStep() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        let original = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        model.append(.rectangle(original))
        model.beginEditing(at: 0)
        for step in 1...5 {
            let moved = original.offsetBy(dx: CGFloat(step) * 0.01, dy: CGFloat(step) * 0.01)
            model.updateAnnotation(at: 0, to: .rectangle(moved))
        }
        model.endEditing()
        model.undo()
        guard case .rectangle(let restored) = model.annotations[0] else {
            Issue.record("annotation kind changed")
            return
        }
        #expect(abs(restored.minX - original.minX) < 0.0001)
        #expect(abs(restored.minY - original.minY) < 0.0001)
    }

    @Test func counterRenumberingSurvivesUndoAndRedo() {
        let model = SmartAnnotationModel(initialTool: .counter)
        model.append(.counter(1, CGPoint(x: 0.1, y: 0.1)))
        model.append(.counter(2, CGPoint(x: 0.2, y: 0.2)))
        model.append(.counter(3, CGPoint(x: 0.3, y: 0.3)))
        model.removeAnnotation(at: 0)
        #expect(model.nextCounter == 3)
        model.undo()
        #expect(model.nextCounter == 4)
        let numbers: [Int] = model.annotations.compactMap { annotation in
            if case .counter(let value, _) = annotation { return value }
            return nil
        }
        #expect(numbers == [1, 2, 3])
        model.redo()
        let renumbered: [Int] = model.annotations.compactMap { annotation in
            if case .counter(let value, _) = annotation { return value }
            return nil
        }
        #expect(renumbered == [1, 2])
        #expect(model.nextCounter == 3)
    }

    // MARK: - Toolbar integration (real buttons, not direct model calls)

    @Test func textAndCropEditsJoinTheSameHistory() {
        let model = SmartAnnotationModel(initialTool: .text)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        model.append(.text("hello", CGPoint(x: 0.3, y: 0.3)))
        #expect(model.annotations.count == 2)

        model.undo()
        #expect(model.annotations.count == 1, "one text commit is one undo step")
        model.redo()
        #expect(model.annotations.count == 2)

        model.selectTool(.crop)
        model.append(.crop(CGRect(x: 0.05, y: 0.05, width: 0.5, height: 0.5)))
        #expect(model.annotations.count == 3)
        model.undo()
        #expect(
            model.annotations.count == 2,
            "undoing a crop returns to the pre-crop annotations"
        )
        model.redo()
        #expect(model.annotations.count == 3)
    }

    @Test func opacityAndLineStyleChangesAreUndoable() {
        let model = SmartAnnotationModel(initialTool: .rectangle)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        model.selectAnnotation(0)
        let originalOpacity = model.currentStyle.opacity
        let originalLineStyle = model.currentStyle.lineStyle

        model.setOpacity(0.3)
        model.endStyleEditing()
        model.setLineStyle(.dashed)
        model.endStyleEditing()

        model.undo()
        #expect(model.style(at: 0).lineStyle == originalLineStyle)
        model.undo()
        #expect(model.style(at: 0).opacity == originalOpacity)
    }

    @Test func toolbarUndoAndRedoDriveTheRealModel() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })
        model.append(.rectangle(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let undo = try #require(
            buttons(in: bar).first { $0.toolTip == AppText.value("scUndo", language: .system) }
        )
        let redo = try #require(
            buttons(in: bar).first { $0.toolTip == AppText.value("scRedo", language: .system) }
        )
        #expect(undo.isEnabled)
        undo.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(model.annotations.isEmpty)
        #expect(redo.isEnabled)
        redo.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(model.annotations.count == 1)
    }

    @Test func toolbarUndoStaysClickableAfterErasingTheLastObject() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        model.removeAnnotation(at: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let undo = try #require(
            buttons(in: bar).first { $0.toolTip == AppText.value("scUndo", language: .system) }
        )
        #expect(undo.isEnabled, "annotations.isEmpty must not decide the button state")
        undo.performClick(nil)
        #expect(model.annotations.count == 1)
    }

    @Test func toolbarUndoStaysClickableAfterClearAll() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        model.append(.arrow(CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)))
        model.removeAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let undo = try #require(
            buttons(in: bar).first { $0.toolTip == AppText.value("scUndo", language: .system) }
        )
        #expect(undo.isEnabled)
        undo.performClick(nil)
        #expect(model.annotations.count == 2)
    }

    @Test func propertiesRowStartsExpandedAndToolSwitchesNeverCollapseIt() throws {
        _ = NSApplication.shared
        let bar = AreaSelectionActionBar { _ in }
        let model = SmartAnnotationModel(initialTool: .rectangle)
        bar.bindAnnotationSession(.init(model: model) { _ in })

        func optionsRow() throws -> NSView {
            let rootStack = try #require(bar.subviews.compactMap { $0 as? NSStackView }.first)
            return try #require(rootStack.arrangedSubviews.last)
        }

        #expect(!(try optionsRow()).isHidden, "properties are expanded by default")

        let collapse = try #require(
            buttons(in: try optionsRow()).first {
                $0.toolTip == AppText.value("scAnnotationHideOptions", language: .system)
            }
        )
        collapse.performClick(nil)
        #expect((try optionsRow()).isHidden)

        // Switching to another tool must not reopen (or further collapse) the
        // row behind the user's back. A tool switch rebuilds the row, so the
        // assertion re-reads the current row rather than a stale reference.
        let ellipse = try #require(
            buttons(in: bar).first {
                $0.toolTip == AppText.value("scAnnotationEllipse", language: .system)
            }
        )
        ellipse.performClick(nil)
        #expect(model.tool == .ellipse)
        #expect((try optionsRow()).isHidden, "a tool switch must not change the user's collapse choice")

        // Clicking the active tool is the explicit way back.
        ellipse.performClick(nil)
        #expect(!(try optionsRow()).isHidden)
    }

    // MARK: - Keyboard router (shared by the real key path)

    @Test func commandZAndShiftCommandZDriveTheSameHistory() throws {
        _ = NSApplication.shared
        let controller = SnapzyAreaSelectionController.shared
        defer { controller.cancelSelection() }
        controller.testInstallInlineAnnotationSession(image: image())
        let model = try #require(controller.testInlineAnnotationModel)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))

        #expect(controller.handleInlineAnnotationKey(keyCode: 6, modifiers: [.command]))
        #expect(model.annotations.isEmpty)
        #expect(controller.handleInlineAnnotationKey(keyCode: 6, modifiers: [.command, .shift]))
        #expect(model.annotations.count == 1)
    }

    @Test func textEditingKeepsNativeUndoAndDoesNotEraseThePicture() throws {
        _ = NSApplication.shared
        let controller = SnapzyAreaSelectionController.shared
        defer { controller.cancelSelection() }
        controller.testInstallInlineAnnotationSession(image: image())
        let model = try #require(controller.testInlineAnnotationModel)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))

        // editingText = true mirrors an NSTextView being first responder.
        #expect(!controller.handleInlineAnnotationKey(keyCode: 6, modifiers: [.command], editingText: true))
        #expect(model.annotations.count == 1, "the picture must not be undone while typing")
    }

    @Test func toolShortcutDisableListIsTheSingleConfigurationSource() {
        let original = SmartAnnotationToolShortcuts.disabledTools
        defer { SmartAnnotationToolShortcuts.disabledTools = original }

        SmartAnnotationToolShortcuts.disabledTools = [.watermark, .filledRectangle]
        #expect(SmartAnnotationToolShortcuts.tool(for: "w") == nil)
        #expect(SmartAnnotationToolShortcuts.tool(forKeyCode: 13) == nil)
        #expect(SmartAnnotationToolShortcuts.tool(for: "f") == nil)
        #expect(SmartAnnotationToolShortcuts.tool(for: "r") == .rectangle)

        SmartAnnotationToolShortcuts.disabledTools = []
        #expect(SmartAnnotationToolShortcuts.tool(for: "w") == .watermark)
        #expect(SmartAnnotationToolShortcuts.tool(forKeyCode: 3) == .filledRectangle)
    }

    @Test func plainLetterShortcutsSwitchInlineToolsButNotWhileTyping() throws {
        _ = NSApplication.shared
        let controller = SnapzyAreaSelectionController.shared
        defer { controller.cancelSelection() }
        controller.testInstallInlineAnnotationSession(image: image(), initialTool: .rectangle)
        let model = try #require(controller.testInlineAnnotationModel)

        #expect(controller.handleInlineAnnotationKey(keyCode: 17, modifiers: [])) // T
        #expect(model.tool == .text)
        #expect(controller.handleInlineAnnotationKey(keyCode: 3, modifiers: [])) // F
        #expect(model.tool == .filledRectangle)
        #expect(controller.handleInlineAnnotationKey(keyCode: 13, modifiers: [])) // W
        #expect(model.tool == .watermark)
        #expect(controller.handleInlineAnnotationKey(keyCode: 15, modifiers: [])) // R
        #expect(model.tool == .rectangle)
        #expect(controller.handleInlineAnnotationKey(keyCode: 14, modifiers: [])) // E
        #expect(model.tool == .eraser)

        // A focused text field keeps every letter for itself.
        #expect(!controller.handleInlineAnnotationKey(keyCode: 17, modifiers: [], editingText: true))
        #expect(model.tool == .eraser)
    }

    @Test func inlineCopyStaysAndCopyAndCloseEndsTheSession() throws {
        _ = NSApplication.shared
        let controller = SnapzyAreaSelectionController.shared
        let pasteboard = makePasteboard()
        controller.clipboardPasteboard = pasteboard
        defer {
            controller.cancelSelection()
            controller.clipboardPasteboard = .general
            controller.testFailInlineClipboardWrite = false
            controller.testResetOutputStyle()
            pasteboard.releaseGlobally()
        }
        var delivered: [(CGImage, AreaSelectionAction)] = []
        controller.testInstallInlineAnnotationSession(image: image()) { image, action in
            delivered.append((image, action))
        }
        let model = try #require(controller.testInlineAnnotationModel)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        // Inline Copy must deliver the same styled image as Done; a 64×64
        // capture with the shadow toggle gains 18pt of padding per side.
        controller.commitInlineAnnotation(as: .toggleShadow)

        // Cmd+C copies the render and keeps the session alive.
        #expect(controller.handleInlineAnnotationKey(keyCode: 8, modifiers: [.command]))
        #expect(controller.testHasInlineAnnotationSession)
        #expect(delivered.isEmpty, "inline Copy must not run the terminal delivery path")
        let data = try #require(pasteboard.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let copied = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(copied.width == 100 && copied.height == 100)

        // Cmd+Shift+C copies and closes.
        #expect(controller.handleInlineAnnotationKey(keyCode: 8, modifiers: [.command, .shift]))
        #expect(!controller.testHasInlineAnnotationSession)
    }

    @Test func inlineCopyAndCloseFailureKeepsTheSessionAndAnnotations() throws {
        _ = NSApplication.shared
        let controller = SnapzyAreaSelectionController.shared
        defer {
            controller.cancelSelection()
            controller.clipboardPasteboard = .general
            controller.testFailInlineClipboardWrite = false
            controller.testResetOutputStyle()
        }
        controller.testInstallInlineAnnotationSession(image: image())
        let model = try #require(controller.testInlineAnnotationModel)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        controller.testFailInlineClipboardWrite = true

        #expect(
            controller.handleInlineAnnotationKey(
                keyCode: 8,
                modifiers: [.command, .shift]
            )
        )
        #expect(
            controller.testHasInlineAnnotationSession,
            "a failed clipboard write must not close the inline session"
        )
        #expect(model.annotations.count == 1, "the edit must survive a failed copy")
    }

    // MARK: - Delivery confirmation and Quick Access

    @Test func explicitCopyReportsClipboardSuccessToTheSelectionGate() async throws {
        let model = ScreenCaptureModel()
        model.testUpdateSettings { settings in
            settings.saveAfterCapture = false
            settings.showQuickAccess = false
            settings.pinAfterCapture = false
        }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        model.clipboardPasteboard = pasteboard

        var delivered: Bool?
        model.handleCapturedImage(
            image(),
            request: CaptureRequest(mode: .area, trigger: .shortcut, intent: .explicitCopy),
            completion: { delivered = $0 }
        )
        let deadline = Date().addingTimeInterval(30)
        while delivered == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered == true, "the HUD may only close after this success signal (delivered=\(String(describing: delivered)))")
        #expect(
            pasteboard.data(forType: .png) != nil,
            "the success signal must mean the image really reached the clipboard"
        )

        // The same signal the HUD receives is what closes it: success dismisses
        // the selection exactly once, so a copy cannot succeed with the overlay
        // left behind.
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _, _, _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true }
        )
        let dismissalsBefore = SnapzyAreaSelectionController.shared.testDismissSelectionCount
        controller.testRespondToSelectionCopyResult(true)
        #expect(
            SnapzyAreaSelectionController.shared.testDismissSelectionCount == dismissalsBefore + 1
        )
    }

    @Test func explicitCopyFailureKeepsTheSelectionAndReportsTheClipboardError() async throws {
        let model = ScreenCaptureModel()
        model.testUpdateSettings { settings in
            settings.saveAfterCapture = false
            settings.showQuickAccess = false
            settings.pinAfterCapture = false
        }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        model.clipboardPasteboard = pasteboard
        model.testFailClipboardWrite = true

        var delivered: Bool?
        model.handleCapturedImage(
            image(),
            request: CaptureRequest(mode: .area, trigger: .shortcut, intent: .explicitCopy),
            completion: { delivered = $0 }
        )
        let deadline = Date().addingTimeInterval(30)
        while delivered == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered == false, "a failed clipboard write must not report success")
        #expect(
            model.errorMessage == AppText.value("qaClipboardFailed", language: model.language),
            "the failure has to be visible to the user"
        )
        #expect(pasteboard.data(forType: .png) == nil)
    }

    @Test func areaSelectionCopyCropsTheFrozenImageAndClosesAfterCopy() async throws {
        _ = NSApplication.shared
        SnapzyAreaSelectionController.shared.testResetOutputStyle()
        let pasteboard = makePasteboard()
        defer {
            SnapzyAreaSelectionController.shared.testResetOutputStyle()
            pasteboard.releaseGlobally()
        }
        var reportedIntent: CaptureDeliveryIntent?
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _, _, _ in },
            onCaptureReporting: { image, intent, _, completion in
                reportedIntent = intent
                completion(SmartCaptureClipboard.copy(image: image, to: pasteboard))
            },
            onError: { _ in },
            screenCaptureAccessProvider: { true }
        )
        let dismissalsBefore = SnapzyAreaSelectionController.shared.testDismissSelectionCount

        controller.testFinishAreaSelectionAction(
            image: image(width: 200, height: 100),
            rect: CGRect(x: 20, y: 20, width: 80, height: 50),
            screenFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
            action: .copy
        )

        let deadline = Date().addingTimeInterval(5)
        while pasteboard.data(forType: .png) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(reportedIntent == .explicitCopy)
        let data = try #require(pasteboard.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let copied = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(copied.width == 80 && copied.height == 50)
        #expect(
            SnapzyAreaSelectionController.shared.testDismissSelectionCount > dismissalsBefore,
            "the HUD closes after the crop reaches the clipboard"
        )
    }

    @Test func clickingCopyClosesTheHUDOnlyAfterTheClipboardWriteSucceeds() async throws {
        _ = NSApplication.shared
        let model = ScreenCaptureModel()
        model.testUpdateSettings { settings in
            settings.saveAfterCapture = false
            settings.showQuickAccess = false
            settings.pinAfterCapture = false
        }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        model.clipboardPasteboard = pasteboard

        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _, _, _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true }
        )
        var delivered: Bool?
        let bar = AreaSelectionActionBar { action in
            guard action == .copy else { return }
            model.handleCapturedImage(
                image(),
                request: CaptureRequest(
                    mode: .area,
                    trigger: .shortcut,
                    intent: .explicitCopy
                ),
                completion: { copied in
                    delivered = copied
                    controller.testRespondToSelectionCopyResult(copied)
                }
            )
        }
        let copyButton = try #require(
            bar.chipButtons.first {
                $0.toolTip == AppText.value("scCopy", language: .system)
            }
        )
        let dismissalsBefore = SnapzyAreaSelectionController.shared.testDismissSelectionCount

        copyButton.performClick(nil)
        let deadline = Date().addingTimeInterval(30)
        while delivered == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(delivered == true)
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(
            SnapzyAreaSelectionController.shared.testDismissSelectionCount == dismissalsBefore + 1,
            "the real Copy button must close the selection after a confirmed clipboard write"
        )
    }

    @Test func selectionCopyFailureKeepsTheHUDAndReportsAnError() {
        var errors: [Error] = []
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _, _, _ in },
            onError: { errors.append($0) },
            screenCaptureAccessProvider: { true }
        )
        let dismissalsBefore = SnapzyAreaSelectionController.shared.testDismissSelectionCount
        controller.testRespondToSelectionCopyResult(false)
        #expect(errors.count == 1, "a failed clipboard write must surface an error")
        #expect(
            SnapzyAreaSelectionController.shared.testDismissSelectionCount == dismissalsBefore,
            "the HUD must not be dismissed on failure"
        )

        controller.testRespondToSelectionCopyResult(true)
        #expect(errors.count == 1, "success adds no error; dismissal is the only effect")
        #expect(
            SnapzyAreaSelectionController.shared.testDismissSelectionCount == dismissalsBefore + 1,
            "success dismisses the selection exactly once"
        )
    }

    @Test func quickAccessCopyRemovesOnlyThatCardAndClosesTheEmptyPanel() async throws {
        let manager = QuickAccessManager.shared
        let previousEnabled = manager.isEnabled
        let previousAutoDismiss = manager.autoDismissEnabled
        let pasteboard = makePasteboard()
        manager.clipboardPasteboard = pasteboard
        manager.isEnabled = true
        manager.autoDismissEnabled = false
        manager.dismissAll()
        defer {
            manager.dismissAll()
            manager.clipboardPasteboard = .general
            manager.autoDismissEnabled = previousAutoDismiss
            manager.isEnabled = previousEnabled
            pasteboard.releaseGlobally()
        }

        let first = TempCaptureManager.shared.saveScreenshot(image(width: 40, height: 30))!
        let second = TempCaptureManager.shared.saveScreenshot(image(width: 40, height: 30))!
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let thumbnail = NSImage(size: NSSize(width: 40, height: 30))
        let itemA = try #require(manager.addScreenshot(url: first, thumbnail: thumbnail))
        let itemB = try #require(manager.addScreenshot(url: second, thumbnail: thumbnail))
        #expect(manager.items.count == 2)

        manager.copyToClipboard(id: itemA.id)
        #expect(manager.items.count == 1, "copying one card must not touch the others")
        #expect(manager.items.first?.id == itemB.id)
        #expect(manager.testIsPanelVisible)
        #expect(pasteboard.data(forType: .png) != nil, "the card copy must reach the clipboard")

        manager.copyToClipboard(id: itemB.id)
        #expect(manager.items.isEmpty)
        // The panel dismissal is animated, and headless CI has no window
        // animation completion. The transition's watchdog runs as a MainActor
        // task, so yield the actor while waiting for the product state.
        let hideDeadline = Date().addingTimeInterval(3)
        while manager.testIsPanelVisible, Date() < hideDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!manager.testIsPanelVisible, "the last copied card closes the empty panel")
    }

    // MARK: - Copy & Close in the full editor

    @Test func sharePreparationWritesTheRenderedImageAsAStableFile() throws {
        let url = try #require(
            SmartCaptureSharing.prepareShareFile(image: image(width: 32, height: 24))
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let shared = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(shared.width == 32)
        #expect(shared.height == 24)
    }

    @Test func aCopiedScreenshotSurvivesADelayedPaste() async throws {
        let url = try #require(
            TempCaptureManager.shared.saveScreenshot(image(width: 40, height: 30))
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let artifactID = UUID()
        let captureID = UUID()

        #expect(
            SmartCaptureClipboard.copy(
                imageURL: url,
                artifactID: artifactID,
                captureID: captureID,
                to: pasteboard
            )
        )
        // Delay longer than a UI frame: the lazy provider must still read the
        // lease-protected source file when the user pastes later.
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let data = try #require(pasteboard.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let pasted = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(pasted.width == 40)
        #expect(pasted.height == 30)
    }

    @Test func quickAccessAnnotateCopyAndCloseUpdatesCardFileAndClipboard() async throws {
        let manager = QuickAccessManager.shared
        let previousEnabled = manager.isEnabled
        let previousAutoDismiss = manager.autoDismissEnabled
        let pasteboard = makePasteboard()
        manager.clipboardPasteboard = pasteboard
        manager.isEnabled = true
        manager.autoDismissEnabled = false
        manager.dismissAll()
        defer {
            manager.dismissAll()
            manager.clipboardPasteboard = .general
            manager.autoDismissEnabled = previousAutoDismiss
            manager.isEnabled = previousEnabled
            pasteboard.releaseGlobally()
        }

        let url = try #require(
            TempCaptureManager.shared.saveScreenshot(image(width: 40, height: 30))
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let thumbnail = NSImage(size: NSSize(width: 40, height: 30))
        let item = try #require(manager.addScreenshot(url: url, thumbnail: thumbnail))
        #expect(manager.presentAnnotationEditor(for: item, language: .simplifiedChinese))
        #expect(manager.testAnnotationEditingItemID == item.id)

        let annotated = image(width: 60, height: 40)
        #expect(
            manager.testCopyAndCloseAnnotatedItem(id: item.id, image: annotated),
            "a successful copy closes the editor"
        )
        #expect(manager.testAnnotationEditingItemID == nil)

        let clipboardData = try #require(pasteboard.data(forType: .png))
        let clipboardSource = try #require(
            CGImageSourceCreateWithData(clipboardData as CFData, nil)
        )
        let copied = try #require(CGImageSourceCreateImageAtIndex(clipboardSource, 0, nil))
        #expect(copied.width == 60 && copied.height == 40)

        // The background save must land on the card's own source file and the
        // thumbnail must describe those same bytes.
        let deadline = Date().addingTimeInterval(5)
        var savedSize: (Int, Int)?
        while Date() < deadline {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let saved = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                savedSize = (saved.width, saved.height)
                if let size = savedSize, size == (60, 40) { break }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(savedSize?.0 == 60 && savedSize?.1 == 40)
        let updated = try #require(manager.items.first(where: { $0.id == item.id }))
        #expect(updated.thumbnail.size == NSSize(width: 60, height: 40))
    }

    @Test func legacyHUDAttachesCopyAndCloseToTheSameClipboardTransaction() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var saved: CGImage?
        let controller = SmartQuickAccessWindowController(
            image: image(width: 40, height: 30),
            language: .simplifiedChinese,
            savedURL: nil,
            onPin: { _ in },
            onClose: {},
            onSave: { image, _ in saved = image },
            onDelete: { _ in }
        )
        controller.clipboardPasteboard = pasteboard
        controller.show()
        controller.testOpenAnnotationEditor()
        let model = try #require(controller.testAnnotationModel)
        model.append(.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))

        #expect(controller.testCopyAndCloseCurrentAnnotation())
        #expect(saved != nil, "the HUD's save callback must receive the annotated image")
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test func hudBarStaysReachableOnSmallAndLargeDisplays() {
        let barSize = CGSize(width: 710, height: 82)
        let displaySizes = [
            CGSize(width: 1_024, height: 768),
            CGSize(width: 1_280, height: 800),
            CGSize(width: 1_440, height: 900),
            CGSize(width: 1_920, height: 1_080),
        ]
        for bounds in displaySizes {
            let selections = [
                CGRect(x: bounds.width / 2 - 40, y: bounds.height / 2 - 30, width: 80, height: 60),
                CGRect(x: bounds.width - 70, y: 8, width: 60, height: 40),
                CGRect(x: 8, y: 8, width: bounds.width - 16, height: bounds.height - 16),
            ]
            for selection in selections {
                let frame = AreaSelectionBarLayout.resolve(
                    selectionRect: selection,
                    barSize: barSize,
                    bounds: bounds
                )
                #expect(frame.minX >= AreaSelectionBarLayout.edgeMargin - 0.5)
                #expect(frame.minY >= AreaSelectionBarLayout.edgeMargin - 0.5)
                #expect(frame.maxX <= bounds.width - AreaSelectionBarLayout.edgeMargin + 0.5)
                #expect(frame.maxY <= bounds.height - AreaSelectionBarLayout.edgeMargin + 0.5)
                #expect(frame.width <= bounds.width)
            }
        }
    }

    @Test func fullEditorKeepsItsActionRailReachableAtTheMinimumWindowSize() throws {
        _ = NSApplication.shared
        let controller = SmartAnnotationWindowController(
            image: image(),
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {},
            onCopyAndClose: { _ in true },
            onPin: { _ in },
            onDelete: {}
        )
        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let window = try #require(controller.testWindow)
        #expect(window.minSize.width >= 720)
        #expect(window.minSize.height >= 420)
        controller.close()
    }

    @Test func fullEditorBottomRailExposesTheHostsSupportedActions() {
        let full = SmartAnnotationWindowController(
            image: image(),
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {},
            onCopyAndClose: { _ in true },
            onPin: { _ in },
            onDelete: {}
        )
        #expect(full.actionAvailability == SmartAnnotationActionAvailability(
            share: true,
            pin: true,
            copyAndClose: true,
            delete: true,
            save: true
        ))

        let minimal = SmartAnnotationWindowController(
            image: image(),
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {}
        )
        #expect(minimal.actionAvailability == SmartAnnotationActionAvailability(
            share: true,
            pin: false,
            copyAndClose: false,
            delete: false,
            save: true
        ))
    }

    @Test func fullEditorCopyAndCloseClosesOnlyOnSuccessfulCopy() throws {
        _ = NSApplication.shared
        let source = image()
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let failing = SmartAnnotationWindowController(
            image: source,
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {},
            onCopyAndClose: { _ in false }
        )
        failing.show()
        failing.testAppendRectangle()
        #expect(!failing.testCopyAndClose(), "a failed clipboard write must keep the editor open")
        #expect(failing.testAnnotationCount == 1, "a failed copy must keep the edit on screen")
        failing.close()

        let succeeding = SmartAnnotationWindowController(
            image: source,
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {},
            onCopyAndClose: { annotated in
                SmartCaptureClipboard.copy(image: annotated, to: pasteboard)
            }
        )
        succeeding.show()
        succeeding.testAppendRectangle()
        #expect(succeeding.testCopyAndClose())
        #expect(
            pasteboard.data(forType: .png) != nil,
            "the editor's Copy & Close must write the rendered annotation"
        )
    }

    @Test func fullEditorRoutesRealKeyEventsThroughTheWindow() throws {
        _ = NSApplication.shared
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let controller = SmartAnnotationWindowController(
            image: image(),
            language: .simplifiedChinese,
            onComplete: { _ in },
            onClose: {},
            onCopyAndClose: { annotated in
                SmartCaptureClipboard.copy(image: annotated, to: pasteboard)
            }
        )
        controller.show()
        let window = try #require(controller.testWindow)

        func keyEvent(
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags,
            characters: String
        ) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        controller.testAppendRectangle()
        #expect(controller.testAnnotationCount == 1)
        _ = window.performKeyEquivalent(
            with: try keyEvent(keyCode: 6, modifiers: .command, characters: "z")
        )
        #expect(controller.testAnnotationCount == 0)
        _ = window.performKeyEquivalent(
            with: try keyEvent(keyCode: 6, modifiers: [.command, .shift], characters: "z")
        )
        #expect(controller.testAnnotationCount == 1)

        // Plain tool letter runs through the same table as the toolbar.
        _ = window.performKeyEquivalent(
            with: try keyEvent(keyCode: 31, modifiers: [], characters: "o")
        )
        #expect(controller.testCurrentTool == .ellipse)

        // With a field editor first responder, the window handler leaves Cmd+Z
        // to the text system. Use keyDown here because SwiftUI key equivalents
        // are only disabled by the real field's focus state.
        controller.testAppendRectangle()
        #expect(controller.testAnnotationCount == 2)
        _ = controller.testInstallTextEditorFirstResponder()
        window.keyDown(
            with: try keyEvent(keyCode: 6, modifiers: .command, characters: "z")
        )
        #expect(controller.testAnnotationCount == 2, "text editing owns Cmd+Z")

        // Return focus to the canvas before the Copy & Close shortcut.
        window.makeFirstResponder(window.contentView)
        // Cmd+Shift+C copies the final render and closes the window.
        _ = window.performKeyEquivalent(
            with: try keyEvent(keyCode: 8, modifiers: [.command, .shift], characters: "c")
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(controller.testWindow == nil)
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test func fullEditorUndoAndRedoShortcutsYieldToTextEditing() {
        #expect(SmartAnnotationEditor.undoShortcut(isEditingText: false) != nil)
        #expect(SmartAnnotationEditor.redoShortcut(isEditingText: false) != nil)
        #expect(
            SmartAnnotationEditor.undoShortcut(isEditingText: true) == nil,
            "Cmd+Z belongs to the focused text field"
        )
        #expect(
            SmartAnnotationEditor.redoShortcut(isEditingText: true) == nil,
            "Cmd+Shift+Z belongs to the focused text field"
        )
    }
}
