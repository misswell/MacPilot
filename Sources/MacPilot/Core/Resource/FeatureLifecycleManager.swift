import Foundation

/// Owns only registered feature runtimes. Registration never starts a feature.
@MainActor
final class FeatureLifecycleManager {
    static let shared = FeatureLifecycleManager()

    private var features: [String: ManagedFeature] = [:]

    var activeIdentifiers: [String] {
        features.values.filter(\.isRunning).map(\.identifier).sorted()
    }

    func register(_ feature: ManagedFeature) {
        precondition(features[feature.identifier] == nil, "Duplicate feature: \(feature.identifier)")
        features[feature.identifier] = feature
    }

    func unregister(_ identifier: String) {
        features.removeValue(forKey: identifier)?.stop()
    }

    func start(_ identifier: String) {
        guard let feature = features[identifier], !feature.isRunning else { return }
        feature.start()
    }

    func stop(_ identifier: String) {
        features[identifier]?.stop()
    }

    func stopAll() {
        for feature in features.values {
            feature.stop()
        }
    }
}
