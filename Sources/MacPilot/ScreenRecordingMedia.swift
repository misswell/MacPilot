import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

enum ScreenRecordingGIFConverter {
    enum ConversionError: Error, Equatable {
        case sourceUnavailable
        case noFrames
        case destinationUnavailable
        case frameGenerationFailed

        var messageKey: String {
            switch self {
            case .sourceUnavailable: return "scRecordingGIFSourceUnavailable"
            case .noFrames: return "scRecordingGIFNoFrames"
            case .destinationUnavailable: return "scRecordingGIFDestinationUnavailable"
            case .frameGenerationFailed: return "scRecordingGIFFailed"
            }
        }
    }

    static func convert(
        videoURL: URL,
        outputURL: URL,
        framesPerSecond: Int = 15,
        maximumWidth: Int = 960
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else {
                throw ConversionError.sourceUnavailable
            }
            let fps = max(1, framesPerSecond)
            let frameCount = max(1, Int(ceil(duration.seconds * Double(fps))))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumWidth, height: maximumWidth)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            try? FileManager.default.removeItem(at: outputURL)
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.gif.identifier as CFString,
                frameCount,
                nil
            ) else {
                throw ConversionError.destinationUnavailable
            }
            let gifProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ]
            var addedFrames = 0
            for index in 0..<frameCount {
                let time = CMTime(
                    seconds: min(duration.seconds, Double(index) / Double(fps)),
                    preferredTimescale: 600
                )
                guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
                let frameProperties: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)
                    ]
                ]
                CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
                addedFrames += 1
            }
            guard addedFrames > 0 else { throw ConversionError.frameGenerationFailed }
            CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError.frameGenerationFailed
            }
            return outputURL
        }.value
    }
}
