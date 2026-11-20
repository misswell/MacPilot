import AppKit
import Foundation
import Testing
@testable import MacPilot

struct ImageViewerScrollGestureTests {
    @Test func defaultModeZoomsWithTheWheelAndNavigatesWithOption() {
        #expect(ImageViewerSettings().scrollBehavior == .optionScrollNavigates)

        var gesture = ImageViewerScrollGesture()
        expectZoom(
            gesture.action(
                deltaY: 10, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 1, navigates: false
            ),
            CGFloat(exp(Double(0.25)))
        )
        #expect(
            gesture.action(
                deltaY: -3, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 2, navigates: true
            ) == .navigate(1)
        )
    }

    @Test func selectingWheelNavigationMakesTheWheelChangeImages() {
        var gesture = ImageViewerScrollGesture()
        #expect(
            gesture.action(
                deltaY: 3, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 1, navigates: true
            ) == .navigate(-1)
        )
        expectZoom(
            gesture.action(
                deltaY: -10, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 2, navigates: false
            ),
            CGFloat(exp(Double(-0.25)))
        )
    }

    @Test func oneTrackpadGestureChangesOnlyOneImageAndIgnoresMomentum() {
        var gesture = ImageViewerScrollGesture()
        #expect(
            gesture.action(
                deltaY: -20, isPrecise: true, phase: .began, momentumPhase: [],
                timestamp: 10, navigates: true
            ) == .navigate(1)
        )
        #expect(
            gesture.action(
                deltaY: -40, isPrecise: true, phase: .changed, momentumPhase: [],
                timestamp: 10.05, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: -80, isPrecise: true, phase: [], momentumPhase: .changed,
                timestamp: 10.1, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: 0, isPrecise: true, phase: .ended, momentumPhase: [],
                timestamp: 10.2, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: -20, isPrecise: true, phase: .began, momentumPhase: [],
                timestamp: 11, navigates: true
            ) == .navigate(1)
        )
    }

    @Test func aShortTrackpadGestureDoesNotChangeTheImage() {
        var gesture = ImageViewerScrollGesture()
        #expect(
            gesture.action(
                deltaY: -5, isPrecise: true, phase: .began, momentumPhase: [],
                timestamp: 1, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: -5, isPrecise: true, phase: .changed, momentumPhase: [],
                timestamp: 1.05, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: -6, isPrecise: true, phase: .changed, momentumPhase: [],
                timestamp: 1.1, navigates: true
            ) == .navigate(1)
        )
    }

    @Test func wheelNotchesRespectTheCooldown() {
        var gesture = ImageViewerScrollGesture()
        #expect(
            gesture.action(
                deltaY: -3, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 20, navigates: true
            ) == .navigate(1)
        )
        #expect(
            gesture.action(
                deltaY: -3, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 20.05, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: -3, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 20.11, navigates: true
            ) == .navigate(1)
        )
    }

    @Test func changingOptionMidGestureStartsANewGesture() {
        var gesture = ImageViewerScrollGesture()
        #expect(
            gesture.action(
                deltaY: -10, isPrecise: true, phase: .began, momentumPhase: [],
                timestamp: 1, navigates: true
            ) == .ignored
        )
        expectZoom(
            gesture.action(
                deltaY: 5, isPrecise: true, phase: .changed, momentumPhase: [],
                timestamp: 1.05, navigates: false
            ),
            CGFloat(exp(Double(0.125)))
        )
        #expect(
            gesture.action(
                deltaY: -20, isPrecise: true, phase: .changed, momentumPhase: [],
                timestamp: 1.1, navigates: true
            ) == .navigate(1)
        )
    }

    @Test func zoomKeepsTheExistingCurveAndClampAndProcessesMomentum() {
        var gesture = ImageViewerScrollGesture()
        expectZoom(
            gesture.action(
                deltaY: 1_000, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 1, navigates: false
            ),
            CGFloat(exp(Double(1)))
        )
        expectZoom(
            gesture.action(
                deltaY: -1_000, isPrecise: false, phase: [], momentumPhase: [],
                timestamp: 2, navigates: false
            ),
            CGFloat(exp(Double(-1)))
        )
        expectZoom(
            gesture.action(
                deltaY: 10, isPrecise: true, phase: [], momentumPhase: .changed,
                timestamp: 3, navigates: false
            ),
            CGFloat(exp(Double(0.25)))
        )
        #expect(
            gesture.action(
                deltaY: 0, isPrecise: true, phase: .ended, momentumPhase: [],
                timestamp: 4, navigates: false
            ) == .ignored
        )
    }

    @Test func aCancelledGestureDoesNotChangeTheImage() {
        var gesture = ImageViewerScrollGesture()
        #expect(
            gesture.action(
                deltaY: -100, isPrecise: true, phase: .cancelled, momentumPhase: [],
                timestamp: 1, navigates: true
            ) == .ignored
        )
        #expect(
            gesture.action(
                deltaY: -20, isPrecise: true, phase: .began, momentumPhase: [],
                timestamp: 2, navigates: true
            ) == .navigate(1)
        )
    }

    private func expectZoom(
        _ action: ImageViewerScrollAction,
        _ expected: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .zoom(let factor) = action else {
            Issue.record("Expected a zoom action, got \(action)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(factor - expected) < 0.0001, sourceLocation: sourceLocation)
    }
}
