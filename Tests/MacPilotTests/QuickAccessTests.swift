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

    @MainActor @Test func shortcutConfigEncodesAndDecodesCarbonModifiers() throws {
        let original = ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.displayString.contains("⌘"))
    }

    @MainActor @Test func keyboardLayoutTranslatorReceivesAlignedCompleteOffsetBlob() {
        let headerSize = MemoryLayout<UCKeyboardLayout>.size
        var layoutData = Data(repeating: 0, count: headerSize + 32)
        let tailOffset = headerSize + 19
        layoutData[tailOffset] = 0xA7
        let expectedLength = layoutData.count
        var receivedAlignedPointer = false
        var receivedCompleteBlob = false
        var receivedTailByte = false

        let translated = ShortcutConfig.printableKeyDisplayString(
            for: UInt32(kVK_ANSI_C),
            layoutData: layoutData
        ) { layout, byteCount, _, _, output, length in
            receivedAlignedPointer = Int(bitPattern: UnsafeRawPointer(layout))
                .isMultiple(of: MemoryLayout<UCKeyboardLayout>.alignment)
            receivedCompleteBlob = byteCount == expectedLength
            let bytes = UnsafeRawBufferPointer(start: layout, count: byteCount)
            receivedTailByte = bytes[tailOffset] == 0xA7
            output[0] = UniChar("C".utf16.first!)
            length = 1
            return noErr
        }

        #expect(translated == "C")
        #expect(receivedAlignedPointer)
        #expect(receivedCompleteBlob)
        #expect(receivedTailByte)
    }

    @MainActor @Test func keyboardLayoutTranslatorRejectsDataShorterThanItsHeader() {
        var translatorCalled = false
        let translated = ShortcutConfig.printableKeyDisplayString(
            for: UInt32(kVK_ANSI_C),
            layoutData: Data(repeating: 0, count: MemoryLayout<UCKeyboardLayout>.size - 1)
        ) { _, _, _, _, _, _ in
            translatorCalled = true
            return noErr
        }

        #expect(translated == nil)
        #expect(!translatorCalled)
    }

    @MainActor @Test func keyboardLayoutTranslatorRejectsKeyCodesOutsideCarbonRange() {
        var translatorCalled = false
        let translated = ShortcutConfig.printableKeyDisplayString(
            for: .max,
            layoutData: Data(repeating: 0, count: MemoryLayout<UCKeyboardLayout>.size)
        ) { _, _, _, _, _, _ in
            translatorCalled = true
            return noErr
        }

        #expect(translated == nil)
        #expect(!translatorCalled)
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

    @Test @MainActor func firstPressOnAPinDragsInsteadOfOnlyActivatingTheWindow() {
        // 贴图浮在别的 App 上时窗口是 inactive 的。拖动面若拒绝 first mouse，
        // 第一次按下只会把窗口激活、事件被吞掉，用户得再拖一次才动。
        let view = QuickAccessPinWindowDragNSView(
            isEnabled: true,
            onDoubleClick: {},
            onContextMenu: { _ in }
        )
        #expect(view.acceptsFirstMouse(for: nil))

        // 锁定的贴图要让点击穿过去，不能替下面的 App 接住这一下。
        view.isEnabled = false
        #expect(!view.acceptsFirstMouse(for: nil))
    }

    @Test @MainActor func pinHoverYieldsThePointerToAWindowDrawnOnTopOfIt() {
        // 贴图的 hover 只认「指针真的落在贴图上」。WPS 之类下拉选项悬在贴图上方时，
        // 指针虽然在贴图 frame 内，像素却属于那个弹窗；贴图一旦现身、抢下 key window，
        // 弹窗就被关掉，用户永远点不到被贴图盖住的那一项。
        let pin = QuickAccessPinHoverCoverage.Surface(
            windowNumber: 100,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        let popup = QuickAccessPinHoverCoverage.Surface(
            windowNumber: 200,
            frame: CGRect(x: 150, y: 150, width: 300, height: 300)
        )
        let overlappingPoint = CGPoint(x: 170, y: 170)

        // 扫描表自前向后排序：弹窗在前就是弹窗的像素。
        #expect(!QuickAccessPinHoverCoverage.isPinExposed(
            at: overlappingPoint, pinWindowNumber: 100, surfaces: [popup, pin]
        ))
        // 贴图在前时一切照旧，hover 该来就来。
        #expect(QuickAccessPinHoverCoverage.isPinExposed(
            at: overlappingPoint, pinWindowNumber: 100, surfaces: [pin, popup]
        ))
        // 指针只在贴图里：没有别的东西盖住它。
        #expect(QuickAccessPinHoverCoverage.isPinExposed(
            at: CGPoint(x: 20, y: 20), pinWindowNumber: 100, surfaces: [popup, pin]
        ))
        // 读不到贴图自己（窗口列表短了一截）时不许把贴图打死，仍按几何判断走。
        #expect(QuickAccessPinHoverCoverage.isPinExposed(
            at: overlappingPoint, pinWindowNumber: 100, surfaces: []
        ))
    }

    @Test @MainActor func theDockContainerDoesNotCountAsCoveringAPin() {
        // 主屏上 Dock 进程有一个铺满整屏的容器窗口（layer 20），贴图只有 layer 5。
        // 覆盖扫描按层级从前到后取第一个包含指针的窗口；把 Dock 的容器当成遮挡，
        // 主屏上任何位置的贴图都永远不 hover —— 副屏没有这个窗口，所以此前
        // 只有副屏正常。
        let dockPID: pid_t = 4_242
        let pinNumber: CGWindowID = 100
        let mainHeight: CGFloat = 1080
        let pointer = CGPoint(x: 500, y: 400)

        func entry(number: CGWindowID, ownerPID: pid_t, level: Int, bounds: CGRect) -> [String: Any] {
            [
                kCGWindowNumber as String: NSNumber(value: number),
                kCGWindowOwnerPID as String: NSNumber(value: ownerPID),
                kCGWindowLayer as String: NSNumber(value: level),
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowBounds as String: bounds.dictionaryRepresentation
            ]
        }

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let dock = entry(
            number: 1, ownerPID: dockPID, level: dockLevel,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        // Quartz bounds 换算回 AppKit 后正好落在 pointer 上：y = 1080 - (480 + 300) = 300。
        let pin = entry(
            number: pinNumber, ownerPID: 8_888, level: 5,
            bounds: CGRect(x: 400, y: 480, width: 400, height: 300)
        )

        let pinOnly = QuickAccessPinHoverCoverage.surfaces(
            from: [dock, pin], mainDisplayHeight: mainHeight, dockPID: dockPID
        )
        #expect(pinOnly.count == 1)
        #expect(QuickAccessPinHoverCoverage.isPinExposed(
            at: pointer, pinWindowNumber: pinNumber, surfaces: pinOnly
        ))

        // Dock 自己弹出的菜单在弹层上，仍然是合法的遮挡。
        let dockMenu = entry(
            number: 2, ownerPID: dockPID, level: 101,
            bounds: CGRect(x: 450, y: 630, width: 200, height: 100)
        )
        let withMenu = QuickAccessPinHoverCoverage.surfaces(
            from: [dock, dockMenu, pin], mainDisplayHeight: mainHeight, dockPID: dockPID
        )
        #expect(withMenu.count == 2)
        #expect(!QuickAccessPinHoverCoverage.isPinExposed(
            at: pointer, pinWindowNumber: pinNumber, surfaces: withMenu
        ))

        // 别的 App 铺满屏幕的窗口仍然算遮挡：只放过 Dock 的容器窗口。
        let foreign = entry(
            number: 3, ownerPID: 9_999, level: dockLevel,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let foreignOnly = QuickAccessPinHoverCoverage.surfaces(
            from: [foreign, pin], mainDisplayHeight: mainHeight, dockPID: dockPID
        )
        #expect(!QuickAccessPinHoverCoverage.isPinExposed(
            at: pointer, pinWindowNumber: pinNumber, surfaces: foreignOnly
        ))
    }

    @Test @MainActor func pinCoverageSweepRunsOnEdgesNotOnEveryMouseMove() {
        // 盖没盖住要问 WindowServer，一次一趟全屏幕窗口列表；鼠标每秒上百个事件，
        // 所以只有「答案会变、而且贴图正要采取行动」的那一刻才值得问。
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        func shouldSweep(inside: Bool, crossed: Bool, isKey: Bool, isCovered: Bool, last: Date?) -> Bool {
            QuickAccessPinHoverCoverage.sweepIsWorthRunning(
                pointerIsInsideFrame: inside,
                didCrossIntoFrame: crossed,
                isKeyWindow: isKey,
                hoverIsSuppressed: isCovered,
                lastSweepAt: last,
                now: now
            )
        }

        // 刚进 frame：hover 正要亮起来，必须问，哪怕刚刚才问过。
        #expect(shouldSweep(inside: true, crossed: true, isKey: true, isCovered: false, last: now))
        // 已经暴露又已经是 key：下一个移动不会改变任何行为，一次都不问。
        #expect(!shouldSweep(inside: true, crossed: false, isKey: true, isCovered: false, last: now))
        // 还不是 key：下一个移动就会去抢 key window —— 那正是关掉别人弹窗的动作，必须先问；
        // 但同一个节流窗口里不重复问。
        #expect(shouldSweep(inside: true, crossed: false, isKey: false, isCovered: false, last: nil))
        #expect(!shouldSweep(
            inside: true, crossed: false, isKey: false, isCovered: false,
            last: now.addingTimeInterval(-QuickAccessPinHoverCoverage.reprobeInterval / 2)
        ))
        #expect(shouldSweep(
            inside: true, crossed: false, isKey: false, isCovered: false,
            last: now.addingTimeInterval(-QuickAccessPinHoverCoverage.reprobeInterval)
        ))
        // 被盖住时要按间隔继续问：弹窗关掉后，指针不必离开 frame 贴图也能活过来。
        #expect(shouldSweep(
            inside: true, crossed: false, isKey: true, isCovered: true,
            last: now.addingTimeInterval(-QuickAccessPinHoverCoverage.reprobeInterval)
        ))
        // 指针不在 frame 内，没有 hover 要决定。
        #expect(!shouldSweep(inside: false, crossed: false, isKey: false, isCovered: true, last: nil))
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
