import AppKit
import Foundation

enum ImageViewerScrollAction: Equatable {
    case navigate(Int)
    case zoom(CGFloat)
    case ignored
}

/// Turns one scroll-wheel event into either navigation or zoom.
///
/// Navigation is deliberately limited to one image per trackpad gesture: a
/// single flick must not race through a folder. A mouse wheel has no gesture
/// phases, so every nonzero event is one step. Dropping events by time makes
/// a quick wheel flick lose images.
struct ImageViewerScrollGesture {
    static let preciseThreshold: CGFloat = 16
    static let gestureGap: TimeInterval = 0.25

    private var accumulatedY: CGFloat = 0
    private var consumedGesture = false
    private var lastEventAt: TimeInterval = -.infinity
    private var wasNavigating = false

    mutating func action(
        deltaY: CGFloat,
        isPrecise: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        timestamp: TimeInterval,
        navigates: Bool
    ) -> ImageViewerScrollAction {
        if navigates != wasNavigating {
            reset()
            wasNavigating = navigates
        }
        guard navigates else { return Self.zoomAction(deltaY) }

        // Momentum is the tail of a trackpad gesture. Acting on it would turn
        // one flick into several image changes.
        guard momentumPhase.isEmpty else { return .ignored }
        if phase.contains(.cancelled) {
            reset()
            return .ignored
        }

        let ended = phase.contains(.ended)
        let action: ImageViewerScrollAction
        if isPrecise {
            if phase.contains(.began) || phase.contains(.mayBegin)
                || timestamp - lastEventAt > Self.gestureGap {
                accumulatedY = 0
                consumedGesture = false
            }
            lastEventAt = timestamp
            if !consumedGesture, deltaY != 0 {
                accumulatedY += deltaY
                if abs(accumulatedY) >= Self.preciseThreshold {
                    consumedGesture = true
                    let direction = Self.direction(for: accumulatedY)
                    accumulatedY = 0
                    action = .navigate(direction)
                } else {
                    action = .ignored
                }
            } else {
                action = .ignored
            }
        } else if deltaY != 0 {
            action = .navigate(Self.direction(for: deltaY))
        } else {
            action = .ignored
        }

        if ended { reset() }
        return action
    }

    private mutating func reset() {
        accumulatedY = 0
        consumedGesture = false
        lastEventAt = -.infinity
    }

    private static func direction(for deltaY: CGFloat) -> Int {
        // Scrolling up shows the previous image; scrolling down shows the next.
        deltaY > 0 ? -1 : 1
    }

    private static func zoomAction(_ deltaY: CGFloat) -> ImageViewerScrollAction {
        guard deltaY.isFinite, deltaY != 0 else { return .ignored }
        return .zoom(exp(min(1, max(-1, deltaY * 0.025))))
    }
}
