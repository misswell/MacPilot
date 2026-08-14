//
//  SnapzySingleFrameCapture.swift
//  Ported from Snapzy/Services/Capture/SingleFrameStreamCaptureSession.swift.
//  Upstream: https://github.com/duongductrong/Snapzy
//  Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License.
//  See THIRD_PARTY_NOTICES.md for the complete license text.
//
//  The capture pipeline keeps the stream, output and delegate alive until a
//  complete frame arrives. Every completion path is funnelled through one
//  lock-guarded finish method so the continuation resumes exactly once.
//

import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Snapzy's macOS 13-compatible single-frame ScreenCaptureKit session.
///
/// The public app only reaches this path on systems where the async
/// `SCScreenshotManager.captureImage(contentFilter:configuration:)` API is not
/// available. Keeping this bridge nonisolated is important: ScreenCaptureKit
/// delivers callbacks on its own queue, not on the main actor.
final class SnapzySingleFrameCaptureSession: NSObject, @unchecked Sendable {
    nonisolated static let defaultTimeout: TimeInterval = 5
    // Reuse Snapzy's thread-safe shared renderer, but disable Core Image's
    // intermediate cache so a fallback capture cannot permanently raise the
    // app's steady-state memory after the frame has been delivered.
    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    private static func failureMessage(_ key: String) -> ScreenCaptureError {
        .captureFailed(AppText.value(key, language: .system))
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var continuation: CheckedContinuation<CGImage, Error>?
    private nonisolated(unsafe) var stream: SCStream?
    private nonisolated(unsafe) var timeoutTask: Task<Void, Never>?
    private nonisolated(unsafe) var finished = false
    private nonisolated(unsafe) var cancellationRequested = false

    @MainActor
    static func capture(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> CGImage {
        let session = SnapzySingleFrameCaptureSession()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                session.begin(
                    contentFilter: contentFilter,
                    configuration: configuration,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        }, onCancel: {
            session.cancel()
        })
    }

    @MainActor
    private func begin(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        timeout: TimeInterval,
        continuation: CheckedContinuation<CGImage, Error>
    ) {
        guard arm(continuation: continuation, timeout: timeout) else { return }

        let stream = SCStream(filter: contentFilter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.misswell.macpilot.snapzy-single-frame")
            )
        } catch {
            finish(.failure(error))
            return
        }

        // Register the fully configured stream only after the synchronous
        // setup succeeds. Cancellation can finish the session at any point;
        // this check prevents a stream created after cancellation from being
        // started without a corresponding stopCapture call.
        guard attach(stream) else {
            Task { try? await stream.stopCapture() }
            return
        }

        Task { [weak self] in
            guard let self, self.canStartCapture else { return }
            do {
                try await stream.startCapture()
            } catch {
                self.finish(.failure(error))
                return
            }

            // Cancellation may race with startCapture(). The finish path can
            // only stop a stream that has already started, so verify again
            // after the await and stop a stream that became stale meanwhile.
            if !self.canStartCapture {
                try? await stream.stopCapture()
            }
        }
    }

    nonisolated private func attach(_ stream: SCStream) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        self.stream = stream
        lock.unlock()
        return true
    }

    nonisolated private var canStartCapture: Bool {
        lock.lock()
        let canStart = !finished
        lock.unlock()
        return canStart
    }

    /// Installs the continuation and arms the timeout.
    ///
    /// This remains an internal, lock-guarded state-machine entry point so the
    /// regression tests can exercise the Snapzy lifecycle without requesting
    /// Screen Recording permission from the test process.
    @discardableResult
    nonisolated func arm(
        continuation: CheckedContinuation<CGImage, Error>,
        timeout: TimeInterval
    ) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: Self.failureMessage("scCaptureAlreadyFinished"))
            return false
        }
        self.continuation = continuation
        let wasCancelled = cancellationRequested
        lock.unlock()

        // A task may be cancelled before the continuation closure runs. Keep
        // that cancellation visible to the state machine instead of leaving
        // the caller suspended forever.
        if wasCancelled {
            finish(.failure(Self.failureMessage("scCaptureCancelled")))
            return false
        }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(Self.failureMessage("scCaptureTimedOut")))
        }
        lock.lock()
        if finished {
            lock.unlock()
            timeoutTask.cancel()
        } else {
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
        return true
    }

    /// Terminates a pending capture when the calling task is cancelled.
    nonisolated func cancel() {
        lock.lock()
        cancellationRequested = true
        let shouldFinish = continuation != nil && !finished
        lock.unlock()
        guard shouldFinish else { return }
        finish(.failure(Self.failureMessage("scCaptureCancelled")))
    }

    /// Completes the capture exactly once and tears down the stream.
    nonisolated func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        timeoutTask?.cancel()
        switch result {
        case .success(let image):
            continuation?.resume(returning: image)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }
    }
}

extension SnapzySingleFrameCaptureSession: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, let imageBuffer = sampleBuffer.imageBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
        guard let image = Self.sharedCIContext.createCGImage(ciImage, from: rect) else {
            finish(.failure(Self.failureMessage("scCaptureInvalidFrame")))
            return
        }
        finish(.success(image))
    }
}

extension SnapzySingleFrameCaptureSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }
}
