import AppKit
import Foundation
import Testing
@testable import MacPilot

struct ScrollingCaptureTests {
    @Test func stitchesEveryRowInPageOrder() throws {
        let output = try #require(ScreenCaptureVerticalStitcher.stitch([
            pageImage(start: 0), pageImage(start: 40), pageImage(start: 80)
        ]))
        #expect(output.height == 200)
        let expected = NSBitmapImageRep(cgImage: pageImage(start: 0, height: 200))
        let actual = NSBitmapImageRep(cgImage: output)
        for row in 0..<200 {
            let lhs = try #require(expected.colorAt(x: 12, y: row)?.usingColorSpace(.deviceRGB))
            let rhs = try #require(actual.colorAt(x: 12, y: row)?.usingColorSpace(.deviceRGB))
            #expect(abs(lhs.redComponent - rhs.redComponent) < 0.01)
            #expect(abs(lhs.blueComponent - rhs.blueComponent) < 0.01)
        }
    }

    @Test func identicalFramesDoNotGrowTheOutput() throws {
        let first = pageImage(start: 0)
        let output = try #require(ScreenCaptureVerticalStitcher.stitch([first, first, first]))
        #expect(output.height == first.height)
    }

    @Test func unrelatedFramesAreRejectedInsteadOfConcatenated() {
        #expect(ScreenCaptureVerticalStitcher.stitch([pageImage(start: 0), pageImage(start: 500)]) == nil)
    }

    @Test func differentOriginalWidthsCannotMatchAfterDownsampling() {
        #expect(ScreenCaptureVerticalStitcher.bestOverlap(
            previous: pageImage(start: 0, width: 300), current: pageImage(start: 40, width: 301)
        ) == 0)
    }

    @Test @MainActor func stationarySamplingDoesNotConsumeTheBudget() async {
        let image = pageImage(start: 0)
        let session = ScrollingCaptureSession(initialImage: image) { image }
        for _ in 0..<35 { await session.sample() }
        #expect(session.acceptedFrameCount == 1)
        #expect(!session.reachedLimit)
        session.cancel()
    }

    @Test @MainActor func rejectedFrameCanBeRecoveredByScrollingBack() async {
        let viewport = ScrollingTestViewport(start: 500)
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) { pageImage(start: viewport.start) }
        await session.sample()
        #expect(session.needsSmallerScroll)
        #expect(session.acceptedFrameCount == 1)
        viewport.start = 40
        await session.sample()
        #expect(!session.needsSmallerScroll)
        #expect(session.acceptedFrameCount == 2)
        session.cancel()
    }

    @Test @MainActor func cancellationDiscardsAnInFlightCapture() async {
        var pending: CheckedContinuation<CGImage, Never>?
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) {
            await withCheckedContinuation { pending = $0 }
        }
        let task = Task { await session.sample() }
        while pending == nil { await Task.yield() }
        session.cancel()
        pending?.resume(returning: pageImage(start: 40))
        await task.value
        #expect(session.acceptedFrameCount == 0)
        #expect(session.isClosed)
        #expect(await session.finish() == nil)
    }

    @Test @MainActor func doneWaitsForAnInFlightFrameAndSamplesTheFinalViewport() async throws {
        var pending: CheckedContinuation<CGImage, Never>?
        var captures = 0
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) {
            captures += 1
            if captures == 1 {
                return await withCheckedContinuation { pending = $0 }
            }
            return pageImage(start: 80)
        }
        let sampling = Task { await session.sample() }
        while pending == nil { await Task.yield() }
        let finishing = Task { await session.finish() }
        while !session.isFinishing { await Task.yield() }
        pending?.resume(returning: pageImage(start: 40))
        await sampling.value
        let output = try #require(await finishing.value)
        #expect(captures == 2)
        #expect(output.height == 200)
        session.cancel()
    }

    @Test @MainActor func cancellationDuringDoneCannotReturnAnImage() async {
        var pending: CheckedContinuation<CGImage, Never>?
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) {
            await withCheckedContinuation { pending = $0 }
        }
        let finishing = Task { await session.finish() }
        while pending == nil { await Task.yield() }
        session.cancel()
        pending?.resume(returning: pageImage(start: 40))
        #expect(await finishing.value == nil)
        #expect(session.acceptedFrameCount == 0)
    }

    @Test @MainActor func failedFinalAlignmentKeepsTheSessionAvailableForRetry() async {
        let viewport = ScrollingTestViewport(start: 500)
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) { pageImage(start: viewport.start) }
        #expect(await session.finish() == nil)
        #expect(!session.isFinishing)
        viewport.start = 40
        let output = await session.finish()
        #expect(output?.height == 160)
        session.cancel()
    }

    @Test @MainActor func sessionOutputAndPreviewContainOnlyCommittedRows() async throws {
        var captures = 0
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) {
            captures += 1
            return pageImage(start: captures == 1 ? 40 : 80)
        }
        await session.preparePreview()
        await session.sample()
        await session.sample()
        let output = try #require(await session.finish())
        #expect(output.height == 200)
        #expect(session.outputHeight == 200)
        #expect(session.previewImage?.height == 200)
        try expectRows(output, match: pageImage(start: 0, height: 200))
        session.cancel()
        #expect(session.previewImage == nil)
    }

    @Test func fixedHeadersAndFootersAreExcludedFromTheContentStrip() throws {
        let stitcher = ScrollingCaptureStitcher()
        _ = stitcher.start(with: pageImage(start: 0, width: 320, height: 400, header: 40, footer: 24))
        let update = try #require(stitcher.append(
            pageImage(start: 80, width: 320, height: 400, header: 40, footer: 24),
            maxOutputHeight: 2_000, renderMergedImage: false
        ))
        #expect(update.acceptedFrameCount == 2)
        let output = try #require(stitcher.mergedImage())
        #expect(output.height == 416)
        try expectRows(output, match: pageImage(start: 0, width: 320, height: 416))
    }

    @Test func upwardCaptureKeepsDocumentOrder() throws {
        let stitcher = ScrollingCaptureStitcher()
        _ = stitcher.start(with: pageImage(start: 80, width: 320, height: 400))
        _ = stitcher.append(pageImage(start: 40, width: 320, height: 400), maxOutputHeight: 2_000)
        let update = try #require(stitcher.append(pageImage(start: 0, width: 320, height: 400), maxOutputHeight: 2_000))
        #expect(update.acceptedFrameCount == 3)
        let output = try #require(stitcher.mergedImage())
        #expect(output.height == 480)
        try expectRows(output, match: pageImage(start: 0, width: 320, height: 480))
    }

    @Test @MainActor func sampleDuringAnInFlightCaptureQueuesTheNewestViewport() async {
        var pending: CheckedContinuation<CGImage, Never>?
        var captures = 0
        let session = ScrollingCaptureSession(initialImage: pageImage(start: 0)) {
            captures += 1
            if captures == 1 { return await withCheckedContinuation { pending = $0 } }
            return pageImage(start: 80)
        }
        let first = Task { await session.sample() }
        while pending == nil { await Task.yield() }
        let second = Task { await session.sample() }
        // Give the second caller a chance to coalesce its pending request.
        for _ in 0..<10 { await Task.yield() }
        pending?.resume(returning: pageImage(start: 40))
        await first.value
        await second.value
        #expect(captures == 2)
        #expect(session.acceptedFrameCount == 3)
        #expect(session.outputHeight == 200)
        session.cancel()
    }

    @Test func previewBoundsAndHeightLimitPreserveTheLastAcceptedStrip() throws {
        let stitcher = ScrollingCaptureStitcher()
        _ = stitcher.start(with: pageImage(start: 0, width: 320, height: 400))
        let update = try #require(stitcher.append(pageImage(start: 80, width: 320, height: 400), maxOutputHeight: 440, renderMergedImage: false))
        if case .reachedHeightLimit = update.outcome {} else { Issue.record("Expected the output height limit") }
        #expect(update.outputHeight == 440)
        let preview = try #require(stitcher.previewImage(maxPixelWidth: 80, maxPixelHeight: 100))
        #expect(preview.width <= 80)
        #expect(preview.height <= 100)
        let output = try #require(stitcher.mergedImage())
        try expectRows(output, match: pageImage(start: 0, width: 320, height: 440))
    }

    @Test func upwardHeightLimitKeepsRowsAdjacentToTheExistingContent() throws {
        let stitcher = ScrollingCaptureStitcher()
        _ = stitcher.start(with: pageImage(start: 80, width: 320, height: 400))
        let update = try #require(stitcher.append(pageImage(start: 0, width: 320, height: 400), maxOutputHeight: 440))
        #expect(update.outputHeight == 440)
        let output = try #require(stitcher.mergedImage())
        try expectRows(output, match: pageImage(start: 40, width: 320, height: 440))
    }
}

@MainActor
private final class ScrollingTestViewport {
    var start: Int
    init(start: Int) { self.start = start }
}

private func expectRows(_ output: CGImage, match expected: CGImage) throws {
    #expect(output.width == expected.width)
    #expect(output.height == expected.height)
    guard output.width == expected.width, output.height == expected.height else { return }
    let actual = NSBitmapImageRep(cgImage: output)
    let reference = NSBitmapImageRep(cgImage: expected)
    for row in 0..<output.height {
        let lhs = try #require(reference.colorAt(x: output.width / 2, y: row)?.usingColorSpace(.deviceRGB))
        let rhs = try #require(actual.colorAt(x: output.width / 2, y: row)?.usingColorSpace(.deviceRGB))
        #expect(abs(lhs.redComponent - rhs.redComponent) < 0.01)
        #expect(abs(lhs.greenComponent - rhs.greenComponent) < 0.01)
        #expect(abs(lhs.blueComponent - rhs.blueComponent) < 0.01)
    }
}

/// Each page row has a unique deterministic color; an incorrect overlap or
/// vertical flip changes the pixel assertions, even if output size is right.
private func pageImage(start: Int, width: Int = 24, height: Int = 120, header: Int = 0, footer: Int = 0) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for row in 0..<height {
        var hash = UInt64(row < header ? 1_000_000 + row : row >= height - footer ? 2_000_000 + row : start + row - header)
        hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        for x in 0..<width {
            let offset = (row * width + x) * 4
            pixels[offset] = UInt8(truncatingIfNeeded: hash >> 32)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: hash >> 40)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: hash >> 48)
        }
    }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent
    )!
}
