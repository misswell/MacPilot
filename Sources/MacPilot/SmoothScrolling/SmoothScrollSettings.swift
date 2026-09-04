import Foundation

/// Configuration for smooth mouse-wheel scrolling.
///
/// The numeric defaults are `step = 33.6`, `speed = 2.7`, and UI duration =
/// `4.35`. Values loaded from an old or hand-edited configuration are clamped
/// before they can reach the input tap.
struct SmoothScrollSettings: Codable, Equatable, Sendable {
    static let stepRange: ClosedRange<Double> = 1...200
    static let speedRange: ClosedRange<Double> = 0.1...10
    static let durationRange: ClosedRange<Double> = 0...5
    static let deadZoneRange: ClosedRange<Double> = 0...10
    static let adaptiveSpeedRange: ClosedRange<Double> = 1...8

    var isEnabled = false
    /// Enables the global wheel-direction reversal independently of smoothing.
    /// Keeping this separate preserves the expected no-op behavior for a new
    /// installation while allowing reversal to remain active when smoothing is
    /// turned off.
    var reverseScrollingEnabled = false
    var smoothVertical = true
    var smoothHorizontal = true
    var reverseVertical = true
    var reverseHorizontal = true
    var minimumStep = 33.6
    var speed = 2.7
    var duration = 4.35
    var deadZone = 1.0
    var simulatesTrackpadPhases = false
    var adaptiveSpeedEnabled = false
    var adaptiveSpeedMaximum = 3.0
    var blockSmoothWhileCommandHeld = true
    var excludedApplicationBundleIdentifiers: [String] = []
    /// Excluded applications whose original wheel direction should be reversed.
    /// This is intentionally independent from the global smooth-scroll reversal.
    var excludedApplicationReverseBundleIdentifiers: [String] = []

    var shouldReverseVertical: Bool {
        reverseScrollingEnabled && reverseVertical
    }

    var shouldReverseHorizontal: Bool {
        reverseScrollingEnabled && reverseHorizontal
    }

    /// The event tap is needed for either smooth scrolling or an independent
    /// reversal setting. Excluded-app reversal also works while smoothing is
    /// disabled, so it keeps the tap alive on its own.
    var requiresInputTap: Bool {
        isEnabled || shouldReverseVertical || shouldReverseHorizontal ||
            !excludedApplicationReverseBundleIdentifiers.isEmpty
    }

    var interpolationFactor: Double {
        Self.interpolationFactor(forDuration: duration)
    }

    static func interpolationFactor(forDuration duration: Double) -> Double {
        // Duration-to-frame-factor curve. A larger UI duration produces a
        // smaller factor and therefore a longer glide.
        let upperLimit = 5.2
        let value = 1 - (duration / upperLimit).squareRoot()
        return (value * 1_000).rounded() / 1_000
    }

    func clamped() -> SmoothScrollSettings {
        var value = self
        value.minimumStep = minimumStep.clamped(to: Self.stepRange)
        value.speed = speed.clamped(to: Self.speedRange)
        value.duration = duration.clamped(to: Self.durationRange)
        value.deadZone = deadZone.clamped(to: Self.deadZoneRange)
        value.adaptiveSpeedMaximum = adaptiveSpeedMaximum.clamped(to: Self.adaptiveSpeedRange)
        value.excludedApplicationBundleIdentifiers = SmoothScrollApplicationExclusions.normalizedIdentifiers(
            excludedApplicationBundleIdentifiers
        )
        let excludedIdentifiers = Set(
            value.excludedApplicationBundleIdentifiers.map(SmoothScrollApplicationExclusions.canonicalIdentifier)
        )
        value.excludedApplicationReverseBundleIdentifiers = SmoothScrollApplicationExclusions.normalizedIdentifiers(
            excludedApplicationReverseBundleIdentifiers.filter {
                excludedIdentifiers.contains(SmoothScrollApplicationExclusions.canonicalIdentifier($0))
            }
        )
        return value
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Before reversal was independent, its effective lifetime followed
        // `isEnabled`. Migrate old files that have no new switch without
        // unexpectedly reversing scrolling for users who had smoothing off.
        if container.contains(.reverseScrollingEnabled) {
            reverseScrollingEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .reverseScrollingEnabled
            ) ?? false
        } else {
            reverseScrollingEnabled = isEnabled
        }
        smoothVertical = try container.decodeIfPresent(Bool.self, forKey: .smoothVertical) ?? true
        smoothHorizontal = try container.decodeIfPresent(Bool.self, forKey: .smoothHorizontal) ?? true
        reverseVertical = try container.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? true
        reverseHorizontal = try container.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? true
        minimumStep = try container.decodeIfPresent(Double.self, forKey: .minimumStep) ?? 33.6
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 2.7
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 4.35
        deadZone = try container.decodeIfPresent(Double.self, forKey: .deadZone) ?? 1.0
        simulatesTrackpadPhases = try container.decodeIfPresent(Bool.self, forKey: .simulatesTrackpadPhases) ?? false
        adaptiveSpeedEnabled = try container.decodeIfPresent(Bool.self, forKey: .adaptiveSpeedEnabled) ?? false
        adaptiveSpeedMaximum = try container.decodeIfPresent(Double.self, forKey: .adaptiveSpeedMaximum) ?? 3.0
        blockSmoothWhileCommandHeld = try container.decodeIfPresent(Bool.self, forKey: .blockSmoothWhileCommandHeld) ?? true
        excludedApplicationBundleIdentifiers = SmoothScrollApplicationExclusions.normalizedIdentifiers(
            try container.decodeIfPresent([String].self, forKey: .excludedApplicationBundleIdentifiers) ?? []
        )
        excludedApplicationReverseBundleIdentifiers = SmoothScrollApplicationExclusions.normalizedIdentifiers(
            try container.decodeIfPresent([String].self, forKey: .excludedApplicationReverseBundleIdentifiers) ?? []
        )
        self = clamped()
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

enum SmoothScrollApplicationExclusions {
    static func canonicalIdentifier(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(canonicalIdentifier(trimmed)).inserted else { return nil }
            return trimmed
        }
    }

    static func contains(_ bundleIdentifier: String?, in excludedIdentifiers: Set<String>) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedIdentifiers.contains(canonicalIdentifier(bundleIdentifier))
    }
}
