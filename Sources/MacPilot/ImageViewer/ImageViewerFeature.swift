import Combine

@MainActor
final class ImageViewerFeature: ObservableObject, ManagedFeature, FeatureResourceReporting, FeatureCacheReporting {
    let identifier = "imageViewer"
    var language: AppLanguage = .system {
        didSet { runtime?.language = language }
    }
    @Published private(set) var runtime: ImageViewerRuntime?
    private var changes: AnyCancellable?
    var isRunning: Bool { runtime != nil }
    var diagnosticTaskCount: Int { runtime?.taskCount ?? 0 }
    var diagnosticObserverCount: Int { runtime?.session?.observerCount ?? 0 }
    var diagnosticCacheBytes: Int { runtime?.session?.cacheBytes ?? 0 }

    func start() {
        guard runtime == nil else { return }
        let newRuntime = ImageViewerRuntime(language: language)
        changes = newRuntime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        runtime = newRuntime
    }

    func stop() {
        guard let runtime else { return }
        changes = nil
        runtime.close()
        self.runtime = nil
    }
}
