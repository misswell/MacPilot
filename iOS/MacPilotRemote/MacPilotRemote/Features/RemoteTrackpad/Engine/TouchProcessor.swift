import UIKit

/// Converts UIKit touch callbacks into ordered samples.
///
/// On ProMotion devices iOS coalesces touch delivery down to the display
/// refresh; `UIEvent.coalescedTouches(for:)` recovers the full 120 Hz history,
/// which is exactly the resolution the velocity estimate needs.
enum TouchProcessor {
    /// Samples for the touches that changed in this callback, ordered by time.
    /// Move callbacks include the coalesced history; began/ended are single
    /// points by nature.
    @MainActor
    static func samples(
        from touches: Set<UITouch>,
        event: UIEvent?,
        phase: TouchPhase,
        in view: UIView
    ) -> [TouchSample] {
        var result: [TouchSample] = []
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let history: [UITouch]
            switch phase {
            case .moved:
                if let event, let coalesced = event.coalescedTouches(for: touch), !coalesced.isEmpty {
                    history = coalesced
                } else {
                    history = [touch]
                }
            case .began, .ended, .cancelled:
                history = [touch]
            }
            for sample in history {
                result.append(
                    TouchSample(
                        position: sample.location(in: view),
                        time: sample.timestamp
                    )
                )
            }
        }
        return result
    }
}
