import AppKit
import MacPilotDockGroupsCore

/// Resolves process icons outside SwiftUI body evaluation. A monitor owns one
/// store and releases its pending work and decoded images when it stops.
@MainActor
final class ProcessIconStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    private var queuedPaths: [String] = []
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()

    var count: Int { images.count }

    func image(for path: String) -> NSImage? { images[path] }

    func request(paths: [String]) {
        let wanted = Set(paths.prefix(100))
        if !Set(images.keys).isSubset(of: wanted) {
            images = images.filter { wanted.contains($0.key) }
        }
        queuedPaths = paths.prefix(100).filter { images[$0] == nil }
        guard loadTask == nil else { return }
        let currentGeneration = generation
        loadTask = Task { [weak self] in
            while let self, self.generation == currentGeneration,
                  !Task.isCancelled, !self.queuedPaths.isEmpty {
                let path = self.queuedPaths.removeFirst()
                let worker = Task.detached(priority: .utility) {
                    DockGroupIconThumbnail.pngData(
                        forFileAt: URL(fileURLWithPath: path), pointSize: 26
                    )
                }
                let data = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard self.generation == currentGeneration, !Task.isCancelled else { return }
                if let data, let image = NSImage(data: data) {
                    self.images[path] = image
                }
            }
            if let self, self.generation == currentGeneration { self.loadTask = nil }
        }
    }

    func clear() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        queuedPaths.removeAll()
        images.removeAll()
    }
}
