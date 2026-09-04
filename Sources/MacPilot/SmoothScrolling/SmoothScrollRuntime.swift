@preconcurrency import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import os

/// Thread-safe scroll interpolator. `SmoothScrollController` drives it from the
/// main thread; the CVDisplayLink callback only performs lock-protected work.
///
/// The display link handle lives inside the locked state so the main thread
/// and the callback thread never race on it. CVDisplayLink calls happen
/// outside the lock, and stopping from within the callback remains supported:
/// the next event simply recreates the link.
final class SmoothScrollRuntime: @unchecked Sendable {
    /// ASCII "MOSSMOOT". Stamped on every synthetic event so the tap callback
    /// can recognize and pass through the runtime's own output.
    static let syntheticEventMarker: Int64 = 0x4D4F_5353_4D4F_4F54
    /// Idle time after the last manual wheel event before tracking ends.
    private static let manualContinuationThreshold: CFTimeInterval = 0.18

    struct State: @unchecked Sendable {
        var eventTemplate: CGEvent?
        var targetProcessID: pid_t = 0
        var displayLink: CVDisplayLink?
        var current = (vertical: 0.0, horizontal: 0.0)
        var buffer = (vertical: 0.0, horizontal: 0.0)
        var previousDirection = (vertical: 0.0, horizontal: 0.0)
        /// Matches `interpolationFactor(forDuration: SmoothScrollSettings().duration)`.
        var interpolationFactor: Double = 0.085
        var deadZone = 1.0
        var simulatesPhases = false
        var manualInputEnded = true
        var lastManualEventTime: CFTimeInterval = 0
        var momentumActive = false
        var pendingEnd = false
        var pendingStopPhase: SmoothScrollPhase?
        var filter = SmoothScrollFilter()
        var phaseMachine = SmoothScrollPhaseMachine()
        var pendingPhaseFrames: [(phase: SmoothScrollPhase, autoAdvance: SmoothScrollPhase?)] = []
        var postedSyntheticFrame = false
    }

    struct FrameResult {
        var output: (vertical: Double, horizontal: Double)
        var phases: [SmoothScrollPhase]
        var shouldPostOutput: Bool
        var shouldStopLink: Bool
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// `CVDisplayLink` is explicitly non-Sendable, so the lock-protected handle
    /// leaves the lock behind this unchecked box instead of a closure return.
    private final class DisplayLinkReference: @unchecked Sendable {
        var value: CVDisplayLink?
    }

    /// Applies the configuration fields used per frame. `SmoothScrollController`
    /// calls this before the event tap can deliver its first event, so the
    /// runtime deliberately does not re-apply settings per event.
    func update(settings: SmoothScrollSettings) {
        lock.withLock { state in
            state.interpolationFactor = settings.interpolationFactor
            state.deadZone = settings.deadZone
            state.simulatesPhases = settings.simulatesTrackpadPhases
        }
    }

    @discardableResult
    func update(
        event: CGEvent,
        verticalTarget: Double,
        horizontalTarget: Double
    ) -> Bool {
        guard let template = event.copy() else { return false }
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if targetPID == 0 { return false }

        let needsStart = lock.withLock { state -> Bool in
            if state.targetProcessID != targetPID {
                SmoothScrollRuntime.resetLocked(&state)
            }
            state.eventTemplate = template
            state.targetProcessID = targetPID
            SmoothScrollRuntime.accumulateInput(
                verticalTarget: verticalTarget,
                horizontalTarget: horizontalTarget,
                now: CFAbsoluteTimeGetCurrent(),
                into: &state
            )
            return state.displayLink == nil
        }
        if needsStart {
            start()
        }
        return true
    }

    /// Folds one planned wheel event into the interpolation buffers. Same-direction
    /// events build up the buffer so fast scrolling glides farther; a direction
    /// flip restarts the glide from zero.
    static func accumulateInput(
        verticalTarget: Double,
        horizontalTarget: Double,
        now: CFTimeInterval,
        into state: inout State
    ) {
        if verticalTarget * state.previousDirection.vertical > 0 {
            state.buffer.vertical += verticalTarget
        } else {
            state.buffer.vertical = verticalTarget
            state.current.vertical = 0
        }
        if horizontalTarget * state.previousDirection.horizontal > 0 {
            state.buffer.horizontal += horizontalTarget
        } else {
            state.buffer.horizontal = horizontalTarget
            state.current.horizontal = 0
        }
        state.previousDirection = (verticalTarget, horizontalTarget)

        let phaseTransition = state.phaseMachine.manualInputDetected(isSeparated: state.manualInputEnded)
        state.manualInputEnded = false
        state.lastManualEventTime = now
        for phase in phaseTransition.queue {
            state.pendingPhaseFrames.append((phase, phase.autoAdvanceAfterEmission))
        }
        if let target = phaseTransition.target {
            state.phaseMachine.apply(target, autoAdvance: phaseTransition.targetAutoAdvance)
        }
        state.momentumActive = false
        state.pendingEnd = false
        state.pendingStopPhase = nil
    }

    func start() {
        guard lock.withLock({ $0.displayLink == nil }) else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        CVDisplayLinkSetOutputCallback(link, Self.displayLinkCallback, Unmanaged.passUnretained(self).toOpaque())

        let reference = DisplayLinkReference()
        reference.value = link
        let shouldStart = lock.withLock { state -> Bool in
            guard state.displayLink == nil else { return false }
            state.displayLink = reference.value
            return true
        }
        if shouldStart {
            CVDisplayLinkStart(link)
        }
    }

    func stop() {
        let reference = DisplayLinkReference()
        lock.withLock { state in
            reference.value = state.displayLink
            state.displayLink = nil
            SmoothScrollRuntime.resetLocked(&state)
        }
        if let link = reference.value {
            CVDisplayLinkStop(link)
        }
    }

    func processFrame() {
        let frame = lock.withLock { state -> FrameResult? in
            guard state.displayLink != nil else { return nil }
            return SmoothScrollRuntime.computeFrame(&state, now: CFAbsoluteTimeGetCurrent())
        }
        guard let frame else { return }
        for phase in frame.phases {
            post(vertical: 0, horizontal: 0, phase: phase)
        }
        if frame.shouldPostOutput {
            post(vertical: frame.output.vertical, horizontal: frame.output.horizontal, phase: nil)
        } else if frame.shouldStopLink {
            stop()
        }
    }

    /// Pure per-frame computation, shared by `processFrame()` and unit tests.
    /// The dead-zone gating and the settle decision are evaluated against the
    /// same frame inside the caller's lock so the two cannot disagree.
    static func computeFrame(_ state: inout State, now: CFTimeInterval) -> FrameResult? {
        guard state.eventTemplate != nil else { return nil }
        var phasesToPost: [SmoothScrollPhase] = []
        for pending in state.pendingPhaseFrames {
            state.phaseMachine.apply(pending.phase, autoAdvance: pending.autoAdvance)
            phasesToPost.append(pending.phase)
        }
        state.pendingPhaseFrames.removeAll()

        let interpolated = (
            vertical: SmoothScrollInterpolator.lerp(
                current: state.current.vertical,
                target: state.buffer.vertical,
                factor: state.interpolationFactor
            ),
            horizontal: SmoothScrollInterpolator.lerp(
                current: state.current.horizontal,
                target: state.buffer.horizontal,
                factor: state.interpolationFactor
            )
        )
        state.current.vertical += interpolated.vertical
        state.current.horizontal += interpolated.horizontal
        let filtered = state.filter.fill(vertical: interpolated.vertical, horizontal: interpolated.horizontal)

        let residual = max(
            abs(state.buffer.vertical - state.current.vertical),
            abs(state.buffer.horizontal - state.current.horizontal)
        )
        let inputPause = now - state.lastManualEventTime
        if !state.manualInputEnded, inputPause > manualContinuationThreshold {
            let transition = state.phaseMachine.manualInputEnded()
            for phase in transition.queue {
                state.pendingPhaseFrames.append((phase, phase.autoAdvanceAfterEmission))
            }
            if let target = transition.target {
                state.phaseMachine.apply(target, autoAdvance: transition.targetAutoAdvance)
                phasesToPost.append(target)
                state.pendingStopPhase = .trackingEnd
            }
            state.manualInputEnded = true
        }
        if state.momentumActive {
            if state.pendingEnd {
                state.phaseMachine.apply(.momentumEnd, autoAdvance: .idle)
                phasesToPost.append(.momentumEnd)
                state.pendingStopPhase = .momentumEnd
                state.momentumActive = false
            } else if residual <= state.deadZone {
                state.pendingEnd = true
            } else {
                state.phaseMachine.apply(.momentumOngoing)
                phasesToPost.append(.momentumOngoing)
            }
        } else if residual > state.deadZone {
            let transition = state.phaseMachine.momentumStart()
            for phase in transition.queue {
                state.pendingPhaseFrames.append((phase, phase.autoAdvanceAfterEmission))
            }
            if let target = transition.target {
                state.phaseMachine.apply(target, autoAdvance: transition.targetAutoAdvance)
                state.momentumActive = true
                phasesToPost.append(target)
            }
        } else if state.pendingStopPhase == .trackingEnd {
            state.pendingStopPhase = nil
        }
        if let stopPhase = state.pendingStopPhase, residual <= state.deadZone, state.momentumActive == false {
            state.phaseMachine.apply(stopPhase, autoAdvance: .idle)
            phasesToPost.append(stopPhase)
            state.pendingStopPhase = nil
        }
        state.postedSyntheticFrame = true

        let shouldPostOutput = max(abs(filtered.vertical), abs(filtered.horizontal)) > state.deadZone
        var shouldStopLink = false
        if !shouldPostOutput, residual <= state.deadZone, state.manualInputEnded, !state.momentumActive {
            // The glide has drained below the dead zone with no manual input
            // and no momentum left; drop any queued stop phase and stop.
            state.pendingStopPhase = nil
            shouldStopLink = true
        }
        return FrameResult(
            output: filtered,
            phases: phasesToPost,
            shouldPostOutput: shouldPostOutput,
            shouldStopLink: shouldStopLink
        )
    }

    private func post(vertical: Double, horizontal: Double, phase: SmoothScrollPhase?) {
        let payload = lock.withLock { state -> (event: CGEvent, pid: pid_t)? in
            guard let template = state.eventTemplate?.copy(), state.targetProcessID != 0 else { return nil }
            template.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: vertical)
            template.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: horizontal)
            template.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
            template.setIntegerValueField(.eventSourceUserData, value: SmoothScrollRuntime.syntheticEventMarker)
            if state.simulatesPhases, let phase {
                template.setDoubleValueField(.scrollWheelEventScrollPhase, value: phase.scrollPhaseValue)
                template.setDoubleValueField(.scrollWheelEventMomentumPhase, value: phase.momentumPhaseValue)
            } else if state.simulatesPhases {
                template.setDoubleValueField(.scrollWheelEventScrollPhase, value: state.phaseMachine.phase.scrollPhaseValue)
                template.setDoubleValueField(.scrollWheelEventMomentumPhase, value: state.phaseMachine.phase.momentumPhaseValue)
            } else {
                template.setDoubleValueField(.scrollWheelEventScrollPhase, value: 0)
                template.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
            }
            state.phaseMachine.didDeliverFrame()
            return (template, state.targetProcessID)
        }
        if let payload {
            payload.event.postToPid(payload.pid)
        }
    }

    private static func resetLocked(_ state: inout State) {
        state.eventTemplate = nil
        state.targetProcessID = 0
        state.current = (0, 0)
        state.buffer = (0, 0)
        state.previousDirection = (0, 0)
        state.manualInputEnded = true
        state.lastManualEventTime = 0
        state.momentumActive = false
        state.pendingEnd = false
        state.pendingStopPhase = nil
        state.filter.reset()
        state.phaseMachine.reset()
        state.pendingPhaseFrames.removeAll()
        state.postedSyntheticFrame = false
    }

    private static let displayLinkCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        Unmanaged<SmoothScrollRuntime>.fromOpaque(context).takeUnretainedValue().processFrame()
        return kCVReturnSuccess
    }
}
