import AppKit
import Foundation
import Testing
@testable import MacPilot

/// Exercises the actual controller through each display's hidden overlay.
/// Synthetic events avoid WindowServer input injection and screen capture.
struct SecondarySelectionRegressionTests {
    @Test @MainActor func manualSelectionOnSecondaryDisplayKeepsItsFrameAndActions() throws {
        try exerciseSecondarySelection(mode: .manualRegion)
    }

    @Test @MainActor func smartElementDragOnSecondaryDisplayBecomesAVisibleSelection() throws {
        try exerciseSecondarySelection(mode: .smartElement)
    }

    @Test @MainActor func smartElementClickOnMainDisplayKeepsTheRecognizedSelection() async throws {
        _ = NSApplication.shared
        guard let mainScreen = NSScreen.main else { return }
        try await exerciseSmartElementClick(on: mainScreen)
    }

    @Test @MainActor func smartElementClickOnSecondaryDisplayKeepsTheRecognizedSelection() async throws {
        _ = NSApplication.shared
        guard let mainScreen = NSScreen.main,
              let secondaryScreen = NSScreen.screens.first(where: { $0 !== mainScreen }) else {
            return
        }
        try await exerciseSmartElementClick(on: secondaryScreen)
    }

    @Test @MainActor func smartElementClickOnMainDisplayUsesOverlayOriginForHoverCoordinates() async throws {
        _ = NSApplication.shared
        guard let mainScreen = NSScreen.main else { return }
        try await exerciseSmartElementClick(on: mainScreen, overlayOriginYOffset: 28)
    }

    @Test @MainActor func smartElementClickOnSecondaryDisplayUsesOverlayOriginForHoverCoordinates() async throws {
        _ = NSApplication.shared
        guard let mainScreen = NSScreen.main,
              let secondaryScreen = NSScreen.screens.first(where: { $0 !== mainScreen }) else {
            return
        }
        try await exerciseSmartElementClick(on: secondaryScreen, overlayOriginYOffset: 28)
    }

    @MainActor
    private func exerciseSecondarySelection(mode: AreaSelectionInteractionMode) throws {
        _ = NSApplication.shared
        guard let mainScreen = NSScreen.main,
              let secondaryScreen = NSScreen.screens.first(where: { $0 !== mainScreen }),
              let secondaryDisplayID = secondaryScreen.displayID else {
            return
        }

        var selectionWindows: [AreaSelectionWindow] = []
        var previewedResult: AreaSelectionResult?
        var requestedAction: (AreaSelectionResult, AreaSelectionAction)?
        let controller = SnapzyAreaSelectionController(
            presentationEffect: { selectionWindows = $0 },
            cursorSetEffect: { _ in }
        )
        defer { controller.cancelSelection() }

        controller.startSelection(
            initialInteractionMode: mode,
            elementTargetResolver: { _ in nil },
            selectionPreview: { previewedResult = $0 },
            actionHandler: { result, action in requestedAction = (result, action) },
            completion: { _ in }
        )

        #expect(selectionWindows.count == NSScreen.screens.count)
        #expect(selectionWindows.allSatisfy { !$0.isVisible && !$0.isKeyWindow })
        let secondaryWindow = try #require(selectionWindows.first { $0.displayID == secondaryDisplayID })
        #expect(secondaryWindow.frame == secondaryScreen.frame)
        #expect(secondaryWindow.overlayView.bounds.size == secondaryScreen.frame.size)

        let localStart = CGPoint(x: 120, y: 140)
        let localEnd = CGPoint(x: 380, y: 320)
        let expectedRect = CGRect(
            x: secondaryScreen.frame.minX + localStart.x,
            y: secondaryScreen.frame.minY + localStart.y,
            width: localEnd.x - localStart.x,
            height: localEnd.y - localStart.y
        )
        let overlay = secondaryWindow.overlayView
        let startInWindow = overlay.convert(localStart, to: nil)
        let endInWindow = overlay.convert(localEnd, to: nil)

        overlay.mouseDown(with: try mouseEvent(.leftMouseDown, at: startInWindow, in: secondaryWindow))
        overlay.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: endInWindow, in: secondaryWindow))
        #expect(overlay.testSelectionBorderPathBounds == CGRect(
            origin: localStart,
            size: CGSize(width: localEnd.x - localStart.x, height: localEnd.y - localStart.y)
        ))
        overlay.mouseUp(with: try mouseEvent(.leftMouseUp, at: endInWindow, in: secondaryWindow))

        let result = try #require(previewedResult)
        #expect(result.rect == expectedRect)
        #expect(result.displayID == secondaryDisplayID)
        #expect(result.displayIDs == [secondaryDisplayID])
        #expect(overlay.presentationDiagnostics()["selectionBorderHidden"] == "false")
        #expect(visibleSelectionHandleCount(in: overlay) == 8)

        for otherWindow in selectionWindows where otherWindow !== secondaryWindow {
            #expect(otherWindow.overlayView.presentationDiagnostics()["selectionBorderHidden"] == "true")
            #expect(visibleSelectionHandleCount(in: otherWindow.overlayView) == 0)
            #expect(!otherWindow.overlayView.subviews.contains { $0 is AreaSelectionActionBar })
        }
        #expect(overlay.subviews.contains { $0 is AreaSelectionActionBar })
        #expect(selectionWindows.allSatisfy { !$0.isVisible })

        secondaryWindow.selectionDelegate?.areaSelectionWindow(secondaryWindow, didRequestAction: .copy)
        #expect(requestedAction?.0.rect == expectedRect)
        #expect(requestedAction?.1 == .copy)
        #expect(selectionWindows.allSatisfy { !$0.isVisible })
    }

    @MainActor
    private func exerciseSmartElementClick(
        on targetScreen: NSScreen,
        overlayOriginYOffset: CGFloat = 0
    ) async throws {
        guard let targetDisplayID = targetScreen.displayID else { return }
        let targetLocalRect = CGRect(x: 280, y: 230, width: 240, height: 160)
        var selectionWindows: [AreaSelectionWindow] = []
        var resolverPoints: [CGPoint] = []
        var selectionRectForResolver: CGRect?
        var previewedResult: AreaSelectionResult?
        var requestedAction: (AreaSelectionResult, AreaSelectionAction)?
        let controller = SnapzyAreaSelectionController(
            presentationEffect: { selectionWindows = $0 },
            cursorSetEffect: { _ in }
        )
        defer { controller.cancelSelection() }

        controller.startSelection(
            initialInteractionMode: .smartElement,
            elementTargetResolver: { point in
                resolverPoints.append(point)
                return selectionRectForResolver
            },
            selectionPreview: { previewedResult = $0 },
            actionHandler: { result, action in requestedAction = (result, action) },
            completion: { _ in }
        )

        let selectionWindow = try #require(selectionWindows.first { $0.displayID == targetDisplayID })
        let overlay = selectionWindow.overlayView
        let originalOverlayOrigin = overlay.frame.origin
        overlay.setFrameOrigin(CGPoint(
            x: originalOverlayOrigin.x,
            y: originalOverlayOrigin.y + overlayOriginYOffset
        ))
        #expect(overlay.frame.origin.y == originalOverlayOrigin.y + overlayOriginYOffset)

        let localPoint = CGPoint(x: targetLocalRect.midX, y: targetLocalRect.midY)
        let windowPoint = overlay.convert(localPoint, to: nil)
        selectionRectForResolver = CGRect(
            origin: selectionWindow.convertPoint(
                toScreen: overlay.convert(targetLocalRect.origin, to: nil)
            ),
            size: targetLocalRect.size
        )
        let recognizedScreenRect = try #require(selectionRectForResolver)
        let expectedResolverPoint = selectionWindow.convertPoint(toScreen: windowPoint)

        // Smart-element recognition is debounced while hovering. Wait for that
        // real overlay path to draw its pre-click border before sending the tap.
        overlay.mouseMoved(with: try mouseEvent(.mouseMoved, at: windowPoint, in: selectionWindow))
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(overlay.presentationDiagnostics()["selectionBorderHidden"] == "false")
        #expect(resolverPoints.contains { abs($0.x - expectedResolverPoint.x) < 0.01
            && abs($0.y - expectedResolverPoint.y) < 0.01 })
        #expect(selectionWindows.allSatisfy { !$0.isVisible })

        overlay.mouseDown(with: try mouseEvent(.leftMouseDown, at: windowPoint, in: selectionWindow))
        overlay.mouseUp(with: try mouseEvent(.leftMouseUp, at: windowPoint, in: selectionWindow))
        // The production path re-resolves on both mouse-down and mouse-up;
        // this fixture stays stable across all three resolver calls.
        #expect(resolverPoints.count >= 3)

        let result = try #require(previewedResult)
        #expect(result.rect == recognizedScreenRect)
        #expect(result.displayID == targetDisplayID)
        #expect(result.displayIDs == [targetDisplayID])
        #expect(overlay.presentationDiagnostics()["selectionBorderHidden"] == "false")
        #expect(visibleSelectionHandleCount(in: overlay) == 8)
        #expect(overlay.subviews.contains { $0 is AreaSelectionActionBar })
        #expect(selectionWindows.allSatisfy { !$0.isVisible })

        selectionWindow.selectionDelegate?.areaSelectionWindow(selectionWindow, didRequestAction: .copy)
        #expect(requestedAction?.0.rect == recognizedScreenRect)
        #expect(requestedAction?.1 == .copy)
        #expect(selectionWindows.allSatisfy { !$0.isVisible })
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    @MainActor
    private func visibleSelectionHandleCount(in overlay: AreaSelectionOverlayView) -> Int {
        (overlay.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.filter { layer in
            guard !layer.isHidden, let path = layer.path else { return false }
            let bounds = path.boundingBox
            return abs(bounds.width - 20) < 0.01 && abs(bounds.height - 20) < 0.01
        }.count
    }
}
