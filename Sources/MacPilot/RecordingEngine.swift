//
//  RecordingEngine.swift
//  MacPilot
//
//  Screen recording engine built on Apple's public frameworks
//  (ScreenCaptureKit, AVFoundation, VideoToolbox, IOKit). It extends the
//  original display-crop recorder with window-scoped capture that follows the
//  recorded window, an optional microphone track, H.264/HEVC encoder
//  selection, and display-sleep suppression for the duration of a recording.
//
//  This is an independent implementation: no third-party code is incorporated.
//

import AVFoundation
import CoreMedia
import CoreVideo
import IOKit.pwr_mgt
import OSLog
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// Keeps the display awake while a recording is running by holding an IOKit
/// power assertion, releasing it when the recording ends.
final class DisplaySleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    func acquire(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isHeld else { return }
        var assertionID = IOPMAssertionID()
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            Self.logger.error("Could not keep the display awake: \(result, privacy: .public)")
            return
        }
        self.assertionID = assertionID
        isHeld = true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard isHeld else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            assertionID = 0
            isHeld = false
        }
    }

    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "DisplaySleepAssertion")
}

/// Video codec selection for the recording engine.
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

/// A plain-data description of a capturable window, kept separate from
/// ScreenCaptureKit types so the selection rules can be unit-tested.
struct ScreenRecordingWindowProbe: Equatable, Sendable {
    var frame: CGRect
    var windowLayer: Int
    var isOnScreen: Bool
    var bundleID: String?
}

/// The ScreenCaptureKit + AVAssetWriter recording session behind
/// `ScreenRecordingModel`. Callbacks arrive on a private serial queue and are
/// guarded by one lock so the main-actor model can stop the stream without
/// racing the final video/audio samples.
final class ScreenRecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingEngine")

    /// Where the stream content comes from and how large the output should be.
    private struct CapturePlan {
        let filter: SCContentFilter
        /// Display-local point rectangle when the recording crops a region of
        /// the display; nil when the filter frames the content itself.
        let sourceRect: CGRect?
        /// Point size that maps onto the output pixel dimensions.
        let outputSize: CGSize
    }

    private let stream: SCStream
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let settings: ScreenRecordingSettings
    private let audioEngine = AVAudioEngine()
    private let sleepAssertion = DisplaySleepAssertion()
    private let sampleQueue = DispatchQueue(label: "com.misswell.macpilot.screen-recording.samples", qos: .userInitiated)
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

    // MARK: - Encoder math

    /// Bitrate budget for the writer. The original MacPilot recorder budgeted
    /// width×height×fps/6 bits per second for H.264; HEVC reaches comparable
    /// quality at roughly 60% of that, and the result is clamped to a range
    /// that stays playable on both ends.
    static func targetBitrate(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        encoder: ScreenRecordingVideoEncoder
    ) -> Int {
        let fps = max(1, framesPerSecond)
        let base = Double(width) * Double(height) * Double(fps) / 6
        let scaled = encoder == .hevc ? base * 0.6 : base
        return max(2_000_000, min(24_000_000, Int(scaled)))
    }

    /// Writer settings for the selected codec: automatic profile level, the
    /// derived bitrate, a two-second GOP, and BT.709 color for SDR content.
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

    /// AAC settings for a writer audio input. Content captured below 44.1 kHz
    /// carries less information, so those inputs get a reduced bitrate.
    static func audioWriterSettings(sampleRate: Int, channels: Int) -> [String: Any] {
        let bitrate = sampleRate < 44_100 ? 64_000 : 128_000
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ]
    }

    static func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }

    // MARK: - Window selection

    /// Picks the recorded window for application-window mode: the on-screen
    /// layer-0 window with the largest overlap on the selection, excluding
    /// MacPilot's own windows. Windows that cover less than half of the
    /// selection are ignored so a sloppy drag falls back to the crop recorder.
    static func selectWindow(
        probes: [ScreenRecordingWindowProbe],
        selection: CGRect,
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.misswell.macpilot"
    ) -> ScreenRecordingWindowProbe? {
        guard selection.width > 0.5, selection.height > 0.5 else { return nil }
        let selectionArea = selection.width * selection.height
        var winner: ScreenRecordingWindowProbe?
        var winnerOverlap: CGFloat = 0
        for probe in probes
        where probe.windowLayer == 0 && probe.isOnScreen && probe.bundleID != ownBundleID {
            let overlap = probe.frame.intersection(selection)
            guard !overlap.isNull else { continue }
            let overlapArea = overlap.width * overlap.height
            guard overlapArea / selectionArea >= 0.5 else { continue }
            if winner == nil || overlapArea > winnerOverlap {
                winner = probe
                winnerOverlap = overlapArea
            }
        }
        return winner
    }

    // MARK: - Preparation

    /// Prepares the stream and the writer. The microphone permission must
    /// already be granted when `settings.capturesMicrophone` is set; the model
    /// resolves that request before calling into the engine.
    static func prepare(
        settings: ScreenRecordingSettings,
        captureRect: CGRect?
    ) async throws -> ScreenRecordingEngine {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenRecordingError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = activeDisplay(from: content.displays, captureRect: captureRect) else {
            throw ScreenRecordingError.noDisplayFound
        }

        let outputURL = try makeOutputURL(for: settings)
        let plan = makeCapturePlan(content: content, display: display, mode: settings.captureMode, captureRect: captureRect)

        let pixelScale = max(1, Double(display.width) / max(1, display.frame.width))
        let width = evenDimension(Int((plan.outputSize.width * pixelScale).rounded()))
        let height = evenDimension(Int((plan.outputSize.height * pixelScale).rounded()))

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format.fileType)
        } catch {
            throw ScreenRecordingError.writerCreationFailed
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoWriterSettings(
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
                outputSettings: audioWriterSettings(sampleRate: 48_000, channels: 2)
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
        let engine = ScreenRecordingEngine(
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

    /// Decides where the video content comes from for the requested mode:
    /// a display crop, the full display, or the single window under the
    /// selection. MacPilot's own windows are hidden in every mode so the
    /// settings window never appears in a recording.
    private static func makeCapturePlan(
        content: SCShareableContent,
        display: SCDisplay,
        mode: ScreenRecordingCaptureMode,
        captureRect: CGRect?
    ) -> CapturePlan {
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        func croppedDisplayPlan(_ quartzRect: CGRect?) -> CapturePlan {
            let localRect = quartzRect
                .map { $0.intersection(display.frame) }
                .flatMap { $0.isNull || $0.isEmpty ? nil : $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
            return CapturePlan(
                filter: SCContentFilter(display: display, excludingWindows: ownWindows),
                sourceRect: localRect,
                outputSize: localRect?.size ?? display.frame.size
            )
        }

        switch mode {
        case .area:
            return croppedDisplayPlan(captureRect)
        case .fullscreen:
            return CapturePlan(
                filter: SCContentFilter(display: display, excludingWindows: ownWindows),
                sourceRect: nil,
                outputSize: display.frame.size
            )
        case .application:
            guard let captureRect else { return croppedDisplayPlan(nil) }
            let probes = content.windows.map { window in
                ScreenRecordingWindowProbe(
                    frame: window.frame,
                    windowLayer: window.windowLayer,
                    isOnScreen: window.isOnScreen,
                    bundleID: window.owningApplication?.bundleIdentifier
                )
            }
            guard let probe = selectWindow(probes: probes, selection: captureRect),
                  let window = window(in: content, matching: probe) else {
                return croppedDisplayPlan(captureRect)
            }
            // A desktop-independent window stream follows the window if the
            // user moves it mid-recording, and frames exactly the window.
            return CapturePlan(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil,
                outputSize: window.frame.size
            )
        }
    }

    /// Finds the capture window whose identity matches the selected probe
    /// (same owning application and the same frame within a point).
    private static func window(in content: SCShareableContent, matching probe: ScreenRecordingWindowProbe) -> SCWindow? {
        let probeFrame = probe.frame
        let probeBundleID = probe.bundleID
        return content.windows.first { window in
            guard window.owningApplication?.bundleIdentifier == probeBundleID else { return false }
            let frame = window.frame
            return abs(frame.minX - probeFrame.minX) < 1
                && abs(frame.minY - probeFrame.minY) < 1
                && abs(frame.width - probeFrame.width) < 1
                && abs(frame.height - probeFrame.height) < 1
        }
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

    // MARK: - Lifecycle

    func start() async throws {
        if settings.capturesMicrophone {
            startMicrophoneCapture()
        }
        try await stream.startCapture()
        sleepAssertion.acquire(reason: "MacPilot screen recording in progress")
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
        stopMicrophoneCapture()
        try? await stream.stopCapture()
        sleepAssertion.release()
        return try await finishWriting()
    }

    func cancel() async {
        let shouldStop = markStoppedIfNeeded()
        if shouldStop {
            stopMicrophoneCapture()
            try? await stream.stopCapture()
        }
        sleepAssertion.release()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Microphone

    /// Records the microphone on its own track via an AVAudioEngine input tap.
    /// With echo cancellation enabled the input node uses voice processing, so
    /// speakers output is attenuated from the recording. A microphone that
    /// fails to start never aborts the video recording — the track is dropped
    /// and the failure is logged.
    private func startMicrophoneCapture() {
        let input = audioEngine.inputNode
        if settings.microphoneEchoCancellation {
            try? input.setVoiceProcessingEnabled(true)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate >= 8_000, format.channelCount > 0 else {
            Self.logger.error("Microphone capture skipped: unusable input format")
            return
        }
        let micInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioWriterSettings(
                sampleRate: Int(format.sampleRate),
                channels: Int(format.channelCount)
            )
        )
        micInput.expectsMediaDataInRealTime = true

        lock.lock()
        guard writer.canAdd(micInput) else {
            lock.unlock()
            Self.logger.error("Microphone track could not be added to the writer")
            return
        }
        writer.add(micInput)
        microphoneInput = micInput
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let sample = buffer.recordingSampleBuffer else { return }
            self.handleMicrophoneSample(sample)
        }
        do {
            try audioEngine.start()
        } catch {
            Self.logger.error("Microphone engine failed to start: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            lock.lock()
            micInput.markAsFinished()
            microphoneInput = nil
            lock.unlock()
        }
    }

    private func handleMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, !isPaused, didStartSession, let microphoneInput else { return }
        let retimed = retimedSampleBuffer(sampleBuffer, subtracting: accumulatedPause) ?? sampleBuffer
        if microphoneInput.isReadyForMoreMediaData, !microphoneInput.append(retimed) {
            Self.logger.debug("Microphone sample was rejected while recording")
        }
    }

    private func stopMicrophoneCapture() {
        lock.lock()
        let hasMicrophone = microphoneInput != nil
        microphoneInput?.markAsFinished()
        microphoneInput = nil
        lock.unlock()
        guard hasMicrophone else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // MARK: - Sample handling

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

    /// Shifts the buffer's timestamps back by the paused duration so the
    /// written file has no gaps where recording was paused.
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
}

// MARK: - PCM buffer conversion

extension AVAudioPCMBuffer {
    /// Wraps the buffer's audio data in a CMSampleBuffer stamped with the
    /// host clock, so microphone samples can feed a writer audio input.
    var recordingSampleBuffer: CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
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
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
