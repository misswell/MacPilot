import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

/// Coverage for the source-migrated Snapzy QuickAccess preview flow.
struct QuickAccessTests {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @MainActor
    @Test func tempCaptureSaveProducesAPngInsideTheTempDirectory() throws {
        let manager = TempCaptureManager.shared
        guard let url = manager.saveScreenshot(image(width: 40, height: 30)) else {
            Issue.record("temp screenshot save failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.isTempFile(url))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension.lowercased() == "png")
        #expect(try Data(contentsOf: url).isEmpty == false)
    }

    @MainActor
    @Test func quickAccessItemRoundTripsScreenshotAndVideoTypes() {
        let fileURL = URL(fileURLWithPath: "/tmp/preview.png")
        let screenshot = QuickAccessItem(url: fileURL, thumbnail: NSImage(size: NSSize(width: 10, height: 10)))
        #expect(screenshot.itemType == .screenshot)
        #expect(screenshot.isVideo == false)

        let video = QuickAccessItem(
            url: fileURL,
            thumbnail: NSImage(size: NSSize(width: 10, height: 10)),
            duration: 12.5
        )
        #expect(video.itemType == .video)
        #expect(video.isVideo)
        #expect(video.formattedDuration == "00:12s")
    }

    @Test func shortcutConfigEncodesAndDecodesCarbonModifiers() throws {
        let original = ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.displayString.contains("⌘"))
    }
}
