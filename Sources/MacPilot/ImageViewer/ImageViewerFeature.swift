import Combine
import Foundation

@MainActor
final class ImageViewerFeature: ObservableObject, ManagedFeature, FeatureResourceReporting, FeatureCacheReporting {
    let identifier = "imageViewer"
    var language: AppLanguage = .system {
        didSet { runtime?.language = language }
    }
    @Published private(set) var settings = ImageViewerSettings()
    @Published private(set) var runtime: ImageViewerRuntime?
    var persist: (() -> Void)?
    private var changes: AnyCancellable?
    private let makeRuntime: (AppLanguage) -> ImageViewerRuntime
    private var keepsRuntimeWhenIdle = false
    var isRunning: Bool { runtime != nil }
    var diagnosticTaskCount: Int { runtime?.taskCount ?? 0 }
    var diagnosticObserverCount: Int { runtime?.session?.observerCount ?? 0 }
    var diagnosticCacheBytes: Int { runtime?.session?.cacheBytes ?? 0 }

    init(makeRuntime: @escaping (AppLanguage) -> ImageViewerRuntime = { ImageViewerRuntime(language: $0) }) {
        self.makeRuntime = makeRuntime
    }

    func start() {
        keepRuntimeWhenIdle()
        ensureRuntime()
    }

    func keepRuntimeWhenIdle() {
        keepsRuntimeWhenIdle = true
    }

    func applyLoadedSettings(_ settings: ImageViewerSettings) {
        self.settings = settings
        runtime?.settings = settings
    }

    func setScrollBehavior(_ behavior: ImageViewerScrollBehavior) {
        guard settings.scrollBehavior != behavior else { return }
        var updated = settings
        updated.scrollBehavior = behavior
        settings = updated
        runtime?.settings = updated
        persist?()
    }

    func openDocuments(_ urls: [URL]) {
        let documents = ImageViewerFileRouter.documents(in: urls)
        guard !documents.isEmpty else { return }
        ensureRuntime()
        runtime?.open(documents)
    }

    private func ensureRuntime() {
        guard runtime == nil else { return }
        let newRuntime = makeRuntime(language)
        newRuntime.settings = settings
        newRuntime.onIdle = { [weak self, weak newRuntime] in
            guard let self, let newRuntime, self.runtime === newRuntime, !self.keepsRuntimeWhenIdle else { return }
            self.stop()
        }
        changes = newRuntime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        runtime = newRuntime
    }

    func stop() {
        keepsRuntimeWhenIdle = false
        guard let runtime else { return }
        changes = nil
        runtime.onIdle = nil
        runtime.close()
        self.runtime = nil
    }
}
