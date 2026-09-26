import Foundation

/// Owns only registered feature runtimes. Registration never starts a feature.
@MainActor
final class FeatureLifecycleManager {
    static let shared = FeatureLifecycleManager()

    private var features: [String: ManagedFeature] = [:]
    private let featureDiagnostics = FeatureDiagnostics()

    var activeIdentifiers: [String] {
        features.values.filter(\.isRunning).map(\.identifier).sorted()
    }

    func diagnostics() -> [FeatureDiagnosticInfo] {
        features.values.map(featureDiagnostics.snapshot(for:)).sorted { $0.identifier < $1.identifier }
    }

    func register(_ feature: ManagedFeature) {
        precondition(features[feature.identifier] == nil, "Duplicate feature: \(feature.identifier)")
        features[feature.identifier] = feature
    }

    func unregister(_ identifier: String) {
        stop(identifier)
        features.removeValue(forKey: identifier)
        featureDiagnostics.forget(identifier)
    }

    func start(_ identifier: String) {
        guard let feature = features[identifier], !feature.isRunning else { return }
        feature.start()
        if feature.isRunning { featureDiagnostics.recordStart(identifier) }
    }

    func stop(_ identifier: String) {
        guard let feature = features[identifier] else { return }
        let wasRunning = feature.isRunning
        feature.stop()
        if wasRunning && !feature.isRunning { featureDiagnostics.recordStop(identifier) }
    }

    func stopAll() {
        for identifier in features.keys { stop(identifier) }
    }
}
