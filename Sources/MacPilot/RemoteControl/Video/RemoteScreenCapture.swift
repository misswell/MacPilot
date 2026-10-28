import CoreGraphics
import CoreMedia
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import OSLog
@preconcurrency import ScreenCaptureKit

/// Stream callbacks, compression and quality state all live on a dedicated
/// queue. One frame may be encoding; the network has its own single send slot.
final class RemoteScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.misswell.macpilot.video.capture", qos: .utility)
    private let encoder = RemoteVideoEncoder()
    private let transport: RemoteVideoTransport
    private var stream: SCStream?
    private var quality: RemoteVideoQuality = .balanced
    private var forceKeyFrame = true
    private var encoding = false
    private var encodingReservation: RemoteVideoTransport.SendReservation?
    private var stopped = false
    private var generation = 0
    private var width = 0
    private var height = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sent = 0
    private var dropped = 0
    private var bytes = 0
    private var encodeTotal = 0.0
    private var encodedCount = 0
    private var totalDropped = 0
    private var lastReport = ProcessInfo.processInfo.systemUptime
    private var lastQualityChange = ProcessInfo.processInfo.systemUptime
    private var slowSends = 0
    private var goodSends = 0
    private var pendingDiagnostics: Data?
    var onFailure: (@Sendable () -> Void)?
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "RemoteVideo")

    init(transport: RemoteVideoTransport) { self.transport = transport }

    func start(display: SCDisplay) async throws {
        sourceWidth = display.width; sourceHeight = display.height
        resize()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
        self.stream = stream
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.stopped else { continuation.resume(throwing: RemoteVideoFailure.capture); return }
                do { try self.encoder.configure(width: self.width, height: self.height, quality: self.quality); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let shouldStop = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stopped) }
        }
        if shouldStop {
            try? await stream.stopCapture()
            throw RemoteVideoFailure.capture
        }
    }

    private func resize() {
        let scale = min(Double(quality.width) / Double(sourceWidth), Double(quality.height) / Double(sourceHeight), 1)
        width = max(2, Int(Double(sourceWidth) * scale) / 2 * 2)
        height = max(2, Int(Double(sourceHeight) * scale) / 2 * 2)
    }

    private func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.capturesAudio = false
        return configuration
    }

    func feedback(_ feedback: RemoteVideoFeedback) {
        queue.async {
            if feedback.needsKeyFrame { self.forceKeyFrame = true }
            if feedback.congested { self.slowSends += 5; self.goodSends = 0 }
        }
    }

    func sentIn(milliseconds: Double) {
        queue.async {
            if let payload = self.pendingDiagnostics,
               self.transport.send(RemoteVideoPacket(frameType: .diagnostics, payload: payload)) {
                self.pendingDiagnostics = nil
            }
            if milliseconds > 70 { self.slowSends += 1; self.goodSends = 0 }
            else { self.goodSends += 1 }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixel = sample.imageBuffer else { return }
        // During a capture configuration change ignore old-sized surfaces.
        guard CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height else { return }
        guard !encoding else { dropped += 1; return }
        guard let reservation = transport.reserveSend() else { dropped += 1; return }
        encoding = true
        encodingReservation = reservation
        let epoch = generation
        let force = forceKeyFrame
        forceKeyFrame = false
        encoder.encode(pixel, time: sample.presentationTimeStamp, forceKeyFrame: force) { [weak self] packet, milliseconds in
            guard let self else { reservation.cancel(); return }
            self.queue.async {
                guard epoch == self.generation, !self.stopped,
                      self.encodingReservation === reservation else { reservation.cancel(); return }
                self.encoding = false
                self.encodingReservation = nil
                self.encodeTotal += milliseconds
                self.encodedCount += 1
                if let packet, self.transport.send(packet, using: reservation) {
                    self.sent += 1; self.bytes += packet.payload.count
                } else { reservation.cancel(); self.dropped += 1; self.forceKeyFrame = true }
                self.reportAndAdapt()
            }
        }
    }

    private func reportAndAdapt() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastReport
        if elapsed >= 2 {
            logger.info("fps=\(Double(self.sent) / elapsed, privacy: .public) encodeMs=\(self.encodeTotal / Double(max(1, self.encodedCount)), privacy: .public) kbps=\(Double(self.bytes) * 8 / elapsed / 1000, privacy: .public) dropped=\(self.dropped, privacy: .public)")
            totalDropped += dropped
            pendingDiagnostics = try? JSONEncoder().encode(RemoteVideoDiagnostics(encodeMs: encodeTotal / Double(max(1, encodedCount)), droppedFrames: totalDropped))
            lastReport = now; sent = 0; dropped = 0; bytes = 0; encodeTotal = 0; encodedCount = 0
        }
        guard now - lastQualityChange >= 8 else { return }
        let next: RemoteVideoQuality?
        if slowSends >= 5 { next = RemoteVideoQuality(rawValue: max(0, quality.rawValue - 1)) }
        else if goodSends >= quality.fps * 8 { next = RemoteVideoQuality(rawValue: min(2, quality.rawValue + 1)) }
        else { next = nil }
        slowSends = 0; goodSends = 0
        guard let next, next != quality else { return }
        quality = next; lastQualityChange = now
        generation += 1; encoding = false; forceKeyFrame = true
        encodingReservation?.cancel(); encodingReservation = nil
        resize()
        do { try encoder.configure(width: width, height: height, quality: quality) }
        catch { onFailure?(); return }
        if let stream {
            let configuration = configuration()
            Task { [weak self] in
                do { try await stream.updateConfiguration(configuration) }
                catch { self?.onFailure?() }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?() }

    func stop() {
        queue.async {
            self.stopped = true; self.generation += 1
            self.encodingReservation?.cancel(); self.encodingReservation = nil; self.encoding = false
            self.encoder.stop()
            if let stream = self.stream {
                self.stream = nil
                Task { try? await stream.stopCapture() }
            }
        }
    }
}
