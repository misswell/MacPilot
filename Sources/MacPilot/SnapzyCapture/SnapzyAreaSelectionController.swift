//
//  SnapzyAreaSelectionController.swift
//  MacPilot adapter for Snapzy's AreaSelectionWindow/AreaSelectionOverlayView.
//
//  The window and overlay implementation is migrated from Snapzy unchanged;
//  this small coordinator only connects its delegate callbacks to MacPilot's
//  screenshot completion closure.
//

import AppKit
import Foundation

@MainActor
final class SnapzyAreaSelectionController: NSObject, AreaSelectionWindowDelegate {
    static let shared = SnapzyAreaSelectionController()

    private var windows: [AreaSelectionWindow] = []
    private var completion: AreaSelectionResultCompletion?
    private var selectionMode: SelectionMode = .screenshot
    private var interactionMode: AreaSelectionInteractionMode = .manualRegion
    private var manualStart: CGPoint?
    private var manualRect: CGRect?
    private var sessionID = UUID()

    private override init() {
        super.init()
    }

    var isPresenting: Bool { !windows.isEmpty }

    func startSelection(
        mode: SelectionMode = .screenshot,
        backdrops: [CGDirectDisplayID: AreaSelectionBackdrop] = [:],
        applicationConfiguration: AreaSelectionApplicationConfiguration? = nil,
        initialInteractionMode: AreaSelectionInteractionMode = .manualRegion,
        completion: @escaping AreaSelectionResultCompletion
    ) {
        cancelSelection()

        selectionMode = mode
        interactionMode = initialInteractionMode
        self.completion = completion
        manualStart = nil
        manualRect = nil
        sessionID = UUID()

        let sessionID = self.sessionID
        let screens = NSScreen.screens
        windows = screens.map { screen in
            let window = AreaSelectionWindow(screen: screen)
            window.selectionDelegate = self
            window.updateSelectionMode(mode)
            window.setReceivesKeyboardInput(true)
            window.overlayView.setAllowsApplicationWindowSelection(applicationConfiguration != nil)
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
    }

    func cancelSelection() {
        guard !windows.isEmpty || completion != nil else { return }
        let oldWindows = windows
        windows.removeAll(keepingCapacity: false)
        completion = nil
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

    private func complete(_ result: AreaSelectionResult?) {
        guard let completion else {
            cancelSelection()
            return
        }
        let currentWindows = windows
        self.completion = nil
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

    // MARK: - AreaSelectionWindowDelegate

    func areaSelectionWindow(_ window: AreaSelectionWindow, didSelectRect rect: CGRect) {
        complete(result(for: .rect(rect), in: window))
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didSelectWindow target: WindowCaptureTarget) {
        complete(result(for: .window(target), in: window))
    }

    func areaSelectionWindowDidCancel(_: AreaSelectionWindow) {
        complete(nil)
    }

    func areaSelectionWindowDidBecomeActive(_ window: AreaSelectionWindow) {
        window.activateKeyboardInputIfNeeded()
    }

    func areaSelectionWindow(_ window: AreaSelectionWindow, didReceiveKeyEvent event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            cancelSelection()
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
        complete(result(for: .rect(rect), in: window))
    }
}
