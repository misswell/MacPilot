import SwiftUI
import UIKit

/// The touch surface — the whole point of the page, so it takes every pixel
/// the status bar and the controls leave behind.
///
/// A plain UIView under the hood: SwiftUI gestures can't reach the coalesced
/// 120 Hz touch history or track two fingers cleanly, and both matter here.
struct TrackpadView: UIViewRepresentable {
    let model: RemoteTrackpadModel

    func makeUIView(context: Context) -> TrackpadSurfaceView {
        let view = TrackpadSurfaceView()
        view.onTouchEvent = { phase, samples, centroid, touchCount in
            model.handleTouchEvent(
                phase: phase,
                samples: samples,
                centroid: centroid,
                touchCount: touchCount
            )
        }
        return view
    }

    func updateUIView(_ uiView: TrackpadSurfaceView, context: Context) {}
}

/// Tracks active touches so the engine can see the whole picture (how many
/// fingers, where the centroid is) instead of only the changed ones.
@MainActor
final class TrackpadSurfaceView: UIView {
    /// (touch phase, changed samples, centroid of all active touches, active count)
    var onTouchEvent: ((TouchPhase, [TouchSample], CGPoint?, Int) -> Void)?

    private var activeTouches: [ObjectIdentifier: CGPoint] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrackpadSurfaceView is created in code only")
    }

    private var centroid: CGPoint? {
        guard !activeTouches.isEmpty else { return nil }
        var sum = CGPoint.zero
        for position in activeTouches.values {
            sum.x += position.x
            sum.y += position.y
        }
        let count = CGFloat(activeTouches.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            activeTouches[ObjectIdentifier(touch)] = touch.location(in: self)
        }
        onTouchEvent?(.began, TouchProcessor.samples(from: touches, event: event, phase: .began, in: self), centroid, activeTouches.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            activeTouches[ObjectIdentifier(touch)] = touch.location(in: self)
        }
        onTouchEvent?(.moved, TouchProcessor.samples(from: touches, event: event, phase: .moved, in: self), centroid, activeTouches.count)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let samples = TouchProcessor.samples(from: touches, event: event, phase: .ended, in: self)
        for touch in touches {
            activeTouches.removeValue(forKey: ObjectIdentifier(touch))
        }
        onTouchEvent?(.ended, samples, centroid, activeTouches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            activeTouches.removeValue(forKey: ObjectIdentifier(touch))
        }
        onTouchEvent?(.cancelled, [], centroid, activeTouches.count)
    }
}
