import AVFoundation
import CoreMedia
import Foundation
import Testing
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

    @Test func targetBitrateScalesWithResolutionAndHalvesForHEVC() {
        // 1920 * 1080 * 30 / 6 for H.264.
        #expect(
            ScreenRecordingEngine.targetBitrate(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .h264
            ) == 10_368_000
        )
        // HEVC runs at 60% of the H.264 budget.
        #expect(
            ScreenRecordingEngine.targetBitrate(
                width: 1920, height: 1080, framesPerSecond: 30, encoder: .hevc
            ) == 6_220_800
        )
        // Tiny captures are lifted to the 2 Mbps floor.
        #expect(
            ScreenRecordingEngine.targetBitrate(
                width: 100, height: 100, framesPerSecond: 5, encoder: .h264
            ) == 2_000_000
        )
        // 8K60 exceeds the 24 Mbps ceiling and is clamped to it.
        #expect(
            ScreenRecordingEngine.targetBitrate(
                width: 7680, height: 4320, framesPerSecond: 60, encoder: .h264
            ) == 24_000_000
        )
    }

    @Test func videoWriterSettingsUseTheSelectedCodecAndDerivedBitrate() throws {
        let hevc = ScreenRecordingEngine.videoWriterSettings(
            width: 1920, height: 1080, framesPerSecond: 30, encoder: .hevc
        )
        #expect(hevc[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let hevcProperties = try #require(hevc[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(hevcProperties[AVVideoAverageBitRateKey] as? Int == 6_220_800)
        #expect(hevcProperties[AVVideoMaxKeyFrameIntervalKey] as? Int == 60)

        let h264 = ScreenRecordingEngine.videoWriterSettings(
            width: 1920, height: 1080, framesPerSecond: 30, encoder: .h264
        )
        #expect(h264[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(h264[AVVideoColorPropertiesKey] as? [String: Any] != nil)
    }

    @Test func audioWriterSettingsReduceBitrateForLowSampleRateDevices() {
        let standard = ScreenRecordingEngine.audioWriterSettings(sampleRate: 48_000, channels: 2)
        #expect(standard[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(standard[AVSampleRateKey] as? Int == 48_000)
        #expect(standard[AVNumberOfChannelsKey] as? Int == 2)
        #expect(standard[AVEncoderBitRateKey] as? Int == 128_000)

        let lowRate = ScreenRecordingEngine.audioWriterSettings(sampleRate: 32_000, channels: 1)
        #expect(lowRate[AVSampleRateKey] as? Int == 32_000)
        #expect(lowRate[AVNumberOfChannelsKey] as? Int == 1)
        #expect(lowRate[AVEncoderBitRateKey] as? Int == 64_000)
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
            ScreenRecordingEngine.selectWindow(
                probes: probes,
                selection: selection,
                ownBundleID: "com.misswell.macpilot"
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
            ScreenRecordingEngine.selectWindow(
                probes: probes,
                selection: selection,
                ownBundleID: "com.misswell.macpilot"
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
            ScreenRecordingEngine.selectWindow(
                probes: partial,
                selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                ownBundleID: "com.misswell.macpilot"
            ) == nil
        )
        #expect(
            ScreenRecordingEngine.selectWindow(
                probes: partial,
                selection: .zero,
                ownBundleID: "com.misswell.macpilot"
            ) == nil
        )
    }

    @Test func outputDimensionsSnapToEvenValues() {
        #expect(ScreenRecordingEngine.evenDimension(1081) == 1080)
        #expect(ScreenRecordingEngine.evenDimension(1080) == 1080)
        #expect(ScreenRecordingEngine.evenDimension(1) == 2)
        #expect(ScreenRecordingEngine.evenDimension(3) == 2)
    }

    @Test func microphoneRecordingFailureSurfacesAStableLocalizationKey() {
        #expect(ScreenRecordingError.microphonePermissionRequired.messageKey == "scRecordingMicPermissionRequired")
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
}
