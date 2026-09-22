//
//  ClipboardPreview.swift
//  MacPilot
//
//  剪贴板悬停详情：内容种类判定、详情取值、悬停状态机与面板右侧预览列。
//

import AppKit
import SwiftUI

// MARK: - Content kind

/// 条目的内容种类。只依据 pasteboard 类型与已存标题判定，不解码任何内容数据，
/// 因此可以在列表的每一行上安全调用。
enum ClipboardContentKind: Hashable {
    case image
    case files
    case link
    case richText
    case text

    init(item: ClipboardItem) {
        let types = Set(item.contents.map(\.type))
        if !types.isDisjoint(with: ClipboardItem.imageTypeRawValues) {
            self = .image
        } else if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            self = .files
        } else if Self.isLink(item.title) {
            self = .link
        } else if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) {
            self = .richText
        } else {
            self = .text
        }
    }

    static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(" "), !text.contains("\n") else { return false }
        guard let scheme = URL(string: text)?.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "file", "mailto"].contains(scheme)
    }

    var symbolName: String {
        switch self {
        case .image: "photo"
        case .files: "doc.on.doc"
        case .link: "link"
        case .richText: "doc.richtext"
        case .text: "text.alignleft"
        }
    }

    var labelKey: String {
        switch self {
        case .image: "clipboardImageLabel"
        case .files: "clipboardKindFiles"
        case .link: "clipboardKindLink"
        case .richText: "clipboardKindRichText"
        case .text: "clipboardKindText"
        }
    }
}

// MARK: - Source application

/// bundle identifier → 可读应用名。列表与详情共用同一份缓存。
@MainActor
enum ClipboardAppNames {
    private static let cache = NSCache<NSString, NSString>()

    /// - Parameter shortenedTo: 列表里限长，详情里不限。
    static func displayName(for bundleIdentifier: String?, shortenedTo limit: Int? = nil) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) {
            return cached as String
        }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?
            .deletingPathExtension().lastPathComponent
        guard let name, !name.isEmpty else { return nil }
        cache.setObject(name as NSString, forKey: key)
        guard let limit else { return name }
        return name.shortened(to: limit)
    }
}

// MARK: - Detail payload

/// 悬停详情需要展示的全部内容。构造时会读取磁盘，只在条目真正被悬停满
/// 延时后调用一次，不参与列表的逐行渲染。
struct ClipboardPreviewDetail {
    static let textLimit = 4_000

    let kind: ClipboardContentKind
    let text: String?
    let isTextTruncated: Bool
    let characterCount: Int
    let lineCount: Int
    let image: NSImage?
    let pixelSize: NSSize?
    let fileURLs: [URL]
    let byteCount: Int

    init(item: ClipboardItem) {
        let kind = item.displayKind
        self.kind = kind
        self.byteCount = item.contentByteCount
        self.pixelSize = kind == .image ? item.imagePixelSize : nil
        self.fileURLs = kind == .files ? item.fileURLs : []
        self.image = kind == .image ? item.previewImage(maxPixelSize: 900) : nil

        let full: String
        switch kind {
        case .image, .files:
            // 图片与文件条目按各自的形态展示，不重复列一遍路径。
            full = ""
        case .link, .richText, .text:
            full = item.previewableText
        }
        self.characterCount = full.count
        self.lineCount = full.isEmpty ? 0 : full.components(separatedBy: "\n").count
        self.isTextTruncated = full.count > Self.textLimit
        self.text = full.isEmpty ? nil : String(full.prefix(Self.textLimit))
    }
}

// MARK: - Hover state machine

/// 悬停预览的状态机：在一条记录上停满 `hoverDelay` 才展开右侧详情列，
/// 划走即收起；移到相邻记录时重新计时。
@MainActor
final class ClipboardPreviewController: ObservableObject {
    static let defaultHoverDelay: TimeInterval = 1
    /// 指针离开某一行后给一点余量：划进右侧详情列不该把详情收掉（那里可以选文字），
    /// 但划向另一行会立刻收起并重新计时，所以余量不会被感知成迟钝。
    static let hideGrace: TimeInterval = 0.15
    /// 与 `NSWindow.setFrame(animate:)` 的时长对齐：收起动画放完后才把详情列从
    /// 布局里移除，否则内容会在窗口缩回去之前突然消失。
    static let collapseDuration: TimeInterval = 0.25

    /// 到点后要执行的动作。
    typealias Work = @MainActor @Sendable () -> Void
    /// 计时注入点：延时 `delay` 秒后执行 `work`。
    ///
    /// 生产用真实计时器；测试换成手动放行的实现，整条状态链就能在同一轮主 Actor 里
    /// 跑完。同进程其他 @MainActor 套件会把主 Actor 队列堵上百秒，靠 `Task.sleep`
    /// 计时的用例在那种环境下只会误报。
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ work: @escaping Work) -> Void

    @Published private(set) var item: ClipboardItem?

    /// 测试里会调短，生产固定用 `defaultHoverDelay`。
    var hoverDelay: TimeInterval = ClipboardPreviewController.defaultHoverDelay

    /// 面板据此展开/收起窗口宽度（详情列是窗口的一部分，不是浮层）。
    var onVisibilityChange: ((Bool) -> Void)?

    var schedule: Scheduler = ClipboardPreviewController.scheduleOnTimer

    private var hoveredID: ClipboardItem.ID?
    private var expanded = false
    /// 每段延时都带一个令牌：重新计时或清场时换掉令牌，旧的那一发到点后发现令牌
    /// 对不上就自行作废。注入的计时器因此只需要「延时后调用」，不需要支持取消。
    private var openToken = UUID()
    private var hideToken = UUID()
    private var collapseToken = UUID()

    // MARK: Rows

    func beginHover(_ item: ClipboardItem) {
        hoveredID = item.id
        let delay = hoverDelay
        let token = UUID()
        openToken = token
        hideToken = UUID()
        // 换行即离开上一条：先收起它，别把旧详情挂在新行的等待期上。
        hide()
        schedule(delay) { [weak self] in
            guard let self, self.openToken == token, self.hoveredID == item.id else { return }
            self.show(item)
        }
    }

    func endHover(_ item: ClipboardItem) {
        // 相邻行之间 enter(B) 可能先于 exit(A) 送达：已被新行接管时不能撤销它。
        guard hoveredID == item.id else { return }
        hoveredID = nil
        openToken = UUID()
        scheduleHide()
    }

    // MARK: Preview surface

    /// 指针进入详情列：保持当前详情。划得慢时收起可能已经启动，那就把窗口重新
    /// 撑开，而不是让它缩掉再重开一次。
    func beginPreviewSurfaceHover() {
        hideToken = UUID()
        guard item != nil else { return }
        collapseToken = UUID()
        setExpanded(true)
    }

    /// 指针离开详情列：没有落到新行上就收起。
    func endPreviewSurfaceHover() {
        hideToken = UUID()
        hide()
    }

    // MARK: Selection

    /// 详情列已经打开时，让键盘上下键的选中项接管预览（鼠标不再影响它）。
    func followSelection(_ item: ClipboardItem?) {
        guard hoveredID != nil || self.item != nil else { return }
        hoveredID = nil
        openToken = UUID()
        hideToken = UUID()
        if let item {
            show(item)
        } else {
            hide()
        }
    }

    /// 面板关闭/条目被选中：立即清场，不留收起动画。
    func reset() {
        hoveredID = nil
        openToken = UUID()
        hideToken = UUID()
        collapseToken = UUID()
        item = nil
        setExpanded(false)
    }

    // MARK: - Private

    private func show(_ item: ClipboardItem) {
        collapseToken = UUID()
        hideToken = UUID()
        self.item = item
        setExpanded(true)
    }

    private func scheduleHide() {
        guard item != nil else { return }
        let grace = Self.hideGrace
        let token = UUID()
        hideToken = token
        schedule(grace) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.hide()
        }
    }

    private func hide() {
        guard item != nil else { return }
        setExpanded(false)
        let duration = Self.collapseDuration
        let token = UUID()
        collapseToken = token
        schedule(duration) { [weak self] in
            guard let self, self.collapseToken == token else { return }
            self.item = nil
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        onVisibilityChange?(value)
    }

    static func scheduleOnTimer(delay: TimeInterval, work: @escaping Work) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            work()
        }
    }
}

// MARK: - Preview column

/// 面板右侧的详情列：类型/来源/统计 + 全文或大图 + 操作提示。
struct ClipboardPreviewColumn: View {
    @ObservedObject var model: ClipboardModel
    let item: ClipboardItem

    @State private var loaded: Loaded?

    /// 详情按条目 id 生效：换条目时先空一帧，避免把上一条的内容错当成新的。
    private struct Loaded {
        let id: ClipboardItem.ID
        let detail: ClipboardPreviewDetail
    }

    private var detail: ClipboardPreviewDetail? {
        loaded?.id == item.id ? loaded?.detail : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 13)
                    .padding(.bottom, 8)
                detailBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                footer
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
            .frame(width: ClipboardPanelLayout.previewColumnWidth - 1)
        }
        .frame(width: ClipboardPanelLayout.previewColumnWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onHover { hovering in
            if hovering {
                model.preview.beginPreviewSurfaceHover()
            } else {
                model.preview.endPreviewSurfaceHover()
            }
        }
        .task(id: item.id) {
            let target = item
            loaded = Loaded(id: target.id, detail: ClipboardPreviewDetail(item: target))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.t(detail?.kind.labelKey ?? "clipboardKindText"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
                Spacer(minLength: 6)
                Text(item.lastCopiedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(metaLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let app = ClipboardAppNames.displayName(for: item.application) {
            parts.append(app)
        }
        if let detail {
            switch detail.kind {
            case .image:
                if let size = detail.pixelSize {
                    parts.append(model.t("clipboardPreviewDimensions", Int(size.width), Int(size.height)))
                }
            case .files:
                parts.append(model.t("clipboardPreviewFileCount", detail.fileURLs.count))
            case .link, .richText, .text:
                parts.append(model.t("clipboardPreviewCharacters", detail.characterCount))
                if detail.lineCount > 1 {
                    parts.append(model.t("clipboardPreviewLines", detail.lineCount))
                }
            }
            if detail.byteCount > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(detail.byteCount), countStyle: .file))
            }
            if item.numberOfCopies > 1 {
                parts.append(model.t("clipboardPreviewCopies", item.numberOfCopies))
            }
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var detailBody: some View {
        if let detail {
            switch detail.kind {
            case .image:
                if let image = detail.image {
                    ScrollView {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.08))
                            )
                    }
                } else {
                    emptyState
                }
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(detail.fileURLs, id: \.self) { url in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                Text(url.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            case .link, .richText, .text:
                if let text = detail.text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(text)
                                .font(.system(size: 11))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            if detail.isTextTruncated {
                                Text(model.t("clipboardPreviewTruncated", ClipboardPreviewDetail.textLimit))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else {
                    emptyState
                }
            }
        } else {
            Color.clear
        }
    }

    private var emptyState: some View {
        Text(model.t("clipboardPreviewEmpty"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ClipboardKeyHint(
                keys: "⏎",
                label: model.t(model.settings.pasteByDefault ? "clipboardHintPaste" : "clipboardHintCopy")
            )
            ClipboardKeyHint(
                keys: "⌘⏎",
                label: model.t(model.settings.pasteByDefault ? "clipboardHintCopy" : "clipboardHintPaste")
            )
            Spacer(minLength: 0)
        }
    }
}
