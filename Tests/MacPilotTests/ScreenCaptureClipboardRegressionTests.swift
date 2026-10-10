import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

struct ScreenCaptureClipboardRegressionTests {
    private func makeImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func retinaCropUsesNegativeVirtualDisplayOrigin() throws {
        let image = try makeImage(
            width: 200,
            height: 100,
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        let screenFrame = CGRect(x: -200, y: -50, width: 100, height: 50)
        let selection = CGRect(x: -190, y: -45, width: 20, height: 10)
        let snapshot = FrozenDisplaySnapshot(
            displayID: 101,
            screenFrame: screenFrame,
            scaleFactor: 2,
            colorSpaceName: nil,
            image: image
        )
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let result = try session.cropImage(for: AreaSelectionResult(
            target: .rect(selection),
            displayID: 101,
            mode: .screenshot
        ))

        #expect(result.image.width == 40)
        #expect(result.image.height == 20)
        #expect(result.screenRect == selection)
    }

    @Test func rotatedPortraitDisplayCropUsesItsOwnFrameAndScale() throws {
        let image = try makeImage(
            width: 100,
            height: 200,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let screenFrame = CGRect(x: -1_000, y: 50, width: 50, height: 100)
        let selection = CGRect(x: -975, y: 75, width: 20, height: 30)
        let snapshot = FrozenDisplaySnapshot(
            displayID: 102,
            screenFrame: screenFrame,
            scaleFactor: 2,
            colorSpaceName: nil,
            image: image
        )
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let result = try session.cropImage(for: AreaSelectionResult(
            target: .rect(selection),
            displayID: 102,
            mode: .screenshot
        ))

        #expect(result.image.width == 40)
        #expect(result.image.height == 60)
        #expect(result.screenRect == selection)
    }

    @Test func mixedDisplayScaleCompositeKeepsEachDisplayAtItsGlobalPosition() throws {
        let retinaImage = try makeImage(
            width: 200,
            height: 200,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let standardImage = try makeImage(
            width: 100,
            height: 100,
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        let snapshots = [
            FrozenDisplaySnapshot(
                displayID: 201,
                screenFrame: CGRect(x: -100, y: 0, width: 100, height: 100),
                scaleFactor: 2,
                colorSpaceName: nil,
                image: retinaImage
            ),
            FrozenDisplaySnapshot(
                displayID: 202,
                screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                scaleFactor: 1,
                colorSpaceName: nil,
                image: standardImage
            )
        ]

        let session = FrozenAreaCaptureSession.fromSnapshots(snapshots)
        let selection = CGRect(x: -50, y: 20, width: 100, height: 40)
        let result = try session.cropCompositeImage(for: AreaSelectionResult(
            target: .rect(selection),
            displayID: 201,
            mode: .screenshot,
            displayIDs: [201, 202]
        ))
        let bitmap = NSBitmapImageRep(cgImage: result.image)
        let leftPixel = try #require(bitmap.colorAt(x: 20, y: 40)?.usingColorSpace(.deviceRGB))
        let rightPixel = try #require(bitmap.colorAt(x: 180, y: 40)?.usingColorSpace(.deviceRGB))

        #expect(result.image.width == 200)
        #expect(result.image.height == 80)
        #expect(result.screenRect == selection)
        #expect(leftPixel.redComponent > 0.8)
        #expect(rightPixel.blueComponent > 0.8)
    }
}
