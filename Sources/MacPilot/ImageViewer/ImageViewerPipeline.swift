import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageViewerReadError: Error {
    case unreadable, unsupported, damaged, tooLarge, lockedPDF, missingPreview

    var textKey: String {
        switch self {
        case .unreadable: "viewerUnreadable"
        case .unsupported: "viewerUnsupported"
        case .damaged: "viewerDamaged"
        case .tooLarge: "viewerTooLarge"
        case .lockedPDF: "viewerLocked"
        case .missingPreview: "viewerSketchMissing"
        }
    }
}

struct ImageViewerFrame: Sendable {
    let image: CGImage
    let originalSize: CGSize
    var pageCount = 1
    var frameCount = 1
    var delay = 0.1
    var repeatCount = 0

    var byteCost: Int { image.bytesPerRow * image.height }
}

struct ImageViewerRenderRequest: Hashable, Sendable {
    let url: URL
    var page = 1
    var frame = 0
    var pixels: Int
}

struct ImageViewerFileStamp: Hashable, Sendable {
    let url: URL
    let modified: Date
    let created: Date?
    let size: Int
    let inode: UInt64?

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        self.url = url
        self.modified = modified
        self.created = attributes[.creationDate] as? Date
        self.size = size
        self.inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

struct ImageViewerCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
    }

    private let limit: Int
    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0

    init(limit: Int, countLimit: Int) {
        self.limit = limit
        self.countLimit = countLimit
    }

    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost newCost: Int) {
        guard newCost > 0, newCost <= limit else { return }
        cost -= entries.removeValue(forKey: key)?.cost ?? 0
        clock &+= 1
        entries[key] = Entry(value: value, cost: newCost, access: clock)
        cost += newCost
        while cost > limit || entries.count > countLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            cost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
    }

    mutating func clear() {
        entries.removeAll()
        cost = 0
    }
}

enum ImageViewerPipeline {
    static let sourceByteLimit = 2 * 1024 * 1024 * 1024
    static let sourcePixelLimit: CGFloat = 250_000_000
    static let maximumDisplayPixels = 4096
    static let maximumPrintPixels = 7200

    static func source(_ url: URL, sketch: ImageViewerSketchPreview, cancelled: () -> Bool) throws -> CGImageSource {
        if cancelled() { throw CancellationError() }
        if url.pathExtension.lowercased() == "sketch" {
            guard let data = sketch.data(for: url, cancelled: cancelled),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ImageViewerReadError.missingPreview
            }
            return source
        }
        try checkFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) != nil else {
            let type = UTType(filenameExtension: url.pathExtension)?.identifier
            let types = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
            throw type.map(types.contains) == true ? ImageViewerReadError.damaged : ImageViewerReadError.unsupported
        }
        return source
    }

    static func checkFile(_ url: URL) throws {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              FileManager.default.isReadableFile(atPath: url.path) else { throw ImageViewerReadError.unreadable }
        guard size > 0 else { throw ImageViewerReadError.damaged }
        guard size <= sourceByteLimit else { throw ImageViewerReadError.tooLarge }
    }

    static func orientedSize(_ properties: [CFString: Any]) -> CGSize? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func render(_ request: ImageViewerRenderRequest, sketch: ImageViewerSketchPreview,
                       cancelled: () -> Bool) throws -> ImageViewerFrame {
        if request.url.pathExtension.lowercased() == "pdf" {
            return try ImageViewerPDFRenderer.render(request, cancelled: cancelled)
        }
        let source = try source(request.url, sketch: sketch, cancelled: cancelled)
        let type = CGImageSourceGetType(source).map { $0 as String }
        let animationKey = type == UTType.gif.identifier ? "{GIF}" : type == UTType.webP.identifier ? "{WebP}" : nil
        let count = animationKey == nil ? 1 : CGImageSourceGetCount(source)
        let index = count > 1 ? request.frame : CGImageSourceGetPrimaryImageIndex(source)
        guard (0..<CGImageSourceGetCount(source)).contains(index),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let size = orientedSize(properties) else { throw ImageViewerReadError.damaged }
        guard size.width * size.height <= sourcePixelLimit else { throw ImageViewerReadError.tooLarge }
        let limit = min(max(1, request.pixels), count > 1 ? 2048 : maximumPrintPixels)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        if cancelled() { throw CancellationError() }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ImageViewerReadError.damaged
        }
        if cancelled() { throw CancellationError() }
        var delay = 0.1
        var loops = 0
        if let animationKey, count > 1 {
            let timing = properties[animationKey as CFString] as? [String: Any]
            let raw = ((timing?["UnclampedDelayTime"] ?? timing?["DelayTime"]) as? NSNumber)?.doubleValue ?? 0.1
            delay = raw.isFinite && raw >= 0.02 ? min(600, raw) : 0.1
            let container = CGImageSourceCopyProperties(source, nil) as? [String: Any]
            let loop = (container?[animationKey] as? [String: Any])?["LoopCount"] as? NSNumber
            loops = max(0, loop?.intValue ?? (type == UTType.gif.identifier ? 1 : 0))
        }
        return ImageViewerFrame(image: image, originalSize: size, frameCount: count, delay: delay, repeatCount: loops)
    }
}
