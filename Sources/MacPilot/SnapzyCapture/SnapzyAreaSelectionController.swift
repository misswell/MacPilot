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

/// Reference-counted hide ownership for 刷新截图. Each refresh takes a token;
/// panels are hidden on the first token and revealed only when the last one
/// for the *visible* session is released. A cancelled session's late
/// completion therefore cannot reveal a newer session's panels.
nonisolated struct RefreshHideLedger {
    private var tokensBySession: [UUID: Set<UUID>] = [:]

    enum ReleaseResult: Equatable {
        case untouched
        case stillHidden
        case reveal
    }

    mutating func begin(sessionID: UUID) -> (token: UUID, hide: Bool) {
        let token = UUID()
        let shouldHide = tokensBySession[sessionID]?.isEmpty ?? true
        tokensBySession[sessionID, default: []].insert(token)
        return (token, shouldHide)
    }

    mutating func end(token: UUID, sessionID: UUID) -> ReleaseResult {
        guard var tokens = tokensBySession[sessionID],
              tokens.remove(token) != nil else { return .untouched }
        guard tokens.isEmpty else {
            tokensBySession[sessionID] = tokens
            return .stillHidden
        }
        tokensBySession[sessionID] = nil
        return .reveal
    }

    mutating func endAll(sessionID: UUID) -> ReleaseResult {
        guard let tokens = tokensBySession.removeValue(forKey: sessionID),
              !tokens.isEmpty else { return .untouched }
        return .reveal
    }

    func isHolding(sessionID: UUID) -> Bool {
        !(tokensBySession[sessionID]?.isEmpty ?? true)
    }
}

@MainActor
final class SnapzyAreaSelectionController: NSObject, AreaSelectionWindowDelegate {
    static let shared = SnapzyAreaSelectionController()

    /// Tests exercise real multi-display selection without presenting windows
    /// or changing the user's cursor. The shipping instance uses AppKit.
    private let presentationEffect: (([AreaSelectionWindow]) -> Void)?
    private let cursorSetEffect: (NSCursor) -> Void

    init(
        presentationEffect: (([AreaSelectionWindow]) -> Void)? = nil,
        cursorSetEffect: @escaping (NSCursor) -> Void = { $0.set() }
    ) {
        self.presentationEffect = presentationEffect
        self.cursorSetEffect = cursorSetEffect
        super.init()
    }

    private var windows: [AreaSelectionWindow] = []
    private var completion: AreaSelectionResultCompletion?
    private var selectionPreview: ((AreaSelectionResult) -> Void)?
    private var actionHandler: ((AreaSelectionResult, AreaSelectionAction) -> Void)?
    /// Supplies the exact pixel size of the crop a result will produce, so the
    /// dimension badge can show real pixels instead of the point size.
    private var selectionPixelSizeProvider: ((AreaSelectionResult) -> CGSize?)?
    private var selectedResult: AreaSelectionResult?
    private weak var selectedWindow: AreaSelectionWindow?
    private var selectionMode: SelectionMode = .screenshot
    private var recordingSelectionConfiguration: RecordingSelectionBarConfiguration?
    private var interactionMode: AreaSelectionInteractionMode = .manualRegion
    private var manualStart: CGPoint?
    private var manualRect: CGRect?
    private var postSelectionPinShortcut = ScreenCaptureShortcutKind.postSelectionPin.defaultBinding
    private var sessionID = UUID()
    private var inlineAnnotationModel: SmartAnnotationModel?
    private var inlineAnnotationImage: CGImage?
    private var inlineAnnotationScaleFactor: CGFloat = 1
    private var inlineAnnotationLanguage: AppLanguage = .system
    private var inlineAnnotationActionHandler: ((CGImage, AreaSelectionAction) -> Void)?
    private var inlineAnnotationCancelHandler: (() -> Void)?
    /// Clipboard surface for inline Copy / Copy & Close. Production always uses
    /// the system pasteboard; tests inject an isolated pasteboard so a capture
    /// test can never clear or overwrite the user's clipboard.
    var clipboardPasteboard: NSPasteboard = .general
    #if DEBUG
    /// Test seam: force the clipboard write to fail without building a
    /// persistent fake pasteboard.
    var testFailInlineClipboardWrite = false
    #endif
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
        presentationEffect = nil
        cursorSetEffect = { $0.set() }
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
        recordingConfiguration: RecordingSelectionBarConfiguration? = nil,
        pixelSizeProvider: ((AreaSelectionResult) -> CGSize?)? = nil,
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
        self.selectionPixelSizeProvider = pixelSizeProvider
        self.postSelectionPinShortcut = postSelectionPinShortcut
        self.recordingSelectionConfiguration = recordingConfiguration
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
            if applicationConfiguration != nil {
                window.overlayView.setWindowSelectionSnapshot(nil, state: .loading)
            }
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
            let sessionPanels = windows
            Task { @MainActor [weak self] in
                // These panels are the only windows removed from the candidate list, so
                // the hit test can never land on the selection overlay while still
                // reaching MacPilot's own windows.  Window numbers are read here rather
                // than above because WindowServer assigns them on presentation.
                let excludedWindowIDs = Set(
                    sessionPanels.map(\.windowNumber).filter { $0 > 0 }.map(CGWindowID.init)
                )
                let outcome = await WindowSelectionQueryService.prepareSnapshot(
                    prefetchedContentTask: task,
                    excludedWindowIDs: excludedWindowIDs
                )
                guard let self, self.sessionID == sessionID else { return }
                for window in self.windows {
                    switch outcome {
                    case .ready(let snapshot):
                        window.overlayView.setWindowSelectionSnapshot(snapshot, state: .ready)
                    case .failed:
                        window.overlayView.setWindowSelectionSnapshot(nil, state: .failed)
                    }
                }
            }
        }

        if let presentationEffect {
            presentationEffect(windows)
        } else {
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
        }
        cursorSetEffect(.crosshair)
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

    // Refresh hides are token owned: a late completion may only release the
    // hide it took, and a cancelled session can never reveal a newer one's
    // still-hidden panels.
    private var refreshHideLedger = RefreshHideLedger()

    func beginRefreshHide(for sessionID: UUID) -> UUID? {
        guard self.sessionID == sessionID, !windows.isEmpty else { return nil }
        let grant = refreshHideLedger.begin(sessionID: sessionID)
        if grant.hide { setPanelsHiddenForRefresh(true) }
        return grant.token
    }

    func endRefreshHide(_ token: UUID, for sessionID: UUID) {
        switch refreshHideLedger.end(token: token, sessionID: sessionID) {
        case .untouched, .stillHidden:
            return
        case .reveal:
            // Only the session that owns the visible panels may reveal them.
            guard self.sessionID == sessionID else { return }
            setPanelsHiddenForRefresh(false)
        }
    }

    func endAllRefreshHides(for sessionID: UUID) {
        guard refreshHideLedger.endAll(sessionID: sessionID) == .reveal else { return }
        guard self.sessionID == sessionID else { return }
        setPanelsHiddenForRefresh(false)
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
        recordingSelectionConfiguration = nil
        selectedResult = nil
        selectedWindow = nil
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        refreshHideLedger = RefreshHideLedger()
        selectionPixelSizeProvider = nil
        sessionID = UUID()
        for window in oldWindows {
            window.overlayView.clearBackdrop()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        cursorSetEffect(.arrow)
    }

    /// Closes a post-selection HUD after an action has been handed to the
    /// capture coordinator.  Unlike `cancelSelection`, this does not invoke
    /// the completion callback a second time.
    #if DEBUG
    /// Test seam: how many times a real dismissal was requested. The copy
    /// failure path must not increment it.
    private(set) var testDismissSelectionCount = 0
    #endif

    func dismissSelection() {
        #if DEBUG
        testDismissSelectionCount += 1
        #endif
        guard !windows.isEmpty else { return }
        let oldWindows = windows
        windows.removeAll(keepingCapacity: false)
        completion = nil
        selectionPreview = nil
        actionHandler = nil
        recordingSelectionConfiguration = nil
        selectedResult = nil
        selectedWindow = nil
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        refreshHideLedger = RefreshHideLedger()
        selectionPixelSizeProvider = nil
        sessionID = UUID()
        for window in oldWindows {
            window.overlayView.hideSelectionResult()
            window.overlayView.clearBackdrop()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        cursorSetEffect(.arrow)
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
        recordingSelectionConfiguration = nil
        selectedResult = nil
        selectedWindow = nil
        windows.removeAll(keepingCapacity: false)
        manualStart = nil
        manualRect = nil
        clearInlineAnnotationSession()
        refreshHideLedger = RefreshHideLedger()
        selectionPixelSizeProvider = nil
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
        cursorSetEffect(.arrow)
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
        let pixelSize = selectionPixelSizeProvider?(result)
        for candidate in windows {
            let actionHandler: (AreaSelectionAction) -> Void = { [weak self, weak candidate] action in
                guard let self, let candidate else { return }
                self.areaSelectionWindow(candidate, didRequestAction: action)
            }
            if selectionMode == .recording,
               candidate === window,
               let recordingSelectionConfiguration {
                candidate.overlayView.showRecordingSelectionResult(
                    screenRect: result.rect,
                    pixelSize: pixelSize,
                    configuration: recordingSelectionConfiguration,
                    actionHandler: actionHandler
                )
            } else {
                candidate.overlayView.showSelectionResult(
                    screenRect: result.rect,
                    pixelSize: pixelSize,
                    showsActions: candidate === window,
                    actionHandler: actionHandler
                )
            }
        }
        selectionPreview(result)
        // The HUD's 「更多」 menu renders the style toggles, so mirror the
        // session-scoped state into the freshly installed bar.
        syncOutputStyleToggles()
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
            //
            // Drop a live annotation session here. `hideSelectionResult()`
            // only tears down the editor view; leaving `inlineAnnotationModel`
            // set would make the next commit render and deliver the abandoned
            // annotation image. The HUD no longer offers 重新选择 while a
            // session is live, but the state machine must not rely on that.
            clearInlineAnnotationSession()
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
        if selectionMode == .recording {
            switch action {
            case .recordingAspectLandscape:
                reframeRecordingSelection(to: 16.0 / 9.0)
                return
            case .recordingAspectPortrait:
                reframeRecordingSelection(to: 9.0 / 16.0)
                return
            default:
                break
            }
        }
        if action == .toggleRoundedCorners || action == .toggleShadow {
            setOutputStyleToggle(action)
            return
        }
        guard let actionHandler else {
            complete(selectedResult)
            return
        }
        actionHandler(selectedResult, action)
    }

    /// Single source of truth for the output-style toggles (圆角截图 / 阴影或边框).
    /// The HUD's 「更多」 menu ticks them from this state, and both the
    /// post-selection pipeline and a live inline annotation session commit
    /// through `outputStyle`.
    private func setOutputStyleToggle(_ action: AreaSelectionAction) {
        if action == .toggleRoundedCorners { isRoundedCornersEnabled.toggle() }
        if action == .toggleShadow { isShadowEnabled.toggle() }
        syncOutputStyleToggles()
    }

    private func reframeRecordingSelection(to aspect: CGFloat) {
        guard let selectedWindow, let selectedResult else { return }
        let fitted = RecordingRegionFraming.rectFitting(
            selectedResult.rect,
            aspect: aspect,
            in: selectedWindow.frame
        )
        guard fitted.width >= 4, fitted.height >= 4,
              let updated = result(for: .rect(fitted), in: selectedWindow) else { return }
        self.selectedResult = updated
        let pixelSize = selectionPixelSizeProvider?(updated)
        for candidate in windows {
            candidate.overlayView.updateSelectionResult(screenRect: updated.rect, pixelSize: pixelSize)
        }
        selectionPreview?(updated)
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
        let pixelSize = selectionPixelSizeProvider?(updated)
        for candidate in windows {
            candidate.overlayView.updateSelectionResult(screenRect: updated.rect, pixelSize: pixelSize)
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
        inlineAnnotationLanguage = language
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
            },
            onDoubleClickCanvas: { [weak self] in
                self?.commitInlineAnnotation(as: .copyAndClose)
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

    #if DEBUG
    /// Test seam: installs an inline session without a live selection window so
    /// the copy/undo semantics can be exercised headlessly.
    func testInstallInlineAnnotationSession(
        image: CGImage,
        initialTool: SmartAnnotationTool = .rectangle,
        onAction: @escaping (CGImage, AreaSelectionAction) -> Void = { _, _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        inlineAnnotationModel = SmartAnnotationModel(initialTool: initialTool)
        inlineAnnotationImage = image
        inlineAnnotationScaleFactor = 1
        inlineAnnotationLanguage = .system
        inlineAnnotationActionHandler = onAction
        inlineAnnotationCancelHandler = onCancel
    }

    var testInlineAnnotationModel: SmartAnnotationModel? { inlineAnnotationModel }
    var testHasInlineAnnotationSession: Bool { hasInlineAnnotationSession }
    #endif

    private func clearInlineAnnotationSession() {
        inlineAnnotationModel = nil
        inlineAnnotationImage = nil
        inlineAnnotationScaleFactor = 1
        inlineAnnotationLanguage = .system
        inlineAnnotationActionHandler = nil
        inlineAnnotationCancelHandler = nil
    }

    /// Copies the current annotated render while keeping the inline session
    /// alive (Snapzy's Inline `Copy`). Only the clipboard is touched: no
    /// Quick Access card is created for a non-terminal copy. The round-corner /
    /// shadow toggles apply here exactly as they do for Done, so Copy and
    /// Copy & Close never disagree about the delivered pixels.
    @discardableResult
    func copyInlineAnnotationWithoutClosing() -> Bool {
        guard let model = inlineAnnotationModel,
              let image = inlineAnnotationImage,
              let rendered = SmartAnnotationRenderer.render(
                  image: image,
                  annotations: model.annotations,
                  styles: model.styledAnnotations.map(\.style)
              )
        else { return false }
        let output = SmartCaptureOutputStyling.apply(
            to: rendered,
            style: outputStyle,
            scaleFactor: inlineAnnotationScaleFactor
        )
        #if DEBUG
        if testFailInlineClipboardWrite {
            showInlineClipboardFailure()
            return false
        }
        #endif
        guard SmartCaptureClipboard.copy(
            image: output,
            to: clipboardPasteboard
        ) else {
            showInlineClipboardFailure()
            return false
        }
        return true
    }

    private func showInlineClipboardFailure() {
        let language = inlineAnnotationLanguage
        let error = NSError(
            domain: "MacPilot.Clipboard",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: AppText.value("qaClipboardFailed", language: language)]
        )
        SmartCaptureToast.shared.showFailure(error: error, language: language)
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
        case .toggleRoundedCorners, .toggleShadow:
            // The style toggles are non-terminal and shared with the
            // post-selection HUD. Before, they were swallowed here, so the
            // 「更多」 menu's 圆角截图 / 阴影或边框 did nothing during a live
            // session even though the commit path honours `outputStyle`.
            setOutputStyleToggle(action)
            return
        case .copy:
            // The visible Copy action keeps the inline session alive, matching
            // Snapzy. Only Copy & Close / Done end the session.
            copyInlineAnnotationWithoutClosing()
            return
        case .copyAndClose:
            // Copy first, close only when the clipboard write succeeded: a
            // failed copy must leave the user's annotations on screen.
            if copyInlineAnnotationWithoutClosing() {
                clearInlineAnnotationSession()
                dismissSelection()
            }
            return
        case .refreshCapture, .scrollingCapture, .newSelection, .adjustSelection, .more, .annotate, .annotateTool:
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
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // While a text field is the first responder, Cmd+Z/Cmd+Shift+Z belong to
        // the text editor. Routing them to the annotation history would undo
        // the whole picture instead of the character the user just typed.
        let editingText = window.firstResponder is NSTextView
        if handleInlineAnnotationKey(keyCode: event.keyCode, modifiers: modifiers, editingText: editingText) {
            return true
        }
        guard let selectedResult else { return false }
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

    /// Single router for annotation keyboard commands. Both the real key event
    /// path and the tests call this, so "the button works but the shortcut
    /// doesn't" cannot slip through.
    @discardableResult
    func handleInlineAnnotationKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        editingText: Bool = false
    ) -> Bool {
        guard hasInlineAnnotationSession else { return false }
        if !editingText, keyCode == 6, modifiers.contains(.command) {
            if modifiers.contains(.shift) {
                inlineAnnotationModel?.redo()
            } else {
                inlineAnnotationModel?.undo()
            }
            return true
        }
        if !editingText, keyCode == 8, modifiers == [.command, .shift] {
            commitInlineAnnotation(as: .copyAndClose)
            return true
        }
        if keyCode == 8, modifiers == [.command] || modifiers == [.control] {
            // Snapzy's inline Copy keeps the session alive so the user can keep
            // annotating. Closing is a separate, explicit action.
            copyInlineAnnotationWithoutClosing()
            return true
        }
        if !editingText, modifiers.isEmpty, let tool = Self.toolShortcut(for: keyCode) {
            inlineAnnotationModel?.selectTool(tool)
            return true
        }
        return false
    }

    /// Plain-letter tool shortcuts for the inline HUD (Snapzy parity). They only
    /// fire without modifiers and never while a text field owns the keyboard.
    static func toolShortcut(for keyCode: UInt16) -> SmartAnnotationTool? {
        SmartAnnotationToolShortcuts.tool(forKeyCode: keyCode)
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
