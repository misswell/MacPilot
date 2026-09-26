import CoreGraphics
import Foundation

/// One finger sample out of UIKit, already in the surface's own coordinates.
struct TouchSample: Equatable {
    var position: CGPoint
    /// `UITouch.timestamp` — system uptime seconds.
    var time: TimeInterval
}

enum TouchPhase {
    case began
    case moved
    case ended
    case cancelled
}

/// Exponential velocity estimate over a stream of samples, in points per
/// second. The smoothing exists to stop per-sample jitter from making the
/// acceleration curve twitchy; the estimate lags the hand by a fraction of a
/// frame, which reads as smoothness rather than delay.
struct VelocityCalculator {
    /// Weight of each new sample in the estimate (0...1).
    var smoothing: Double = 0.35

    private(set) var velocity: CGPoint = .zero
    private var previous: (position: CGPoint, time: TimeInterval)?

    /// Records one sample and returns the smoothed velocity.
    @discardableResult
    mutating func record(position: CGPoint, time: TimeInterval) -> CGPoint {
        guard let previous else {
            self.previous = (position, time)
            velocity = .zero
            return velocity
        }
        let dt = time - previous.time
        guard dt > 0.0005 else { return velocity }
        let instantaneous = CGPoint(
            x: (position.x - previous.position.x) / dt,
            y: (position.y - previous.position.y) / dt
        )
        let alpha = min(max(smoothing, 0), 1)
        velocity = CGPoint(
            x: velocity.x + (instantaneous.x - velocity.x) * alpha,
            y: velocity.y + (instantaneous.y - velocity.y) * alpha
        )
        self.previous = (position, time)
        return velocity
    }

    mutating func reset() {
        previous = nil
        velocity = .zero
    }
}
