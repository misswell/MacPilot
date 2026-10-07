import CoreGraphics
import Foundation

/// A serial commit lane owns Snapzy's stitcher. The main actor only keeps a
/// thumbnail and counters; full-size accepted frames live in the stitcher.
@MainActor
final class ScrollingCaptureSession {
    private(set) var acceptedFrameCount = 1
    private(set) var outputHeight: Int
    private(set) var previewImage: CGImage?
    private(set) var reachedLimit = false
    private(set) var needsSmallerScroll = false
    private(set) var likelyReachedBoundary = false
    private(set) var isFinishing = false
    private(set) var isClosed = false
    var isCapturing: Bool { captureTask != nil }
    var onChange: () -> Void = {}
    var onError: (Error) -> Void = { _ in }
    private var hasCaptureError = false
    private var captureTask: Task<Void, Never>?
    private var pendingSample = false
    private var processor: ScrollingCaptureProcessor?
    private let capture: @MainActor () async throws -> CGImage

    init(initialImage: CGImage, capture: @escaping @MainActor () async throws -> CGImage) {
        outputHeight = initialImage.height
        processor = ScrollingCaptureProcessor(initialImage: ScrollingCaptureImage(value: initialImage))
        self.capture = capture
    }

    func preparePreview() async {
        guard let processor else { return }
        let preview = await processor.preview()
        guard !isClosed else { return }
        previewImage = preview?.value
        onChange()
    }

    func sample() async {
        guard !isFinishing else { return }
        await sampleCurrentFrame()
    }

    private func sampleCurrentFrame() async {
        guard !isClosed, !reachedLimit else { return }
        if let captureTask {
            // Keep one pending refresh, including scrolls during an in-flight
            // capture. The next capture sees the newest viewport.
            pendingSample = true
            await captureTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.captureTask = nil
                if !self.isClosed { self.onChange() }
            }
            repeat {
                self.pendingSample = false
                self.hasCaptureError = false
                do {
                    let image = try await self.capture()
                    guard !self.isClosed, !Task.isCancelled, let processor = self.processor else { return }
                    let result = await processor.append(ScrollingCaptureImage(value: image))
                    guard !self.isClosed, !Task.isCancelled else { return }
                    self.reachedLimit = result.reachedLimit
                    if let update = result.update {
                        self.acceptedFrameCount = update.acceptedFrameCount
                        self.outputHeight = update.outputHeight
                        self.likelyReachedBoundary = update.likelyReachedBoundary
                        if case .ignoredAlignmentFailed = update.outcome {
                            self.needsSmallerScroll = true
                        } else {
                            self.needsSmallerScroll = false
                        }
                    } else if !result.reachedLimit {
                        self.needsSmallerScroll = true
                    }
                    self.previewImage = result.preview?.value ?? self.previewImage
                    self.onChange()
                } catch {
                    guard !self.isClosed, !Task.isCancelled else { return }
                    self.hasCaptureError = true
                    self.onError(error)
                }
            } while self.pendingSample && !self.isClosed && !self.reachedLimit && !Task.isCancelled
        }
        captureTask = task
        onChange()
        await task.value
    }

    func finish() async -> CGImage? {
        guard !isClosed, !isFinishing else { return nil }
        isFinishing = true
        defer {
            isFinishing = false
            if !isClosed { onChange() }
        }
        onChange()
        await captureTask?.value
        try? await Task.sleep(for: .milliseconds(180))
        guard !isClosed, !Task.isCancelled else { return nil }
        await sampleCurrentFrame()
        guard !isClosed, !Task.isCancelled,
              !needsSmallerScroll, !hasCaptureError, let processor else { return nil }
        let output = await processor.output()
        guard !isClosed, !Task.isCancelled else { return nil }
        return output?.value
    }

    func cancel() {
        isClosed = true
        pendingSample = false
        captureTask?.cancel()
        processor = nil
        previewImage = nil
        acceptedFrameCount = 0
    }
}

/// CGImage is immutable; wrappers cross the actor boundary without exposing
/// the mutable, actor-confined stitcher.
struct ScrollingCaptureImage: @unchecked Sendable {
    let value: CGImage
}

private struct ScrollingCaptureProcessedFrame: @unchecked Sendable {
    let update: ScrollingCaptureStitchUpdate?
    let preview: ScrollingCaptureImage?
    let reachedLimit: Bool
}

private actor ScrollingCaptureProcessor {
    private let stitcher = ScrollingCaptureStitcher()
    private var initialImage: ScrollingCaptureImage?
    private var capturedBytes: Int
    private let maximumOutputHeight: Int

    init(initialImage: ScrollingCaptureImage) {
        self.initialImage = initialImage
        capturedBytes = SmartScrollingCaptureBudget.bytes(of: initialImage.value)
        maximumOutputHeight = min(32_768, ScreenCaptureVerticalStitcher.maximumOutputBytes / 4 / max(1, initialImage.value.width))
    }

    private func initialize() {
        if let image = initialImage {
            _ = stitcher.start(with: image.value)
            initialImage = nil
        }
    }

    func append(_ image: ScrollingCaptureImage) -> ScrollingCaptureProcessedFrame {
        autoreleasepool {
            initialize()
            let bytes = SmartScrollingCaptureBudget.bytes(of: image.value)
            guard SmartScrollingCaptureBudget.accepts(
                capturedBytes: capturedBytes, frameCount: stitcher.acceptedFrameCount, adding: bytes
            ) else {
                return ScrollingCaptureProcessedFrame(update: nil, preview: nil, reachedLimit: true)
            }
            let previousCount = stitcher.acceptedFrameCount
            let update = stitcher.append(image.value, maxOutputHeight: maximumOutputHeight, renderMergedImage: false)
            if stitcher.acceptedFrameCount > previousCount { capturedBytes += bytes }
            let reachedLimit: Bool
            if case .reachedHeightLimit = update?.outcome { reachedLimit = true } else { reachedLimit = false }
            return ScrollingCaptureProcessedFrame(update: update, preview: makePreview(), reachedLimit: reachedLimit)
        }
    }

    func preview() -> ScrollingCaptureImage? {
        autoreleasepool { initialize(); return makePreview() }
    }

    private func makePreview() -> ScrollingCaptureImage? {
        stitcher.previewImage(maxPixelWidth: 440, maxPixelHeight: 840).map { ScrollingCaptureImage(value: $0) }
    }

    func output() -> ScrollingCaptureImage? {
        autoreleasepool { initialize(); return stitcher.mergedImage().map { ScrollingCaptureImage(value: $0) } }
    }
}
