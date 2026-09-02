//
//  QuickRecorderRecordingEngine.swift
//  MacPilot
//
//  Recording engine adapted from QuickRecorder
//  (https://github.com/lihaoyun6/QuickRecorder), Copyright (C) 2024 lihaoyun6,
//  licensed under the GNU Affero General Public License v3.0.
//
//  The following parts are derived from QuickRecorder and reworked for
//  MacPilot's settings model, state machine, and Swift 6 concurrency rules:
//    * Stream filter construction for window captures and the "hide our own
//      windows" behaviour (RecordEngine.prepRecord / SCContext.getSelfWindows).
//    * Video writer setup including the H.264/HEVC codec choice, the
//      resolution-aware target bitrate formula, and the BT.709 color
//      properties (RecordEngine.initVideo).
//    * Microphone capture through an AVAudioEngine input tap with optional
//      echo cancellation, the CMSampleBuffer conversion for PCM buffers, and
//      the active input device sample-rate discovery
//      (RecordEngine.startMicRecording, SCContext.getSampleRate).
//    * The audio writer settings including the reduced bitrate for low-rate
//      devices (SCContext.updateAudioSettings).
//    * Idle-display-sleep prevention while recording
//      (Supports/SleepPreventer.swift).
//
//  Pause handling keeps MacPilot's accumulated-pause presentation timestamp
//  retiming; the combined work is distributed under AGPL-3.0 (see
//  THIRD_PARTY_NOTICES.md).
//

import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import IOKit.pwr_mgt
import OSLog
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// Prevents the display from idling to sleep while a recording is running.
/// Ported from QuickRecorder's `Supports/SleepPreventer.swift`.
final class QuickRecorderSleepPreventer: @unchecked Sendable {
    static let shared = QuickRecorderSleepPreventer()

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0

    func preventSleep(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        let type = "PreventUserIdleDisplaySleep" as CFString
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result != kIOReturnSuccess {
            Self.logger.error("Failed to prevent display sleep: \(result, privacy: .public)")
        }
    }

    func allowSleep() {
        lock.lock()
        defer { lock.unlock() }
        guard assertionID != 0 else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess { assertionID = 0 }
    }

    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "QuickRecorderSleepPreventer")
}

/// A lightweight window description used by the pure window-matching logic so
/// the resolution rules stay unit-testable without ScreenCaptureKit objects.
struct QuickRecorderWindowCandidate: Equatable, Sendable {
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool
    var bundleID: String?
}

/// Video codec selection for the QuickRecorder-derived recording engine.
/// QuickRecorder encodes with H.264 or HEVC and derives the target bitrate
/// from the output resolution and frame rate.
enum ScreenRecordingVideoEncoder: String, CaseIterable, Codable, Identifiable, Sendable {
    case h264
    case hevc

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .h264: return "scRecordingEncoderH264"
        case .hevc: return "scRecordingEncoderHEVC"
        }
    }
}

enum QuickRecorderRecordingEngineSupport {
    /// QuickRecorder's target bitrate formula (RecordEngine.initVideo) with
    /// MacPilot's existing 24 Mbps safety clamp. QuickRecorder floors the
    /// resolution at 600 pt per axis, scales the frame rate by 1/8, and halves
    /// the multiplier for HEVC.
    static func targetBitrate(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        encoder: ScreenRecordingVideoEncoder
    ) -> Int {
        let fps = max(1, framesPerSecond)
        let resolution = Double(max(600, width)) * Double(max(600, height))
        let fpsMultiplier = Double(fps) / 8
        let encoderMultiplier: Double = encoder == .hevc ? 0.5 : 0.9
        let bitrate = resolution * fpsMultiplier * encoderMultiplier
        return max(200_000, min(24_000_000, Int(bitrate)))
    }

    /// QuickRecorder's video writer settings (RecordEngine.initVideo): the
    /// selected codec with its automatic profile level, the derived bitrate,
    /// and BT.709 color properties for SDR content.
    static func videoWriterSettings(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        encoder: ScreenRecordingVideoEncoder
    ) -> [String: Any] {
        let codec: AVVideoCodecType = encoder == .hevc ? .hevc : .h264
        let profileLevel: String = encoder == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel as String
            : AVVideoProfileLevelH264HighAutoLevel
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate(
                    width: width,
                    height: height,
                    framesPerSecond: framesPerSecond,
                    encoder: encoder
                ),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoProfileLevelKey: profileLevel
            ],
            AVVideoColorPropertiesKey: [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }

    /// QuickRecorder's audio writer settings (SCContext.updateAudioSettings):
    /// AAC at the requested rate, with the bitrate halved (and capped at
    /// 64 kbps) for input devices running below 44.1 kHz.
    static func audioWriterSettings(
        sampleRate: Int,
        channels: Int,
        bitRate: Int = 128_000
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        var effectiveBitRate = bitRate
        if sampleRate < 44_100 { effectiveBitRate = min(64_000, effectiveBitRate / 2) }
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        settings[AVEncoderBitRateKey] = effectiveBitRate
        return settings
    }

    /// QuickRecorder's window-matching rule: prefer the on-screen, layer-0
    /// window with the largest overlap on the captured rectangle while never
    /// matching our own windows. Returns nil when no window covers at least
    /// half of the selection.
    static func bestWindowCandidate(
        candidates: [QuickRecorderWindowCandidate],
        captureRect: CGRect,
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.misswell.macpilot"
    ) -> QuickRecorderWindowCandidate? {
        guard !captureRect.isNull, captureRect.width > 0.5, captureRect.height > 0.5 else { return nil }
        let selectionArea = captureRect.width * captureRect.height
        var bestCandidate: QuickRecorderWindowCandidate?
        var bestOverlap: CGFloat = 0
        for candidate in candidates
        where candidate.layer == 0 && candidate.isOnScreen && candidate.bundleID != ownBundleID {
            let intersection = candidate.frame.intersection(captureRect)
            guard !intersection.isNull else { continue }
            let overlap = intersection.width * intersection.height
            guard overlap / selectionArea >= 0.5 else { continue }
            if bestCandidate == nil || overlap > bestOverlap {
                bestCandidate = candidate
                bestOverlap = overlap
            }
        }
        return bestCandidate
    }

    /// The nominal sample rate of the default input device, falling back to
    /// the active format of the process audio input. Ported from
    /// QuickRecorder's `SCContext.getDefaultSampleRate`.
    static func defaultInputSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != 0 else { return nil }

        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout.size(ofValue: sampleRate))
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        let rateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        guard rateStatus == noErr, sampleRate > 0 else { return nil }
        return Int(sampleRate)
    }

    static func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

/// The QuickRecorder-derived recording engine. Owns the ScreenCaptureKit
/// stream, the AVAssetWriter, and the optional microphone tap. The callbacks
/// arrive on private queues and are guarded by one lock so the main-actor
/// model can stop the stream without racing the final samples.
final class QuickRecorderRecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "QuickRecorderRecordingEngine")

    private struct CapturePlan {
        let filter: SCContentFilter
        /// Display-local point rect for area-style crops on display filters.
        let sourceRect: CGRect?
        /// The point size that maps onto the output pixel dimensions.
        let captureSize: CGSize
    }

    private let stream: SCStream
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let settings: ScreenRecordingSettings
    private let audioEngine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "com.misswell.macpilot.quick-recorder.samples", qos: .userInitiated)
    private let lock = NSLock()

    private var microphoneInput: AVAssetWriterInput?
    private var didStartSession = false
    private var didReceiveVideoFrame = false
    private var streamError: Error?
    private var isStopped = false
    private var isPaused = false
    private var accumulatedPause = CMTime.zero
    private var pauseStartedAt: Date?

    private init(
        stream: SCStream,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput?,
        outputURL: URL,
        settings: ScreenRecordingSettings
    ) {
        self.stream = stream
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.outputURL = outputURL
        self.settings = settings
    }

    /// Prepares the stream and the writer. The microphone permission must
    /// already be granted when `settings.capturesMicrophone` is set; the
    /// model handles that request before calling into the engine.
    static func prepare(
        settings: ScreenRecordingSettings,
        captureRect: CGRect?
    ) async throws -> QuickRecorderRecordingEngine {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenRecordingError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = activeDisplay(from: content.displays, captureRect: captureRect) else {
            throw ScreenRecordingError.noDisplayFound
        }

        let outputURL = try makeOutputURL(for: settings)
        let plan = buildCapturePlan(
            content: content,
            display: display,
            mode: settings.captureMode,
            captureRect: captureRect
        )

        let pixelScale = max(1, Double(display.width) / max(1, display.frame.width))
        let width = QuickRecorderRecordingEngineSupport.evenDimension(
            Int((plan.captureSize.width * pixelScale).rounded())
        )
        let height = QuickRecorderRecordingEngineSupport.evenDimension(
            Int((plan.captureSize.height * pixelScale).rounded())
        )

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format.fileType)
        } catch {
            throw ScreenRecordingError.writerCreationFailed
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: QuickRecorderRecordingEngineSupport.videoWriterSettings(
                width: width,
                height: height,
                framesPerSecond: settings.framesPerSecond,
                encoder: settings.encoder
            )
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ScreenRecordingError.writerCreationFailed }
        writer.add(videoInput)

        var systemAudioInput: AVAssetWriterInput?
        if settings.capturesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: QuickRecorderRecordingEngineSupport.audioWriterSettings(
                    sampleRate: 48_000,
                    channels: 2
                )
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
            }
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        configuration.queueDepth = settings.framesPerSecond >= 60 ? 8 : 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = settings.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if let sourceRect = plan.sourceRect {
            configuration.sourceRect = sourceRect
        }
        if settings.capturesSystemAudio {
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }

        let stream = SCStream(filter: plan.filter, configuration: configuration, delegate: nil)
        let engine = QuickRecorderRecordingEngine(
            stream: stream,
            writer: writer,
            videoInput: videoInput,
            systemAudioInput: systemAudioInput,
            outputURL: outputURL,
            settings: settings
        )
        try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.sampleQueue)
        if systemAudioInput != nil {
            try stream.addStreamOutput(engine, type: .audio, sampleHandlerQueue: engine.sampleQueue)
        }
        return engine
    }

    /// Builds the stream filter for the requested mode. Window captures use
    /// QuickRecorder's desktop-independent window filter so the recording
    /// follows the selected window; every mode hides MacPilot's own windows.
    private static func buildCapturePlan(
        content: SCShareableContent,
        display: SCDisplay,
        mode: ScreenRecordingCaptureMode,
        captureRect: CGRect?
    ) -> CapturePlan {
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        func displayCropPlan(_ quartzRect: CGRect?) -> CapturePlan {
            let localRect = quartzRect
                .map { $0.intersection(display.frame) }
                .flatMap { $0.isNull || $0.isEmpty ? nil : $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
            let size = localRect?.size ?? display.frame.size
            return CapturePlan(
                filter: SCContentFilter(display: display, excludingWindows: ownWindows),
                sourceRect: localRect,
                captureSize: size
            )
        }

        switch mode {
        case .area:
            return displayCropPlan(captureRect)
        case .fullscreen:
            return CapturePlan(
                filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: ownWindows),
                sourceRect: nil,
                captureSize: display.frame.size
            )
        case .application:
            guard let captureRect else { return displayCropPlan(nil) }
            let candidates = content.windows.map { window -> QuickRecorderWindowCandidate in
                QuickRecorderWindowCandidate(
                    frame: window.frame,
                    layer: window.windowLayer,
                    isOnScreen: window.isOnScreen,
                    bundleID: window.owningApplication?.bundleIdentifier
                )
            }
            guard let match = QuickRecorderRecordingEngineSupport.bestWindowCandidate(
                candidates: candidates,
                captureRect: captureRect
            ) else {
                return displayCropPlan(captureRect)
            }
            let matchedFrame = match.frame
            let matchedBundleID = match.bundleID
            let window = content.windows.first { window in
                guard window.owningApplication?.bundleIdentifier == matchedBundleID else { return false }
                let frame = window.frame
                return abs(frame.minX - matchedFrame.minX) < 1
                    && abs(frame.minY - matchedFrame.minY) < 1
                    && abs(frame.width - matchedFrame.width) < 1
                    && abs(frame.height - matchedFrame.height) < 1
            }
            guard let window else {
                return displayCropPlan(captureRect)
            }
            return CapturePlan(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil,
                captureSize: window.frame.size
            )
        }
    }

    func start() async throws {
        if settings.capturesMicrophone {
            installMicrophone()
        }
        try await stream.startCapture()
        QuickRecorderSleepPreventer.shared.preventSleep(reason: "MacPilot screen recording in progress")
    }

    /// Installs the QuickRecorder-style microphone tap: optional echo
    /// cancellation through voice processing, then an input-node tap whose PCM
    /// buffers are converted into sample buffers for a dedicated audio track.
    /// A failing microphone never aborts the video recording; it is logged and
    /// the track is dropped.
    private func installMicrophone() {
        let input = audioEngine.inputNode
        if settings.microphoneEchoCancellation {
            try? input.setVoiceProcessingEnabled(true)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate >= 8_000, format.channelCount > 0 else {
            Self.logger.error("Microphone capture skipped: unusable input format")
            return
        }
        let sampleRate = Int(format.sampleRate)
        let channels = Int(format.channelCount)
        let microphoneInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: QuickRecorderRecordingEngineSupport.audioWriterSettings(
                sampleRate: sampleRate,
                channels: channels
            )
        )
        microphoneInput.expectsMediaDataInRealTime = true
        lock.lock()
        defer { lock.unlock() }
        guard writer.canAdd(microphoneInput) else {
            Self.logger.error("Microphone track could not be added to the writer")
            return
        }
        writer.add(microphoneInput)
        self.microphoneInput = microphoneInput

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let sample = buffer.qrSampleBuffer else { return }
            self.appendMicrophoneSample(sample)
        }
        do {
            try audioEngine.start()
        } catch {
            Self.logger.error("Microphone engine failed to start: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            microphoneInput.markAsFinished()
            self.microphoneInput = nil
        }
    }

    private func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, !isPaused, didStartSession, let microphoneInput else { return }
        let retimed = retimedSampleBuffer(sampleBuffer, subtracting: accumulatedPause) ?? sampleBuffer
        if microphoneInput.isReadyForMoreMediaData, !microphoneInput.append(retimed) {
            Self.logger.debug("Microphone sample was rejected while recording")
        }
    }

    private func stopMicrophone() {
        lock.lock()
        let hasMicrophone = microphoneInput != nil
        microphoneInput?.markAsFinished()
        microphoneInput = nil
        lock.unlock()
        guard hasMicrophone else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, !isPaused else { return }
        isPaused = true
        pauseStartedAt = Date()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, isPaused else { return }
        if let pauseStartedAt {
            accumulatedPause = accumulatedPause + CMTime(
                seconds: max(0, Date().timeIntervalSince(pauseStartedAt)),
                preferredTimescale: 600
            )
        }
        self.pauseStartedAt = nil
        isPaused = false
    }

    func stop() async throws -> URL {
        guard markStoppedIfNeeded() else { return outputURL }
        stopMicrophone()
        try? await stream.stopCapture()
        QuickRecorderSleepPreventer.shared.allowSleep()
        return try await finishWriting()
    }

    func cancel() async {
        let shouldStop = markStoppedIfNeeded()
        if shouldStop {
            stopMicrophone()
            try? await stream.stopCapture()
        }
        QuickRecorderSleepPreventer.shared.allowSleep()
        try? FileManager.default.removeItem(at: outputURL)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, !isPaused else { return }
        let sampleBuffer = retimedSampleBuffer(sampleBuffer, subtracting: accumulatedPause) ?? sampleBuffer

        switch type {
        case .screen:
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid, !timestamp.isIndefinite else { return }
            if !didStartSession {
                guard writer.startWriting() else {
                    streamError = writer.error ?? ScreenRecordingError.writerCreationFailed
                    return
                }
                writer.startSession(atSourceTime: timestamp)
                didStartSession = true
            }
            didReceiveVideoFrame = true
            if videoInput.isReadyForMoreMediaData, !videoInput.append(sampleBuffer) {
                streamError = writer.error ?? ScreenRecordingError.streamFailed("video writer rejected a frame")
            }
        case .audio:
            guard didStartSession, let systemAudioInput, systemAudioInput.isReadyForMoreMediaData else { return }
            if !systemAudioInput.append(sampleBuffer) {
                Self.logger.debug("System audio sample was rejected while recording")
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        streamError = error
    }

    private func finishWriting() async throws -> URL {
        try prepareWriterForFinishing()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: ScreenRecordingError.streamFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return outputURL
    }

    private func markStoppedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return false }
        isStopped = true
        return true
    }

    private func prepareWriterForFinishing() throws {
        lock.lock()
        defer { lock.unlock() }
        if let streamError {
            throw ScreenRecordingError.streamFailed(streamError.localizedDescription)
        }
        guard didReceiveVideoFrame else {
            throw ScreenRecordingError.noVideoFrames
        }
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
    }

    private func retimedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        subtracting offset: CMTime
    ) -> CMSampleBuffer? {
        guard offset.isValid, CMTimeCompare(offset, .zero) != 0 else { return sampleBuffer }
        var entryCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else {
            return sampleBuffer
        }
        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: entryCount
        )
        let readStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: entryCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: &entryCount
            )
        }
        guard readStatus == noErr else { return sampleBuffer }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid,
               !timing[index].presentationTimeStamp.isIndefinite {
                timing[index].presentationTimeStamp = CMTimeSubtract(
                    timing[index].presentationTimeStamp,
                    offset
                )
            }
            if timing[index].decodeTimeStamp.isValid,
               !timing[index].decodeTimeStamp.isIndefinite {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp,
                    offset
                )
            }
        }
        var retimed: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timing.count,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &retimed
            )
        }
        return status == noErr ? retimed : sampleBuffer
    }

    private static func activeDisplay(from displays: [SCDisplay], captureRect: CGRect?) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        if let captureRect {
            return displays.max {
                let lhs = $0.frame.intersection(captureRect)
                let rhs = $1.frame.intersection(captureRect)
                return max(0, lhs.width) * max(0, lhs.height) < max(0, rhs.width) * max(0, rhs.height)
            }
        }
        let pointer = NSEvent.mouseLocation
        return displays.first(where: { $0.frame.contains(pointer) }) ?? displays.first
    }

    private static func makeOutputURL(for settings: ScreenRecordingSettings) throws -> URL {
        let folder = ScreenRecordingOutput.folder(for: settings)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "MacPilot-" + timestamp
        var outputURL = folder.appendingPathComponent("\(baseName).\(settings.format.fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = folder.appendingPathComponent("\(baseName)-\(suffix).\(settings.format.fileExtension)")
            suffix += 1
        }
        return outputURL
    }
}

/// Converts a PCM buffer into a sample buffer so the AVAudioEngine
/// microphone tap can feed a dedicated AVAssetWriterInput audio track.
/// Ported from QuickRecorder's RecordEngine.swift
/// (based on https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c).
extension AVAudioPCMBuffer {
    var qrSampleBuffer: CMSampleBuffer? {
        let asbd = format.streamDescription
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?

        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
