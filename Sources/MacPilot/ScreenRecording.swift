import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreMedia
import CoreVideo
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI

enum ScreenRecordingFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case mov
    case mp4

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }
}

/// The recording region chosen before the ScreenCaptureKit stream starts.
/// Snapzy opens the area selector by default, while keeping fullscreen and
/// application-window capture available as explicit modes.
enum ScreenRecordingCaptureMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case area
    case fullscreen
    case application

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .area: return "scRecordingArea"
        case .fullscreen: return "scRecordingFullscreen"
        case .application: return "scRecordingApplication"
        }
    }
}

struct ScreenRecordingSettings: Codable, Equatable, Sendable {
    /// The default recording shortcut deliberately adds Option to macOS's
    /// built-in Command-Shift-5 screenshot shortcut.  Keeping the default
    /// outside the system-owned combination makes the setting immediately
    /// usable after a fresh install.
    static let defaultShortcut = SmartCaptureShortcutBinding(
        keyCode: UInt16(kVK_ANSI_5),
        modifiers: [.command, .option]
    )

    private static let legacyDefaultShortcut = SmartCaptureShortcutBinding(
        keyCode: UInt16(kVK_ANSI_5),
        modifiers: [.command, .shift]
    )

    var outputFolder: String
    var format: ScreenRecordingFormat
    var captureMode: ScreenRecordingCaptureMode
    var framesPerSecond: Int
    var showsCursor: Bool
    var capturesSystemAudio: Bool
    var shortcut: SmartCaptureShortcutBinding

    private enum CodingKeys: String, CodingKey {
        case outputFolder, format, captureMode, framesPerSecond, showsCursor
        case capturesSystemAudio, shortcut
    }

    init(
        outputFolder: String = "",
        format: ScreenRecordingFormat = .mov,
        captureMode: ScreenRecordingCaptureMode = .area,
        framesPerSecond: Int = 30,
        showsCursor: Bool = true,
        capturesSystemAudio: Bool = false,
        shortcut: SmartCaptureShortcutBinding = Self.defaultShortcut,
        migrateLegacyDefaultShortcut: Bool = false
    ) {
        self.outputFolder = outputFolder
        self.format = format
        self.captureMode = captureMode
        self.framesPerSecond = min(60, max(5, framesPerSecond))
        self.showsCursor = showsCursor
        self.capturesSystemAudio = capturesSystemAudio
        let safeShortcut = shortcut.isValid ? shortcut : Self.defaultShortcut
        // The first development builds used Apple's system screenshot key as
        // the recording default. Migrate that exact persisted value while
        // preserving every other user-selected shortcut. Direct callers that
        // explicitly provide a binding are never rewritten.
        self.shortcut = migrateLegacyDefaultShortcut && safeShortcut == Self.legacyDefaultShortcut
            ? Self.defaultShortcut
            : safeShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outputFolder: try container.decodeIfPresent(String.self, forKey: .outputFolder) ?? "",
            format: try container.decodeIfPresent(ScreenRecordingFormat.self, forKey: .format) ?? .mov,
            captureMode: try container.decodeIfPresent(ScreenRecordingCaptureMode.self, forKey: .captureMode) ?? .area,
            framesPerSecond: try container.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 30,
            showsCursor: try container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true,
            capturesSystemAudio: try container.decodeIfPresent(Bool.self, forKey: .capturesSystemAudio) ?? false,
            shortcut: try container.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .shortcut)
                ?? Self.defaultShortcut,
            migrateLegacyDefaultShortcut: true
        )
    }
}

enum ScreenRecordingState: String, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
}

enum ScreenRecordingError: Error, Equatable, Sendable {
    case permissionRequired
    case noDisplayFound
    case alreadyRecording
    case notRecording
    case writerCreationFailed
    case noVideoFrames
    case streamFailed(String)

    var messageKey: String {
        switch self {
        case .permissionRequired: return "scRecordingPermissionRequired"
        case .noDisplayFound: return "scRecordingNoDisplay"
        case .alreadyRecording: return "scRecordingAlreadyRunning"
        case .notRecording: return "scRecordingNotRunning"
        case .writerCreationFailed: return "scRecordingWriterFailed"
        case .noVideoFrames: return "scRecordingNoVideoFrames"
        case .streamFailed: return "scRecordingStreamFailed"
        }
    }

}

enum ScreenRecordingOutput {
    static func folder(for settings: ScreenRecordingSettings) -> URL {
        let trimmed = settings.outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("MacPilot Recordings", isDirectory: true)
    }
}

/// A small ScreenCaptureKit + AVAssetWriter session.  The callbacks arrive on
/// a private serial queue and are guarded by a lock so the main-actor model can
/// stop the stream without racing the final video/audio samples.
private final class ScreenRecordingSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecording")

    private let stream: SCStream
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let sampleQueue = DispatchQueue(label: "com.misswell.macpilot.screen-recording.samples", qos: .userInitiated)
    private let lock = NSLock()
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
        audioInput: AVAssetWriterInput?,
        outputURL: URL
    ) {
        self.stream = stream
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.outputURL = outputURL
    }

    static func prepare(
        settings: ScreenRecordingSettings,
        captureRect: CGRect?
    ) async throws -> ScreenRecordingSession {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenRecordingError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = activeDisplay(from: content.displays, captureRect: captureRect) else {
            throw ScreenRecordingError.noDisplayFound
        }

        let outputFolder = ScreenRecordingOutput.folder(for: settings)
        try FileManager.default.createDirectory(
            at: outputFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "MacPilot-" + timestamp
        var outputURL = outputFolder.appendingPathComponent("\(baseName).\(settings.format.fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = outputFolder.appendingPathComponent("\(baseName)-\(suffix).\(settings.format.fileExtension)")
            suffix += 1
        }

        let displayScaleX = CGFloat(display.width) / max(1, display.frame.width)
        let displayScaleY = CGFloat(display.height) / max(1, display.frame.height)
        let localCaptureRect = captureRect
            .map { $0.intersection(display.frame) }
            .flatMap { $0.isNull || $0.isEmpty ? nil : $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
        let width = evenDimension(Int(((localCaptureRect?.width ?? display.frame.width) * displayScaleX).rounded()))
        let height = evenDimension(Int(((localCaptureRect?.height ?? display.frame.height) * displayScaleY).rounded()))
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format.fileType)
        } catch {
            throw ScreenRecordingError.writerCreationFailed
        }

        let bitrate = max(2_000_000, min(24_000_000, width * height * settings.framesPerSecond / 6))
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: settings.framesPerSecond * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ScreenRecordingError.writerCreationFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if settings.capturesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        configuration.queueDepth = settings.framesPerSecond >= 60 ? 8 : 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = settings.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if let localCaptureRect {
            configuration.sourceRect = localCaptureRect
        }
        if settings.capturesSystemAudio {
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: nil
        )
        let session = ScreenRecordingSession(
            stream: stream,
            writer: writer,
            videoInput: videoInput,
            audioInput: audioInput,
            outputURL: outputURL
        )
        try stream.addStreamOutput(session, type: .screen, sampleHandlerQueue: session.sampleQueue)
        if audioInput != nil {
            try stream.addStreamOutput(session, type: .audio, sampleHandlerQueue: session.sampleQueue)
        }
        return session
    }

    func start() async throws {
        try await stream.startCapture()
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

        try? await stream.stopCapture()
        return try await finishWriting()
    }

    func cancel() async {
        let shouldStop = markStoppedIfNeeded()
        if shouldStop { try? await stream.stopCapture() }
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
            guard didStartSession, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(sampleBuffer) {
                Self.logger.debug("Audio sample was rejected while recording")
            }
        case .microphone:
            break
        @unknown default:
            break
        }
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
        audioInput?.markAsFinished()
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

    private static func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

private final class ScreenRecordingShortcutContext: @unchecked Sendable {
    weak var model: ScreenRecordingModel?

    init(model: ScreenRecordingModel) {
        self.model = model
    }
}

private enum ScreenRecordingCarbonHotKey {
    static let signature: OSType = 0x4D505245 // "MPRE"
    static let identifier: UInt32 = 1

    static func modifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
        var result: UInt32 = 0
        if binding.modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if binding.modifiers.contains(.option) { result |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { result |= UInt32(controlKey) }
        if binding.modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static var id: EventHotKeyID {
        EventHotKeyID(signature: signature, id: identifier)
    }
}

private func screenRecordingCarbonEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let context = Unmanaged<ScreenRecordingShortcutContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == ScreenRecordingCarbonHotKey.signature,
          hotKeyID.id == ScreenRecordingCarbonHotKey.identifier else {
        return status == noErr ? noErr : status
    }
    Task { @MainActor in context.model?.toggleFromShortcut() }
    return noErr
}

@MainActor
final class ScreenRecordingModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecording")

    @Published private(set) var settings = ScreenRecordingSettings()
    @Published private(set) var state: ScreenRecordingState = .idle
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isConvertingGIF = false

    var language: AppLanguage = .system
    var persist: (() -> Void)?
    /// Injected by the app model so the recording shortcut cannot shadow a
    /// screenshot entry point. Standalone model tests and previews can leave
    /// this unset.
    var isShortcutInUse: ((SmartCaptureShortcutBinding) -> Bool)?
    var onCompleted: ((URL) -> Void)?
    /// Requests the shared screenshot selection overlay for area/application
    /// recording. The callback is intentionally injected so the recording
    /// model remains independent from the overlay controller.
    var onRequestSelection: ((ScreenRecordingCaptureMode) -> Void)?

    private var session: ScreenRecordingSession?
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pauseStartedAt: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var shortcutContext: ScreenRecordingShortcutContext?
    nonisolated(unsafe) private var shortcutHotKey: EventHotKeyRef?
    nonisolated(unsafe) private var shortcutEventHandler: EventHandlerRef?

    deinit {
        timerTask?.cancel()
    }

    func applyLoadedSettings(_ settings: ScreenRecordingSettings) {
        self.settings = settings
    }

    func activateFromConfiguration() {
        registerShortcut()
    }

    func suspendShortcut() {
        unregisterShortcut()
    }

    func resumeShortcut() {
        _ = registerShortcut()
    }

    func setOutputFolder(_ url: URL) {
        updateSettings { $0.outputFolder = url.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    func setFormat(_ format: ScreenRecordingFormat) {
        updateSettings { $0.format = format }
    }

    func setCaptureMode(_ mode: ScreenRecordingCaptureMode) {
        updateSettings { $0.captureMode = mode }
    }

    func setFramesPerSecond(_ value: Int) {
        updateSettings { $0.framesPerSecond = min(60, max(5, value)) }
    }

    func setShowsCursor(_ value: Bool) {
        updateSettings { $0.showsCursor = value }
    }

    func setCapturesSystemAudio(_ value: Bool) {
        updateSettings { $0.capturesSystemAudio = value }
    }

    @discardableResult
    func setShortcut(_ binding: SmartCaptureShortcutBinding) -> Bool {
        guard binding.isValid else {
            errorMessage = AppText.value(
                binding.validationError?.messageKey ?? "scShortcutRegistrationFailed",
                language: language
            )
            return false
        }
        guard binding != settings.shortcut else { return true }
        guard !(isShortcutInUse?(binding) ?? false) else {
            errorMessage = AppText.value("scShortcutUsedByScreenshot", language: language)
            return false
        }
        let previous = settings.shortcut
        unregisterShortcut()
        settings.shortcut = binding
        guard registerShortcut() else {
            settings.shortcut = previous
            _ = registerShortcut()
            errorMessage = AppText.value("scShortcutRegistrationFailed", language: language)
            return false
        }
        persist?()
        errorMessage = nil
        return true
    }

    func start() {
        start(captureRect: nil)
    }

    /// Starts a recording immediately when a selection has already been made.
    /// Passing `nil` from the public `start()` path requests the pre-record
    /// area selector for the configured area/application modes.
    func start(captureRect: CGRect?) {
        guard state == .idle else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        if captureRect == nil, settings.captureMode != .fullscreen {
            guard let onRequestSelection else {
                errorMessage = localized(ScreenRecordingError.noDisplayFound)
                return
            }
            onRequestSelection(settings.captureMode)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            errorMessage = localized(ScreenRecordingError.permissionRequired)
            return
        }
        state = .preparing
        errorMessage = nil
        let snapshot = settings
        Task { [weak self] in
            do {
                let session = try await ScreenRecordingSession.prepare(
                    settings: snapshot,
                    captureRect: captureRect
                )
                try await session.start()
                guard let self else {
                    await session.cancel()
                    return
                }
                self.session = session
                self.startedAt = Date()
                self.pauseStartedAt = nil
                self.accumulatedPauseDuration = 0
                self.elapsedTime = 0
                self.state = .recording
                self.startTimer()
            } catch {
                guard let self else { return }
                self.state = .idle
                self.errorMessage = self.localized(error)
                Self.logger.error("Could not start recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func toggleFromShortcut() {
        switch state {
        case .idle:
            start()
        case .recording:
            stop()
        case .paused:
            stop()
        case .preparing, .stopping:
            break
        }
    }

    func pause() {
        guard state == .recording, let session else { return }
        session.pause()
        pauseStartedAt = Date()
        elapsedTime = elapsedDuration(at: Date())
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused, let session else { return }
        session.resume()
        if let pauseStartedAt {
            accumulatedPauseDuration += max(0, Date().timeIntervalSince(pauseStartedAt))
        }
        self.pauseStartedAt = nil
        state = .recording
        startTimer()
    }

    func togglePause() {
        switch state {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    func stop() {
        guard (state == .recording || state == .paused), let session else {
            if state == .idle { errorMessage = localized(ScreenRecordingError.notRecording) }
            return
        }
        state = .stopping
        stopTimer()
        self.session = nil
        Task { [weak self] in
            do {
                let url = try await session.stop()
                guard let self else { return }
                self.lastRecordingURL = url
                self.elapsedTime = self.elapsedDuration(at: Date())
                self.startedAt = nil
                self.pauseStartedAt = nil
                self.accumulatedPauseDuration = 0
                self.state = .idle
                self.errorMessage = nil
                self.onCompleted?(url)
            } catch {
                guard let self else { return }
                self.state = .idle
                self.startedAt = nil
                self.errorMessage = self.localized(error)
                Self.logger.error("Could not finish recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        guard let session else {
            state = .idle
            stopTimer()
            return
        }
        self.session = nil
        state = .idle
        startedAt = nil
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        stopTimer()
        Task { await session.cancel() }
    }

    func openOutputFolder() {
        let folder = ScreenRecordingOutput.folder(for: settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func convertLastRecordingToGIF() {
        guard !isConvertingGIF, state == .idle, let source = lastRecordingURL else { return }
        guard source.pathExtension.lowercased() != "gif" else { return }
        isConvertingGIF = true
        errorMessage = nil
        let output = source.deletingPathExtension().appendingPathExtension("gif")
        Task { [weak self] in
            do {
                let gif = try await ScreenRecordingGIFConverter.convert(
                    videoURL: source,
                    outputURL: output
                )
                guard let self else { return }
                self.lastRecordingURL = gif
                self.isConvertingGIF = false
                self.onCompleted?(gif)
            } catch {
                guard let self else { return }
                self.isConvertingGIF = false
                self.errorMessage = self.localized(error)
            }
        }
    }

    func shutdown() {
        timerTask?.cancel()
        timerTask = nil
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        state = .idle
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        unregisterShortcut()
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .recording else { return }
                self.elapsedTime = self.elapsedDuration(at: Date())
            }
        }
    }

    private func elapsedDuration(at date: Date) -> TimeInterval {
        guard let startedAt else { return elapsedTime }
        let activePause = pauseStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return max(0, date.timeIntervalSince(startedAt) - accumulatedPauseDuration - activePause)
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func updateSettings(_ mutate: (inout ScreenRecordingSettings) -> Void) {
        mutate(&settings)
        persist?()
    }

    @discardableResult
    private func registerShortcut() -> Bool {
        guard settings.shortcut.validationError == nil,
              SmartCaptureSystemShortcutDetector.conflicts(for: settings.shortcut).isEmpty else {
            return false
        }
        guard shortcutHotKey == nil, shortcutEventHandler == nil else { return true }
        let context = ScreenRecordingShortcutContext(model: self)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            screenRecordingCarbonEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(context).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr, let handler else { return false }

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(settings.shortcut.keyCode),
            ScreenRecordingCarbonHotKey.modifiers(for: settings.shortcut),
            ScreenRecordingCarbonHotKey.id,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        guard status == noErr, let hotKey else {
            RemoveEventHandler(handler)
            return false
        }
        shortcutContext = context
        shortcutEventHandler = handler
        shortcutHotKey = hotKey
        return true
    }

    private func unregisterShortcut() {
        if let shortcutHotKey { UnregisterEventHotKey(shortcutHotKey) }
        if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
        shortcutHotKey = nil
        shortcutEventHandler = nil
        shortcutContext = nil
    }

    private func localized(_ error: Error) -> String {
        if let recordingError = error as? ScreenRecordingError {
            if case .streamFailed(let detail) = recordingError {
                return AppText.value(recordingError.messageKey, language: language, arguments: [detail])
            }
            return AppText.value(recordingError.messageKey, language: language)
        }
        if let conversionError = error as? ScreenRecordingGIFConverter.ConversionError {
            return AppText.value(conversionError.messageKey, language: language)
        }
        return AppText.value("scRecordingUnknownError", language: language)
    }
}
