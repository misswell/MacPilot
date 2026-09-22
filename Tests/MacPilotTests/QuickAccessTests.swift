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

    @Test func ocrFailureToastHasItsOwnCopyInBothLanguages() {
        // 识别失败与「没识别到文字」是两回事，两种语言都得各自的文案。
        #expect(AppText.value("scOCRFailed", language: .simplifiedChinese) == "文字识别失败。")
        #expect(AppText.value("scOCRFailed", language: .english) == "Text recognition failed.")
        #expect(AppText.value("scOCRFailed", language: .english)
            != AppText.value("scOCRNoText", language: .english))
    }

    @Test @MainActor func zoomHUDBecomesVisibleWhileZooming() {
        // 滚轮、pinch 和 HUD 自己的 +/− 最后都落在缩放值上，
        // 所以「刚刚缩放过」就是 HUD 出现的信号。
        let state = Self.makeZoomablePinState()
        #expect(!state.isZoomInteractionLive)

        _ = state.applyZoomStep(PinnedScreenshotChromeStyle.zoomHUDStep)
        #expect(state.isZoomInteractionLive)
        #expect(QuickAccessPinZoomHUDPolicy.isVisible(pointerInZone: false, interactionIsLive: true))

        // 指针探到图片底部中央，也是把它留下来的正当理由。
        let zone = QuickAccessPinZoomHUDPolicy.zone(in: CGSize(width: 900, height: 600))
        #expect(zone.contains(CGPoint(x: 450, y: 588)))
        #expect(QuickAccessPinZoomHUDPolicy.isVisible(pointerInZone: true, interactionIsLive: false))
    }

    @Test func zoomHUDHidesWhenIdle() {
        // 静止下来的贴图必须只是一张图：HUD 是缩放期间的读数，不是常驻控件。
        #expect(!QuickAccessPinZoomHUDPolicy.isVisible(pointerInZone: false, interactionIsLive: false))

        let zone = QuickAccessPinZoomHUDPolicy.zone(in: CGSize(width: 900, height: 600))
        #expect(!zone.contains(CGPoint(x: 20, y: 20)))
        #expect(!zone.contains(CGPoint(x: 20, y: 588)))
        #expect(zone.maxY == 600)
        // 读数只在底部一小条里等着，不会盖住画面中间。
        #expect(zone.height <= 600 * 0.1)

        // 它自己会走：出现后由一个有限的时间决定何时淡掉。
        #expect(PinnedScreenshotChromeStyle.zoomHUDIdleInterval > 0)
    }

    @MainActor
    private static func makeZoomablePinState(
        image size: NSSize = NSSize(width: 900, height: 600)
    ) -> QuickAccessPinWindowState {
        let image = NSImage(size: size)
        return QuickAccessPinWindowState(
            id: UUID(),
            url: nil,
            image: image,
            thumbnail: image,
            baseSize: CGSize(width: size.width, height: size.height),
            maxSize: CGSize(width: 1_440, height: 920)
        )
    }

    @Test @MainActor func zoomOnlyOffersReachableScales() {
        // 1000x700 on a 1440x920 stage: the screen fit caps the top at 131%,
        // the interactive floor leaves the 40% bottom intact.
        let state = Self.makeZoomablePinState(image: NSSize(width: 1_000, height: 700))
        #expect(Int((state.minimumZoomFactor * 100).rounded()) == 40)
        #expect(Int((state.maximumZoomFactor * 100).rounded(.down)) == 131)

        for percent in [40, 100, 131] {
            let size = state.setZoomPercent(percent)
            #expect(state.zoomPercent == percent)
            #expect(abs(size.width - 1_000 * CGFloat(percent) / 100) < 0.5)
        }

        // Shrinking the stage below the current scale pulls the ceiling in but
        // never drops the value the HUD is showing.
        _ = state.updateSizing(baseSize: CGSize(width: 1_000, height: 700), maxSize: CGSize(width: 1_010, height: 707))
        #expect(state.zoomFactor >= state.minimumZoomFactor)
        #expect(state.zoomFactor <= state.maximumZoomFactor)
    }

    @Test @MainActor func zoomStepNeverEscapesReachableScale() {
        // +/− 每次 10%，一路按到底也不能越过可达范围：缩到底还能停住，
        // 放到头也不会越过屏幕能装下的那个比例。
        let state = Self.makeZoomablePinState(image: NSSize(width: 1_000, height: 700))
        let step = PinnedScreenshotChromeStyle.zoomHUDStep

        for _ in 0..<40 { _ = state.applyZoomStep(-step) }
        #expect(state.zoomFactor == state.minimumZoomFactor)
        #expect(state.zoomPercent == 40)

        for _ in 0..<60 { _ = state.applyZoomStep(step) }
        #expect(state.zoomFactor == state.maximumZoomFactor)
        #expect(state.zoomPercent == 131)
        #expect(state.displaySize.width <= 1_440 + 0.5)
        #expect(state.displaySize.height <= 920 + 0.5)
    }

    @Test func pinOpensAtTheSizeItWasCaptured() {
        // 默认贴图 = 实际大小：小图不再被抬到「可交互最小尺寸」，大图只在屏幕
        // 装不下时按比例缩，上限就是屏幕能装下的那块地方。
        let screen = CGSize(width: 1_512, height: 950)

        let small = QuickAccessPinWindowSizing.sizes(
            for: CGSize(width: 150, height: 100), visibleSize: screen)
        #expect(small.base == CGSize(width: 150, height: 100))

        let fits = QuickAccessPinWindowSizing.sizes(
            for: CGSize(width: 900, height: 600), visibleSize: screen)
        #expect(fits.base == CGSize(width: 900, height: 600))

        let large = QuickAccessPinWindowSizing.sizes(
            for: CGSize(width: 3_000, height: 1_000), visibleSize: screen)
        #expect(large.max == CGSize(width: 1_512 - 48, height: 950 - 48))
        #expect(large.base.width <= large.max.width + 0.5)
        #expect(large.base.height <= large.max.height + 0.5)
        // 缩的是比例，不是把图压扁。
        #expect(abs(large.base.width / large.base.height - 3) < 0.01)
    }

    @Test @MainActor func smallPinKeepsHundredPercentReachable() {
        // 小于交互下限时，缩放下限不能被那个下限顶过 100%：否则「放大」会从缩放
        // 钳制里偷偷回来，`resetZoom()` 也不再是截下来的那个尺寸。
        let image = NSImage(size: NSSize(width: 150, height: 100))
        let state = QuickAccessPinWindowState(
            id: UUID(),
            url: nil,
            image: image,
            thumbnail: image,
            baseSize: CGSize(width: 150, height: 100),
            maxSize: CGSize(width: 1_464, height: 902)
        )
        #expect(state.zoomPercent == 100)
        #expect(state.minimumZoomFactor == 1)
        #expect(state.displaySize == CGSize(width: 150, height: 100))

        // 放大依旧可以，但那是用户主动要的比例，不是打开时强加的。
        #expect(state.maximumZoomFactor == 2)
        #expect(state.setZoomPercent(200) == CGSize(width: 300, height: 200))
        #expect(state.resetZoom() == CGSize(width: 150, height: 100))
    }

    @Test @MainActor func pinChromeFollowsThePointerAndSurvivesTheDrag() {
        // 控制岛是 hover 才出现的 affordance；拖文件时窗口被藏起来、指针状态
        // 停在拖走的那一刻，岛不能从光标底下消失。
        #expect(QuickAccessPinChromeVisibility.isVisible(mouseInside: true, isDraggingFile: false))
        #expect(QuickAccessPinChromeVisibility.isVisible(mouseInside: false, isDraggingFile: true))
        #expect(!QuickAccessPinChromeVisibility.isVisible(mouseInside: false, isDraggingFile: false))
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
