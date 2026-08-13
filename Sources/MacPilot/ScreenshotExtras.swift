import AppKit
import CoreImage
import Foundation
import ImageIO
import Vision

/// A lightweight history record for captures made through the Snapzy-style
/// screenshot flow.  The record intentionally stores a path instead of an
/// image so history never keeps full-resolution bitmaps alive in memory.
struct SmartCaptureHistoryItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let path: String
    let date: Date
    let width: Int
    let height: Int
    let byteCount: Int64

    init(
        id: UUID = UUID(),
        url: URL,
        date: Date = Date(),
        width: Int,
        height: Int,
        byteCount: Int64
    ) {
        self.id = id
        self.path = url.path
        self.date = date
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }

    var url: URL { URL(fileURLWithPath: path) }
}

enum SmartCaptureHistoryStore {
    private static let defaultsKey = "MacPilot.smartCapture.history.v1"
    private static let maximumItems = 60

    static func load(defaults: UserDefaults = .standard) -> [SmartCaptureHistoryItem] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SmartCaptureHistoryItem].self, from: data) else {
            return []
        }
        let valid = decoded
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.date > $1.date }
            .prefix(maximumItems)
            .map { $0 }
        if valid.count != decoded.count { save(valid, defaults: defaults) }
        return valid
    }

    static func save(_ items: [SmartCaptureHistoryItem], defaults: UserDefaults = .standard) {
        let trimmed = Array(items
            .sorted { $0.date > $1.date }
            .prefix(maximumItems))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func remove(_ id: UUID, from items: [SmartCaptureHistoryItem]) -> [SmartCaptureHistoryItem] {
        items.filter { $0.id != id }
    }
}

enum SmartCaptureThumbnail {
    static func load(url: URL, maximumPixelSize: Int = 320) async -> CGImage? {
        let result: SendableScreenshotImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary
            ) else { return nil }
            return SendableScreenshotImage(value: image)
        }.value
        return result?.value
    }
}

/// Vertical image compositor used by the scrolling screenshot flow.  It
/// detects the largest matching strip between adjacent frames, which avoids
/// duplicating the stationary part of a page when the scroll amount varies.
enum ScreenCaptureVerticalStitcher {
    private struct Raster {
        let data: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int

        func difference(to other: Raster, row: Int, otherRow: Int, sampleStep: Int) -> Double {
            guard width == other.width else { return .greatestFiniteMagnitude }
            var total = 0.0
            var count = 0
            var x = 0
            while x < width {
                let lhs = row * bytesPerRow + x * 4
                let rhs = otherRow * other.bytesPerRow + x * 4
                for channel in 0..<3 {
                    total += abs(Double(data[lhs + channel]) - Double(other.data[rhs + channel]))
                }
                count += 3
                x += sampleStep
            }
            return count == 0 ? .greatestFiniteMagnitude : total / Double(count)
        }
    }

    /// Returns the overlap in pixels between the bottom of `previous` and the
    /// top of `current`.  A zero result means no reliable overlap was found.
    static func bestOverlap(
        previous: CGImage,
        current: CGImage,
        minimumOverlap: Int = 12,
        tolerance: Double = 18
    ) -> Int {
        guard let lhs = raster(previous), let rhs = raster(current), lhs.width == rhs.width else { return 0 }
        let maximum = min(lhs.height, rhs.height) - 1
        guard maximum >= minimumOverlap else { return 0 }
        let step = max(1, lhs.width / 180)
        var best = 0
        var bestScore = Double.greatestFiniteMagnitude
        // Large overlaps are common for slow trackpad scrolling, so search
        // from the largest to the smallest and keep the first equally good
        // candidate.  Sampling four rows per candidate keeps this cheap.
        for overlap in stride(from: maximum, through: minimumOverlap, by: -1) {
            let samples = min(5, overlap)
            var score = 0.0
            for sample in 0..<samples {
                let offset = samples == 1 ? 0 : sample * (overlap - 1) / (samples - 1)
                score += lhs.difference(
                    to: rhs,
                    row: lhs.height - overlap + offset,
                    otherRow: offset,
                    sampleStep: step
                )
            }
            score /= Double(samples)
            if score < bestScore {
                bestScore = score
                best = overlap
            }
        }
        return bestScore <= tolerance ? best : 0
    }

    static func stitch(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return first }
        guard images.allSatisfy({ $0.width == first.width }) else { return nil }
        var overlaps: [Int] = []
        var totalHeight = first.height
        for index in 1..<images.count {
            let overlap = bestOverlap(previous: images[index - 1], current: images[index])
            overlaps.append(overlap)
            totalHeight += images[index].height - overlap
        }
        guard let context = CGContext(
            data: nil,
            width: first.width,
            height: max(1, totalHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: first.width, height: totalHeight))

        // CGImage drawing uses a bottom-left graphics origin.  Placing the
        // first frame at the top and each later frame below it gives the
        // expected visual order for a page scrolled downwards.
        var top = totalHeight
        for (index, image) in images.enumerated() {
            let overlap = index == 0 ? 0 : overlaps[index - 1]
            top -= index == 0 ? image.height : image.height - overlap
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: top, width: first.width, height: image.height))
        }
        return context.makeImage()
    }

    private static func raster(_ image: CGImage) -> Raster? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Raster(data: data, width: width, height: height, bytesPerRow: width * 4)
    }
}

enum ScreenCaptureObjectCutout {
    static func removeBackground(from image: CGImage) async throws -> CGImage {
        let sendable = SendableScreenshotImage(value: image)
        return try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: sendable.value, options: [:])
                try handler.perform([request])
                guard let observation = request.results?.first,
                      !observation.allInstances.isEmpty else {
                    throw ScreenCaptureError.captureFailed("No foreground object was detected.")
                }
                let maskBuffer = try observation.generateScaledMaskForImage(
                    forInstances: observation.allInstances,
                    from: handler
                )
                let source = CIImage(cgImage: sendable.value)
                let mask = CIImage(cvPixelBuffer: maskBuffer)
                    .cropped(to: source.extent)
                let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                    .cropped(to: source.extent)
                let result = source.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: background,
                    kCIInputMaskImageKey: mask
                ])
                let context = CIContext(options: [.cacheIntermediates: false])
                guard let output = context.createCGImage(result, from: source.extent) else {
                    throw ScreenCaptureError.captureFailed("The foreground mask could not be rendered.")
                }
                return output
            }
        }.value
    }
}

enum ScreenCaptureQRCode {
    static func detect(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .filter { !$0.isEmpty }
    }
}

private struct SendableScreenshotImage: @unchecked Sendable {
    let value: CGImage
}
