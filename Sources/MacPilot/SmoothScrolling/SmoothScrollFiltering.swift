import Foundation

/// Linear interpolation used by the display-link frame generator.
enum SmoothScrollInterpolator {
    static func lerp(current: Double, target: Double, factor: Double) -> Double {
        (target - current) * factor
    }
}

/// Two-value curve filter. It removes startup jitter by interpolating the
/// previous frame toward the newly generated one.
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
