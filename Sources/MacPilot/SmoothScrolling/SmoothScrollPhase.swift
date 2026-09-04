import Foundation

enum SmoothScrollPhase: Equatable, Sendable {
    case idle
    case trackingBegin
    case trackingOngoing
    case trackingEnd
    case momentumBegin
    case momentumOngoing
    case momentumEnd

    var scrollPhaseValue: Double {
        switch self {
        case .idle: 0
        case .trackingBegin: 1
        case .trackingOngoing: 2
        case .trackingEnd: 4
        case .momentumBegin, .momentumOngoing, .momentumEnd: 0
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

/// Pure scroll phase machine. It is only emitted when trackpad phase
/// simulation is enabled; ordinary pixel scroll remains compatible with
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
