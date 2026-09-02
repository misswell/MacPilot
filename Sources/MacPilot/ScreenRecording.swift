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
    var capturesMicrophone: Bool
    var microphoneEchoCancellation: Bool
    var encoder: ScreenRecordingVideoEncoder
    var shortcut: SmartCaptureShortcutBinding

    private enum CodingKeys: String, CodingKey {
        case outputFolder, format, captureMode, framesPerSecond, showsCursor
        case capturesSystemAudio, capturesMicrophone, microphoneEchoCancellation
        case encoder, shortcut
    }

    init(
        outputFolder: String = "",
        format: ScreenRecordingFormat = .mov,
        captureMode: ScreenRecordingCaptureMode = .area,
        framesPerSecond: Int = 30,
        showsCursor: Bool = true,
        capturesSystemAudio: Bool = false,
        capturesMicrophone: Bool = false,
        microphoneEchoCancellation: Bool = true,
        encoder: ScreenRecordingVideoEncoder = .h264,
        shortcut: SmartCaptureShortcutBinding = Self.defaultShortcut,
        migrateLegacyDefaultShortcut: Bool = false
    ) {
        self.outputFolder = outputFolder
        self.format = format
        self.captureMode = captureMode
        self.framesPerSecond = min(60, max(5, framesPerSecond))
        self.showsCursor = showsCursor
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneEchoCancellation = microphoneEchoCancellation
        self.encoder = encoder
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
            capturesMicrophone: try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? false,
            microphoneEchoCancellation: try container.decodeIfPresent(Bool.self, forKey: .microphoneEchoCancellation) ?? true,
            encoder: try container.decodeIfPresent(ScreenRecordingVideoEncoder.self, forKey: .encoder) ?? .h264,
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
    case microphonePermissionRequired
    case noDisplayFound
    case alreadyRecording
    case notRecording
    case writerCreationFailed
    case noVideoFrames
    case streamFailed(String)

    var messageKey: String {
        switch self {
        case .permissionRequired: return "scRecordingPermissionRequired"
        case .microphonePermissionRequired: return "scRecordingMicPermissionRequired"
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

    private var session: ScreenRecordingEngine?
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

    func setCapturesMicrophone(_ value: Bool) {
        updateSettings { $0.capturesMicrophone = value }
    }

    func setMicrophoneEchoCancellation(_ value: Bool) {
        updateSettings { $0.microphoneEchoCancellation = value }
    }

    func setEncoder(_ encoder: ScreenRecordingVideoEncoder) {
        updateSettings { $0.encoder = encoder }
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
                if snapshot.capturesMicrophone {
                    let granted = await Self.ensureMicrophonePermission()
                    guard granted else {
                        guard let self else { return }
                        self.state = .idle
                        self.errorMessage = self.localized(ScreenRecordingError.microphonePermissionRequired)
                        return
                    }
                }
                let session = try await ScreenRecordingEngine.prepare(
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

    /// The recording engine captures the microphone through its own audio
    /// tap, so the permission must be resolved before the stream starts.
    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
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
