import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import CoreGraphics
import Foundation
import Testing
import VideoToolbox
@testable import MacPilot

struct RecordingEngineTests {
    @Test func videoEncodersOfferH264AndHEVCWithStableLabels() throws {
        #expect(ScreenRecordingVideoEncoder.allCases == [.h264, .hevc])
        #expect(ScreenRecordingVideoEncoder.h264.titleKey == "scRecordingEncoderH264")
        #expect(ScreenRecordingVideoEncoder.hevc.titleKey == "scRecordingEncoderHEVC")

        let settings = ScreenRecordingSettings(encoder: .hevc)
        let decoded = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.encoder == .hevc)
    }

    @Test func recordingSettingsDecodeLegacyPayloadWithEngineDefaults() throws {
        let settings = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data("{\"format\":\"mov\",\"framesPerSecond\":30}".utf8)
        )
        #expect(settings.encoder == .h264)
        #expect(!settings.capturesMicrophone)
        #expect(settings.microphoneEchoCancellation)
        // Recording defaults.
        #expect(settings.audioFormat == .aac)
        #expect(settings.audioQuality == .high)
        #expect(settings.remuxAudio)
        #expect(settings.highRes)
        #expect(settings.includeMenuBar)
        #expect(settings.excludeSelf)
        #expect(settings.background == .wallpaper)
        #expect(settings.captureMode == .area)
        #expect(settings.countdownSeconds == 0)
        #expect(settings.autoStopMinutes == 0)

        let explicit = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data(
                "{\"capturesMicrophone\":true,\"microphoneEchoCancellation\":false,\"encoder\":\"hevc\",\"captureMode\":\"audio\"}".utf8
            )
        )
        #expect(explicit.capturesMicrophone)
        #expect(!explicit.microphoneEchoCancellation)
        #expect(explicit.encoder == .hevc)
        #expect(explicit.captureMode == .audio)
    }

    /// Recording bitrate formula: `resolution × fps/8 × encoder
    /// multiplier × quality multiplier`, floored at 200 kbps.
    @Test func targetBitrateFollowsTheRecordingFormula() {
        // 1920×1080 @30 fps, H.264, high quality → 2_073_600 × 3.75 × 0.9.
        #expect(
            ScreenRecordingCodecPlanner.bitrateBudget(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .h264,
                quality: .high, hdr: false
            ) == 6_998_400
        )
        // H.265 uses half the pre-multiplier budget (7,776,000 × 0.5).
        #expect(
            ScreenRecordingCodecPlanner.bitrateBudget(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .hevc,
                quality: .high, hdr: false
            ) == 3_888_000
        )
        // Tiny capture at 1 fps falls to the 200 kbps floor.
        #expect(
            ScreenRecordingCodecPlanner.bitrateBudget(
                width: 100, height: 100, framesPerSecond: 1, encoder: .h264,
                quality: .high, hdr: false
            ) == 200_000
        )
        // HDR doubles the budget.
        #expect(
            ScreenRecordingCodecPlanner.bitrateBudget(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .hevc,
                quality: .high, hdr: true
            ) == 7_776_000
        )
    }

    @Test func targetBitrateQualityLadderKeepsLowBelowMediumBelowHigh() {
        let base = (width: 3840, height: 2160, fps: 60, encoder: ScreenRecordingVideoEncoder.h264)
        let high = ScreenRecordingCodecPlanner.bitrateBudget(
            width: base.width, height: base.height, framesPerSecond: base.fps,
            encoder: base.encoder, quality: .high, hdr: false
        )
        let medium = ScreenRecordingCodecPlanner.bitrateBudget(
            width: base.width, height: base.height, framesPerSecond: base.fps,
            encoder: base.encoder, quality: .medium, hdr: false
        )
        let low = ScreenRecordingCodecPlanner.bitrateBudget(
            width: base.width, height: base.height, framesPerSecond: base.fps,
            encoder: base.encoder, quality: .low, hdr: false
        )
        #expect(high == 55_987_200) // 3840×2160 × 7.5 × 0.9, quality 1.0
        #expect(medium < high)
        #expect(low < medium)
        #expect(low >= 200_000)
    }

    @Test func videoWriterSettingsUseTheSelectedCodecAndDerivedBitrate() throws {
        let hevc = ScreenRecordingCodecPlanner.videoCompressionSettings(
            width: 1920, height: 1080, framesPerSecond: 30,
            encoder: .hevc, alphaEnabled: false, hdr: false, quality: .high
        )
        #expect(hevc[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let hevcProperties = try #require(hevc[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(hevcProperties[AVVideoAverageBitRateKey] as? Int == 3_888_000)
        #expect(hevcProperties[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main_AutoLevel as String)

        // Alpha recordings pick HEVC With Alpha.
        let alpha = ScreenRecordingCodecPlanner.videoCompressionSettings(
            width: 1920, height: 1080, framesPerSecond: 30,
            encoder: .hevc, alphaEnabled: true, hdr: false, quality: .high
        )
        #expect(alpha[AVVideoCodecKey] as? AVVideoCodecType == .hevcWithAlpha)

        // HDR recordings use HEVC Main10 without BT.709 overrides.
        let hdr = ScreenRecordingCodecPlanner.videoCompressionSettings(
            width: 1920, height: 1080, framesPerSecond: 30,
            encoder: .hevc, alphaEnabled: false, hdr: true, quality: .high
        )
        #expect(hdr[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let hdrProperties = try #require(hdr[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(hdrProperties[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        #expect(hdr[AVVideoColorPropertiesKey] == nil)

        let h264 = ScreenRecordingCodecPlanner.videoCompressionSettings(
            width: 1920, height: 1080, framesPerSecond: 30,
            encoder: .h264, alphaEnabled: false, hdr: false, quality: .high
        )
        #expect(h264[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(h264[AVVideoColorPropertiesKey] as? [String: Any] != nil)
    }

    @Test func alphaSettingsForceHEVCAndMOV() {
        let settings = ScreenRecordingSettings(
            format: .mp4,
            encoder: .h264,
            withAlpha: true
        )
        #expect(settings.effectiveEncoder == .hevc)
        #expect(settings.effectiveFormat == .mov)
    }

    @Test func audioWriterSettingsMatchFormatAndQualityOptions() {
        let aac = ScreenRecordingCodecPlanner.audioCompressionSettings(
            sampleRate: 48_000, channels: 2, format: .aac, quality: .high
        )
        #expect(aac[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(aac[AVSampleRateKey] as? Int == 48_000)
        #expect(aac[AVNumberOfChannelsKey] as? Int == 2)
        #expect(aac[AVEncoderBitRateKey] as? Int == 256_000)

        let lowRate = ScreenRecordingCodecPlanner.audioCompressionSettings(
            sampleRate: 32_000, channels: 1, format: .aac, quality: .high
        )
        #expect(lowRate[AVSampleRateKey] as? Int == 32_000)
        #expect(lowRate[AVNumberOfChannelsKey] as? Int == 1)
        #expect(lowRate[AVEncoderBitRateKey] as? Int == 64_000)

        let extreme = ScreenRecordingCodecPlanner.audioCompressionSettings(
            sampleRate: 48_000, channels: 2, format: .aac, quality: .extreme
        )
        #expect(extreme[AVEncoderBitRateKey] as? Int == 320_000)

        let alac = ScreenRecordingCodecPlanner.audioCompressionSettings(
            sampleRate: 48_000, channels: 2, format: .alac, quality: .high
        )
        #expect(alac[AVFormatIDKey] as? AudioFormatID == kAudioFormatAppleLossless)
        #expect(alac[AVEncoderBitDepthHintKey] as? Int == 16)
        #expect(alac[AVEncoderBitRateKey] == nil)

        let flac = ScreenRecordingCodecPlanner.audioCompressionSettings(
            sampleRate: 48_000, channels: 2, format: .flac, quality: .high
        )
        #expect(flac[AVFormatIDKey] as? AudioFormatID == kAudioFormatFLAC)
        #expect(ScreenRecordingAudioFormat.flac.fileExtension == "caf")
        #expect(ScreenRecordingAudioFormat.alac.fileType == .m4a)
    }

    @Test func backgroundMappingMatchesTheConfiguredPalette() {
        #expect(ScreenRecordingCapturePlanner.backgroundFill(for: ScreenRecordingSettings(background: .wallpaper)) == nil)
        #expect(ScreenRecordingCapturePlanner.backgroundFill(for: ScreenRecordingSettings(background: .clear)) == CGColor.clear)

        func rgba(_ color: CGColor?) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
            guard let components = color?.components, !components.isEmpty else { return nil }
            // Grayscale color spaces carry a single white component.
            if components.count == 1 {
                return (components[0], components[0], components[0], color?.alpha ?? 1)
            }
            guard components.count >= 3 else { return nil }
            return (components[0], components[1], components[2], color?.alpha ?? 1)
        }

        // CGColor.black lives in a grayscale space whose components are not
        // uniformly introspectable, so compare directly.
        #expect(ScreenRecordingCapturePlanner.backgroundFill(for: ScreenRecordingSettings(background: .black)) == CGColor.black)

        let custom = rgba(ScreenRecordingCapturePlanner.backgroundFill(for: ScreenRecordingSettings(background: .custom, customBackgroundHex: "#FF0000")))
        #expect(custom?.red == 1)
        #expect(custom?.green == 0)
        #expect(custom?.blue == 0)
        // Invalid hex falls back to black rather than failing the recording.
        let invalid = ScreenRecordingCapturePlanner.backgroundFill(for: ScreenRecordingSettings(background: .custom, customBackgroundHex: "nope"))
        #expect(invalid != nil)
    }

    @Test func pixelFormatMappingCoversAllRecorderOptions() {
        #expect(ScreenRecordingPixelFormat.automatic.pixelFormat == nil)
        #expect(ScreenRecordingPixelFormat.bgra32.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(ScreenRecordingPixelFormat.yuv420p8v.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(ScreenRecordingPixelFormat.yuv420p8f.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(ScreenRecordingPixelFormat.yuv420p10v.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(ScreenRecordingPixelFormat.yuv420p10f.pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    @Test func windowSelectionPrefersTheLargestOverlapWithoutMatchingOwnWindows() {
        let selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        let probes = [
            ScreenRecordingWindowProbe(
                frame: CGRect(x: 0, y: 0, width: 60, height: 100), windowLayer: 0, isOnScreen: true,
                bundleID: "com.example.small"
            ),
            ScreenRecordingWindowProbe(
                frame: CGRect(x: 0, y: 0, width: 100, height: 100), windowLayer: 0, isOnScreen: true,
                bundleID: "com.example.large"
            )
        ]
        #expect(
            ScreenRecordingWindowPicker.largestOverlap(
                in: probes,
                selection: selection,
                excludingOwnBundleID: "com.misswell.macpilot"
            )?.bundleID == "com.example.large"
        )
    }

    @Test func windowSelectionIgnoresOffscreenOverlaysAndOwnWindows() {
        let selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        let probes = [
            ScreenRecordingWindowProbe(
                frame: selection, windowLayer: 0, isOnScreen: false, bundleID: "com.example.offscreen"
            ),
            ScreenRecordingWindowProbe(
                frame: selection, windowLayer: 25, isOnScreen: true, bundleID: "com.example.overlay"
            ),
            ScreenRecordingWindowProbe(
                frame: selection, windowLayer: 0, isOnScreen: true, bundleID: "com.misswell.macpilot"
            )
        ]
        #expect(
            ScreenRecordingWindowPicker.largestOverlap(
                in: probes,
                selection: selection,
                excludingOwnBundleID: "com.misswell.macpilot"
            ) == nil
        )
    }

    @Test func windowSelectionRequiresMajorityCoverageAndAUsableSelection() {
        // Barely 10% overlap is not treated as a window recording.
        let partial = [
            ScreenRecordingWindowProbe(
                frame: CGRect(x: 90, y: 0, width: 100, height: 100), windowLayer: 0, isOnScreen: true,
                bundleID: "com.example.partial"
            )
        ]
        #expect(
            ScreenRecordingWindowPicker.largestOverlap(
                in: partial,
                selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                excludingOwnBundleID: "com.misswell.macpilot"
            ) == nil
        )
        #expect(
            ScreenRecordingWindowPicker.largestOverlap(
                in: partial,
                selection: .zero,
                excludingOwnBundleID: "com.misswell.macpilot"
            ) == nil
        )
    }

    @Test func outputDimensionsSnapToEvenValues() {
        #expect(ScreenRecordingCodecPlanner.snapToEven(1081) == 1080)
        #expect(ScreenRecordingCodecPlanner.snapToEven(1080) == 1080)
        #expect(ScreenRecordingCodecPlanner.snapToEven(1) == 2)
        #expect(ScreenRecordingCodecPlanner.snapToEven(3) == 2)
    }

    @Test func microphoneRecordingFailureSurfacesAStableLocalizationKey() {
        #expect(ScreenRecordingError.microphonePermissionRequired.messageKey == "scRecordingMicPermissionRequired")
        #expect(ScreenRecordingError.noAudioCaptured.messageKey == "scRecordingNoAudio")
        #expect(ScreenRecordingError.cameraPermissionRequired.messageKey == "scRecordingCameraPermissionRequired")
        #expect(ScreenRecordingError.deviceNotFound.messageKey == "scRecordingDeviceNotFound")
    }

    @Test @MainActor func recordingModelPersistsEnginePreferences() {
        let model = ScreenRecordingModel()
        var persisted = false
        model.persist = { persisted = true }

        model.setCapturesMicrophone(true)
        model.setMicrophoneEchoCancellation(false)
        model.setEncoder(.hevc)

        #expect(model.settings.capturesMicrophone)
        #expect(!model.settings.microphoneEchoCancellation)
        #expect(model.settings.encoder == .hevc)
        #expect(persisted)
    }

    @Test @MainActor func recordingModelStoresSecondaryHotKeysAndBlocklist() {
        let model = ScreenRecordingModel()
        var persisted = false
        model.persist = { persisted = true }

        let binding = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_ANSI_S),
            modifiers: [.command, .option]
        )
        #expect(binding.isValid)
        model.setHotKey(.stop, binding)
        #expect(model.hotKey(for: .stop) == binding)
        #expect(persisted)

        model.setHotKey(.saveFrame, binding)
        model.setHotKey(.stop, nil)
        #expect(model.hotKey(for: .stop) == nil)
        #expect(model.hotKey(for: .saveFrame) == binding)

        model.setBlocklist(["com.example.one", "com.example.two"])
        #expect(model.settings.blocklist == ["com.example.one", "com.example.two"])

        // Countdown and auto-stop clamp to sane ranges.
        model.setCountdownSeconds(500)
        model.setAutoStopMinutes(-4)
        #expect(model.settings.countdownSeconds == 99)
        #expect(model.settings.autoStopMinutes == 0)
    }

    @Test @MainActor func withAlphaToggleRestoresTheWallpaperBackground() {
        let model = ScreenRecordingModel()
        model.setWithAlpha(true)
        #expect(model.settings.withAlpha)
        #expect(model.settings.format == .mov)
        #expect(model.settings.encoder == .hevc)
        model.setBackground(.clear)
        model.setWithAlpha(false)
        #expect(!model.settings.withAlpha)
        #expect(model.settings.background == .wallpaper)
    }
}
