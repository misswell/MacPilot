//
//  ScreenRecordingSettings.swift
//  MacPilot
//
//  User-facing recording options: capture modes, container/codec choices,
//  audio formats, quality ladders, behavior toggles, and their Codable
//  container with safe decoding defaults for older config.json files.
//

import AVFoundation
import Carbon.HIToolbox
import CoreVideo
import Foundation

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

