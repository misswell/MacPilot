import CoreGraphics
import Foundation

/// Configuration for Mos-derived smooth mouse-wheel scrolling.
///
/// The numeric defaults match Mos' scrolling defaults (`step = 33.6`,
/// `speed = 2.7`, and UI duration = `4.35`). Values loaded from an old or
/// hand-edited configuration are clamped before they can reach the input tap.
struct SmoothScrollSettings: Codable, Equatable, Sendable {
    static let stepRange: ClosedRange<Double> = 1...200
    static let speedRange: ClosedRange<Double> = 0.1...10
    static let durationRange: ClosedRange<Double> = 0...5
    static let deadZoneRange: ClosedRange<Double> = 0...10
    static let adaptiveSpeedRange: ClosedRange<Double> = 1...8

    var isEnabled = false
    var smoothVertical = true
    var smoothHorizontal = true
    var reverseVertical = true
    var reverseHorizontal = true
    var minimumStep = 33.6
    var speed = 2.7
    var duration = 4.35
    var deadZone = 1.0
    var simulatesTrackpadPhases = false
    var adaptiveSpeedEnabled = false
    var adaptiveSpeedMaximum = 3.0
    var blockSmoothWhileCommandHeld = true

    var interpolationFactor: Double {
        Self.interpolationFactor(forDuration: duration)
    }

    static func interpolationFactor(forDuration duration: Double) -> Double {
        // This is Mos' duration-to-frame-factor curve. A larger UI duration
        // produces a smaller factor and therefore a longer glide.
        let upperLimit = 5.2
        let value = 1 - (duration / upperLimit).squareRoot()
        return (value * 1_000).rounded() / 1_000
    }

    func clamped() -> SmoothScrollSettings {
        var value = self
        value.minimumStep = minimumStep.clamped(to: Self.stepRange)
        value.speed = speed.clamped(to: Self.speedRange)
        value.duration = duration.clamped(to: Self.durationRange)
        value.deadZone = deadZone.clamped(to: Self.deadZoneRange)
        value.adaptiveSpeedMaximum = adaptiveSpeedMaximum.clamped(to: Self.adaptiveSpeedRange)
        return value
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        smoothVertical = try container.decodeIfPresent(Bool.self, forKey: .smoothVertical) ?? true
        smoothHorizontal = try container.decodeIfPresent(Bool.self, forKey: .smoothHorizontal) ?? true
        reverseVertical = try container.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? true
        reverseHorizontal = try container.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? true
        minimumStep = try container.decodeIfPresent(Double.self, forKey: .minimumStep) ?? 33.6
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 2.7
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 4.35
        deadZone = try container.decodeIfPresent(Double.self, forKey: .deadZone) ?? 1.0
        simulatesTrackpadPhases = try container.decodeIfPresent(Bool.self, forKey: .simulatesTrackpadPhases) ?? false
        adaptiveSpeedEnabled = try container.decodeIfPresent(Bool.self, forKey: .adaptiveSpeedEnabled) ?? false
        adaptiveSpeedMaximum = try container.decodeIfPresent(Double.self, forKey: .adaptiveSpeedMaximum) ?? 3.0
        blockSmoothWhileCommandHeld = try container.decodeIfPresent(Bool.self, forKey: .blockSmoothWhileCommandHeld) ?? true
        self = clamped()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

enum SmoothScrollAxis {
    case vertical
    case horizontal
}

struct SmoothScrollAxisValue: Equatable, Sendable {
    var fixedDelta: Int64 = 0
    var pointDelta: Double = 0
    var fixedPointDelta: Double = 0
    var isPrecise = false
    var value: Double = 0

    var isValid: Bool { value != 0 }
}

/// Parses the three CG scroll fields used by different mouse drivers.
enum SmoothScrollWheelEventParser {
    static func axis(_ axis: SmoothScrollAxis, in event: CGEvent) -> SmoothScrollAxisValue {
        var parsed = SmoothScrollAxisValue()
        switch axis {
        case .vertical:
            parsed.fixedDelta = Int64(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            parsed.pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            parsed.fixedPointDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        case .horizontal:
            parsed.fixedDelta = Int64(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            parsed.pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            parsed.fixedPointDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        }

        if parsed.pointDelta != 0 {
            parsed.isPrecise = true
            parsed.value = parsed.pointDelta
        } else if parsed.fixedPointDelta != 0 {
            parsed.value = parsed.fixedPointDelta
        } else if parsed.fixedDelta != 0 {
            parsed.value = Double(parsed.fixedDelta)
        }
        return parsed
    }

    static func clear(_ axis: SmoothScrollAxis, in event: CGEvent) {
        switch axis {
        case .vertical:
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        case .horizontal:
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        }
    }

    static func reverse(_ axis: SmoothScrollAxis, in event: CGEvent) -> SmoothScrollAxisValue {
        let parsed = Self.axis(axis, in: event)
        switch axis {
        case .vertical:
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -parsed.fixedDelta)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -parsed.pointDelta)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -parsed.fixedPointDelta)
        case .horizontal:
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -parsed.fixedDelta)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -parsed.pointDelta)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -parsed.fixedPointDelta)
        }
        var reversed = parsed
        reversed.value = -parsed.value
        return reversed
    }

    static func isTrackpadLike(_ event: CGEvent) -> Bool {
        event.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0 ||
        event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0 ||
        event.getDoubleValueField(.scrollWheelEventScrollCount) != 0 ||
        event.getDoubleValueField(.scrollWheelEventIsContinuous) != 0
    }

    static func isRemoteSmoothed(_ event: CGEvent) -> Bool {
        event.getDoubleValueField(.scrollWheelEventIsContinuous) != 0
    }
}

/// The decision returned for one physical wheel event.
struct SmoothScrollPlan: Equatable, Sendable {
    var verticalTarget: Double = 0
    var horizontalTarget: Double = 0
    var passThroughVertical = false
    var passThroughHorizontal = false
    var shouldSuppressOriginal = false

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
            plan.verticalTarget = settings.reverseVertical ? -vertical.value : vertical.value
        }
        if horizontal.value != 0 {
            plan.horizontalTarget = settings.reverseHorizontal ? -horizontal.value : horizontal.value
        }

        // Mos raises tiny wheel deltas to its minimum step before applying speed.
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

        plan.shouldSuppressOriginal = plan.consumesAnyAxis && !plan.passThroughVertical && !plan.passThroughHorizontal
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
        let clampedMaximum = Swift.min(Swift.max(maximum, 1), 8)
        guard clampedMaximum > 1 else { return 1 }
        let clampedInterval = Swift.min(Swift.max(interval, fastInterval), slowInterval)
        let normalizedSpeed = (slowInterval - clampedInterval) / (slowInterval - fastInterval)
        let boosted = 1 + (clampedMaximum - 1) * normalizedSpeed
        return (boosted * 100).rounded() / 100
    }
}

/// Linear interpolation used by Mos' display-link frame generator.
enum SmoothScrollInterpolator {
    static func lerp(current: Double, target: Double, factor: Double) -> Double {
        (target - current) * factor
    }
}

/// Two-value curve filter derived from Mos' ScrollFilter. It removes startup
/// jitter by interpolating the previous frame toward the newly generated one.
struct SmoothScrollFilter: Equatable, Sendable {
    private(set) var verticalWindow: [Double] = [0, 0]
    private(set) var horizontalWindow: [Double] = [0, 0]

    mutating func fill(vertical: Double, horizontal: Double) -> (vertical: Double, horizontal: Double) {
        verticalWindow = polish(verticalWindow, with: vertical)
        horizontalWindow = polish(horizontalWindow, with: horizontal)
        return (verticalWindow[0], horizontalWindow[0])
    }

    mutating func reset() {
        verticalWindow = [0, 0]
        horizontalWindow = [0, 0]
    }

    private func polish(_ values: [Double], with next: Double) -> [Double] {
        let first = values[1]
        let difference = next - first
        return [first, first + 0.23 * difference, first + 0.5 * difference, first + 0.77 * difference, next]
    }
}

enum SmoothScrollPhase: Equatable, Sendable {
    case idle
    case hold
    case trackingBegin
    case trackingOngoing
    case trackingEnd
    case momentumBegin
    case momentumOngoing
    case momentumEnd
    case leave

    var scrollPhaseValue: Double {
        switch self {
        case .idle: 0
        case .hold: 128
        case .trackingBegin: 1
        case .trackingOngoing: 2
        case .trackingEnd: 4
        case .momentumBegin, .momentumOngoing, .momentumEnd: 0
        case .leave: 8
        }
    }

    var momentumPhaseValue: Double {
        switch self {
        case .momentumBegin: 1
        case .momentumOngoing: 2
        case .momentumEnd: 3
        default: 0
        }
    }

    var autoAdvanceAfterEmission: SmoothScrollPhase? {
        switch self {
        case .trackingBegin: .trackingOngoing
        case .momentumEnd: .idle
        default: nil
        }
    }
}

/// Pure form of Mos' scroll phase machine. It is only emitted when trackpad
/// phase simulation is enabled; ordinary pixel scroll remains compatible with
/// apps that do not understand trackpad phase fields.
struct SmoothScrollPhaseMachine: Equatable, Sendable {
    private(set) var phase: SmoothScrollPhase = .idle
    private var pendingPhaseAfterDelivery: SmoothScrollPhase?

    struct Transition: Equatable, Sendable {
        var queue: [SmoothScrollPhase]
        var target: SmoothScrollPhase?
        var targetAutoAdvance: SmoothScrollPhase?

        init(
            queue: [SmoothScrollPhase] = [],
            target: SmoothScrollPhase? = nil,
            targetAutoAdvance: SmoothScrollPhase? = nil
        ) {
            self.queue = queue
            self.target = target
            self.targetAutoAdvance = targetAutoAdvance
        }
    }

    mutating func reset() {
        phase = .idle
        pendingPhaseAfterDelivery = nil
    }

    mutating func manualInputDetected(isSeparated: Bool) -> Transition {
        if phase == .momentumBegin || phase == .momentumOngoing {
            if isSeparated {
                return Transition(queue: [.momentumEnd, .trackingBegin])
            }
            return Transition(
                queue: [.momentumEnd],
                target: .trackingBegin,
                targetAutoAdvance: .trackingOngoing
            )
        }
        if isSeparated { return Transition(queue: [.trackingBegin]) }
        if phase == .trackingBegin || phase == .trackingOngoing { return Transition(target: .trackingOngoing) }
        return Transition(target: .trackingBegin, targetAutoAdvance: .trackingOngoing)
    }

    mutating func manualInputEnded() -> Transition {
        switch phase {
        case .trackingBegin, .trackingOngoing:
            return Transition(target: .trackingEnd)
        default:
            return Transition()
        }
    }

    mutating func momentumStart() -> Transition {
        switch phase {
        case .trackingEnd, .momentumEnd:
            return Transition(target: .momentumBegin, targetAutoAdvance: .momentumOngoing)
        case .momentumBegin:
            return Transition(target: .momentumOngoing)
        default:
            return Transition()
        }
    }

    mutating func momentumFinish() -> Transition {
        switch phase {
        case .momentumBegin, .momentumOngoing:
            return Transition(target: .momentumEnd, targetAutoAdvance: .idle)
        case .trackingBegin, .trackingOngoing, .trackingEnd:
            return Transition(target: .trackingEnd, targetAutoAdvance: .idle)
        default:
            return Transition()
        }
    }

    mutating func apply(_ next: SmoothScrollPhase, autoAdvance: SmoothScrollPhase? = nil) {
        phase = next
        pendingPhaseAfterDelivery = autoAdvance
    }

    mutating func didDeliverFrame() {
        if let next = pendingPhaseAfterDelivery {
            phase = next
            pendingPhaseAfterDelivery = nil
        }
    }
}
