//
//  SnapzyAreaSelectionController.swift
//  MacPilot adapter for Snapzy's AreaSelectionWindow/AreaSelectionOverlayView.
//
//  The window and overlay implementation is migrated from Snapzy unchanged;
//  this small coordinator connects selection callbacks to MacPilot's capture
//  pipeline and keeps the PixPin-style post-selection HUD alive until an
//  explicit action is chosen.
//

import AppKit
import Foundation
import SwiftUI

enum SnapzyInlineAnnotationShortcutRouting {
    /// While a chrome-less annotation session is live, every terminal action
    /// (pin/copy/save/ocr) commits the session instead of hitting the HUD.
    static func shouldCommitInlineAnnotation(
        action: AreaSelectionAction,
        hasInlineAnnotationEditor: Bool
    ) -> Bool {
        hasInlineAnnotationEditor && Self.terminalActions.contains(action)
    }

    static let terminalActions: [AreaSelectionAction] = [
        .pin, .copy, .save, .ocr, .upload, .capture,
    ]
}

/// Output post-processing applied when the capture is committed (iShot's
/// 圆角截图 / 阴影或边框 side-bar toggles).
nonisolated struct SmartCaptureOutputStyle: Equatable, Sendable {
    var roundedCorners: Bool
    var cornerRadius: CGFloat
    var shadow: Bool

    static let inactive = SmartCaptureOutputStyle(roundedCorners: false, cornerRadius: 0, shadow: false)
}

@MainActor
final class SnapzyAreaSelectionController: NSObject, AreaSelectionWindowDelegate {
    static let shared = SnapzyAreaSelectionController()

    private var windows: [AreaSelectionWindow] = []
    private var completion: AreaSelectionResultCompletion?
    private var selectionPreview: ((AreaSelectionResult) -> Void)?
    private var actionHandler: ((AreaSelectionResult, AreaSelectionAction) -> Void)?
    private var selectedResult: AreaSelectionResult?
    private weak var selectedWindow: AreaSelectionWindow?
    private var selectionMode: SelectionMode = .screenshot
    private var interactionMode: AreaSelectionInteractionMode = .manualRegion
    private var manualStart: CGPoint?
    private var manualRect: CGRect?
    private var postSelectionPinShortcut = ScreenCaptureShortcutKind.postSelectionPin.defaultBinding
    private var sessionID = UUID()
    private var inlineAnnotationModel: SmartAnnotationModel?
    private var inlineAnnotationImage: CGImage?
    private var inlineAnnotationScaleFactor: CGFloat = 1
    private var inlineAnnotationActionHandler: ((CGImage, AreaSelectionAction) -> Void)?
    private var inlineAnnotationCancelHandler: (() -> Void)?
    private(set) var isRoundedCornersEnabled = false
    private(set) var isShadowEnabled = false
    static let defaultOutputCornerRadius: CGFloat = 12

    var outputStyle: SmartCaptureOutputStyle {
        SmartCaptureOutputStyle(
            roundedCorners: isRoundedCornersEnabled,
            cornerRadius: isRoundedCornersEnabled ? Self.defaultOutputCornerRadius : 0,
            shadow: isShadowEnabled
        )
    }

    var hasInlineAnnotationSession: Bool {
        inlineAnnotationModel != nil
    }

    private override init() {
        super.init()
    }

    var isPresenting: Bool { !windows.isEmpty }

    #if DEBUG
      var testWindows: [AreaSelectionWindow] { windows }
    #endif

    @discardableResult
    func startSelection(
        mode: SelectionMode = .screenshot,
        backdrops: [CGDirectDisplayID: AreaSelectionBackdrop] = [:],
        applicationConfiguration: AreaSelectionApplicationConfiguration? = nil,
        initialInteractionMode: AreaSelectionInteractionMode = .manualRegion,
        postSelectionPinShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.postSelectionPin.defaultBinding,
        elementTargetResolver: ((CGPoint) -> CGRect?)? = nil,
        sessionID requestedSessionID: UUID? = nil,
        selectionPreview: ((AreaSelectionResult) -> Void)? = nil,
        actionHandler: ((AreaSelectionResult, AreaSelectionAction) -> Void)? = nil,
        completion: @escaping AreaSelectionResultCompletion
    ) -> UUID {
        cancelSelection()

        selectionMode = mode
        interactionMode = initialInteractionMode
        self.completion = completion
        self.selectionPreview = selectionPreview
        self.actionHandler = actionHandler
        self.postSelectionPinShortcut = postSelectionPinShortcut
        selectedResult = nil
        selectedWindow = nil
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        isRoundedCornersEnabled = false
        isShadowEnabled = false
        sessionID = requestedSessionID ?? UUID()

        let sessionID = self.sessionID
        let screens = NSScreen.screens
        windows = screens.map { screen in
            // Build the panel completely while hidden.  The non-pooled
            // initializer orders the window immediately, and the old path
            // then ordered it again after configuring the backdrop/mode.  On
            // a shortcut-driven capture that produced a visible flash before
            // the frozen frame had arrived.
            let window = AreaSelectionWindow(screen: screen, pooled: true)
            window.selectionDelegate = self
            window.updateSelectionMode(mode)
            window.setReceivesKeyboardInput(true)
            window.overlayView.setAllowsApplicationWindowSelection(applicationConfiguration != nil)
            window.overlayView.setElementTargetResolver(elementTargetResolver)
            window.overlayView.setInteractionMode(initialInteractionMode)
            if let displayID = screen.displayID,
               let backdrop = backdrops[displayID] {
                window.overlayView.applyBackdrop(backdrop)
            }
            return window
        }

        if applicationConfiguration != nil {
            let task = applicationConfiguration?.prefetchedContentTask
            Task { @MainActor [weak self] in
                let snapshot = await WindowSelectionQueryService.prepareSnapshot(
                    prefetchedContentTask: task,
                    excludeOwnApplication: applicationConfiguration?.excludeOwnApplication ?? true
                )
                guard let self, self.sessionID == sessionID else { return }
                for window in self.windows {
                    window.overlayView.setWindowSelectionSnapshot(snapshot)
                }
            }
        }

        let pointer = NSEvent.mouseLocation
        let activeWindow = windows.first(where: { $0.frame.contains(pointer) }) ?? windows.first
        // Order the non-active display panels first, then present the panel
        // under the pointer with one combined order+key operation. Keeping
        // those operations together avoids a WindowServer composition frame
        // where the shortcut overlay is visible but not yet the key window.
        for window in windows where window !== activeWindow {
            window.orderFrontRegardless()
        }
        activeWindow?.makeKeyAndOrderFront(nil)
        activeWindow?.activateKeyboardInputIfNeeded()
        NSCursor.crosshair.set()
        return sessionID
    }

    func isPresenting(sessionID: UUID) -> Bool {
        self.sessionID == sessionID && !windows.isEmpty
    }

    /// 刷新截图 support: temporarily hides every selection panel so a fresh
    /// capture cannot include the overlay itself.
    func setPanelsHiddenForRefresh(_ hidden: Bool) {
        for window in windows {
            window.setPanelHiddenForRefresh(hidden)
        }
    }

    func updateBackdrops(
        _ backdrops: [CGDirectDisplayID: AreaSelectionBackdrop],
        for sessionID: UUID
    ) {
        guard self.sessionID == sessionID, !windows.isEmpty else { return }
        for window in windows {
            guard let displayID = window.displayID,
                  let backdrop = backdrops[displayID] else { continue }
            window.overlayView.applyBackdrop(backdrop)
        }
    }

    func cancelSelection() {
        guard !windows.isEmpty || completion != nil else { return }
        let oldWindows = windows
        windows.removeAll(keepingCapacity: false)
        completion = nil
        selectionPreview = nil
        actionHandler = nil
        selectedResult = nil
        selectedWindow = nil
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        sessionID = UUID()
        for window in oldWindows {
            window.overlayView.clearBackdrop()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        NSCursor.arrow.set()
    }

    /// Closes a post-selection HUD after an action has been handed to the
    /// capture coordinator.  Unlike `cancelSelection`, this does not invoke
    /// the completion callback a second time.
    func dismissSelection() {
        guard !windows.isEmpty else { return }
        let oldWindows = windows
        windows.removeAll(keepingCapacity: false)
        completion = nil
        selectionPreview = nil
        actionHandler = nil
        selectedResult = nil
        selectedWindow = nil
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        sessionID = UUID()
        for window in oldWindows {
            window.overlayView.hideSelectionResult()
            window.overlayView.clearBackdrop()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        NSCursor.arrow.set()
    }

    private func complete(_ result: AreaSelectionResult?) {
        guard let completion else {
            cancelSelection()
            return
        }
        let currentWindows = windows
        self.completion = nil
        selectionPreview = nil
        actionHandler = nil
        selectedResult = nil
        selectedWindow = nil
        windows.removeAll(keepingCapacity: false)
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        for window in currentWindows {
            // A committed selection follows a different teardown path from
            // cancel/dismiss. Clear the layer contents and the cached luma
            // bitmap before closing so a full-display frozen frame cannot be
            // retained by the window/layer tree after the HUD is gone.
            window.overlayView.clearBackdrop()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        NSCursor.arrow.set()
        completion(result)
    }

    private func result(for target: AreaSelectionTarget, in window: AreaSelectionWindow) -> AreaSelectionResult? {
        guard let displayID = window.displayID else { return nil }
        let rect = target.rect
        let displayIDs = Set(
            NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
                guard let candidateID = screen.displayID,
                      screen.frame.intersects(rect)
                else { return nil }
                return candidateID
            }
        )
        return AreaSelectionResult(
            target: target,
            displayID: displayID,
            mode: selectionMode,
            displayIDs: displayIDs.isEmpty ? [displayID] : displayIDs
        )
    }

    private func presentSelection(_ result: AreaSelectionResult, in window: AreaSelectionWindow) {
        guard let selectionPreview else {
            complete(result)
            return
        }

        selectedResult = result
        selectedWindow = window
        for candidate in windows {
            candidate.overlayView.showSelectionResult(
                screenRect: result.rect,
                showsActions: candidate === window,
                actionHandler: { [weak self, weak candidate] action in
                    guard let self, let candidate else { return }
                    self.areaSelectionWindow(candidate, didRequestAction: action)
                }
            )
        }
        selectionPreview(result)
    }

    // MARK: - AreaSelectionWindowDelegate

    func areaSelectionWindow(_ window: AreaSelectionWindow, didSelectRect rect: CGRect) {
        guard let result = result(for: .rect(rect), in: window) else {
            complete(nil)
            return
        }
        presentSelection(result, in: window)
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didSelectWindow target: WindowCaptureTarget) {
        guard let result = result(for: .window(target), in: window) else {
            complete(nil)
            return
        }
        presentSelection(result, in: window)
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didRequestAction action: AreaSelectionAction) {
        guard let selectedResult else {
            if action == .cancel { complete(nil) }
            return
        }
        if action == .cancel {
            complete(nil)
            return
        }
        if action == .newSelection {
            // PixPin keeps the same frozen-display session alive while the
            // user starts another drag. Do not send this through the capture
            // pipeline or dismiss the overlay.
            self.selectedResult = nil
            self.selectedWindow = nil
            for candidate in windows {
                candidate.overlayView.hideSelectionResult()
            }
            return
        }
        if action == .adjustSelection {
            // Make the button observable and enter the same frame-editing
            // state used by the resize handles.  Previously this branch was
            // a no-op, so the button appeared dead even though the handles
            // happened to work when grabbed directly.
            selectedWindow?.overlayView.beginSelectionAdjustment()
            return
        }
        if action == .more {
            // Adjustment is performed directly by dragging the frame/handles;
            // the More button opens its own menu and never tears down the HUD.
            return
        }
        if action == .toggleRoundedCorners {
            isRoundedCornersEnabled.toggle()
            syncOutputStyleToggles()
            return
        }
        if action == .toggleShadow {
            isShadowEnabled.toggle()
            syncOutputStyleToggles()
            return
        }
        guard let actionHandler else {
            complete(selectedResult)
            return
        }
        actionHandler(selectedResult, action)
    }

    private func syncOutputStyleToggles() {
        selectedWindow?.overlayView.syncOutputStyleToggles(
            roundedCorners: isRoundedCornersEnabled,
            shadow: isShadowEnabled
        )
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didChangeSelectionRect rect: CGRect) {
        guard selectedWindow === window,
              let updated = result(for: .rect(rect), in: window) else { return }
        selectedResult = updated
        for candidate in windows {
            candidate.overlayView.updateSelectionResult(screenRect: updated.rect)
        }
        selectionPreview?(updated)
    }

    /// Installs the chrome-less annotation editor directly over the selected
    /// frame (iShot-style in-place editing).  The blue border, resize handles,
    /// coordinate bubble and the HUD toolbar stay visible; the toolbar's tool
    /// buttons switch tools on the live model and its action buttons route the
    /// rendered image through `onAction`.  No second window is created.
    @discardableResult
    func presentInlineAnnotationSession(
        image: CGImage,
        scaleFactor: CGFloat,
        language: AppLanguage,
        initialTool: AreaSelectionAnnotationTool,
        onAction: @escaping (CGImage, AreaSelectionAction) -> Void,
        onCancel: @escaping () -> Void
    ) -> Bool {
        guard let selectedWindow, let selectedResult else { return false }
        let toolbarPlacement = SmartAnnotationEditor.toolbarPlacement(
            for: selectedResult.rect,
            in: selectedWindow.frame
        )
        let model = SmartAnnotationModel(initialTool: initialTool.smartAnnotationTool)
        inlineAnnotationModel = model
        inlineAnnotationImage = image
        inlineAnnotationScaleFactor = scaleFactor
        inlineAnnotationActionHandler = onAction
        inlineAnnotationCancelHandler = onCancel

        let editor = NSHostingView(rootView: SmartAnnotationEditor(
            image: image,
            language: language,
            model: model,
            embedded: true,
            showsToolbar: false,
            embeddedToolbarPlacement: toolbarPlacement,
            embeddedCanvasSize: selectedResult.rect.size,
            onCancel: { [weak self] in
                self?.commitInlineAnnotation(as: .cancel)
            },
            onComplete: { [weak self] in
                self?.commitInlineAnnotation(as: .save)
            }
        ))
        selectedWindow.overlayView.showEmbeddedAnnotationEditor(
            editor,
            screenRect: selectedResult.rect,
            toolbarPlacement: toolbarPlacement,
            showsToolbar: false
        )
        selectedWindow.overlayView.attachAnnotationSession(model: model) { [weak self] action in
            self?.commitInlineAnnotation(as: action)
        }
        return true
    }

    private func clearInlineAnnotationSession() {
        inlineAnnotationModel = nil
        inlineAnnotationImage = nil
        inlineAnnotationScaleFactor = 1
        inlineAnnotationActionHandler = nil
        inlineAnnotationCancelHandler = nil
    }

    /// Renders the live annotations and routes the final image through the
    /// capture coordinator for the requested action.  Non-terminal actions
    /// (toggles/refresh) are ignored here — they never end the session.
    func commitInlineAnnotation(as action: AreaSelectionAction) {
        guard let model = inlineAnnotationModel else { return }
        switch action {
        case .cancel:
            let onCancel = inlineAnnotationCancelHandler
            clearInlineAnnotationSession()
            dismissSelection()
            onCancel?()
            return
        case .toggleRoundedCorners, .toggleShadow, .refreshCapture,
             .newSelection, .adjustSelection, .more, .annotate, .annotateTool:
            return
        default:
            break
        }
        guard let image = inlineAnnotationImage,
              let rendered = SmartAnnotationRenderer.render(
                  image: image,
                  annotations: model.annotations,
                  styles: model.styledAnnotations.map(\.style)
              )
        else { return }
        let output = SmartCaptureOutputStyling.apply(
            to: rendered,
            style: outputStyle,
            scaleFactor: inlineAnnotationScaleFactor
        )
        let handler = inlineAnnotationActionHandler
        clearInlineAnnotationSession()
        dismissSelection()
        handler?(output, action)
    }

    func areaSelectionWindowDidCancel(_: AreaSelectionWindow) {
        complete(nil)
    }

    func areaSelectionWindowDidBecomeActive(_ window: AreaSelectionWindow) {
        window.activateKeyboardInputIfNeeded()
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didReceiveKeyEvent event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if hasInlineAnnotationSession {
                // Esc during the in-place session discards the annotations and
                // tears the capture down through the cancel path.
                commitInlineAnnotation(as: .cancel)
            } else {
                // Notify the capture coordinator so it can resume Quick Access
                // and release the frozen display session.  `cancelSelection()`
                // is intentionally silent because it is also used while starting
                // a replacement session.
                complete(nil)
            }
            return true
        }
        let eventModifiers = InputSourceShortcutModifiers(event.modifierFlags)
        if !event.isARepeat,
           event.keyCode == postSelectionPinShortcut.keyCode,
           eventModifiers == postSelectionPinShortcut.modifiers {
            if hasInlineAnnotationSession {
                commitInlineAnnotation(as: .pin)
            } else if selectedResult != nil {
                areaSelectionWindow(window, didRequestAction: .pin)
            }
            return true
        }
        guard let selectedResult else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 8, modifiers == [.command] || modifiers == [.control] {
            commitOrRequest(.copy, window: window)
            return true
        }
        if event.keyCode == 1, modifiers == [.command] || modifiers == [.control] {
            commitOrRequest(.save, window: window)
            return true
        }
        if hasInlineAnnotationSession, [123, 124, 125, 126].contains(event.keyCode) {
            // Arrow keys nudge the text caret while typing; never move the
            // frame underneath a live annotation session.
            return true
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            let delta: CGFloat = 1
            var rect = selectedResult.rect
            let isShrinking = modifiers.contains(.shift)
            let isExpanding = modifiers.contains(.control)
            if isShrinking || isExpanding {
                let amount = isShrinking ? -delta : delta
                switch event.keyCode {
                case 123: rect.size.width += amount
                case 124:
                    rect.origin.x -= amount
                    rect.size.width += amount
                case 125: rect.size.height += amount
                case 126:
                    rect.origin.y -= amount
                    rect.size.height += amount
                default: break
                }
            } else {
                switch event.keyCode {
                case 123: rect.origin.x -= delta
                case 124: rect.origin.x += delta
                case 125: rect.origin.y -= delta
                case 126: rect.origin.y += delta
                default: break
                }
            }
            guard rect.width >= 4, rect.height >= 4 else { return true }
            areaSelectionWindow(window, didChangeSelectionRect: rect)
            return true
        }
        if event.keyCode == 36, modifiers.isEmpty {
            // Enter confirms the session like the classic editor's Done button;
            // without a live session it keeps the historical copy action.
            commitOrRequest(hasInlineAnnotationSession ? .save : .copy, window: window)
            return true
        }
        return false
    }

    /// Routes a terminal action through the inline session commit when one is
    /// live, otherwise to the post-selection action pipeline.
    private func commitOrRequest(_ action: AreaSelectionAction, window: AreaSelectionWindow) {
        if hasInlineAnnotationSession {
            commitInlineAnnotation(as: action)
        } else {
            areaSelectionWindow(window, didRequestAction: action)
        }
    }

    func areaSelectionWindowDidRequestDisplayActivation(_ window: AreaSelectionWindow) {
        window.activateKeyboardInputIfNeeded()
    }

    func areaSelectionWindowDidRequestImmediateManualSelection(_: AreaSelectionWindow) {}

    func areaSelectionWindow(_ window: AreaSelectionWindow, manualSelectionBeganAt screenPoint: CGPoint) {
        manualStart = screenPoint
        manualRect = .zero
        window.overlayView.renderManualSelection(screenRect: .zero, currentScreenPoint: screenPoint)
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, manualSelectionChangedTo screenPoint: CGPoint) {
        guard let manualStart else { return }
        let rect = CGRect(
            x: min(manualStart.x, screenPoint.x),
            y: min(manualStart.y, screenPoint.y),
            width: abs(screenPoint.x - manualStart.x),
            height: abs(screenPoint.y - manualStart.y)
        )
        manualRect = rect
        window.overlayView.renderManualSelection(screenRect: rect, currentScreenPoint: screenPoint)
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, manualSelectionEndedAt screenPoint: CGPoint) {
        guard let manualStart else {
            complete(nil)
            return
        }
        let rect = CGRect(
            x: min(manualStart.x, screenPoint.x),
            y: min(manualStart.y, screenPoint.y),
            width: abs(screenPoint.x - manualStart.x),
            height: abs(screenPoint.y - manualStart.y)
        )
        guard rect.width >= 2, rect.height >= 2 else {
            complete(nil)
            return
        }
        guard let result = result(for: .rect(rect), in: window) else {
            complete(nil)
            return
        }
        presentSelection(result, in: window)
    }
}
