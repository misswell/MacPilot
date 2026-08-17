import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

struct SmoothScrollingTests {
    @Test func settingsDecodeWithMosDefaultsAndSafeBounds() throws {
        let data = Data(#"{"minimumStep":999,"speed":0,"duration":99,"deadZone":-10}"#.utf8)
        let settings = try JSONDecoder().decode(SmoothScrollSettings.self, from: data)

        #expect(!settings.isEnabled)
        #expect(settings.minimumStep == 200)
        #expect(settings.speed == 0.1)
        #expect(settings.duration == 5)
        #expect(settings.deadZone == 0)
    }

    @Test func mosDurationCurveUsesIndependentKnownValues() {
        #expect(SmoothScrollSettings.interpolationFactor(forDuration: 0) == 1)
        #expect(SmoothScrollSettings.interpolationFactor(forDuration: 4.35) == 0.085)
        #expect(SmoothScrollSettings.interpolationFactor(forDuration: 5) == 0.019)
    }

    @Test func plannerNormalizesReversesAndAppliesSpeed() {
        var settings = SmoothScrollSettings()
        settings.reverseVertical = true
        settings.minimumStep = 30
        settings.speed = 2
        var vertical = SmoothScrollAxisValue()
        vertical.value = -3

        let plan = SmoothScrollPlanner.plan(vertical: vertical, horizontal: SmoothScrollAxisValue(), settings: settings)

        #expect(plan.verticalTarget == 60)
        #expect(plan.shouldSuppressOriginal)
    }

    @Test func plannerPassesThroughDisabledAxesWhileSmoothingEnabledAxes() {
        var settings = SmoothScrollSettings()
        settings.smoothVertical = true
        settings.smoothHorizontal = false
        settings.minimumStep = 10
        settings.speed = 1
        var vertical = SmoothScrollAxisValue()
        vertical.value = 20
        var horizontal = SmoothScrollAxisValue()
        horizontal.value = 7

        let plan = SmoothScrollPlanner.plan(vertical: vertical, horizontal: horizontal, settings: settings)

        #expect(plan.verticalTarget == -20)
        #expect(plan.horizontalTarget == 0)
        #expect(plan.passThroughHorizontal)
        #expect(!plan.shouldSuppressOriginal)
    }

    @Test func curveFilterRemovesStartupJitterWithKnownFirstFrame() {
        var filter = SmoothScrollFilter()
        let first = filter.fill(vertical: 10, horizontal: 0)
        let second = filter.fill(vertical: 20, horizontal: 0)

        #expect(first.vertical == 0)
        #expect(abs(second.vertical - 2.3) < 1e-9)
    }

    @Test func phaseMachineInterruptsMomentumWithEndAndTrackingBegin() {
        var machine = SmoothScrollPhaseMachine()
        machine.apply(.momentumOngoing)

        let transition = machine.manualInputDetected(isSeparated: true)

        #expect(transition.queue == [.momentumEnd, .trackingBegin])
        #expect(transition.target == nil)
    }

    @Test func phaseMachineEmitsTrackingBeginFromIdle() {
        var machine = SmoothScrollPhaseMachine()

        let transition = machine.manualInputDetected(isSeparated: true)

        #expect(transition.queue == [.trackingBegin])
        #expect(transition.target == nil)
        #expect(machine.phase == .idle)
    }

    @Test func wheelEventParserPrefersPrecisePointDeltas() throws {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 12.75)

        let vertical = SmoothScrollWheelEventParser.axis(.vertical, in: event)
        let horizontal = SmoothScrollWheelEventParser.axis(.horizontal, in: event)

        #expect(vertical.value == 12.75)
        #expect(!horizontal.isValid)
    }

    @Test func smoothScrollingLocalizationIsBilingual() {
        #expect(AppText.value("smoothScrolling", language: .simplifiedChinese) == "平滑滚动")
        #expect(AppText.value("smoothScrolling", language: .english) == "Smooth Scrolling")
        #expect(AppText.value("smoothScrollingEnable", language: .simplifiedChinese) == "启用平滑滚动")
        #expect(AppText.value("smoothScrollingEnable", language: .english) == "Enable smooth scrolling")
    }

    @Test func adaptiveSpeedBoostIncreasesForFasterWheelCadence() {
        let fast = SmoothScrollVelocityBoost.factor(interval: 0.01, enabled: true, maximum: 3)
        let slow = SmoothScrollVelocityBoost.factor(interval: 0.4, enabled: true, maximum: 3)
        let disabled = SmoothScrollVelocityBoost.factor(interval: 0.01, enabled: false, maximum: 3)

        #expect(fast > slow)
        #expect(fast > 2)
        #expect(disabled == 1)
    }

    @Test func adaptiveSpeedSettingsDefaultOffAndClampLimit() throws {
        let defaultSettings = SmoothScrollSettings()
        #expect(!defaultSettings.adaptiveSpeedEnabled)
        #expect(defaultSettings.adaptiveSpeedMaximum == 3)

        let data = Data(#"{"adaptiveSpeedEnabled":true,"adaptiveSpeedMaximum":99}"#.utf8)
        let decoded = try JSONDecoder().decode(SmoothScrollSettings.self, from: data)
        #expect(decoded.adaptiveSpeedEnabled)
        #expect(decoded.adaptiveSpeedMaximum == 8)
    }
}
