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

    @MainActor
    @Test func quickAccessInsertsProvidedThumbnailBeforeFileExists() {
        let manager = QuickAccessManager.shared
        let previousEnabled = manager.isEnabled
        let previousAutoDismiss = manager.autoDismissEnabled
        manager.isEnabled = true
        manager.autoDismissEnabled = false
        manager.dismissAll()
        defer {
            manager.dismissAll()
            manager.autoDismissEnabled = previousAutoDismiss
            manager.isEnabled = previousEnabled
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-preview-\(UUID().uuidString).png")
        let thumbnail = NSImage(size: NSSize(width: 120, height: 80))
        let item = manager.addScreenshot(url: url, thumbnail: thumbnail)

        #expect(item?.url == url)
        #expect(item?.thumbnail.size == thumbnail.size)
        #expect(manager.items.first?.id == item?.id)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func shortcutConfigEncodesAndDecodesCarbonModifiers() throws {
        let original = ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.displayString.contains("⌘"))
    }

    @Test func ocrToastPreviewCollapsesAndTruncatesRecognizedText() {
        // OCR 复制后的轻提示只显示一行摘要，长文本必须被收敛。
        #expect(SmartCaptureToast.preview(of: "发票 金额\n合计 128.00 元") == "发票 金额 合计 128.00 元")
        #expect(SmartCaptureToast.preview(of: "   ") == "")

        let long = String(repeating: "识", count: 200)
        let preview = SmartCaptureToast.preview(of: long, limit: 20)
        #expect(preview == String(repeating: "识", count: 20) + "…")
        #expect(SmartCaptureToast.preview(of: long).count == 81)
    }

    @Test func zoomScrubKeepsPinChromeVisibleWhenTheDragOvershoots() {
        #expect(QuickAccessPinWindowChromeVisibility.isVisible(mouseInside: false, zoomScrubbing: true))
        #expect(QuickAccessPinWindowChromeVisibility.isVisible(mouseInside: true, zoomScrubbing: false))
        #expect(!QuickAccessPinWindowChromeVisibility.isVisible(mouseInside: false, zoomScrubbing: false))
    }

    @Test @MainActor func zoomScrubOnlyOffersReachableScales() {
        // 1000x700 on a 1440x920 stage: the screen fit caps the top at 131%,
        // the interactive floor leaves the 40% bottom intact.
        let image = NSImage(size: NSSize(width: 1_000, height: 700))
        let state = QuickAccessPinWindowState(
            id: UUID(),
            url: nil,
            image: image,
            thumbnail: image,
            baseSize: CGSize(width: 1_000, height: 700),
            maxSize: CGSize(width: 1_440, height: 920)
        )
        #expect(state.zoomScrubRange == 40...131)

        for percent in [40, 100, 131] {
            let size = state.setZoomPercent(percent)
            #expect(state.zoomPercent == percent)
            #expect(abs(size.width - 1_000 * CGFloat(percent) / 100) < 0.5)
        }

        // Shrinking the stage below the current scale pulls the ceiling in but
        // never drops the value the scrubber is showing.
        _ = state.updateSizing(baseSize: CGSize(width: 1_000, height: 700), maxSize: CGSize(width: 1_010, height: 707))
        #expect(state.zoomScrubRange.contains(state.zoomPercent))
        #expect(state.zoomScrubRange.lowerBound <= state.zoomScrubRange.upperBound)
    }

    @Test func zoomScrubStaysPutWhileTheWindowScales() {
        // Only the narrowest pins give up width; past that the capsule keeps a
        // constant width, which is what holds the thumb under the cursor.
        #expect(QuickAccessPinWindowSizing.zoomScrubWidth(for: 800) == QuickAccessPinWindowSizing.zoomScrubIdealWidth)
        #expect(QuickAccessPinWindowSizing.zoomScrubWidth(for: 1_440) == QuickAccessPinWindowSizing.zoomScrubIdealWidth)
        let narrowest = QuickAccessPinWindowSizing.minimumInteractiveSize.width
        #expect(QuickAccessPinWindowSizing.zoomScrubWidth(for: narrowest) == narrowest - QuickAccessPinWindowSizing.chromeReservedWidth)
        #expect(QuickAccessPinWindowSizing.zoomScrubWidth(for: narrowest) < QuickAccessPinWindowSizing.zoomScrubIdealWidth)
    }

    @Test func toastPathDetailKeepsTheFileNameAndAbbreviatesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inside = URL(fileURLWithPath: home + "/Pictures/MacPilot Screenshots/2026-09-20/MacPilot_a.png")
        let display = SmartCaptureToast.displayPath(for: inside)
        #expect(display.hasPrefix("~/"))
        #expect(display.hasSuffix("MacPilot_a.png"))
        #expect(SmartCaptureToast.displayPath(for: URL(fileURLWithPath: "/tmp/elsewhere.png")) == "/tmp/elsewhere.png")
    }

    /// 轻提示是模型层回调直接画的窗口：跑测试时它必须闭嘴，否则每个落盘用例都会在用户屏幕上闪一下。
    @Test func toastDetectsTheTestHost() {
        #expect(SmartCaptureToast.isTestHost)
    }
}
