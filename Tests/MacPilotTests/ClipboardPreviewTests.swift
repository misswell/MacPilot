import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MacPilot

/// 悬停详情预览：右侧详情列只在鼠标停够时间后出现，划走即收起。
@MainActor
struct ClipboardPreviewTests {
    private func makeTextItem(_ text: String) -> ClipboardItem {
        var item = ClipboardItem(contents: [
            ClipboardContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
        ])
        item.title = text
        return item
    }

    private func makeController(
        delay: TimeInterval = ClipboardPreviewController.defaultHoverDelay
    ) -> (ClipboardPreviewController, ManualClock) {
        let controller = ClipboardPreviewController()
        let clock = ManualClock()
        controller.hoverDelay = delay
        controller.schedule = { interval, work in clock.schedule(delay: interval, work: work) }
        return (controller, clock)
    }

    /// 手动放行的计时器。测试在同一轮主 Actor 里把延时「过完」，不依赖真实时钟：
    /// 同进程其他 @MainActor 套件会把主 Actor 队列堵上一两分钟，靠 `Task.sleep`
    /// 计时的用例在那种环境下只会误报。
    @MainActor
    private final class ManualClock {
        private var pending: [ClipboardPreviewController.Work] = []
        private(set) var delays: [TimeInterval] = []

        func schedule(delay: TimeInterval, work: @escaping ClipboardPreviewController.Work) {
            delays.append(delay)
            pending.append(work)
        }

        /// 放行最早的一段延时。
        func fireNext() {
            guard !pending.isEmpty else { return }
            pending.removeFirst()()
        }

        /// 按登记顺序放行全部延时（同一条链上先后登记的计时）。
        func fireAll() {
            let batch = pending
            pending.removeAll()
            for work in batch { work() }
        }
    }

    // MARK: - Timing

    @Test func previewOpensAfterHoveringForTheDelay() {
        #expect(ClipboardPreviewController.defaultHoverDelay == 1)

        let (controller, clock) = makeController()
        var signals: [Bool] = []
        controller.onVisibilityChange = { signals.append($0) }
        let item = makeTextItem("hello")

        controller.beginHover(item)
        // 停满一秒才展开：登记的第一段延时就是 hoverDelay。
        #expect(clock.delays == [1])
        #expect(controller.item == nil)
        #expect(signals.isEmpty)

        clock.fireNext()
        #expect(controller.item?.id == item.id)
        #expect(signals == [true])
    }

    @Test func briefHoverNeverOpensThePreview() {
        let (controller, clock) = makeController()
        var signals: [Bool] = []
        controller.onVisibilityChange = { signals.append($0) }
        let item = makeTextItem("hello")

        controller.beginHover(item)
        controller.endHover(item)
        clock.fireAll()

        #expect(controller.item == nil)
        #expect(signals.isEmpty)
    }

    @Test func hoveringOffARecordHidesThePreview() {
        let (controller, clock) = makeController()
        var signals: [Bool] = []
        controller.onVisibilityChange = { signals.append($0) }
        let item = makeTextItem("hello")

        controller.beginHover(item)
        clock.fireNext()

        controller.endHover(item)
        #expect(clock.delays == [1, ClipboardPreviewController.hideGrace])
        // 宽限期还没过：详情列要留着，指针可能只是擦到相邻行或列的交界处。
        #expect(controller.item?.id == item.id)
        #expect(signals == [true])

        clock.fireNext()
        #expect(signals == [true, false])
        // 详情列要等收起动画放完才从布局里移除，窗口才不会突然缺一块。
        #expect(controller.item?.id == item.id)

        clock.fireNext()
        #expect(controller.item == nil)
    }

    @Test func slidingToTheNextRecordRetargetsThePreview() {
        let (controller, clock) = makeController()
        var signals: [Bool] = []
        controller.onVisibilityChange = { signals.append($0) }
        let first = makeTextItem("first")
        let second = makeTextItem("second")

        controller.beginHover(first)
        clock.fireNext()
        #expect(controller.item?.id == first.id)

        // AppKit 相邻行之间可能先发 enter(B) 再发 exit(A)：后到的 exit(A)
        // 不能把 B 的计时器一起取消掉，否则贴着边界滑动就永远出不来详情。
        controller.beginHover(second)
        controller.endHover(first)
        #expect(signals == [true, false])
        #expect(controller.item?.id == first.id)

        clock.fireAll()
        #expect(controller.item?.id == second.id)
        #expect(signals == [true, false, true])
    }

    @Test func hoveringThePreviewSurfaceKeepsTheDetailOpen() {
        let (controller, clock) = makeController()
        var signals: [Bool] = []
        controller.onVisibilityChange = { signals.append($0) }
        let item = makeTextItem("hello")

        controller.beginHover(item)
        clock.fireNext()
        controller.endHover(item)
        controller.beginPreviewSurfaceHover()
        clock.fireAll()

        // 详情列里可以选文字，指针划过去不该把刚展开的详情收掉。
        #expect(controller.item?.id == item.id)
        #expect(signals == [true])

        controller.endPreviewSurfaceHover()
        #expect(signals == [true, false])
        clock.fireNext()
        #expect(controller.item == nil)
    }

    @Test func keyboardNavigationFollowsOnlyAfterHoverEngagedThePreview() {
        let (controller, clock) = makeController()
        let hovered = makeTextItem("hovered")
        let moved = makeTextItem("moved")

        // 纯键盘浏览（从未悬停）不会凭空撑开详情列。
        controller.followSelection(moved)
        #expect(controller.item == nil)

        controller.beginHover(hovered)
        clock.fireNext()
        controller.followSelection(moved)
        #expect(controller.item?.id == moved.id)

        // 键盘接管后，上一条迟到的 exit 不能再影响详情。
        controller.endHover(hovered)
        #expect(controller.item?.id == moved.id)
    }

    @Test func resetClearsPendingAndRunningTimers() {
        let (controller, clock) = makeController()
        var signals: [Bool] = []
        controller.onVisibilityChange = { signals.append($0) }
        let item = makeTextItem("hello")

        controller.beginHover(item)
        clock.fireNext()
        controller.endHover(item)
        controller.reset()

        #expect(controller.item == nil)
        #expect(signals == [true, false])

        clock.fireAll()
        #expect(controller.item == nil)
        #expect(signals == [true, false])
    }

    // MARK: - Detail payload

    @Test func textRecordPreviewsItsWholeBodyWithCounts() {
        let body = "第一行\n第二行\n第三行"
        let detail = ClipboardPreviewDetail(item: makeTextItem(body))

        #expect(detail.kind == .text)
        #expect(detail.text == body)
        #expect(detail.characterCount == body.count)
        #expect(detail.lineCount == 3)
        #expect(!detail.isTextTruncated)
    }

    @Test func longTextPreviewIsCappedAndSaysSo() {
        let body = String(repeating: "a", count: ClipboardPreviewDetail.textLimit + 500)
        let detail = ClipboardPreviewDetail(item: makeTextItem(body))

        #expect(detail.text?.count == ClipboardPreviewDetail.textLimit)
        #expect(detail.isTextTruncated)
        #expect(detail.characterCount == body.count)
    }

    @Test func linkRecordIsRecognisedByItsTitleNotItsData() {
        var item = makeTextItem("https://github.com/misswell/Saury.git")
        item.contents = [
            ClipboardContent(
                type: NSPasteboard.PasteboardType.html.rawValue,
                value: Data("<a href='x'>x</a>".utf8)
            )
        ]

        #expect(ClipboardContentKind(item: item) == .link)
    }

    @Test func richTextRecordFallsBackToItsPlainBodyForPreview() {
        let item = ClipboardItem(contents: [
            ClipboardContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("纯文本部分".utf8)),
            ClipboardContent(type: NSPasteboard.PasteboardType.html.rawValue, value: Data("<b>x</b>".utf8))
        ])
        let detail = ClipboardPreviewDetail(item: item)

        #expect(detail.kind == .richText)
        #expect(detail.text == "纯文本部分")
    }

    @Test func sentenceLikeTextIsNotMistakenForALink() {
        #expect(ClipboardContentKind.isLink("https://github.com/misswell/Saury.git") == true)
        #expect(ClipboardContentKind.isLink("存在一个 bug，就是我们刚才其实修复了但没有修复") == false)
        #expect(ClipboardContentKind.isLink("https://example.com a b c") == false)
    }

    @Test func imageRecordPreviewsADecodedImageWithItsRealDimensions() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 1_600,
            height: 900,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 900))
        let rendered = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))

        let item = ClipboardItem(contents: [
            ClipboardContent(type: NSPasteboard.PasteboardType.png.rawValue, value: png, size: png.count)
        ])
        let detail = ClipboardPreviewDetail(item: item)

        #expect(detail.kind == .image)
        #expect(detail.pixelSize == NSSize(width: 1_600, height: 900))
        #expect(detail.image != nil)
        #expect(detail.byteCount == png.count)
        // 详情图仍走有界解码，不把整张原图拉进内存。
        #expect((detail.image?.pixelSize.width ?? 0) <= 900)
    }

    @Test func fileRecordListsPathsInsteadOfDuplicatingThemAsText() {
        // 访达一次复制多个文件时写的是**一个** fileURL 数据块，里面一行一个 URL。
        let blob = "file:///tmp/one.txt\nfile:///tmp/two.txt"
        let item = ClipboardItem(contents: [
            ClipboardContent(
                type: NSPasteboard.PasteboardType.fileURL.rawValue,
                value: Data(blob.utf8),
                size: blob.utf8.count
            )
        ])
        let detail = ClipboardPreviewDetail(item: item)

        #expect(detail.kind == .files)
        #expect(detail.fileURLs.map(\.path) == ["/tmp/one.txt", "/tmp/two.txt"])
        #expect(detail.text == nil)
    }

    // MARK: - Row labels

    @Test func everyClipboardPanelLabelExistsInBothLanguages() {
        for key in [
            "clipboardItemCount",
            "clipboardHintSelect",
            "clipboardHintPaste",
            "clipboardHintCopy",
            "clipboardHintDelete",
            "clipboardKindText",
            "clipboardKindRichText",
            "clipboardKindFiles",
            "clipboardKindLink",
            "clipboardPreviewCharacters",
            "clipboardPreviewLines",
            "clipboardPreviewCopies",
            "clipboardPreviewDimensions",
            "clipboardPreviewFileCount",
            "clipboardPreviewTruncated",
            "clipboardPreviewEmpty",
        ] {
            let chinese = AppText.value(key, language: .simplifiedChinese)
            let english = AppText.value(key, language: .english)
            #expect(!chinese.isEmpty, "\(key)")
            #expect(!english.isEmpty, "\(key)")
            #expect(chinese != english, "\(key) was not translated")
        }
    }

    @Test func contentKindLabelsResolveToRealCopy() {
        for kind in [ClipboardContentKind.image, .files, .link, .richText, .text] {
            #expect(!AppText.value(kind.labelKey, language: .simplifiedChinese).isEmpty)
            #expect(!AppText.value(kind.labelKey, language: .english).isEmpty)
            #expect(!kind.symbolName.isEmpty)
        }
    }
}
