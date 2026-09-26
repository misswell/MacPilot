import AppKit
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol

/// The cursor-driving surface the realtime input coordinator talks to. A
/// protocol so the coordinator's tests never post real events.
@MainActor
protocol MouseInjecting: AnyObject {
    /// Whether this injector is allowed to post events at all. Posting mouse
    /// events is an Accessibility-protected operation.
    var canPostEvents: Bool { get }

    /// Moves the cursor by a relative delta. `buttons` are the buttons held
    /// while moving; a move with the left button held is a drag.
    func moveCursor(dx: Double, dy: Double, buttons: RemoteInputButtons)

    func click(button: RemoteInputButton, action: RemoteInputAction)
}

@MainActor
protocol ScrollInjecting: AnyObject {
    /// Continuous, pixel-precision scrolling in finger direction: positive
    /// `dy` means the fingers moved down and the content follows them, exactly
    /// the way a built-in trackpad behaves with natural scrolling on.
    func scroll(dx: Double, dy: Double)
}

/// Posts real mouse events into the HID system state.
///
/// Motion is relative — the iPhone sends finger deltas, not screen coordinates,
/// so Retina scaling, resolution changes and multi-display arrangements are the
/// window server's problem, not the wire format's. Deltas are applied to the
/// cursor's current position at post time, which also avoids accumulating
/// rounding error across a long gesture.
@MainActor
final class MouseInjector: MouseInjecting {
    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    var canPostEvents: Bool { AXIsProcessTrusted() }

    func moveCursor(dx: Double, dy: Double, buttons: RemoteInputButtons) {
        guard let source, let location = CGEvent(source: source)?.location else { return }
        let dragging = buttons.contains(.left)
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.post(tap: .cghidEventTap)
    }

    func click(button: RemoteInputButton, action: RemoteInputAction) {
        guard let source, let location = CGEvent(source: source)?.location else { return }
        let type: CGEventType
        let cgButton: CGMouseButton
        switch (button, action) {
        case (.left, .down): type = .leftMouseDown; cgButton = .left
        case (.left, .up): type = .leftMouseUp; cgButton = .left
        case (.right, .down): type = .rightMouseDown; cgButton = .right
        case (.right, .up): type = .rightMouseUp; cgButton = .right
        }
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: cgButton
        ) else { return }
        event.post(tap: .cghidEventTap)
    }
}

/// Posts continuous scroll wheel events, pixel-precision like a trackpad
/// rather than line-stepped like a mouse wheel. Same field layout the
/// SmoothScrolling feature uses, posted globally instead of to one pid.
@MainActor
final class ScrollInjector: ScrollInjecting {
    func scroll(dx: Double, dy: Double) {
        // The `scrollEventSource` convenience does not exist in this toolchain's
        // overlay, so the template comes from the scrollWheelEvent2 constructor.
        // Pixel units make the wheel values continuous, and the point delta
        // fields below carry the real motion.
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        // Positive axis1 = viewport up = content follows fingers moving down;
        // positive axis2 = tilt right = content follows fingers moving right.
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.post(tap: .cghidEventTap)
    }
}
