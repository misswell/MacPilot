//
//  RecordingOutputPlanning.swift
//  MacPilot
//
//  Deterministic planning for recording outputs: the bitrate budget, the
//  compression dictionaries handed to AVAssetWriter inputs, pixel-size
//  normalization, and hex parsing for custom background colors. Nothing in
//  here touches a writer or a stream, so every rule is unit-testable in
//  isolation.
//

import AVFoundation
import CoreGraphics
import VideoToolbox

/// Compression planning for the video and audio tracks of a recording.
enum ScreenRecordingCodecPlanner {
    /// Bitrate budget for the video track:
    /// `pixel area (each side floored at 600) × fps/8 × codec factor ×
    /// quality factor × (HDR ×2)`, floored at 200 kbps. The quality factor
    /// follows a logarithmic curve of the pixel throughput, with explicit
    /// clamps for the low and medium rungs.
    static func bitrateBudget(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        encoder: ScreenRecordingVideoEncoder,
        quality: ScreenRecordingVideoQuality,
        hdr: Bool
    ) -> Int {
        let fps = Double(max(1, framesPerSecond))
        let pixelCount = Double(max(600, width) * max(600, height))
        let throughput = sqrt(pixelCount) * (fps / 8)
        let adaptiveQuality = 1 - (log10(throughput) / 5)
        let qualityFactor: Double
        switch quality {
        case .high:
            qualityFactor = 1.0
        case .medium:
            qualityFactor = max(0.4, min(0.6, adaptiveQuality * 3))
        case .low:
            qualityFactor = max(0.1, adaptiveQuality)
        }
        let codecFactor: Double = encoder == .hevc ? 0.5 : 0.9
        let budget = pixelCount * (fps / 8) * codecFactor * qualityFactor * (hdr ? 2 : 1)
        return max(200_000, Int(budget))
    }

    /// Compression dictionary for the video writer input. Alpha recordings
    /// use HEVC With Alpha; HDR recordings use HEVC Main10 and skip the
    /// BT.709 color overrides so the captured color space is preserved.
    static func videoCompressionSettings(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        encoder: ScreenRecordingVideoEncoder,
        alphaEnabled: Bool,
        hdr: Bool,
        quality: ScreenRecordingVideoQuality
    ) -> [String: Any] {
        let hevcFamily = encoder == .hevc || hdr
        let codec: AVVideoCodecType
        if hevcFamily {
            codec = (alphaEnabled && !hdr) ? .hevcWithAlpha : .hevc
        } else {
            codec = .h264
        }
        let profileLevel: String
        if hdr {
            profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        } else if hevcFamily {
            profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
        } else {
            profileLevel = AVVideoProfileLevelH264HighAutoLevel
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: profileLevel,
                AVVideoAverageBitRateKey: bitrateBudget(
                    width: width,
                    height: height,
                    framesPerSecond: framesPerSecond,
                    encoder: encoder,
                    quality: quality,
                    hdr: hdr
                ),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond
            ] as [String: Any]
        ]
        if !hdr {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ] as [String: Any]
        }
        return settings
    }

    /// Compression dictionary for an audio writer input. Low-sample-rate
    /// sources have their bitrate halved and capped at 64 kbps; lossless
    /// formats ignore the bitrate entirely.
    static func audioCompressionSettings(
        sampleRate: Int,
        channels: Int,
        format: ScreenRecordingAudioFormat,
        quality: ScreenRecordingAudioQuality
    ) -> [String: Any] {
        var bitRate = quality.rawValue * 1000
        if sampleRate < 44_100 { bitRate = min(64_000, bitRate / 2) }
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        switch format {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = bitRate
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        }
        return settings
    }

    /// H.264 and HEVC encoders reject odd pixel dimensions.
    static func snapToEven(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}

extension CGColor {
    /// Parses `#RRGGBB` or `#RRGGBBAA` for the custom background fill.
    static func parse(hexString: String) -> CGColor? {
        var sanitized = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        guard sanitized.count == 6 || sanitized.count == 8,
              let value = UInt64(sanitized, radix: 16) else { return nil }
        if sanitized.count == 6 {
            return CGColor(
                red: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: 1
            )
        }
        return CGColor(
            red: CGFloat((value >> 24) & 0xFF) / 255.0,
            green: CGFloat((value >> 16) & 0xFF) / 255.0,
            blue: CGFloat((value >> 8) & 0xFF) / 255.0,
            alpha: CGFloat(value & 0xFF) / 255.0
        )
    }
}
