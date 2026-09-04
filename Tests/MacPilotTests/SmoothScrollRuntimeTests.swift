import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

/// Coverage for the two previously untested seams of the smooth scrolling
/// pipeline: the tap callback's bypass ordering (`SmoothScrollGate`) and the
/// display-link frame computation (`SmoothScrollRuntime`).
struct SmoothScrollRuntimeTests {
    private var enabledSettings: SmoothScrollSettings {
        var settings = SmoothScrollSettings()
        settings.isEnabled = true
        return settings
    }

    private func axis(_ value: Double) -> SmoothScrollAxisValue {
        var parsed = SmoothScrollAxisValue()
        parsed.value = value
        return parsed
    }

    private func makeEvent() throws -> CGEvent {
        try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ))
    }

    // MARK: Gate ordering

    @Test func gateBypassesExcludedTargetsBeforeAllOtherChecks() {
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: true,
            shouldReverseExcludedTarget: true,
            isRemoteSmoothed: true,
            vertical: SmoothScrollAxisValue(),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: true,
            settings: SmoothScrollSettings(),
            commandBlocked: true
        )

        #expect(decision.action == .bypassExcluded(reverse: true))
        #expect(!decision.reverseOriginalVertical)
        #expect(!decision.reverseOriginalHorizontal)
    }

    @Test func gateBypassesExcludedTargetsWithoutReversalUnlessConfigured() {
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: true,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: false,
            vertical: axis(5),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: false,
            settings: enabledSettings,
            commandBlocked: false
        )

        #expect(decision.action == .bypassExcluded(reverse: false))
    }

    @Test func gatePassesRemoteSmoothedEventsBeforeValidityAndSmoothingChecks() {
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: false,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: true,
            vertical: SmoothScrollAxisValue(),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: false,
            settings: SmoothScrollSettings(),
            commandBlocked: true
        )

        #expect(decision.action == .passThroughRemoteSmoothed)
    }

    @Test func gatePassesEventsWithoutUsableAxisDeltas() {
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: false,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: false,
            vertical: SmoothScrollAxisValue(),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: false,
            settings: enabledSettings,
            commandBlocked: true
        )

        #expect(decision.action == .passThroughInvalidAxes)
    }

    @Test func gatePassesTrackpadLikeEventsAfterApplyingReversal() {
        var settings = enabledSettings
        settings.reverseScrollingEnabled = true
        settings.reverseHorizontal = false

        let decision = SmoothScrollGate.decide(
            isExcludedTarget: false,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: false,
            vertical: axis(5),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: true,
            settings: settings,
            commandBlocked: false
        )

        #expect(decision.action == .passThroughTrackpadLike)
        #expect(decision.reverseOriginalVertical)
        #expect(!decision.reverseOriginalHorizontal)
    }

    @Test func gatePassesWhenSmoothingIsDisabledButStillReverses() {
        var settings = SmoothScrollSettings()
        settings.isEnabled = false
        settings.reverseScrollingEnabled = true

        let decision = SmoothScrollGate.decide(
            isExcludedTarget: false,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: false,
            vertical: axis(5),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: false,
            settings: settings,
            commandBlocked: false
        )

        #expect(decision.action == .passThroughSmoothingDisabled)
        #expect(decision.reverseOriginalVertical)
        #expect(decision.reverseOriginalHorizontal)
    }

    @Test func gateBlocksSmoothingWhileCommandIsHeld() {
        var settings = enabledSettings
        settings.reverseScrollingEnabled = true

        let decision = SmoothScrollGate.decide(
            isExcludedTarget: false,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: false,
            vertical: axis(5),
            horizontal: SmoothScrollAxisValue(),
            isTrackpadLike: false,
            settings: settings,
            commandBlocked: true
        )

        #expect(decision.action == .passThroughCommandBlocked)
        #expect(decision.reverseOriginalVertical)
    }

    @Test func gateAdmitsPhysicalWheelEventsForSmoothing() {
        let decision = SmoothScrollGate.decide(
            isExcludedTarget: false,
            shouldReverseExcludedTarget: false,
            isRemoteSmoothed: false,
            vertical: axis(5),
            horizontal: axis(-2),
            isTrackpadLike: false,
            settings: enabledSettings,
            commandBlocked: false
        )

        #expect(decision.action == .smooth)
        #expect(!decision.reverseOriginalVertical)
        #expect(!decision.reverseOriginalHorizontal)
    }

    // MARK: Buffer accumulation

    @Test func accumulateBuildsBufferAlongSameDirectionAndResetsOnFlip() {
        var state = SmoothScrollRuntime.State()

        SmoothScrollRuntime.accumulateInput(verticalTarget: 5, horizontalTarget: 0, now: 1, into: &state)
        #expect(state.buffer.vertical == 5)
        #expect(state.current.vertical == 0)

        SmoothScrollRuntime.accumulateInput(verticalTarget: 3, horizontalTarget: 0, now: 2, into: &state)
        #expect(state.buffer.vertical == 8)

        SmoothScrollRuntime.accumulateInput(verticalTarget: -4, horizontalTarget: 0, now: 3, into: &state)
        #expect(state.buffer.vertical == -4)
        #expect(state.current.vertical == 0)
        #expect(!state.manualInputEnded)
    }

    @Test func accumulateQueuesTrackingBeginFromIdle() throws {
        var state = SmoothScrollRuntime.State()
        state.eventTemplate = try makeEvent()

        SmoothScrollRuntime.accumulateInput(verticalTarget: 5, horizontalTarget: 0, now: 1, into: &state)
        #expect(state.pendingPhaseFrames.map { $0.phase } == [.trackingBegin])
        #expect(state.lastManualEventTime == 1)

        // A display-link frame consumes the queued phase before the next event.
        let frame = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1.05))
        #expect(frame.phases == [.trackingBegin])
        #expect(state.pendingPhaseFrames.isEmpty)

        SmoothScrollRuntime.accumulateInput(verticalTarget: 5, horizontalTarget: 0, now: 2, into: &state)
        #expect(state.pendingPhaseFrames.isEmpty)
        #expect(state.phaseMachine.phase == .trackingOngoing)
    }

    // MARK: Frame computation

    @Test func frameInterpolatesTowardBufferAndGatesOnDeadZone() throws {
        var state = SmoothScrollRuntime.State()
        state.eventTemplate = try makeEvent()
        state.buffer.vertical = 10
        state.interpolationFactor = 0.5
        state.deadZone = 0.1

        let first = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1))
        #expect(state.current.vertical == 5)
        #expect(first.output.vertical == 0)
        #expect(first.phases.isEmpty)
        #expect(!first.shouldPostOutput)
        #expect(!first.shouldStopLink)

        let second = try #require(SmoothScrollRuntime.computeFrame(&state, now: 2))
        #expect(state.current.vertical == 7.5)
        #expect(abs(second.output.vertical - 1.15) < 1e-9)
        #expect(second.shouldPostOutput)
    }

    @Test func frameDrivesTrackingAndMomentumPhasesToCompletion() throws {
        var state = SmoothScrollRuntime.State()
        state.eventTemplate = try makeEvent()
        state.simulatesPhases = true
        state.interpolationFactor = 0.5
        state.deadZone = 1.0

        SmoothScrollRuntime.accumulateInput(verticalTarget: 40, horizontalTarget: 0, now: 1, into: &state)

        let first = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1.05))
        #expect(first.phases == [.trackingBegin])

        let second = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1.25))
        #expect(second.phases == [.trackingEnd, .momentumBegin])
        #expect(state.momentumActive)

        let third = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1.3))
        #expect(third.phases == [.momentumOngoing])

        // The buffer drains by half each frame; once the residual falls inside
        // the dead zone momentum is scheduled to end and then reports it.
        var sawMomentumEnd = false
        for tick in 1...60 {
            guard let frame = SmoothScrollRuntime.computeFrame(&state, now: 1.3 + Double(tick) * 0.05) else {
                continue
            }
            if frame.phases.contains(.momentumEnd) {
                sawMomentumEnd = true
                break
            }
        }
        #expect(sawMomentumEnd)
    }

    @Test func frameStopsLinkOnlyAfterManualInputSettles() throws {
        var state = SmoothScrollRuntime.State()
        state.eventTemplate = try makeEvent()
        state.interpolationFactor = 1.0
        state.deadZone = 5.0

        SmoothScrollRuntime.accumulateInput(verticalTarget: 4, horizontalTarget: 0, now: 1, into: &state)

        let first = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1.05))
        #expect(!first.shouldStopLink)

        let second = try #require(SmoothScrollRuntime.computeFrame(&state, now: 1.5))
        #expect(second.shouldStopLink)
    }
}
