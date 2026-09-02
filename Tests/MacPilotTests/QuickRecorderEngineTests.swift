import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import MacPilot

struct QuickRecorderEngineTests {
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

    @Test func recordingSettingsDecodeLegacyPayloadWithQuickRecorderDefaults() throws {
        let settings = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data("{\"format\":\"mov\",\"framesPerSecond\":30}".utf8)
        )
        #expect(settings.encoder == .h264)
        #expect(!settings.capturesMicrophone)
        #expect(settings.microphoneEchoCancellation)

        let explicit = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data(
                "{\"capturesMicrophone\":true,\"microphoneEchoCancellation\":false,\"encoder\":\"hevc\"}".utf8
            )
        )
        #expect(explicit.capturesMicrophone)
        #expect(!explicit.microphoneEchoCancellation)
        #expect(explicit.encoder == .hevc)
    }

    @Test func targetBitrateFollowsTheQuickRecorderFormula() {
        // 1920x1080 @ 30 fps H.264: 1920 * 1080 * (30 / 8) * 0.9
        #expect(
            QuickRecorderRecordingEngineSupport.targetBitrate(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .h264
            ) == 6_998_400
        )
        // HEVC halves the encoder multiplier: 1920 * 1080 * (30 / 8) * 0.5.
        #expect(
            QuickRecorderRecordingEngineSupport.targetBitrate(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .hevc
            ) == 3_888_000
        )
        // The resolution floors at 600 pt per axis and the result floors at 200 kbps.
        #expect(
            QuickRecorderRecordingEngineSupport.targetBitrate(
                width: 10, height: 10, framesPerSecond: 1, encoder: .h264
            ) == 200_000
        )
        // MacPilot clamps the formula's upper end at 24 Mbps.
        #expect(
            QuickRecorderRecordingEngineSupport.targetBitrate(
                width: 7680, height: 4320, framesPerSecond: 60, encoder: .h264
            ) == 24_000_000
        )
    }

    @Test func videoWriterSettingsUseTheSelectedCodecAndDerivedBitrate() throws {
        let hevc = QuickRecorderRecordingEngineSupport.videoWriterSettings(
            width: 1920, height: 1080, framesPerSecond: 30, encoder: .hevc
        )
        #expect(hevc[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let hevcProperties = try #require(hevc[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(hevcProperties[AVVideoAverageBitRateKey] as? Int == 3_888_000)

        let h264 = QuickRecorderRecordingEngineSupport.videoWriterSettings(
            width: 1920, height: 1080, framesPerSecond: 30, encoder: .h264
        )
        #expect(h264[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(h264[AVVideoColorPropertiesKey] as? [String: Any] != nil)
    }

    @Test func audioWriterSettingsHalveBitrateForLowSampleRateDevices() {
        let standard = QuickRecorderRecordingEngineSupport.audioWriterSettings(sampleRate: 48_000, channels: 2)
        #expect(standard[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(standard[AVSampleRateKey] as? Int == 48_000)
        #expect(standard[AVNumberOfChannelsKey] as? Int == 2)
        #expect(standard[AVEncoderBitRateKey] as? Int == 128_000)

        let lowRate = QuickRecorderRecordingEngineSupport.audioWriterSettings(sampleRate: 32_000, channels: 1)
        #expect(lowRate[AVSampleRateKey] as? Int == 32_000)
        #expect(lowRate[AVNumberOfChannelsKey] as? Int == 1)
        #expect(lowRate[AVEncoderBitRateKey] as? Int == 64_000)
    }

    @Test func windowMatchingPrefersTheLargestOverlapWithoutMatchingOwnWindows() {
        let selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        let candidates = [
            QuickRecorderWindowCandidate(
                frame: CGRect(x: 0, y: 0, width: 60, height: 100), layer: 0, isOnScreen: true,
                bundleID: "com.example.small"
            ),
            QuickRecorderWindowCandidate(
                frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0, isOnScreen: true,
                bundleID: "com.example.large"
            )
        ]
        #expect(
            QuickRecorderRecordingEngineSupport.bestWindowCandidate(
                candidates: candidates,
                captureRect: selection,
                ownBundleID: "com.misswell.macpilot"
            )?.bundleID == "com.example.large"
        )
    }

    @Test func windowMatchingIgnoresOffscreenOverlaysAndOwnWindows() {
        let selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        let candidates = [
            QuickRecorderWindowCandidate(
                frame: selection, layer: 0, isOnScreen: false, bundleID: "com.example.offscreen"
            ),
            QuickRecorderWindowCandidate(
                frame: selection, layer: 25, isOnScreen: true, bundleID: "com.example.overlay"
            ),
            QuickRecorderWindowCandidate(
                frame: selection, layer: 0, isOnScreen: true, bundleID: "com.misswell.macpilot"
            )
        ]
        #expect(
            QuickRecorderRecordingEngineSupport.bestWindowCandidate(
                candidates: candidates,
                captureRect: selection,
                ownBundleID: "com.misswell.macpilot"
            ) == nil
        )
    }

    @Test func windowMatchingRequiresMajorityCoverageAndAUsableSelection() {
        // Barely 10% overlap is not treated as a window recording.
        let partial = [
            QuickRecorderWindowCandidate(
                frame: CGRect(x: 90, y: 0, width: 100, height: 100), layer: 0, isOnScreen: true,
                bundleID: "com.example.partial"
            )
        ]
        #expect(
            QuickRecorderRecordingEngineSupport.bestWindowCandidate(
                candidates: partial,
                captureRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                ownBundleID: "com.misswell.macpilot"
            ) == nil
        )
        #expect(
            QuickRecorderRecordingEngineSupport.bestWindowCandidate(
                candidates: partial,
                captureRect: .zero,
                ownBundleID: "com.misswell.macpilot"
            ) == nil
        )
    }

    @Test func outputDimensionsSnapToEvenValues() {
        #expect(QuickRecorderRecordingEngineSupport.evenDimension(1081) == 1080)
        #expect(QuickRecorderRecordingEngineSupport.evenDimension(1080) == 1080)
        #expect(QuickRecorderRecordingEngineSupport.evenDimension(1) == 2)
        #expect(QuickRecorderRecordingEngineSupport.evenDimension(3) == 2)
    }

    @Test func microphoneRecordingFailureSurfacesAStableLocalizationKey() {
        #expect(ScreenRecordingError.microphonePermissionRequired.messageKey == "scRecordingMicPermissionRequired")
    }

    @Test @MainActor func recordingModelPersistsQuickRecorderEnginePreferences() {
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
}
