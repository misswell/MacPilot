@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics
import CoreVideo
import Foundation
import os

/// Low-level presenter for Mos-style smooth wheel scrolling.
///
/// A single CGEvent tap reads physical wheel events on the main run loop, feeds
/// their deltas into a CVDisplayLink-backed interpolator, then posts synthetic
/// continuous scroll events directly to the original target process.
@MainActor
final class SmoothScrollController {
    private let runtime = SmoothScrollRuntime()
    private var activeSettings = SmoothScrollSettings()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var displayLink: CVDisplayLink?
    private(set) var isActive = false

    private let eventMask: CGEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

    func activate(settings: SmoothScrollSettings) {
        activeSettings = settings
        guard settings.isEnabled else {
            deactivate()
            return
        }
        guard AXIsProcessTrusted() else {
            deactivate()
            return
        }
        guard !isActive else {
            runtime.update(settings: settings)
            return
        }
        runtime.update(settings: settings)
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        runtime.start()
    }

    func deactivate() {
        guard isActive || eventTap != nil else {
            runtime.stop()
            return
        }
        isActive = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            if CFRunLoopContainsSource(CFRunLoopGetCurrent(), source, .commonModes) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            runLoopSource = nil
        }
        runtime.stop()
    }

    func shutdown() {
        deactivate()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<SmoothScrollController>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            controller.handleTapEvent(type: type, event: event)
        }
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            runtime.stop()
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.eventSourceUserData) != SmoothScrollRuntime.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }
        guard !SmoothScrollWheelEventParser.isRemoteSmoothed(event),
              !SmoothScrollWheelEventParser.isTrackpadLike(event) else {
            return Unmanaged.passUnretained(event)
        }

        let settings = activeSettings
        let vertical = SmoothScrollWheelEventParser.axis(.vertical, in: event)
        let horizontal = SmoothScrollWheelEventParser.axis(.horizontal, in: event)
        let plan = SmoothScrollPlanner.plan(vertical: vertical, horizontal: horizontal, settings: settings)

        guard plan.consumesAnyAxis else { return Unmanaged.passUnretained(event) }

        // Reversing also applies to axes that pass through untouched, matching
        // Mos' behavior before the smooth/no-smooth split.
        if settings.reverseVertical { _ = SmoothScrollWheelEventParser.reverse(.vertical, in: event) }
        if settings.reverseHorizontal { _ = SmoothScrollWheelEventParser.reverse(.horizontal, in: event) }

        let accepted = runtime.update(
            event: event,
            verticalTarget: plan.verticalTarget,
            horizontalTarget: plan.horizontalTarget,
            settings: settings
        )

        // A disabled axis keeps its physical delta on the original event so that
        // apps still receive real (non-synthetic) horizontal scrolling while the
        // vertical axis is being smoothed.
        if plan.passThroughVertical || plan.passThroughHorizontal {
            if plan.verticalTarget != 0 { SmoothScrollWheelEventParser.clear(.vertical, in: event) }
            if plan.horizontalTarget != 0 { SmoothScrollWheelEventParser.clear(.horizontal, in: event) }
            return Unmanaged.passUnretained(event)
        }
        return accepted ? nil : Unmanaged.passUnretained(event)
    }

    nonisolated fileprivate static let displayLinkCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        Unmanaged<SmoothScrollRuntime>.fromOpaque(context).takeUnretainedValue().processFrame()
        return kCVReturnSuccess
    }
}

/// Thread-safe scroll interpolator. `SmoothScrollController` drives it from the
/// main thread; the CVDisplayLink callback only performs lock-protected work.
final class SmoothScrollRuntime: @unchecked Sendable {
    static let syntheticEventMarker: Int64 = 0x4D4F53534D4F4F54

    private struct State: @unchecked Sendable {
        var eventTemplate: CGEvent?
        var targetProcessID: pid_t = 0
        var generation: UInt64 = 0
        var current = (vertical: 0.0, horizontal: 0.0)
        var buffer = (vertical: 0.0, horizontal: 0.0)
        var previousDirection = (vertical: 0.0, horizontal: 0.0)
        var interpolationFactor: Double = 0.085
        var deadZone = 1.0
        var simulatesPhases = false
        var manualInputEnded = true
        var momentumActive = false
        var pendingEnd = false
        var pendingStopPhase: SmoothScrollPhase?
        var filter = SmoothScrollFilter()
        var phaseMachine = SmoothScrollPhaseMachine()
        var pendingPhaseFrames: [SmoothScrollPhase] = []
        var postedSyntheticFrame = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var displayLink: CVDisplayLink?

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
        horizontalTarget: Double,
        settings: SmoothScrollSettings
    ) -> Bool {
        guard let template = event.copy() else { return false }
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if targetPID == 0 { return false }

        lock.withLock { state in
            if state.targetProcessID != targetPID {
                SmoothScrollRuntime.resetLocked(&state)
            }
            state.eventTemplate = template
            state.targetProcessID = targetPID
            state.generation &+= 1
            state.interpolationFactor = settings.interpolationFactor
            state.deadZone = settings.deadZone
            state.simulatesPhases = settings.simulatesTrackpadPhases

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
            state.pendingPhaseFrames.append(contentsOf: phaseTransition.queue)
            if let target = phaseTransition.target {
                state.phaseMachine.apply(target)
            }
            state.momentumActive = false
            state.pendingEnd = false
            state.pendingStopPhase = nil
        }
        if displayLink == nil {
            start()
        }
        return true
    }

    func start() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        CVDisplayLinkSetOutputCallback(link, SmoothScrollController.displayLinkCallback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
        CVDisplayLinkStart(link)
    }

    func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        lock.withLock { state in
            SmoothScrollRuntime.resetLocked(&state)
        }
    }

    func processFrame() {
        guard displayLink != nil else { return }
        let frame = lock.withLock { state -> (output: (vertical: Double, horizontal: Double), phases: [SmoothScrollPhase])? in
            guard state.eventTemplate != nil else { return nil }
            var phasesToPost = state.pendingPhaseFrames
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
            if !state.manualInputEnded {
                let transition = state.phaseMachine.manualInputEnded()
                state.pendingPhaseFrames.append(contentsOf: transition.queue)
                if let target = transition.target {
                    state.phaseMachine.apply(target)
                    state.pendingStopPhase = .trackingEnd
                }
                state.manualInputEnded = true
            }
            if state.momentumActive {
                if state.pendingEnd {
                    phasesToPost.append(.momentumEnd)
                    state.pendingStopPhase = .momentumEnd
                    state.momentumActive = false
                } else if residual <= state.deadZone {
                    state.pendingEnd = true
                } else {
                    phasesToPost.append(.momentumOngoing)
                }
            } else if residual > state.deadZone {
                let transition = state.phaseMachine.momentumStart()
                state.pendingPhaseFrames.append(contentsOf: transition.queue)
                if let target = transition.target {
                    state.phaseMachine.apply(target)
                    state.momentumActive = true
                    phasesToPost.append(target)
                }
            } else if state.pendingStopPhase == .trackingEnd {
                state.pendingStopPhase = nil
            }
            if let stopPhase = state.pendingStopPhase, residual <= state.deadZone, state.momentumActive == false {
                phasesToPost.append(stopPhase)
                state.pendingStopPhase = nil
            }
            state.postedSyntheticFrame = true
            return (filtered, phasesToPost)
        }

        guard let frame else { return }
        for phase in frame.phases {
            post(vertical: 0, horizontal: 0, phase: phase)
        }
        if max(abs(frame.output.vertical), abs(frame.output.horizontal)) > currentDeadZone {
            post(vertical: frame.output.vertical, horizontal: frame.output.horizontal, phase: nil)
        } else {
            stopIfSettled()
        }
    }

    private var currentDeadZone: Double {
        lock.withLock { $0.deadZone }
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

    private func stopIfSettled() {
        let shouldStop = lock.withLock { state -> Bool in
            guard state.postedSyntheticFrame else { return false }
            let residual = max(
                abs(state.buffer.vertical - state.current.vertical),
                abs(state.buffer.horizontal - state.current.horizontal)
            )
            guard residual <= state.deadZone, state.manualInputEnded, !state.momentumActive else { return false }
            state.pendingStopPhase = nil
            return true
        }
        if shouldStop { stop() }
    }

    private static func resetLocked(_ state: inout State) {
        state.eventTemplate = nil
        state.targetProcessID = 0
        state.generation &+= 1
        state.current = (0, 0)
        state.buffer = (0, 0)
        state.previousDirection = (0, 0)
        state.manualInputEnded = true
        state.momentumActive = false
        state.pendingEnd = false
        state.pendingStopPhase = nil
        state.filter.reset()
        state.phaseMachine.reset()
        state.pendingPhaseFrames.removeAll()
        state.postedSyntheticFrame = false
    }
}
