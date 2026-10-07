// Region-scoped stream adapted from Snapzy commit 224afa560f54d868376b84d0761539f289c08ffb.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause; see THIRD_PARTY_NOTICES.md.
import AppKit
import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit

struct ScrollingCaptureLiveFrame: @unchecked Sendable {
    let image: CGImage
    let capturedAt: TimeInterval
}

@MainActor
final class ScrollingCaptureFrameSource: NSObject {
    private final class Renderer: @unchecked Sendable {
        let context = CIContext(options: [.cacheIntermediates: false])
    }
    private let sampleQueue = DispatchQueue(label: "com.misswell.macpilot.scrolling-capture", qos: .userInitiated)
    private nonisolated let renderer = Renderer()
    private nonisolated(unsafe) var lastPublishedAt: TimeInterval = 0
    private var stream: SCStream?
    private var onFrame: ((ScrollingCaptureLiveFrame) -> Void)?
    private var onFailure: (() -> Void)?

    func start(rect: CGRect, pixelSize: CGSize, onFrame: @escaping (ScrollingCaptureLiveFrame) -> Void, onFailure: @escaping () -> Void) async throws {
        guard let (filter, configuration) = try await SnapzyScreenCaptureManager.shared.prepareScrollingCapture(rect: rect, pixelSize: pixelSize) else { return }
        try Task.checkCancellation()
        self.onFrame = onFrame
        self.onFailure = onFailure
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
            if self.stream !== stream || Task.isCancelled {
                try? await stream.stopCapture()
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let activeStream = stream
        stream = nil
        onFrame = nil
        onFailure = nil
        guard let activeStream else { return }
        try? activeStream.removeStreamOutput(self, type: .screen)
        Task { try? await activeStream.stopCapture() }
    }
}

extension ScrollingCaptureFrameSource: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            guard let statusRaw = attachments?.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete,
                  let displayTime = attachments?.first?[.displayTime] as? UInt64, displayTime > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPublishedAt >= 1.0 / 15 else { return }
            let capturedAt = CMClockMakeHostTimeFromSystemUnits(displayTime).seconds
            guard capturedAt.isFinite, capturedAt > 0 else { return }
            let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            guard let image = renderer.context.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: rect) else { return }
            lastPublishedAt = now
            let frame = ScrollingCaptureLiveFrame(image: image, capturedAt: capturedAt)
            let streamID = ObjectIdentifier(stream)
            Task { @MainActor [weak self] in
                guard let self, self.stream.map({ ObjectIdentifier($0) }) == streamID else { return }
                self.onFrame?(frame)
            }
        }
    }
}

extension ScrollingCaptureFrameSource: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map({ ObjectIdentifier($0) }) == streamID else { return }
            let failure = self.onFailure
            self.stop()
            failure?()
        }
    }
}
