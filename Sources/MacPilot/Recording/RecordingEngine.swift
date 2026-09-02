//
//  RecordingEngine.swift
//  MacPilot
//
//  The ScreenCaptureKit + AVAssetWriter session behind `ScreenRecordingModel`.
//  Constructed from the plans in `RecordingCapturePlanning` and
//  `RecordingOutputPlanning`, it runs the stream, feeds the writer inputs
//  (video, system audio, microphone), removes paused stretches from the
//  timeline, honors save-frame requests, gates frames while the system
//  presenter overlay transitions, and hands the finished file through the
//  audio mixer when a mixdown was requested.
//
//  Callbacks arrive on a private serial queue and are guarded by one lock
//  so the main-actor model can stop the stream without racing the final
//  video/audio samples.
//

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreMedia
import CoreVideo
import OSLog
@preconcurrency import ScreenCaptureKit
import VideoToolbox

final class ScreenRecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingEngine")

    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let systemAudioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let settings: ScreenRecordingSettings
    private let audioEngine = AVAudioEngine()
    private let sleepAssertion = DisplaySleepAssertion()
    private let sampleQueue = DispatchQueue(label: "com.misswell.macpilot.screen-recording.samples", qos: .userInitiated)
    private let micSampleQueue = DispatchQueue(label: "com.misswell.macpilot.screen-recording.mic", qos: .userInitiated)
    private let lock = NSLock()

    private var microphoneInput: AVAssetWriterInput?
    private var micCaptureSession: AVCaptureSession?
    private var didStartWritingSession = false
    private var didCaptureVideo = false
    private var didCaptureAudio = false
    private var streamFailure: Error?
    private var isTerminated = false
    private var isPaused = false
    private var pausedDuration = CMTime.zero
    private var pauseStartedAt: Date?

    /// End timestamps of recently delivered frames; a frame whose end time
    /// is already in this window is a duplicate and gets dropped.
    private var recentFrameEndTimes: [CMTime] = []
    private let rollingFrameWindow = 20

    // MARK: Presenter overlay

    private var presenterOverlayActive = false
    private var presenterOverlayReady = false
    private var presenterOverlayState = "OFF"
    private var presenterOverlaySafeDelay: Int { settings.presenterOverlaySafeDelay }

    /// Fired with `true` when the system presenter overlay takes over (the
    /// floating camera window should hide) and `false` when it ends.
    var presenterOverlayActivityHandler: ((Bool) -> Void)?
    var frameSavedHandler: ((URL) -> Void)?
    var encoderFallbackHandler: ((ScreenRecordingVideoEncoder) -> Void)?

    // MARK: Frame saving

    private var frameSaveRequested = false
    private var frameSaveHandler: ((URL?) -> Void)?
    private var posterImageCache: NSImage?

    private init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput?,
        systemAudioInput: AVAssetWriterInput?,
        outputURL: URL,
        settings: ScreenRecordingSettings
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.outputURL = outputURL
        self.settings = settings
    }

    /// Wires the stream after construction because `SCStream` receives its
    /// delegate at initialization time and the engine is that delegate.
    fileprivate func attach(stream: SCStream) {
        self.stream = stream
    }

    private var isAudioOnly: Bool { settings.captureMode == .audio }

    // MARK: - Session construction

    /// Builds the stream and the writer for one recording. The microphone
    /// permission must already be granted when `settings.capturesMicrophone`
    /// is set; the model resolves that request before calling in.
    static func makeSession(
        settings: ScreenRecordingSettings,
        captureRect: CGRect?,
        frontmostWindowOnly: Bool = false
    ) async throws -> ScreenRecordingEngine {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenRecordingError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = activeDisplay(from: content.displays, captureRect: captureRect) else {
            throw ScreenRecordingError.noDisplayFound
        }

        let isAudioOnly = settings.captureMode == .audio
        let blueprint = ScreenRecordingCapturePlanner.blueprint(
            content: content,
            display: display,
            mode: settings.captureMode,
            selection: captureRect,
            frontmostOnly: frontmostWindowOnly,
            settings: settings
        )
        let outputURL = try nextRecordingURL(for: settings)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: outputURL,
                fileType: isAudioOnly ? settings.audioFormat.fileType : settings.effectiveFormat.fileType
            )
        } catch {
            throw ScreenRecordingError.writerCreationFailed
        }

        let pixelScale = max(1, Double(display.width) / max(1, display.frame.width))
        let scale = settings.highRes ? pixelScale : 1
        let outputWidth = ScreenRecordingCodecPlanner.snapToEven(Int((blueprint.renderSize.width * scale).rounded()))
        let outputHeight = ScreenRecordingCodecPlanner.snapToEven(Int((blueprint.renderSize.height * scale).rounded()))

        var videoInput: AVAssetWriterInput?
        if !isAudioOnly {
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: ScreenRecordingCodecPlanner.videoCompressionSettings(
                    width: outputWidth,
                    height: outputHeight,
                    framesPerSecond: settings.framesPerSecond,
                    encoder: settings.effectiveEncoder,
                    alphaEnabled: settings.withAlpha,
                    hdr: settings.recordHDR,
                    quality: settings.videoQuality
                )
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenRecordingError.writerCreationFailed }
            writer.add(input)
            videoInput = input
        }

        let audioFormat: ScreenRecordingAudioFormat = isAudioOnly ? settings.audioFormat : .aac
        var systemAudioInput: AVAssetWriterInput?
        let wantsSystemAudio = isAudioOnly || settings.capturesSystemAudio
        if wantsSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: ScreenRecordingCodecPlanner.audioCompressionSettings(
                    sampleRate: 48_000,
                    channels: 2,
                    format: audioFormat,
                    quality: settings.audioQuality
                )
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
            }
        }

        let configuration = makeStreamConfiguration(
            settings: settings,
            blueprint: blueprint,
            outputWidth: isAudioOnly ? 2 : outputWidth,
            outputHeight: isAudioOnly ? 2 : outputHeight,
            systemAudioEnabled: wantsSystemAudio
        )

        let engine = ScreenRecordingEngine(
            writer: writer,
            videoInput: videoInput,
            systemAudioInput: systemAudioInput,
            outputURL: outputURL,
            settings: settings
        )
        // The engine is also the stream delegate so presenter overlay
        // lifecycle callbacks reach the session.
        let stream = SCStream(filter: blueprint.filter, configuration: configuration, delegate: engine)
        engine.attach(stream: stream)
        try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.sampleQueue)
        if systemAudioInput != nil {
            try stream.addStreamOutput(engine, type: .audio, sampleHandlerQueue: engine.sampleQueue)
        }
        if !isAudioOnly, settings.encoder == .h264, !settings.recordHDR {
            await engine.probeHardwareH264Encoder(width: configuration.width, height: configuration.height)
        }
        return engine
    }

    /// Stream-level capture options derived from the settings: HDR adopts
    /// the system capture preset on macOS 15+, the pixel format/color space
    /// and background fill apply to video, and the frame interval is left
    /// unthrottled at 60 fps and for audio-only streams (ScreenCaptureKit
    /// only delivers frames when content changes anyway).
    private static func makeStreamConfiguration(
        settings: ScreenRecordingSettings,
        blueprint: ScreenRecordingCapturePlanner.Blueprint,
        outputWidth: Int,
        outputHeight: Int,
        systemAudioEnabled: Bool
    ) -> SCStreamConfiguration {
        let isAudioOnly = settings.captureMode == .audio
        let configuration: SCStreamConfiguration
        if !isAudioOnly, settings.recordHDR, #available(macOS 15.0, *) {
            configuration = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
        } else {
            configuration = SCStreamConfiguration()
        }
        configuration.width = outputWidth
        configuration.height = outputHeight
        if !isAudioOnly {
            if settings.recordHDR {
                // Capture HDR into a BT.2020 PQ container.
                configuration.colorSpaceName = CGColorSpace.itur_2100_PQ
                configuration.queueDepth = 8
            } else {
                configuration.pixelFormat = settings.pixelFormat.pixelFormat ?? kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
            }
            if let fill = ScreenRecordingCapturePlanner.backgroundFill(for: settings) {
                configuration.backgroundColor = fill
            }
            configuration.showsCursor = settings.showsCursor
            if let cropRect = blueprint.cropRect {
                configuration.sourceRect = cropRect
            }
        }
        configuration.capturesAudio = systemAudioEnabled
        configuration.excludesCurrentProcessAudio = true
        if systemAudioEnabled {
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }
        configuration.minimumFrameInterval = isAudioOnly
            ? CMTime(value: 1, timescale: CMTimeScale.max)
            : CMTime(value: 1, timescale: settings.framesPerSecond >= 60 ? 0 : CMTimeScale(settings.framesPerSecond))
        return configuration
    }

    /// The display a recording targets: the one with the largest overlap on
    /// the selection, or the one under the pointer.
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

    /// Picks the output file name. When the audio tracks will be mixed down
    /// after recording, the writer targets a triple-extension file so the
    /// mixdown can land atomically on the clean single-extension name.
    private static func nextRecordingURL(for settings: ScreenRecordingSettings) throws -> URL {
        let folder = ScreenRecordingOutput.folder(for: settings)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "MacPilot-" + timestamp

        let isAudioOnly = settings.captureMode == .audio
        let containerExtension = isAudioOnly ? settings.audioFormat.fileExtension : settings.effectiveFormat.fileExtension
        let willMixdown = settings.capturesMicrophone && settings.capturesSystemAudio && settings.remuxAudio
        let targetExtension = willMixdown ? "\(containerExtension).\(containerExtension).\(containerExtension)" : containerExtension

        var outputURL = folder.appendingPathComponent("\(baseName).\(targetExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = folder.appendingPathComponent("\(baseName)-\(suffix).\(targetExtension)")
            suffix += 1
        }
        return outputURL
    }

    /// Checks that a hardware H.264 encoder can handle the requested size;
    /// offers a switch to HEVC (persisted through the model) when it can't.
    private func probeHardwareH264Encoder(width: Int, height: Int) async {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status != noErr else { return }
        if await MainActor.run(body: Self.offerEncoderFallback) {
            encoderFallbackHandler?(.hevc)
        }
    }

    @MainActor
    private static func offerEncoderFallback() -> Bool {
        let alert = NSAlert()
        alert.messageText = AppText.value("scRecordingEncoderWarningTitle", language: .english)
        alert.informativeText = AppText.value("scRecordingEncoderWarningBody", language: .english)
        alert.addButton(withTitle: AppText.value("scRecordingEncoderWarningSwitch", language: .english))
        alert.addButton(withTitle: AppText.value("scRecordingEncoderWarningContinue", language: .english))
        alert.alertStyle = .critical
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Lifecycle

    func start() async throws {
        if settings.capturesMicrophone {
            startMicrophoneCapture()
        }
        try await stream.startCapture()
        if settings.preventSleep {
            sleepAssertion.acquire(reason: "MacPilot screen recording in progress")
        }
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated, !isPaused else { return }
        isPaused = true
        pauseStartedAt = Date()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated, isPaused else { return }
        if let pauseStartedAt {
            pausedDuration = pausedDuration + CMTime(
                seconds: max(0, Date().timeIntervalSince(pauseStartedAt)),
                preferredTimescale: 600
            )
        }
        self.pauseStartedAt = nil
        isPaused = false
    }

    func stop() async throws -> URL {
        guard beginTermination() else { return cleanedOutputURL() }
        stopMicrophoneCapture()
        try? await stream.stopCapture()
        sleepAssertion.release()
        let writtenURL = try await finalizeWriting()
        return try await mixdownIfNeeded(writtenURL: writtenURL)
    }

    func cancel() async {
        let shouldTerminate = beginTermination()
        if shouldTerminate {
            stopMicrophoneCapture()
            try? await stream.stopCapture()
        }
        sleepAssertion.release()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func beginTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return false }
        isTerminated = true
        return true
    }

    /// The file name the finished recording should carry: a mixdown rewrites
    /// the triple-extension target onto its clean name.
    private func cleanedOutputURL() -> URL {
        let willMixdown = settings.capturesMicrophone && settings.capturesSystemAudio && settings.remuxAudio
        guard willMixdown else { return outputURL }
        return outputURL.deletingPathExtension().deletingPathExtension()
    }

    // MARK: - Frame saving

    /// Saves the next captured frame as a PNG (the "save current frame"
    /// hotkey). The request is honored even while paused.
    func requestFrameSave(completion: @escaping (URL?) -> Void) {
        lock.lock()
        frameSaveRequested = true
        frameSaveHandler = completion
        lock.unlock()
    }

    /// The first captured frame, kept for the completion preview.
    var initialFrameImage: NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return posterImageCache
    }

    // MARK: - Microphone

    /// Records the microphone onto its own track. The default device uses
    /// an AVAudioEngine input tap (with voice processing for echo
    /// cancellation and the configured ducking level); a named device is
    /// captured through AVCaptureAudioDataOutput. A microphone that fails
    /// to start never aborts the recording — the track is dropped and the
    /// failure logged.
    private func startMicrophoneCapture() {
        let audioFormat: ScreenRecordingAudioFormat = isAudioOnly ? settings.audioFormat : .aac

        func makeWriterInput(sampleRate: Int, channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: ScreenRecordingCodecPlanner.audioCompressionSettings(
                    sampleRate: sampleRate,
                    channels: channels,
                    format: audioFormat,
                    quality: settings.audioQuality
                )
            )
            input.expectsMediaDataInRealTime = true
            return input
        }

        func registerWriterInput(_ input: AVAssetWriterInput) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard writer.canAdd(input) else {
                Self.logger.error("Microphone track could not be added to the writer")
                return false
            }
            writer.add(input)
            microphoneInput = input
            return true
        }

        if settings.microphoneDeviceName != "default",
           let device = ScreenRecordingDeviceController.availableMicrophones().first(where: { device in
               device.localizedName == self.settings.microphoneDeviceName
           }) {
            // Named device: AVCaptureSession path.
            let session = AVCaptureSession()
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                Self.logger.error("Microphone device could not be opened: \(self.settings.microphoneDeviceName, privacy: .public)")
                return
            }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: micSampleQueue)
            guard session.canAddOutput(output) else {
                Self.logger.error("Microphone output could not be configured")
                return
            }
            session.addOutput(output)
            let sampleRate = ScreenRecordingDeviceController.selectedMicrophoneSampleRate(deviceName: self.settings.microphoneDeviceName)
            let writerInput = makeWriterInput(sampleRate: sampleRate, channels: 2)
            guard registerWriterInput(writerInput) else { return }
            micCaptureSession = session
            session.startRunning()
            return
        }

        let input = audioEngine.inputNode
        if settings.microphoneEchoCancellation {
            try? input.setVoiceProcessingEnabled(true)
            configureDucking(for: input)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate >= 8_000, format.channelCount > 0 else {
            Self.logger.error("Microphone capture skipped: unusable input format")
            return
        }
        let writerInput = makeWriterInput(sampleRate: Int(format.sampleRate), channels: Int(format.channelCount))
        guard registerWriterInput(writerInput) else { return }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self, let sample = buffer.hostClockSampleBuffer else { return }
            self.handleMicrophoneSample(sample)
        }
        do {
            try audioEngine.start()
        } catch {
            Self.logger.error("Microphone engine failed to start: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            lock.lock()
            writerInput.markAsFinished()
            microphoneInput = nil
            lock.unlock()
        }
    }

    /// Ducks the system ("other") audio while the voice-processed
    /// microphone is live, at the configured strength.
    private func configureDucking(for node: AVAudioInputNode) {
        guard settings.microphoneEchoCancellation, let audioUnit = node.audioUnit else { return }
        let level: AUVoiceIOOtherAudioDuckingLevel
        switch settings.audioDuckingLevel {
        case .min: level = .min
        case .mid: level = .mid
        case .max: level = .max
        }
        var configuration = AUVoiceIOOtherAudioDuckingConfiguration()
        configuration.mEnableAdvancedDucking = true
        configuration.mDuckingLevel = level
        let status = withUnsafePointer(to: &configuration) { pointer in
            AudioUnitSetProperty(
                audioUnit,
                kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                kAudioUnitScope_Global,
                0,
                pointer,
                UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
            )
        }
        if status != noErr {
            Self.logger.debug("Ducking level property not applied: \(status)")
        }
    }

    private func handleMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated, !isPaused, didStartWritingSession, let microphoneInput else { return }
        let retimed = sampleBufferRetimed(sampleBuffer, shiftingBy: pausedDuration) ?? sampleBuffer
        if microphoneInput.isReadyForMoreMediaData, !microphoneInput.append(retimed) {
            Self.logger.debug("Microphone sample was rejected while recording")
        }
    }

    private func stopMicrophoneCapture() {
        lock.lock()
        let hadMicrophone = microphoneInput != nil
        microphoneInput?.markAsFinished()
        microphoneInput = nil
        lock.unlock()
        guard hadMicrophone else { return }
        if let captureSession = micCaptureSession {
            if captureSession.isRunning { captureSession.stopRunning() }
            micCaptureSession = nil
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    // MARK: - Stream output

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // The save-frame request is honored before the pause check, so a
        // frame can be captured even while paused.
        if type == .screen, let imageBuffer = sampleBuffer.imageBuffer {
            lock.lock()
            let wantsSave = frameSaveRequested
            let handler = frameSaveHandler
            if wantsSave {
                frameSaveRequested = false
                frameSaveHandler = nil
            }
            lock.unlock()
            if wantsSave {
                let url = Self.writeFramePNG(from: imageBuffer, settings: settings)
                handler?(url)
                if let url {
                    frameSavedHandler?(url)
                }
            }
        }

        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated, !isPaused else { return }
        let sampleBuffer = sampleBufferRetimed(sampleBuffer, shiftingBy: pausedDuration) ?? sampleBuffer

        switch type {
        case .screen:
            guard !isAudioOnly else { return }
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first else { return }
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid, !timestamp.isIndefinite else { return }
            if !didStartWritingSession {
                guard writer.startWriting() else {
                    streamFailure = writer.error ?? ScreenRecordingError.writerCreationFailed
                    return
                }
                writer.startSession(atSourceTime: timestamp)
                didStartWritingSession = true
            }
            didCaptureVideo = true
            if posterImageCache == nil {
                posterImageCache = Self.posterThumbnail(from: sampleBuffer)
            }

            // While the system presenter overlay transitions between its
            // states, frames are dropped until the overlay is ready.
            if #available(macOS 14.2, *), let rect = attachments[.presenterOverlayContentRect] as? [String: Any] {
                let overlayState = Self.presenterOverlayState(for: rect)
                if overlayState != presenterOverlayState {
                    presenterOverlayReady = false
                    DispatchQueue.global().asyncAfter(deadline: .now() + TimeInterval(presenterOverlaySafeDelay)) { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        self.presenterOverlayReady = true
                        self.lock.unlock()
                    }
                    presenterOverlayState = overlayState
                }
                if presenterOverlayActive && !presenterOverlayReady { return }
            }

            // Drop duplicates through the rolling end-time window.
            var frameEnd = timestamp
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            if duration.value > 0 { frameEnd = CMTimeAdd(frameEnd, duration) }
            if recentFrameEndTimes.contains(where: { CMTimeCompare($0, frameEnd) >= 0 }) { return }
            recentFrameEndTimes.append(frameEnd)
            if recentFrameEndTimes.count > rollingFrameWindow {
                recentFrameEndTimes.removeFirst(recentFrameEndTimes.count - rollingFrameWindow)
            }

            if let videoInput, videoInput.isReadyForMoreMediaData, !videoInput.append(sampleBuffer) {
                streamFailure = writer.error ?? ScreenRecordingError.streamFailed("video writer rejected a frame")
            }
        case .audio:
            guard let systemAudioInput else { return }
            // Audio-only recordings anchor the writer session on the first
            // system-audio sample because no video frame ever arrives.
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !didStartWritingSession {
                guard timestamp.isValid, !timestamp.isIndefinite else { return }
                guard writer.startWriting() else {
                    streamFailure = writer.error ?? ScreenRecordingError.writerCreationFailed
                    return
                }
                writer.startSession(atSourceTime: timestamp)
                didStartWritingSession = true
            }
            didCaptureAudio = true
            if systemAudioInput.isReadyForMoreMediaData, !systemAudioInput.append(sampleBuffer) {
                Self.logger.debug("System audio sample was rejected while recording")
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    /// Classifies the presenter overlay content rect: X == ∞ means the
    /// overlay turned off, X == 0 the small tile, anything else the large
    /// tile.
    @available(macOS 14.2, *)
    private static func presenterOverlayState(for rect: [String: Any]) -> String {
        let x = rect["X"] as? CGFloat
        if x == .infinity { return "OFF" }
        if x == 0.0 { return "Small" }
        if x != nil { return "Big" }
        return "OFF"
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return }
        streamFailure = error
    }

    // MARK: Presenter overlay lifecycle

    func outputVideoEffectDidStart(for stream: SCStream) {
        lock.lock()
        presenterOverlayActive = true
        presenterOverlayReady = false
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + TimeInterval(presenterOverlaySafeDelay)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.presenterOverlayReady = true
            self.lock.unlock()
        }
        Task { @MainActor [weak self] in
            self?.presenterOverlayActivityHandler?(true)
        }
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        lock.lock()
        presenterOverlayActive = false
        presenterOverlayReady = false
        presenterOverlayState = "OFF"
        lock.unlock()
        Task { @MainActor [weak self] in
            self?.presenterOverlayActivityHandler?(false)
        }
    }

    // MARK: - Frame writing

    /// Writes the frame to "<folder>/Capturing at <date>.png". HDR captures
    /// go through a 10-bit PNG pipeline with a +1 EV adjustment.
    private static func writeFramePNG(from imageBuffer: CVPixelBuffer, settings: ScreenRecordingSettings) -> URL? {
        let folder = ScreenRecordingOutput.folder(for: settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("Capturing at \(timestamp).png")
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        do {
            if settings.recordHDR {
                let exposed = ciImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
                let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
                if #available(macOS 14.0, *) {
                    try context.writePNGRepresentation(of: exposed, to: url, format: .RGB10, colorSpace: colorSpace)
                } else {
                    try context.writePNGRepresentation(of: exposed, to: url, format: .RGBA8, colorSpace: colorSpace)
                }
            } else {
                guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return nil }
                try png.write(to: url)
            }
            return url
        } catch {
            Self.logger.error("Could not save frame: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func posterThumbnail(from sampleBuffer: CMSampleBuffer) -> NSImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
    }

    // MARK: - Finishing

    private func finalizeWriting() async throws -> URL {
        try validateCapturedContent()

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

    private func validateCapturedContent() throws {
        lock.lock()
        defer { lock.unlock() }
        if let streamFailure {
            throw ScreenRecordingError.streamFailed(streamFailure.localizedDescription)
        }
        if isAudioOnly {
            guard didCaptureAudio else { throw ScreenRecordingError.noAudioCaptured }
        } else {
            guard didCaptureVideo else { throw ScreenRecordingError.noVideoFrames }
        }
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
    }

    // MARK: - Mixdown

    /// When both system audio and the microphone were captured and "mix
    /// microphone into main track" is enabled, the finished file's audio
    /// tracks are blended into one and re-muxed with the video. Native
    /// mixdown presets only produce AAC/M4A, so lossless audio-only files
    /// keep their two-track container.
    private func mixdownIfNeeded(writtenURL: URL) async throws -> URL {
        guard settings.capturesMicrophone, settings.capturesSystemAudio, settings.remuxAudio else {
            return writtenURL
        }
        if isAudioOnly, settings.audioFormat != .aac {
            return writtenURL
        }
        ScreenRecordingNotifications.show(
            titleKey: "scRecordingMixingTitle",
            bodyKey: "scRecordingMixingBody"
        )
        let container: AVFileType = isAudioOnly ? .m4a : settings.effectiveFormat.fileType
        let result = await ScreenRecordingAudioMixer.mixAndRemux(videoURL: writtenURL, container: container)
        switch result {
        case .success:
            try? FileManager.default.removeItem(at: writtenURL)
            return cleanedOutputURL()
        case .failure(let error):
            Self.logger.error("Audio mixdown failed, keeping original: \(error.localizedDescription, privacy: .public)")
            return writtenURL
        }
    }
}

// MARK: - Named-device microphone capture

extension ScreenRecordingEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handleMicrophoneSample(sampleBuffer)
    }
}
