import CoreGraphics
import Foundation

/// Owns long-shot sampling independently of the HUD. Cancelling invalidates
/// every suspended operation, including ScreenCaptureKit calls that cannot
/// themselves be cancelled immediately.
@MainActor
final class ScrollingCaptureSession {
    private(set) var frames: [CGImage]
    private(set) var reachedLimit = false
    private(set) var needsSmallerScroll = false
    private(set) var isFinishing = false
    private(set) var isClosed = false
    var isCapturing: Bool { captureTask != nil }
    var onChange: () -> Void = {}
    var onError: (Error) -> Void = { _ in }
    private var hasCaptureError = false
    private var capturedBytes: Int
    private var captureTask: Task<Void, Never>?
    private let capture: @MainActor () async throws -> CGImage

    init(initialImage: CGImage, capture: @escaping @MainActor () async throws -> CGImage) {
        frames = [initialImage]
        capturedBytes = SmartScrollingCaptureBudget.bytes(of: initialImage)
        self.capture = capture
    }

    func sample() async {
        guard !isFinishing else { return }
        await sampleCurrentFrame()
    }

    private func sampleCurrentFrame() async {
        guard !isClosed, !reachedLimit else { return }
        if let captureTask {
            await captureTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.captureTask = nil
                if !self.isClosed { self.onChange() }
            }
            self.hasCaptureError = false
            do {
                let image = try await self.capture()
                guard !self.isClosed, !Task.isCancelled, let previous = self.frames.last else { return }
                let pair = [ScrollingCaptureImage(value: previous), ScrollingCaptureImage(value: image)]
                let overlap = await Task.detached(priority: .userInitiated) {
                    autoreleasepool {
                        ScreenCaptureVerticalStitcher.bestOverlap(previous: pair[0].value, current: pair[1].value)
                    }
                }.value
                guard !self.isClosed, !Task.isCancelled else { return }
                self.needsSmallerScroll = overlap == 0
                // An unchanged page (including the end of the document) must
                // neither grow the output nor consume the frame budget.
                if overlap > 0, overlap < image.height {
                    let bytes = SmartScrollingCaptureBudget.bytes(of: image)
                    if SmartScrollingCaptureBudget.accepts(
                        capturedBytes: self.capturedBytes, frameCount: self.frames.count, adding: bytes
                    ) {
                        self.frames.append(image)
                        self.capturedBytes += bytes
                    } else {
                        self.reachedLimit = true
                    }
                }
            } catch {
                guard !self.isClosed, !Task.isCancelled else { return }
                self.hasCaptureError = true
                self.onError(error)
            }
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
        // Drain the in-flight sample, then capture the actual final viewport.
        // A pending debounce must not discard the last scroll on Done.
        await captureTask?.value
        try? await Task.sleep(for: .milliseconds(180))
        guard !isClosed, !Task.isCancelled else { return nil }
        await sampleCurrentFrame()
        guard !isClosed, !Task.isCancelled else { return nil }
        guard !needsSmallerScroll, !hasCaptureError else { return nil }
        let images = frames.map { ScrollingCaptureImage(value: $0) }
        let output = await Task.detached(priority: .userInitiated) {
            autoreleasepool { ScreenCaptureVerticalStitcher.stitch(images.map(\.value)) }
        }.value
        guard !isClosed, !Task.isCancelled else { return nil }
        return output
    }

    func cancel() {
        isClosed = true
        captureTask?.cancel()
        frames.removeAll()
        capturedBytes = 0
    }
}

/// Immutable image references read by one worker while the main actor owns
/// the frame list. CGImage exposes no mutation through this wrapper.
private struct ScrollingCaptureImage: @unchecked Sendable {
    let value: CGImage
}
