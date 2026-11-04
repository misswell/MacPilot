import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

/// The window-server verdict behind the capture-first order.
struct ScreenshotPopupWindowProbeTests {
    private func entry(layer: Int, ownerPID: pid_t, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: 1),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowOwnerPID as String: NSNumber(value: ownerPID),
            kCGWindowAlpha as String: NSNumber(value: alpha),
        ]
    }

    private var popupLayer: Int { Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    private var mainMenuLayer: Int { Int(CGWindowLevelForKey(.mainMenuWindow)) }
    private var dockLayer: Int { Int(CGWindowLevelForKey(.dockWindow)) }

    @Test func anOpenMenuFromAnotherApplicationIsAPopup() {
        #expect(ScreenshotPopupWindowProbe.hasOpenPopup(
            in: [entry(layer: popupLayer, ownerPID: pid_t(501))],
            ownPID: pid_t(42),
            dockPID: pid_t(761)
        ))
    }

    /// The user can open MacPilot's own status-item menu and then press the
    /// capture shortcut; that menu is not the popup the backdrop must contain.
    @Test func macPilotOwnPopupIsNotAnotherApplicationsPopup() {
        #expect(!ScreenshotPopupWindowProbe.hasOpenPopup(
            in: [entry(layer: popupLayer, ownerPID: pid_t(42))],
            ownPID: pid_t(42),
            dockPID: pid_t(761)
        ))
    }

    /// A bare desktop has the menu bar (24) and the Dock's full-display container
    /// (20) on screen. Counting either would send every ordinary screenshot down
    /// the capture-first path.
    @Test func menuBarAndDockContainerSurfacesAreNotPopups() {
        #expect(!ScreenshotPopupWindowProbe.hasOpenPopup(
            in: [
                entry(layer: mainMenuLayer, ownerPID: pid_t(422)),
                entry(layer: dockLayer, ownerPID: pid_t(761)),
                entry(layer: 0, ownerPID: pid_t(501)),
            ],
            ownPID: pid_t(42),
            dockPID: pid_t(761)
        ))
    }

    /// The Dock's own menus ride at the popup levels, so they are still captured.
    @Test func aDockMenuStillCountsAsAPopup() {
        #expect(ScreenshotPopupWindowProbe.hasOpenPopup(
            in: [entry(layer: popupLayer, ownerPID: pid_t(761))],
            ownPID: pid_t(42),
            dockPID: pid_t(761)
        ))
    }

    @Test func anInvisiblePopupWindowIsNotOnScreen() {
        #expect(!ScreenshotPopupWindowProbe.hasOpenPopup(
            in: [entry(layer: popupLayer, ownerPID: pid_t(501), alpha: 0)],
            ownPID: pid_t(42),
            dockPID: pid_t(761)
        ))
    }

    @Test func ordinaryWindowsAreNotPopups() {
        #expect(!ScreenshotPopupWindowProbe.hasOpenPopup(
            in: [
                entry(layer: 0, ownerPID: pid_t(501)),
                entry(layer: 3, ownerPID: pid_t(501)),
            ],
            ownPID: pid_t(42),
            dockPID: pid_t(761)
        ))
        #expect(!ScreenshotPopupWindowProbe.hasOpenPopup(in: [], ownPID: pid_t(42), dockPID: pid_t(761)))
    }
}

/// Ordering between the frozen backdrop and the overlay presentation.
///
/// Both seams are injected: the probe answer and the presentation itself. The
/// tests never ask the real window server anything, never present a panel and
/// never run a ScreenCaptureKit capture.
struct SnapzyPopupCaptureOrderingTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.makeImage())
    }

    private func frozenSession() throws -> FrozenAreaCaptureSession {
        let displayID = CGDirectDisplayID(1)
        return FrozenAreaCaptureSession.fromSnapshot(
            FrozenDisplaySnapshot(
                displayID: displayID,
                screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                scaleFactor: 1,
                colorSpaceName: nil,
                image: try image()
            )
        )
    }

    @MainActor
    private func makeController(onError: @escaping (Error) -> Void = { _ in }) -> SmartScreenshotController {
        SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: onError,
            screenCaptureAccessProvider: { true }
        )
    }

    /// The regression: the shortcut used to present the overlay first, which ended
    /// the other application's popup tracking session, so the frozen backdrop taken
    /// afterwards never contained the open dropdown.
    @Test @MainActor func popupPresentCaptureTakesTheBackdropBeforePresentingTheOverlay() async throws {
        _ = NSApplication.shared
        let displayID = CGDirectDisplayID(1)
        var events: [String] = []
        var preparationCount = 0
        let session = try frozenSession()
        let controller = makeController()
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let sessionID = controller.startSnapzySelection(
            mode: .manualArea,
            popupIsOnScreen: { true },
            presentSelection: { backdrops in
                events.append(backdrops[displayID] == nil ? "present:no-backdrop" : "present:backdrop")
            },
            preparation: {
                preparationCount += 1
                try await Task.yield()
                events.append("capture")
                return session
            }
        )
        #expect(sessionID != nil)
        // Holding back the overlay is the whole point: nothing is on screen yet.
        #expect(events.isEmpty)

        await controller.testSnapzyPreparationTask?.value

        #expect(events == ["capture", "present:backdrop"])
        #expect(preparationCount == 1)
    }

    /// The ordinary screenshot keeps its instant overlay; the frozen frame streams
    /// in behind it, exactly as before this change.
    @Test @MainActor func noPopupKeepsThePresentFirstFastPath() async throws {
        _ = NSApplication.shared
        var events: [String] = []
        let session = try frozenSession()
        let controller = makeController()
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let sessionID = controller.startSnapzySelection(
            mode: .manualArea,
            popupIsOnScreen: { false },
            presentSelection: { backdrops in
                events.append(backdrops.isEmpty ? "present:empty" : "present:backdrop")
            },
            preparation: {
                try await Task.yield()
                events.append("capture")
                return session
            }
        )
        #expect(sessionID != nil)
        // Presented synchronously, before the capture task even ran.
        #expect(events == ["present:empty"])

        await controller.testSnapzyPreparationTask?.value

        #expect(events == ["present:empty", "capture"])
    }

    /// A failed capture in the capture-first order must not leave an overlay on
    /// screen that photographed nothing, and must surface the failure.
    @Test @MainActor func popupPresentCaptureFailureNeverPresentsTheOverlay() async throws {
        _ = NSApplication.shared
        var events: [String] = []
        var reportedErrors: [Error] = []
        let controller = makeController(onError: { reportedErrors.append($0) })
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let sessionID = controller.startSnapzySelection(
            mode: .manualArea,
            popupIsOnScreen: { true },
            presentSelection: { _ in events.append("present") },
            preparation: { throw ScreenCaptureError.noDisplayFound }
        )
        #expect(sessionID != nil)

        await controller.testSnapzyPreparationTask?.value

        #expect(events.isEmpty)
        #expect(reportedErrors.count == 1)
    }

    /// A pre-captured session is handed to the presentation through the backdrops
    /// dictionary — the path the pending-action logic already understands.
    @Test @MainActor func preCapturedSessionIsHandedOverThroughTheBackdropsPath() async throws {
        _ = NSApplication.shared
        let displayID = CGDirectDisplayID(1)
        var presentedDisplayIDs: Set<CGDirectDisplayID> = []
        let session = try frozenSession()
        let controller = makeController()
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        _ = controller.startSnapzySelection(
            mode: .smartElement,
            popupIsOnScreen: { true },
            presentSelection: { backdrops in
                presentedDisplayIDs = Set(backdrops.keys)
            },
            preparation: {
                try await Task.yield()
                return session
            }
        )

        await controller.testSnapzyPreparationTask?.value

        #expect(presentedDisplayIDs == [displayID])
    }

    /// ScreenCaptureKit can stall with no error at all. The overlay is already
    /// on screen in the fast path, so a missing frozen frame used to leave a
    /// selection that drew fine but ignored double-click and every HUD button —
    /// the actions queued in `pendingSnapzyAction` behind a frame that never
    /// arrived. The deadline has to fail visibly instead.
    @Test @MainActor func aStalledFrozenBackdropFailsInsteadOfLeavingADeadOverlay() async throws {
        _ = NSApplication.shared
        var presented = false
        var reportedErrors: [Error] = []
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { reportedErrors.append($0) },
            screenCaptureAccessProvider: { true },
            snapzyBackdropDeadline: .milliseconds(60)
        )
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let sessionID = controller.startSnapzySelection(
            mode: .manualArea,
            popupIsOnScreen: { false },
            presentSelection: { _ in presented = true },
            preparation: {
                // Stands in for a capture call that never returns.
                try await Task.sleep(for: .seconds(30))
                throw ScreenCaptureError.captureFailed("unreachable")
            }
        )
        #expect(sessionID != nil)
        #expect(presented)

        await controller.testSnapzyDeadlineTask?.value

        #expect(reportedErrors.count == 1)
        #expect(controller.testSnapzyPreparationTask == nil)
    }

    /// The opposite side of the same deadline: a capture that arrives in time
    /// must disarm it, so a slow-but-successful preparation never reports a
    /// timeout after the user is already working on the frozen frame.
    @Test @MainActor func aCompletedFrozenBackdropDisarmsTheDeadline() async throws {
        _ = NSApplication.shared
        var reportedErrors: [Error] = []
        let session = try frozenSession()
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { reportedErrors.append($0) },
            screenCaptureAccessProvider: { true },
            snapzyBackdropDeadline: .milliseconds(120)
        )
        defer {
            controller.cancelSelection()
            controller.stop()
        }

        _ = controller.startSnapzySelection(
            mode: .manualArea,
            popupIsOnScreen: { false },
            presentSelection: { _ in },
            preparation: {
                try await Task.yield()
                return session
            }
        )
        let deadline = try #require(controller.testSnapzyDeadlineTask)

        await controller.testSnapzyPreparationTask?.value
        await deadline.value

        #expect(reportedErrors.isEmpty)
    }
}
