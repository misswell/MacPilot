import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacPilot

enum ImageViewerFixture {
    static func withFolder<Value>(_ body: (URL) throws -> Value) throws -> Value {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    static func bitmap(_ width: Int = 1200, _ height: Int = 800) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    static func image(in folder: URL, named name: String, type: UTType = .png,
                      properties: [CFString: Any] = [:]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try bitmap(), properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    static func pdf(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("multi.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 100, height: 150)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for page in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: CGFloat(page) / 4, alpha: 1))
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

struct ImageViewerRenderingTests {
    @Test func nativeImageFormatsDownsampleWithoutChangingSourceDimensions() throws {
        let supportedWriters = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        try ImageViewerFixture.withFolder { folder in
            for type in [UTType.jpeg, .png, .tiff, .heic] where supportedWriters.contains(type.identifier) {
                let file = try ImageViewerFixture.image(in: folder, named: "sample.\(type.preferredFilenameExtension!)", type: type)
                let frame = try ImageViewerPipeline.render(.init(url: file, pixels: 300),
                                                           sketch: ImageViewerSketchPreview(), cancelled: { false })
                #expect(frame.originalSize == CGSize(width: 1200, height: 800))
                #expect(frame.image.width == 300)
                #expect(frame.image.height == 200)
                #expect(frame.byteCost == frame.image.bytesPerRow * frame.image.height)
            }
        }
    }

    @Test func distinguishesUnreadableCorruptAndUnsupportedDocuments() throws {
        try ImageViewerFixture.withFolder { folder in
            let sketch = ImageViewerSketchPreview()
            let photo = folder.appendingPathComponent("broken.jpg")
            #expect(throws: ImageViewerReadError.unreadable) {
                try ImageViewerPipeline.render(.init(url: photo, pixels: 512), sketch: sketch, cancelled: { false })
            }
            try Data([1, 2, 3]).write(to: photo)
            #expect(throws: ImageViewerReadError.damaged) {
                try ImageViewerPipeline.render(.init(url: photo, pixels: 512), sketch: sketch, cancelled: { false })
            }
            let unknown = folder.appendingPathComponent("unknown.xyz")
            try Data([1, 2, 3]).write(to: unknown)
            #expect(throws: ImageViewerReadError.unsupported) {
                try ImageViewerPipeline.render(.init(url: unknown, pixels: 512), sketch: sketch, cancelled: { false })
            }
            #expect(ImageViewerFileKind.isCandidate(folder.appendingPathComponent("camera.nef")))
        }
    }

    @Test func gifAndWebPDecodeSecondFrameAndReportContainerTiming() throws {
        try ImageViewerFixture.withFolder { folder in
            let gif = folder.appendingPathComponent("test.gif")
            let dest = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil))
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2]] as CFDictionary)
            for delay in [0.1, 0.25] {
                CGImageDestinationAddImage(dest, try ImageViewerFixture.bitmap(16, 8),
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            try #require(CGImageDestinationFinalize(dest))
            let webp = folder.appendingPathComponent("test.webp")
            let bytes = try #require(Data(base64Encoded:
                "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAD/////AgBBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAPoAAABWUDhMDwAAAC8BQAAABxDR//4HIqL/AQA="))
            try bytes.write(to: webp)
            for file in [gif, webp] {
                let frame = try ImageViewerPipeline.render(.init(url: file, frame: 1, pixels: 16),
                                                           sketch: ImageViewerSketchPreview(), cancelled: { false })
                #expect(frame.frameCount == 2)
                #expect(abs(frame.delay - 0.25) < 0.005)
                #expect(frame.repeatCount == 2)
            }
        }
    }

    @Test func pdfRendersOnlyTheRequestedPageAndHonorsCancellation() throws {
        try ImageViewerFixture.withFolder { folder in
            let file = try ImageViewerFixture.pdf(in: folder)
            let request = ImageViewerRenderRequest(url: file, page: 2, pixels: 300)
            let frame = try ImageViewerPDFRenderer.render(request, cancelled: { false })
            #expect(frame.pageCount == 3)
            #expect(frame.originalSize == CGSize(width: 100, height: 150))
            #expect(frame.image.width == 200)
            #expect(frame.image.height == 300)
            #expect(throws: CancellationError.self) { try ImageViewerPDFRenderer.render(request, cancelled: { true }) }
        }
    }

    @Test func sketchPackageReadsOnlyARegularPreviewInsideThePackage() throws {
        try ImageViewerFixture.withFolder { folder in
            let package = folder.appendingPathComponent("document.sketch", isDirectory: true)
            let previews = package.appendingPathComponent("previews", isDirectory: true)
            try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
            let outside = try ImageViewerFixture.image(in: folder, named: "outside.png")
            let link = previews.appendingPathComponent("preview.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let sketch = ImageViewerSketchPreview()
            #expect(sketch.data(for: package, cancelled: { false }) == nil)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.copyItem(at: outside, to: link)
            #expect(sketch.data(for: package, cancelled: { true }) == nil)
            let rendered = try ImageViewerPipeline.render(.init(url: package, pixels: 256), sketch: sketch, cancelled: { false })
            #expect(rendered.image.width == 256)
        }
    }

    @Test func cacheEvictsLeastRecentlyUsedAtActualByteLimit() {
        var cache = ImageViewerCache<String, Int>(limit: 10, countLimit: 4)
        cache.insert(1, for: "recent", cost: 4)
        cache.insert(2, for: "stale", cost: 4)
        #expect(cache.value(for: "recent") == 1)
        cache.insert(3, for: "new", cost: 5)
        cache.insert(4, for: "oversized", cost: 11)
        #expect(cache.value(for: "stale") == nil)
        #expect(cache.value(for: "recent") == 1)
        #expect(cache.value(for: "new") == 3)
        #expect(cache.cost == 9)
        cache.clear()
        #expect(cache.cost == 0)
    }
}
