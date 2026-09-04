import Foundation

/// The decision returned for one physical wheel event.
struct SmoothScrollPlan: Equatable, Sendable {
    var verticalTarget: Double = 0
    var horizontalTarget: Double = 0
    var passThroughVertical = false
    var passThroughHorizontal = false

    var consumesAnyAxis: Bool {
        verticalTarget != 0 || horizontalTarget != 0
    }
}

/// Pure input decision, separated from the event tap so edge cases are testable.
enum SmoothScrollPlanner {
    static func plan(
        vertical: SmoothScrollAxisValue,
        horizontal: SmoothScrollAxisValue,
        settings: SmoothScrollSettings
    ) -> SmoothScrollPlan {
        var plan = SmoothScrollPlan()
        if vertical.value != 0 {
            plan.verticalTarget = settings.shouldReverseVertical ? -vertical.value : vertical.value
        }
        if horizontal.value != 0 {
            plan.horizontalTarget = settings.shouldReverseHorizontal ? -horizontal.value : horizontal.value
        }

        // Tiny wheel deltas are raised to the minimum step before applying speed.
        if settings.smoothVertical, plan.verticalTarget != 0 {
            plan.verticalTarget = normalized(plan.verticalTarget, minimum: settings.minimumStep) * settings.speed
        } else {
            plan.passThroughVertical = vertical.value != 0
            plan.verticalTarget = 0
        }
        if settings.smoothHorizontal, plan.horizontalTarget != 0 {
            plan.horizontalTarget = normalized(plan.horizontalTarget, minimum: settings.minimumStep) * settings.speed
        } else {
            plan.passThroughHorizontal = horizontal.value != 0
            plan.horizontalTarget = 0
        }
        return plan
    }

    private static func normalized(_ value: Double, minimum: Double) -> Double {
        value > 0 ? Swift.max(value.magnitude, minimum) : -Swift.max(value.magnitude, minimum)
    }
}

/// Converts the physical wheel cadence into an optional speed boost.
/// Events arriving faster than `fastInterval` get the full configured boost;
/// slower events diminish toward the base speed.
enum SmoothScrollVelocityBoost {
    static let fastInterval: CFTimeInterval = 0.08
    static let slowInterval: CFTimeInterval = 0.35

    static func factor(
        interval: CFTimeInterval,
        enabled: Bool,
        maximum: Double
    ) -> Double {
        guard enabled, interval.isFinite else { return 1 }
        let clampedMaximum = maximum.clamped(to: SmoothScrollSettings.adaptiveSpeedRange)
        guard clampedMaximum > 1 else { return 1 }
        let clampedInterval = Swift.min(Swift.max(interval, fastInterval), slowInterval)
        let normalizedSpeed = (slowInterval - clampedInterval) / (slowInterval - fastInterval)
        let boosted = 1 + (clampedMaximum - 1) * normalizedSpeed
        return (boosted * 100).rounded() / 100
    }
}

/// What the tap callback should do with one scrollWheel event.
enum SmoothScrollGateAction: Equatable, Sendable {
    /// The event targets an excluded application; it never enters smoothing.
    /// `reverse` mirrors the independent excluded-app reversal and rewrites
    /// both axes of the original event.
    case bypassExcluded(reverse: Bool)
    /// Continuous events from our own runtime or other producers pass through.
    case passThroughRemoteSmoothed
    /// Neither axis carries a usable delta.
    case passThroughInvalidAxes
    /// Enter the smoothing planner.
    case smooth
    /// Trackpad-like drivers bypass smoothing but keep reversal.
    case passThroughTrackpadLike
    /// Smoothing is off; the tap stays installed for reversal only.
    case passThroughSmoothingDisabled
    /// ⌘ is held and smoothing is configured to pause while it is.
    case passThroughCommandBlocked
}

/// The tap callback's decision for one event, including the global reversal
/// that must be written into the original event before it keeps flowing.
struct SmoothScrollGateDecision: Equatable, Sendable {
    var action: SmoothScrollGateAction
    var reverseOriginalVertical = false
    var reverseOriginalHorizontal = false
}

/// Pure bypass decision for the scroll event tap.
///
/// It encodes the exact classification order the callback must keep:
/// excluded applications first, then remote-smoothed events, then axis
/// validity, then trackpad-like drivers, then the smoothing-only guards.
/// Reversal is reported for every path where the original event keeps
/// flowing after the validity check, so reversal also covers trackpad-like
/// events and passes taken while smoothing is disabled or blocked by ⌘.
enum SmoothScrollGate {
    static func decide(
        isExcludedTarget: Bool,
        shouldReverseExcludedTarget: Bool,
        isRemoteSmoothed: Bool,
        vertical: SmoothScrollAxisValue,
        horizontal: SmoothScrollAxisValue,
        isTrackpadLike: Bool,
        settings: SmoothScrollSettings,
        commandBlocked: Bool
    ) -> SmoothScrollGateDecision {
        if isExcludedTarget {
            return SmoothScrollGateDecision(action: .bypassExcluded(reverse: shouldReverseExcludedTarget))
        }
        if isRemoteSmoothed {
            return SmoothScrollGateDecision(action: .passThroughRemoteSmoothed)
        }
        guard vertical.isValid || horizontal.isValid else {
            return SmoothScrollGateDecision(action: .passThroughInvalidAxes)
        }

        var decision = SmoothScrollGateDecision(action: .smooth)
        decision.reverseOriginalVertical = settings.shouldReverseVertical
        decision.reverseOriginalHorizontal = settings.shouldReverseHorizontal

        if isTrackpadLike {
            decision.action = .passThroughTrackpadLike
            return decision
        }
        guard settings.isEnabled else {
            decision.action = .passThroughSmoothingDisabled
            return decision
        }
        if commandBlocked {
            decision.action = .passThroughCommandBlocked
            return decision
        }
        return decision
    }
}
