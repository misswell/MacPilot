import Foundation

private final class ImageViewerJob: Operation, @unchecked Sendable {
    private let work: @Sendable (ImageViewerJob) -> Void

    init(_ work: @escaping @Sendable (ImageViewerJob) -> Void) { self.work = work }

    override func main() {
        guard !isCancelled else { return }
        autoreleasepool { work(self) }
    }
}

private struct ImageViewerCacheKey: Hashable, Sendable {
    let stamp: ImageViewerFileStamp
    let page: Int
    let pixels: Int
}

private final class ImageViewerSessionCaches: @unchecked Sendable {
    let lock = NSLock()
    var revision = 0
    var navigation = ImageViewerCache<ImageViewerCacheKey, ImageViewerFrame>(limit: 16 << 20, countLimit: 64)
    var rendered = ImageViewerCache<ImageViewerCacheKey, ImageViewerFrame>(limit: 64 << 20, countLimit: 64)
    var metadata = ImageViewerCache<ImageViewerCacheKey, ImageViewerInformation>(limit: 256, countLimit: 256)

    func clear() {
        lock.withLock {
            revision += 1
            navigation.clear()
            rendered.clear()
            metadata.clear()
        }
    }
}

@MainActor
final class ImageViewerSession {
    private struct FolderEntry {
        var job: UUID?
        var result: Result<ImageViewerFolderIndex, Error>?
        var subscribers: [UUID: (Result<ImageViewerFolderIndex, Error>) -> Void] = [:]
    }

    private let renders = ImageViewerSession.queue("render", lanes: 2)
    private lazy var metadata = Self.queue("information", lanes: 1)
    private lazy var printing = Self.queue("print", lanes: 1)
    private lazy var indexes = Self.queue("folder", lanes: 1)
    private let caches = ImageViewerSessionCaches()
    private let sketch = ImageViewerSketchPreview()
    private var pressure: (any DispatchSourceMemoryPressure)?
    private var jobs: [UUID: ImageViewerJob] = [:]
    private var folders: [URL: FolderEntry] = [:]
    private var prefetchJob: UUID?
    private var allowsPrefetch = true
    private(set) var isClosed = false

    var taskCount: Int { jobs.count }
    var observerCount: Int { pressure == nil ? 0 : 1 }
    var folderCount: Int { folders.count }
    var cacheBytes: Int { caches.lock.withLock { caches.navigation.cost + caches.rendered.cost } + sketch.cost }

    init(observePressure: Bool = true) {
        if observePressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.handlePressure() }
            }
            source.resume()
            pressure = source
        }
    }

    private static func queue(_ name: String, lanes: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "MacPilot.ImageViewer.\(name)"
        queue.maxConcurrentOperationCount = lanes
        queue.qualityOfService = .userInitiated
        return queue
    }

    private func submit<Output: Sendable>(
        on queue: OperationQueue, lowPriority: Bool = false,
        work: @escaping @Sendable (ImageViewerJob) throws -> Output,
        done: @escaping @MainActor (Result<Output, Error>) -> Void
    ) -> UUID? {
        guard !isClosed else { return nil }
        let id = UUID()
        let job = ImageViewerJob { [weak self] operation in
            let result = Result { try work(operation) }
            guard !operation.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.jobs.removeValue(forKey: id) != nil, !self.isClosed else { return }
                done(result)
            }
        }
        if lowPriority { job.queuePriority = .low; job.qualityOfService = .utility }
        jobs[id] = job
        queue.addOperation(job)
        return id
    }

    func cancel(_ id: UUID?) {
        guard let id else { return }
        jobs.removeValue(forKey: id)?.cancel()
    }

    func render(_ request: ImageViewerRenderRequest, forPrint: Bool = false, preview: Bool = false,
                done: @escaping @MainActor (Result<ImageViewerFrame, Error>) -> Void) -> UUID? {
        guard !isClosed else { return nil }
        let revision = caches.lock.withLock { caches.revision }
        return submit(on: forPrint ? printing : renders, lowPriority: preview, work: { [caches, sketch] job in
            let cacheable = !forPrint && request.frame == 0 && request.url.pathExtension.lowercased() != "pdf"
            let key = cacheable ? ImageViewerFileStamp(request.url).map {
                ImageViewerCacheKey(stamp: $0, page: request.page, pixels: request.pixels)
            } : nil
            if let key, let hit = caches.lock.withLock({
                preview ? caches.navigation.value(for: key)
                    : caches.rendered.value(for: key) ?? caches.navigation.value(for: key)
            }) { return hit }
            let frame = try ImageViewerPipeline.render(request, sketch: sketch, cancelled: { job.isCancelled })
            if let key, frame.frameCount == 1 {
                caches.lock.withLock {
                    guard revision == caches.revision, !job.isCancelled else { return }
                    if preview {
                        caches.navigation.insert(frame, for: key, cost: frame.byteCost)
                    } else {
                        caches.rendered.insert(frame, for: key, cost: frame.byteCost)
                    }
                }
            }
            return frame
        }, done: done)
    }

    func prefetch(_ url: URL, pixels: Int) {
        guard Self.canPrefetch(url), allowsPrefetch, prefetchJob == nil else { return }
        prefetchJob = render(ImageViewerRenderRequest(url: url, pixels: min(2048, pixels)), preview: true) { [weak self] _ in
            self?.prefetchJob = nil
        }
    }

    static func canPrefetch(_ url: URL) -> Bool {
        !["pdf", "gif", "webp"].contains(url.pathExtension.lowercased())
    }

    func information(_ request: ImageViewerRenderRequest,
                     done: @escaping @MainActor (Result<ImageViewerInformation, Error>) -> Void) -> UUID? {
        guard !isClosed else { return nil }
        let revision = caches.lock.withLock { caches.revision }
        return submit(on: metadata, work: { [caches, sketch] job in
            let key = ImageViewerFileStamp(request.url).map {
                ImageViewerCacheKey(stamp: $0, page: request.page, pixels: 0)
            }
            if let key, let hit = caches.lock.withLock({ caches.metadata.value(for: key) }) { return hit }
            let info = try ImageViewerInformation.read(request, sketch: sketch, cancelled: { job.isCancelled })
            if let key {
                caches.lock.withLock {
                    guard revision == caches.revision, !job.isCancelled else { return }
                    caches.metadata.insert(info, for: key, cost: 1)
                }
            }
            return info
        }, done: done)
    }

    func subscribe(to folder: URL, id: UUID,
                   done: @escaping (Result<ImageViewerFolderIndex, Error>) -> Void) {
        guard !isClosed else { return }
        var entry = folders[folder] ?? FolderEntry()
        entry.subscribers[id] = done
        if let result = entry.result {
            folders[folder] = entry
            done(result)
            return
        }
        if entry.job == nil {
            entry.job = submit(on: indexes, work: { job in
                try ImageViewerFolderIndex.scan(folder, cancelled: { job.isCancelled })
            }, done: { [weak self] result in self?.finishFolder(folder, result: result) })
        }
        folders[folder] = entry
    }

    private func finishFolder(_ folder: URL, result: Result<ImageViewerFolderIndex, Error>) {
        guard var entry = folders[folder] else { return }
        entry.job = nil
        entry.result = result
        folders[folder] = entry
        for (id, done) in entry.subscribers where folders[folder]?.subscribers[id] != nil { done(result) }
    }

    func unsubscribe(from folder: URL, id: UUID) {
        guard var entry = folders[folder] else { return }
        entry.subscribers.removeValue(forKey: id)
        if entry.subscribers.isEmpty {
            cancel(entry.job)
            folders.removeValue(forKey: folder)
        } else {
            folders[folder] = entry
        }
    }

    func handlePressure() {
        allowsPrefetch = false
        cancel(prefetchJob)
        prefetchJob = nil
        caches.clear()
        sketch.clear()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        folders.removeAll()
        prefetchJob = nil
        pressure?.cancel()
        pressure = nil
        caches.clear()
        sketch.clear(closing: true)
    }
}
