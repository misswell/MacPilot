import Foundation

/// Registers the runtime owners after configuration has been loaded. Creating
/// a model does not start its background work; only the lifecycle manager does.
@MainActor
final class FeatureRegistry {
    static let shared = FeatureRegistry()

    private init() {}

    func registerAll(model: MacPilotModel, in manager: FeatureLifecycleManager) {
        manager.register(model.exitFeature)
        manager.register(model.launchFeature)
        manager.register(model.clipboard)
        manager.register(model.awake)
        manager.register(model.cpuMonitor)
        manager.register(model.memoryMonitor)
        manager.register(model.ble)
        manager.register(model.remoteControl)
        manager.register(model.fileCompression)
        manager.register(model.screenCapture)
        manager.register(model.screenRecordingFeature)
        manager.register(model.pictureInPicture)
        manager.register(model.inputSources)
        manager.register(model.windowSwitcher)
        manager.register(model.smoothScrolling)
        manager.register(model.dockGroups)
        manager.register(model.localPorts)
        manager.register(model.rightClickFeature)
    }
}
