import CoreGraphics

/// Scroll glide: after the fingers lift with speed, scrolling continues and
/// decays exponentially instead of stopping dead.
///
/// The processor is fed the velocity at lift and produces decaying deltas per
/// tick until the speed drains below the stop threshold.
struct InertiaProcessor {
    /// Seconds for the velocity to decay to ~37%.
    var decayTimeConstant: Double = 0.30
    /// Glide ends below this speed (points/s).
    var stopSpeed: Double = 55

    private(set) var velocity: CGPoint = .zero
    private(set) var isRunning = false

    mutating func start(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > stopSpeed else {
            stop()
            return
        }
        self.velocity = velocity
        isRunning = true
    }

    /// The scroll delta for the next `dt` seconds of glide, or `nil` once the
    /// glide has drained.
    mutating func tick(dt: Double) -> CGPoint? {
        guard isRunning, dt > 0 else { return nil }
        let factor = exp(-dt / max(decayTimeConstant, 0.01))
        velocity = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
        let delta = CGPoint(x: velocity.x * dt, y: velocity.y * dt)
        if hypot(velocity.x, velocity.y) < stopSpeed {
            stop()
        }
        return delta
    }

    mutating func stop() {
        velocity = .zero
        isRunning = false
    }
}
