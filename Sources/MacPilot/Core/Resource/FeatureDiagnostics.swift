import Foundation

/// Features with owned resources expose their live handles to diagnostics.
/// A missing report is shown as unavailable rather than being mistaken for 0.
@MainActor
protocol FeatureResourceReporting {
    var diagnosticTaskCount: Int { get }
    var diagnosticObserverCount: Int { get }
}

struct FeatureDiagnosticInfo: Equatable {
    let identifier: String
    let startedAt: Date?
    let stoppedAt: Date?
    let isRunning: Bool
    let taskCount: Int?
    let observerCount: Int?
    /// Process footprint at each lifecycle transition, not a claim of memory
    /// exclusively owned by this feature.
    let footprintAtStart: UInt64?
    let footprintAtStop: UInt64?
    var footprintDelta: Int64? {
        guard let footprintAtStart, let footprintAtStop else { return nil }
        return Int64(clamping: footprintAtStop) - Int64(clamping: footprintAtStart)
    }
}

@MainActor
final class FeatureDiagnostics {
    private struct Transition {
        var startedAt: Date?
        var stoppedAt: Date?
        var footprintAtStart: UInt64?
        var footprintAtStop: UInt64?
    }

    private var transitions: [String: Transition] = [:]

    func recordStart(_ identifier: String) {
        var transition = transitions[identifier] ?? Transition()
        transition.startedAt = Date()
        transition.footprintAtStart = ProcessMemorySampler.ownFootprint()
        transitions[identifier] = transition
    }

    func recordStop(_ identifier: String) {
        var transition = transitions[identifier] ?? Transition()
        transition.stoppedAt = Date()
        transition.footprintAtStop = ProcessMemorySampler.ownFootprint()
        transitions[identifier] = transition
    }

    func forget(_ identifier: String) {
        transitions.removeValue(forKey: identifier)
    }

    func snapshot(for feature: ManagedFeature) -> FeatureDiagnosticInfo {
        let transition = transitions[feature.identifier]
        let resources = feature as? FeatureResourceReporting
        return FeatureDiagnosticInfo(
            identifier: feature.identifier,
            startedAt: transition?.startedAt,
            stoppedAt: transition?.stoppedAt,
            isRunning: feature.isRunning,
            taskCount: resources?.diagnosticTaskCount,
            observerCount: resources?.diagnosticObserverCount,
            footprintAtStart: transition?.footprintAtStart,
            footprintAtStop: transition?.footprintAtStop
        )
    }
}
