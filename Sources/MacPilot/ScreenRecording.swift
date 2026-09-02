import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreMedia
import CoreVideo
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI

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

/// Audio container/codec used by audio-only recordings and (in the future)
/// standalone audio exports. MP3 and Opus are intentionally absent
/// because they would require bundling LAME / non-native encoders.
enum ScreenRecordingAudioFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case aac
    case alac
    case flac

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .aac, .alac: return "m4a"
        case .flac: return "caf"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .aac, .alac: return .m4a
        case .flac: return .caf
        }
    }

    var titleKey: String {
        switch self {
        case .aac: return "scRecordingAudioFormatAAC"
        case .alac: return "scRecordingAudioFormatALAC"
        case .flac: return "scRecordingAudioFormatFLAC"
        }
    }
}

/// Audio bitrate ladder in kbps.
enum ScreenRecordingAudioQuality: Int, CaseIterable, Codable, Identifiable, Sendable {
    case normal = 128
    case good = 192
    case high = 256
    case extreme = 320

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .normal: return "scRecordingAudioQualityNormal"
        case .good: return "scRecordingAudioQualityGood"
        case .high: return "scRecordingAudioQualityHigh"
        case .extreme: return "scRecordingAudioQualityExtreme"
        }
    }
}

/// Source pixel format handed to ScreenCaptureKit. `automatic` keeps the
/// engine default (BGRA); the YUV variants trade color fidelity for
/// encoder throughput.
enum ScreenRecordingPixelFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case yuv420p8v
    case yuv420p8f
    case yuv420p10v
    case yuv420p10f
    case bgra32

    var id: String { rawValue }

    var pixelFormat: FourCharCode? {
        switch self {
        case .automatic: return nil
        case .bgra32: return kCVPixelFormatType_32BGRA
        case .yuv420p8v: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv420p8f: return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .yuv420p10v: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .yuv420p10f: return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }

    var titleKey: String {
        switch self {
        case .automatic: return "scRecordingPixelAuto"
        case .yuv420p8v: return "scRecordingPixelYUV420p8v"
        case .yuv420p8f: return "scRecordingPixelYUV420p8f"
        case .yuv420p10v: return "scRecordingPixelYUV420p10v"
        case .yuv420p10f: return "scRecordingPixelYUV420p10f"
        case .bgra32: return "scRecordingPixelBGRA"
        }
    }
}

/// Fill color used where the captured content is transparent. `wallpaper`
/// keeps the actual desktop wallpaper (by leaving wallpaper windows in the
/// capture).
enum ScreenRecordingBackground: String, CaseIterable, Codable, Identifiable, Sendable {
    case wallpaper
    case clear
    case black
    case white
    case red
    case green
    case yellow
    case orange
    case gray
    case blue
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .wallpaper: return "scRecordingBackgroundWallpaper"
        case .clear: return "scRecordingBackgroundClear"
        case .black: return "scRecordingBackgroundBlack"
        case .white: return "scRecordingBackgroundWhite"
        case .red: return "scRecordingBackgroundRed"
        case .green: return "scRecordingBackgroundGreen"
        case .yellow: return "scRecordingBackgroundYellow"
        case .orange: return "scRecordingBackgroundOrange"
        case .gray: return "scRecordingBackgroundGray"
        case .blue: return "scRecordingBackgroundBlue"
        case .custom: return "scRecordingBackgroundCustom"
        }
    }
}

/// Quality ladder applied to the recording bitrate formula.
enum ScreenRecordingVideoQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .low: return "scRecordingQualityLow"
        case .medium: return "scRecordingQualityMedium"
        case .high: return "scRecordingQualityHigh"
        }
    }
}

/// Side-tone ducking strength used while voice processing (echo
/// cancellation) is active.
enum ScreenRecordingAudioDuckingLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case min
    case mid
    case max

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .min: return "scRecordingDuckingMin"
        case .mid: return "scRecordingDuckingMid"
        case .max: return "scRecordingDuckingMax"
        }
    }
}

/// Secondary recording shortcuts. `toggle` lives in `ScreenRecordingSettings
/// .shortcut` for backward compatibility; the remaining purposes are stored
/// in `hotkeys` and disabled until the user assigns them.
enum ScreenRecordingHotKeyPurpose: String, CaseIterable, Codable, Identifiable, Sendable {
    case stop
    case pauseResume
    case startAudio
    case startScreen
    case startWindow
    case startArea
    case saveFrame
    case toggleMagnifier

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .stop: return "scRecordingHotKeyStop"
        case .pauseResume: return "scRecordingHotKeyPauseResume"
        case .startAudio: return "scRecordingHotKeyStartAudio"
        case .startScreen: return "scRecordingHotKeyStartScreen"
        case .startWindow: return "scRecordingHotKeyStartWindow"
        case .startArea: return "scRecordingHotKeyStartArea"
        case .saveFrame: return "scRecordingHotKeySaveFrame"
        case .toggleMagnifier: return "scRecordingHotKeyMagnifier"
        }
    }
}

/// The recording region chosen before the ScreenCaptureKit stream starts.
/// Snapzy opens the area selector by default, while keeping fullscreen and
/// application-window capture available as explicit modes. `audio` records
/// system audio (plus an optional microphone track) without video.
enum ScreenRecordingCaptureMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case area
    case fullscreen
    case application
    case audio

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .area: return "scRecordingArea"
        case .fullscreen: return "scRecordingFullscreen"
        case .application: return "scRecordingApplication"
        case .audio: return "scRecordingAudioMode"
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
    var audioFormat: ScreenRecordingAudioFormat
    var audioQuality: ScreenRecordingAudioQuality
    var withAlpha: Bool
    var recordHDR: Bool
    var highRes: Bool
    var pixelFormat: ScreenRecordingPixelFormat
    var background: ScreenRecordingBackground
    var customBackgroundHex: String
    var videoQuality: ScreenRecordingVideoQuality
    var countdownSeconds: Int
    var autoStopMinutes: Int
    var remuxAudio: Bool
    var microphoneDeviceName: String
    var audioDuckingLevel: ScreenRecordingAudioDuckingLevel
    var highlightMouse: Bool
    var hideDesktopFiles: Bool
    var hideControlCenter: Bool
    var includeMenuBar: Bool
    var excludeSelf: Bool
    var preventSleep: Bool
    var showPreviewAfterRecord: Bool
    var showRecordingController: Bool
    var presenterOverlaySafeDelay: Int
    var blocklist: [String]
    var hotkeys: [String: SmartCaptureShortcutBinding]

    private enum CodingKeys: String, CodingKey {
        case outputFolder, format, captureMode, framesPerSecond, showsCursor
        case capturesSystemAudio, capturesMicrophone, microphoneEchoCancellation
        case encoder, shortcut
        case audioFormat, audioQuality, withAlpha, recordHDR, highRes, pixelFormat
        case background, customBackgroundHex, videoQuality
        case countdownSeconds, autoStopMinutes, remuxAudio, microphoneDeviceName
        case audioDuckingLevel, highlightMouse, hideDesktopFiles, hideControlCenter
        case includeMenuBar, excludeSelf, preventSleep, showPreviewAfterRecord
        case showRecordingController, presenterOverlaySafeDelay, blocklist, hotkeys
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
        audioFormat: ScreenRecordingAudioFormat = .aac,
        audioQuality: ScreenRecordingAudioQuality = .high,
        withAlpha: Bool = false,
        recordHDR: Bool = false,
        highRes: Bool = true,
        pixelFormat: ScreenRecordingPixelFormat = .automatic,
        background: ScreenRecordingBackground = .wallpaper,
        customBackgroundHex: String = "#000000",
        videoQuality: ScreenRecordingVideoQuality = .high,
        countdownSeconds: Int = 0,
        autoStopMinutes: Int = 0,
        remuxAudio: Bool = true,
        microphoneDeviceName: String = "default",
        audioDuckingLevel: ScreenRecordingAudioDuckingLevel = .mid,
        highlightMouse: Bool = false,
        hideDesktopFiles: Bool = false,
        hideControlCenter: Bool = false,
        includeMenuBar: Bool = true,
        excludeSelf: Bool = true,
        preventSleep: Bool = true,
        showPreviewAfterRecord: Bool = true,
        showRecordingController: Bool = true,
        presenterOverlaySafeDelay: Int = 1,
        blocklist: [String] = [],
        hotkeys: [String: SmartCaptureShortcutBinding] = [:],
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
        self.audioFormat = audioFormat
        self.audioQuality = audioQuality
        self.withAlpha = withAlpha
        self.recordHDR = recordHDR
        self.highRes = highRes
        self.pixelFormat = pixelFormat
        self.background = background
        self.customBackgroundHex = customBackgroundHex
        self.videoQuality = videoQuality
        self.countdownSeconds = min(99, max(0, countdownSeconds))
        self.autoStopMinutes = min(99 * 24 * 60, max(0, autoStopMinutes))
        self.remuxAudio = remuxAudio
        self.microphoneDeviceName = microphoneDeviceName
        self.audioDuckingLevel = audioDuckingLevel
        self.highlightMouse = highlightMouse
        self.hideDesktopFiles = hideDesktopFiles
        self.hideControlCenter = hideControlCenter
        self.includeMenuBar = includeMenuBar
        self.excludeSelf = excludeSelf
        self.preventSleep = preventSleep
        self.showPreviewAfterRecord = showPreviewAfterRecord
        self.showRecordingController = showRecordingController
        self.presenterOverlaySafeDelay = min(99, max(0, presenterOverlaySafeDelay))
        self.blocklist = blocklist
        self.hotkeys = hotkeys.filter { purpose in
            ScreenRecordingHotKeyPurpose(rawValue: purpose.key) != nil && purpose.value.isValid
        }
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
            audioFormat: try container.decodeIfPresent(ScreenRecordingAudioFormat.self, forKey: .audioFormat) ?? .aac,
            audioQuality: try container.decodeIfPresent(ScreenRecordingAudioQuality.self, forKey: .audioQuality) ?? .high,
            withAlpha: try container.decodeIfPresent(Bool.self, forKey: .withAlpha) ?? false,
            recordHDR: try container.decodeIfPresent(Bool.self, forKey: .recordHDR) ?? false,
            highRes: try container.decodeIfPresent(Bool.self, forKey: .highRes) ?? true,
            pixelFormat: try container.decodeIfPresent(ScreenRecordingPixelFormat.self, forKey: .pixelFormat) ?? .automatic,
            background: try container.decodeIfPresent(ScreenRecordingBackground.self, forKey: .background) ?? .wallpaper,
            customBackgroundHex: try container.decodeIfPresent(String.self, forKey: .customBackgroundHex) ?? "#000000",
            videoQuality: try container.decodeIfPresent(ScreenRecordingVideoQuality.self, forKey: .videoQuality) ?? .high,
            countdownSeconds: try container.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? 0,
            autoStopMinutes: try container.decodeIfPresent(Int.self, forKey: .autoStopMinutes) ?? 0,
            remuxAudio: try container.decodeIfPresent(Bool.self, forKey: .remuxAudio) ?? true,
            microphoneDeviceName: try container.decodeIfPresent(String.self, forKey: .microphoneDeviceName) ?? "default",
            audioDuckingLevel: try container.decodeIfPresent(ScreenRecordingAudioDuckingLevel.self, forKey: .audioDuckingLevel) ?? .mid,
            highlightMouse: try container.decodeIfPresent(Bool.self, forKey: .highlightMouse) ?? false,
            hideDesktopFiles: try container.decodeIfPresent(Bool.self, forKey: .hideDesktopFiles) ?? false,
            hideControlCenter: try container.decodeIfPresent(Bool.self, forKey: .hideControlCenter) ?? false,
            includeMenuBar: try container.decodeIfPresent(Bool.self, forKey: .includeMenuBar) ?? true,
            excludeSelf: try container.decodeIfPresent(Bool.self, forKey: .excludeSelf) ?? true,
            preventSleep: try container.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? true,
            showPreviewAfterRecord: try container.decodeIfPresent(Bool.self, forKey: .showPreviewAfterRecord) ?? true,
            showRecordingController: try container.decodeIfPresent(Bool.self, forKey: .showRecordingController) ?? true,
            presenterOverlaySafeDelay: try container.decodeIfPresent(Int.self, forKey: .presenterOverlaySafeDelay) ?? 1,
            blocklist: try container.decodeIfPresent([String].self, forKey: .blocklist) ?? [],
            hotkeys: try container.decodeIfPresent([String: SmartCaptureShortcutBinding].self, forKey: .hotkeys) ?? [:],
            migrateLegacyDefaultShortcut: true
        )
    }

    /// Recording with an alpha channel forces the HEVC encoder and a MOV
    /// container regardless of the configured encoder and format.
    var effectiveEncoder: ScreenRecordingVideoEncoder {
        withAlpha ? .hevc : encoder
    }

    var effectiveFormat: ScreenRecordingFormat {
        withAlpha ? .mov : format
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
    case cameraPermissionRequired
    case noDisplayFound
    case alreadyRecording
    case notRecording
    case writerCreationFailed
    case noVideoFrames
    case noAudioCaptured
    case deviceNotFound
    case streamFailed(String)

    var messageKey: String {
        switch self {
        case .permissionRequired: return "scRecordingPermissionRequired"
        case .microphonePermissionRequired: return "scRecordingMicPermissionRequired"
        case .cameraPermissionRequired: return "scRecordingCameraPermissionRequired"
        case .noDisplayFound: return "scRecordingNoDisplay"
        case .alreadyRecording: return "scRecordingAlreadyRunning"
        case .notRecording: return "scRecordingNotRunning"
        case .writerCreationFailed: return "scRecordingWriterFailed"
        case .noVideoFrames: return "scRecordingNoVideoFrames"
        case .noAudioCaptured: return "scRecordingNoAudio"
        case .deviceNotFound: return "scRecordingDeviceNotFound"
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

    static func modifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
        var result: UInt32 = 0
        if binding.modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if binding.modifiers.contains(.option) { result |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { result |= UInt32(controlKey) }
        if binding.modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func id(for index: UInt32) -> EventHotKeyID {
        EventHotKeyID(signature: signature, id: index)
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
          hotKeyID.signature == ScreenRecordingCarbonHotKey.signature else {
        return status == noErr ? noErr : status
    }
    Task { @MainActor in context.model?.handleHotKey(index: Int(hotKeyID.id)) }
    return noErr
}

/// App-level hooks attached to every recording session: persisting the
/// H.264→HEVC hardware fallback and hiding the floating camera window while
/// the system Presenter Overlay takes over.
struct ScreenRecordingSessionHooks: @unchecked Sendable {
    var onEncoderFallback: ((ScreenRecordingVideoEncoder) -> Void)?
    var onPresenterOverlayChanged: ((Bool) -> Void)?
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
    @Published private(set) var isDeviceRecording = false
    @Published private(set) var selectedCameraName = ""
    @Published private(set) var selectedDeviceName = ""
    @Published private(set) var availableCameras: [AVCaptureDevice] = []
    @Published private(set) var availableCaptureDevices: [AVCaptureDevice] = []
    @Published private(set) var availableMicrophones: [AVCaptureDevice] = []

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
    var sessionConfigurationHooks: ScreenRecordingSessionHooks?

    private var session: ScreenRecordingEngine?
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pauseStartedAt: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var shortcutContext: ScreenRecordingShortcutContext?
    private var isCountingDown = false
    /// Registered Carbon hot keys in registration order. Index 0 is always
    /// the primary toggle shortcut.
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyEventHandler: EventHandlerRef?

    /// Windows belonging to this app that must remain capturable while
    /// `excludeSelf` is on (the camera/iDevice/mouse/magnifier overlays).
    nonisolated static let capturableOverlayWindowTitles: Set<String> = [
        "Camera Overlayer",
        "iDevice Overlayer",
        "Mouse Pointer",
        "Screen Magnifier"
    ]

    deinit {
        timerTask?.cancel()
    }

    func applyLoadedSettings(_ settings: ScreenRecordingSettings) {
        self.settings = settings
        refreshCaptureDeviceLists()
    }

    func activateFromConfiguration() {
        registerAllHotKeys()
        refreshCaptureDeviceLists()
    }

    func suspendShortcut() {
        unregisterAllHotKeys()
    }

    func resumeShortcut() {
        _ = registerAllHotKeys()
    }

    // MARK: - Settings mutation

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

    func setAudioFormat(_ format: ScreenRecordingAudioFormat) {
        updateSettings { $0.audioFormat = format }
    }

    func setAudioQuality(_ quality: ScreenRecordingAudioQuality) {
        updateSettings { $0.audioQuality = quality }
    }

    /// Enabling alpha forces HEVC + MOV; turning it off restores the
    /// wallpaper background from a transparent one.
    func setWithAlpha(_ value: Bool) {
        updateSettings {
            $0.withAlpha = value
            if value {
                $0.encoder = .hevc
                $0.format = .mov
            } else if $0.background == .clear {
                $0.background = .wallpaper
            }
        }
    }

    func setRecordHDR(_ value: Bool) {
        updateSettings { $0.recordHDR = value }
    }

    func setHighRes(_ value: Bool) {
        updateSettings { $0.highRes = value }
    }

    func setPixelFormat(_ format: ScreenRecordingPixelFormat) {
        updateSettings { $0.pixelFormat = format }
    }

    func setBackground(_ background: ScreenRecordingBackground) {
        updateSettings { $0.background = background }
    }

    func setCustomBackgroundHex(_ hex: String) {
        updateSettings { $0.customBackgroundHex = hex }
    }

    func setVideoQuality(_ quality: ScreenRecordingVideoQuality) {
        updateSettings { $0.videoQuality = quality }
    }

    func setCountdownSeconds(_ seconds: Int) {
        updateSettings { $0.countdownSeconds = min(99, max(0, seconds)) }
    }

    func setAutoStopMinutes(_ minutes: Int) {
        updateSettings { $0.autoStopMinutes = min(99 * 24 * 60, max(0, minutes)) }
    }

    func setRemuxAudio(_ value: Bool) {
        updateSettings { $0.remuxAudio = value }
    }

    func setMicrophoneDeviceName(_ name: String) {
        updateSettings { $0.microphoneDeviceName = name }
    }

    func setAudioDuckingLevel(_ level: ScreenRecordingAudioDuckingLevel) {
        updateSettings { $0.audioDuckingLevel = level }
    }

    func setHighlightMouse(_ value: Bool) {
        updateSettings { $0.highlightMouse = value }
    }

    func setHideDesktopFiles(_ value: Bool) {
        updateSettings { $0.hideDesktopFiles = value }
    }

    func setHideControlCenter(_ value: Bool) {
        updateSettings { $0.hideControlCenter = value }
    }

    func setIncludeMenuBar(_ value: Bool) {
        updateSettings { $0.includeMenuBar = value }
    }

    func setExcludeSelf(_ value: Bool) {
        updateSettings { $0.excludeSelf = value }
    }

    func setPreventSleep(_ value: Bool) {
        updateSettings { $0.preventSleep = value }
    }

    func setShowPreviewAfterRecord(_ value: Bool) {
        updateSettings { $0.showPreviewAfterRecord = value }
    }

    func setShowRecordingController(_ value: Bool) {
        updateSettings { $0.showRecordingController = value }
    }

    func setPresenterOverlaySafeDelay(_ seconds: Int) {
        updateSettings { $0.presenterOverlaySafeDelay = min(99, max(0, seconds)) }
    }

    func setBlocklist(_ bundleIDs: [String]) {
        updateSettings { $0.blocklist = bundleIDs }
    }

    func setHotKey(_ purpose: ScreenRecordingHotKeyPurpose, _ binding: SmartCaptureShortcutBinding?) {
        updateSettings {
            if let binding, binding.isValid {
                $0.hotkeys[purpose.rawValue] = binding
            } else {
                $0.hotkeys.removeValue(forKey: purpose.rawValue)
            }
        }
        _ = registerAllHotKeys()
    }

    func hotKey(for purpose: ScreenRecordingHotKeyPurpose) -> SmartCaptureShortcutBinding? {
        settings.hotkeys[purpose.rawValue]
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
        settings.shortcut = binding
        guard registerAllHotKeys() else {
            settings.shortcut = previous
            _ = registerAllHotKeys()
            errorMessage = AppText.value("scShortcutRegistrationFailed", language: language)
            return false
        }
        persist?()
        errorMessage = nil
        return true
    }

    // MARK: - Capture devices

    func refreshCaptureDeviceLists() {
        availableCameras = ScreenRecordingDeviceController.availableCameras()
        availableCaptureDevices = ScreenRecordingDeviceController.availableMobileDevices()
        availableMicrophones = ScreenRecordingDeviceController.availableMicrophones()
    }

    /// Toggles the floating camera preview window. The preview window is
    /// an on-screen window that the recording stream captures, so whatever
    /// it shows lands in the video.
    func toggleCameraOverlay(named deviceName: String) {
        if selectedCameraName == deviceName {
            selectedCameraName = ""
            ScreenRecordingDeviceController.shared.closeCameraOverlay()
            return
        }
        guard let device = availableCameras.first(where: { $0.localizedName == deviceName }) else { return }
        selectedCameraName = deviceName
        ScreenRecordingDeviceController.shared.showCameraOverlay(device: device)
    }

    /// Toggles the floating iPhone/iPad preview. Starting an actual device
    /// recording goes through `startDeviceRecording(named:)`.
    func toggleDevicePreview(named deviceName: String) {
        if selectedDeviceName == deviceName {
            selectedDeviceName = ""
            ScreenRecordingDeviceController.shared.closeDeviceOverlay()
            return
        }
        selectedDeviceName = deviceName
        ScreenRecordingDeviceController.shared.showDevicePreview(named: deviceName) { [weak self] in
            self?.selectedDeviceName = ""
        }
    }

    /// Records an iPhone/iPad screen via AVCaptureSession. The macOS
    /// screen is not captured; the device feed goes straight into a video
    /// file.
    func startDeviceRecording(named deviceName: String) {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        errorMessage = nil
        let settings = self.settings
        Task { [weak self] in
            guard let self else { return }
            var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                || AVCaptureDevice.authorizationStatus(for: .muxed) == .authorized
            if !cameraAuthorized {
                cameraAuthorized = await Self.requestCameraAccess()
            }
            guard cameraAuthorized else {
                self.errorMessage = self.localized(ScreenRecordingError.cameraPermissionRequired)
                return
            }
            let started = ScreenRecordingDeviceController.shared.startDeviceRecording(
                named: deviceName,
                settings: settings
            ) { [weak self] url in
                guard let self else { return }
                self.isDeviceRecording = false
                self.selectedDeviceName = ""
                self.lastRecordingURL = url
                self.onCompleted?(url)
            }
            if started {
                self.isDeviceRecording = true
                self.selectedDeviceName = deviceName
            } else {
                self.errorMessage = self.localized(ScreenRecordingError.deviceNotFound)
            }
        }
    }

    func stopDeviceRecording() {
        guard isDeviceRecording else { return }
        ScreenRecordingDeviceController.shared.stopDeviceRecording()
        isDeviceRecording = false
        selectedDeviceName = ""
    }

    // MARK: - Start / stop

    func start() {
        start(captureRect: nil)
    }

    /// Starts a recording immediately when a selection has already been made.
    /// Passing `nil` from the public `start()` path requests the pre-record
    /// area selector for the configured area/application modes.
    func start(captureRect: CGRect?) {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        if captureRect == nil, settings.captureMode != .fullscreen {
            guard let onRequestSelection else {
                errorMessage = localized(ScreenRecordingError.noDisplayFound)
                return
            }
            onRequestSelection(settings.captureMode)
            return
        }
        if settings.captureMode == .audio {
            startAudioRecording()
            return
        }
        let countdown = settings.countdownSeconds
        if countdown > 0 {
            isCountingDown = true
            ScreenRecordingCountdownPanel.shared.show(seconds: countdown) { [weak self] in
                guard let self else { return }
                self.isCountingDown = false
                self.beginStart(captureRect: captureRect, directWindow: false)
            }
        } else {
            beginStart(captureRect: captureRect, directWindow: false)
        }
    }

    /// Starts a recording of the current screen without the selection
    /// overlay, regardless of the configured capture mode (the "record
    /// current screen" hotkey path).
    func startScreenRecording() {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        beginCountdownOr { [weak self] in
            self?.beginStart(captureRect: nil, directWindow: false, overrideCaptureMode: .fullscreen)
        }
    }

    private func beginCountdownOr(_ action: @escaping () -> Void) {
        let countdown = settings.countdownSeconds
        if countdown > 0 {
            isCountingDown = true
            ScreenRecordingCountdownPanel.shared.show(seconds: countdown) { [weak self] in
                guard let self else { return }
                self.isCountingDown = false
                action()
            }
        } else {
            action()
        }
    }

    /// Starts a recording of the frontmost application's on-screen window
    /// without showing the selection overlay (the "record topmost window"
    /// hotkey path).
    func startFrontmostWindowRecording() {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        beginCountdownOr { [weak self] in
            self?.beginStart(captureRect: nil, directWindow: true, overrideCaptureMode: .application)
        }
    }

    /// Starts a system-audio (optionally microphone) recording with no video.
    func startAudioRecording() {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        beginCountdownOr { [weak self] in
            self?.beginStart(captureRect: nil, directWindow: false, overrideCaptureMode: .audio)
        }
    }

    private func beginStart(captureRect: CGRect?, directWindow: Bool, overrideCaptureMode: ScreenRecordingCaptureMode? = nil) {
        guard state == .idle else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            errorMessage = localized(ScreenRecordingError.permissionRequired)
            return
        }
        state = .preparing
        errorMessage = nil
        var snapshot = settings
        if let overrideCaptureMode {
            snapshot.captureMode = overrideCaptureMode
        }
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
                let session = try await ScreenRecordingEngine.makeSession(
                    settings: snapshot,
                    captureRect: captureRect,
                    frontmostWindowOnly: directWindow
                )
                try await session.start()
                guard let self else {
                    await session.cancel()
                    return
                }
                session.encoderFallbackHandler = self.sessionConfigurationHooks?.onEncoderFallback
                session.presenterOverlayActivityHandler = self.sessionConfigurationHooks?.onPresenterOverlayChanged
                self.session = session
                self.startedAt = Date()
                self.pauseStartedAt = nil
                self.accumulatedPauseDuration = 0
                self.elapsedTime = 0
                self.state = .recording
                self.startTimer()
                self.recordingSessionBegan()
            } catch {
                guard let self else { return }
                self.state = .idle
                self.errorMessage = self.localized(error)
                Self.logger.error("Could not start recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Called once the engine is streaming: raises the floating controller,
    /// enables the mouse highlight and magnifier monitors, and asks for
    /// notification permission so the completion notice can be delivered.
    private func recordingSessionBegan() {
        ScreenRecordingNotifications.requestAuthorization()
        if settings.showRecordingController {
            ScreenRecordingFloatingController.shared.show(model: self)
        }
        if settings.highlightMouse {
            ScreenRecordingMouseHighlighter.shared.startMonitoring(showsCursor: settings.showsCursor)
        }
    }

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

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: - Hot key dispatch

    /// Called from the Carbon event handler with the registered hot key
    /// index (0 = primary toggle).
    func handleHotKey(index: Int) {
        // Index 0 is reserved for the primary toggle shortcut.
        if index == 0 {
            toggleFromShortcut()
            return
        }
        let order = hotKeyOrder
        guard index - 1 < order.count else { return }
        switch order[index - 1] {
        case .stop:
            if state == .recording || state == .paused { stop() }
        case .pauseResume:
            if state == .recording || state == .paused { togglePause() }
        case .startAudio:
            if state == .idle { startAudioRecording() }
        case .startScreen:
            if state == .idle { startScreenRecording() }
        case .startWindow:
            if state == .idle { startFrontmostWindowRecording() }
        case .startArea:
            if state == .idle { start() }
        case .saveFrame:
            saveFrame()
        case .toggleMagnifier:
            ScreenRecordingMagnifier.shared.toggle()
        }
    }

    func saveFrame() {
        guard state == .recording, let session else { return }
        session.requestFrameSave { url in
            guard let url else { return }
            ScreenRecordingNotifications.show(
                titleKey: "scRecordingFrameSaved",
                bodyKey: "scRecordingFrameSavedBody",
                arguments: [url.lastPathComponent]
            )
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
        let previewImage = session.initialFrameImage
        self.session = nil
        ScreenRecordingFloatingController.shared.close()
        ScreenRecordingMouseHighlighter.shared.stopMonitoring()
        ScreenRecordingMagnifier.shared.stop()
        Task { [weak self] in
            do {
                let url = try await session.stop()
                guard let self else { return }
                self.finishRecording(url: url, previewImage: previewImage)
            } catch {
                guard let self else { return }
                self.state = .idle
                self.startedAt = nil
                self.errorMessage = self.localized(error)
                Self.logger.error("Could not finish recording: \(error.localizedDescription, privacy: .public)")
                ScreenRecordingNotifications.show(
                    titleKey: "scRecordingSaveFailedTitle",
                    bodyKey: "scRecordingSaveFailedBody",
                    arguments: [self.errorMessage ?? ""]
                )
            }
        }
    }

    private func finishRecording(url: URL, previewImage: NSImage?) {
        lastRecordingURL = url
        elapsedTime = elapsedDuration(at: Date())
        startedAt = nil
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        state = .idle
        errorMessage = nil
        if settings.showPreviewAfterRecord, let image = previewImage ?? lastFrameThumbnail(for: url) {
            ScreenRecordingCompletionPreview.shared.show(image: image, fileURL: url)
        }
        ScreenRecordingNotifications.show(
            titleKey: "scRecordingCompletedTitle",
            bodyKey: "scRecordingCompletedBody",
            arguments: [url.lastPathComponent]
        )
        onCompleted?(url)
    }

    private func lastFrameThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 500, height: 500)
        guard let cgImage = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 10), actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
        ScreenRecordingFloatingController.shared.close()
        ScreenRecordingMouseHighlighter.shared.stopMonitoring()
        ScreenRecordingMagnifier.shared.stop()
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
        if isDeviceRecording {
            ScreenRecordingDeviceController.shared.stopDeviceRecording()
            isDeviceRecording = false
        }
        state = .idle
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        unregisterAllHotKeys()
    }

    // MARK: - Timer / auto stop

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .recording else { return }
                let elapsed = self.elapsedDuration(at: Date())
                self.elapsedTime = elapsed
                // Timed auto stop: the configured minute value ends the
                // recording when the elapsed time passes it.
                let limit = self.settings.autoStopMinutes
                if limit > 0, elapsed / 60 >= Double(limit) {
                    self.stop()
                    return
                }
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

    // MARK: - Hot key registration

    /// Hot key registration order: index 0 = primary toggle, then the
    /// secondary purposes in `ScreenRecordingHotKeyPurpose.allCases` order
    /// for every purpose with an assigned binding.
    private var hotKeyOrder: [ScreenRecordingHotKeyPurpose] {
        ScreenRecordingHotKeyPurpose.allCases.filter { settings.hotkeys[$0.rawValue] != nil }
    }

    @discardableResult
    private func registerAllHotKeys() -> Bool {
        unregisterAllHotKeys()
        guard settings.shortcut.validationError == nil,
              SmartCaptureSystemShortcutDetector.conflicts(for: settings.shortcut).isEmpty else {
            return false
        }
        var bindings: [SmartCaptureShortcutBinding] = [settings.shortcut]
        for purpose in hotKeyOrder {
            if let binding = settings.hotkeys[purpose.rawValue] {
                bindings.append(binding)
            }
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = ScreenRecordingShortcutContext(model: self)
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

        var registered: [EventHotKeyRef?] = []
        for (index, binding) in bindings.enumerated() {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                ScreenRecordingCarbonHotKey.modifiers(for: binding),
                ScreenRecordingCarbonHotKey.id(for: UInt32(index)),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyNoOptions),
                &hotKey
            )
            if status == noErr, let hotKey {
                registered.append(hotKey)
            } else if index == 0 {
                // The primary shortcut must register or nothing works.
                RemoveEventHandler(handler)
                self.hotKeyEventHandler = nil
                return false
            }
        }
        shortcutContext = context
        hotKeyEventHandler = handler
        hotKeyRefs = registered
        errorMessage = nil
        return true
    }

    private func unregisterAllHotKeys() {
        for hotKey in hotKeyRefs {
            if let hotKey { UnregisterEventHotKey(hotKey) }
        }
        hotKeyRefs = []
        if let hotKeyEventHandler { RemoveEventHandler(hotKeyEventHandler) }
        hotKeyEventHandler = nil
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
