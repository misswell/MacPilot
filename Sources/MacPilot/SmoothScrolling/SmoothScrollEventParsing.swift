import CoreGraphics

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
