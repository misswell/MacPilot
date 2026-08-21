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
    private var sessionID = UUID()

    private override init() {
        super.init()
    }

    var isPresenting: Bool { !windows.isEmpty }

    @discardableResult
    func startSelection(
        mode: SelectionMode = .screenshot,
        backdrops: [CGDirectDisplayID: AreaSelectionBackdrop] = [:],
        applicationConfiguration: AreaSelectionApplicationConfiguration? = nil,
        initialInteractionMode: AreaSelectionInteractionMode = .manualRegion,
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
        selectedResult = nil
        selectedWindow = nil
        manualStart = nil
        manualRect = nil
        sessionID = requestedSessionID ?? UUID()

        let sessionID = self.sessionID
        let screens = NSScreen.screens
        windows = screens.map { screen in
            let window = AreaSelectionWindow(screen: screen)
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

        for window in windows {
            window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let activeWindow = windows.first(where: { $0.frame.contains(pointer) }) ?? windows.first
        activeWindow?.makeKeyAndOrderFront(nil)
        activeWindow?.activateKeyboardInputIfNeeded()
        NSCursor.crosshair.set()
        return sessionID
    }

    func isPresenting(sessionID: UUID) -> Bool {
        self.sessionID == sessionID && !windows.isEmpty
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
        for window in currentWindows {
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
            // the More button is intentionally a non-terminal affordance until
            // its menu is implemented. Both actions must leave the selection
            // and toolbar visible.
            return
        }
        guard let actionHandler else {
            complete(selectedResult)
            return
        }
        actionHandler(selectedResult, action)
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

    /// Installs the annotation editor directly over the selected frame.  The
    /// editor is an NSView hosted by the existing full-screen selection panel;
    /// no second centered annotation window is created.
    @discardableResult
    func presentInlineAnnotationEditor(
        image: CGImage,
        language: AppLanguage,
        initialTool: AreaSelectionAnnotationTool,
        onComplete: @escaping (CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) -> Bool {
        guard let selectedWindow, let selectedResult else { return false }
        let model = SmartAnnotationModel(initialTool: initialTool.smartAnnotationTool)
        let editor = NSHostingView(rootView: SmartAnnotationEditor(
            image: image,
            language: language,
            model: model,
            embedded: true,
            onCancel: { [weak self] in
                self?.dismissSelection()
                onCancel()
            },
            onComplete: { [weak self] in
                guard let self else { return }
                guard let rendered = SmartAnnotationRenderer.render(
                    image: image,
                    annotations: model.annotations
                ) else { return }
                self.dismissSelection()
                onComplete(rendered)
            }
        ))
        selectedWindow.overlayView.showEmbeddedAnnotationEditor(
            editor,
            screenRect: selectedResult.rect
        )
        return true
    }

    func areaSelectionWindowDidCancel(_: AreaSelectionWindow) {
        complete(nil)
    }

    func areaSelectionWindowDidBecomeActive(_ window: AreaSelectionWindow) {
        window.activateKeyboardInputIfNeeded()
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didReceiveKeyEvent event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            // Notify the capture coordinator so it can resume Quick Access
            // and release the frozen display session.  `cancelSelection()`
            // is intentionally silent because it is also used while starting
            // a replacement session.
            complete(nil)
            return true
        }
        guard let selectedResult else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 8, modifiers == [.command] || modifiers == [.control] {
            areaSelectionWindow(window, didRequestAction: .copy)
            return true
        }
        if event.keyCode == 1, modifiers == [.command] || modifiers == [.control] {
            areaSelectionWindow(window, didRequestAction: .save)
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
            areaSelectionWindow(window, didRequestAction: .copy)
            return true
        }
        return false
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
