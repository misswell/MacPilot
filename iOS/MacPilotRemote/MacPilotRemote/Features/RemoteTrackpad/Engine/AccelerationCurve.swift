import CoreGraphics

/// Pointer gain over finger speed: slow movement maps 1:1 so fine targets are
/// reachable, fast movement ramps up to 4:1 so a flick crosses the screen
/// without the hand leaving the glass.
///
/// The ramp is a smoothstep between the two ends — there is no knee, so the
/// transition is invisible the way a built-in trackpad's is.
struct AccelerationCurve {
    /// User preference, 0.5...2. It shifts where the ramp starts, not its
    /// endpoints: a higher setting reaches full gain at gentler speeds.
    var trackingSpeed: Double = 1
    /// Finger speed (points/s) at which gain is halfway to maximum.
    var referenceSpeed: Double = 750
    /// Maximum gain for a fast flick.
    var maximumGain: Double = 4

    func gain(fingerSpeed: Double) -> Double {
        let reference = max(referenceSpeed / max(trackingSpeed, 0.1), 1)
        let t = min(max(fingerSpeed / reference, 0), 1)
        let smoothstep = t * t * (3 - 2 * t)
        return 1 + (maximumGain - 1) * smoothstep
    }

    /// Scales one raw finger delta by the gain the finger's speed earns.
    func apply(dx: Double, dy: Double, fingerSpeed: Double) -> CGPoint {
        let factor = gain(fingerSpeed: fingerSpeed)
        return CGPoint(x: dx * factor, y: dy * factor)
    }
}
