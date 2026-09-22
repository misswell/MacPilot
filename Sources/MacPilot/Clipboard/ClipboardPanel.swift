//
//  ClipboardPanel.swift
//  MacPilot
//
//  剪贴板历史弹出面板（NSPanel + SwiftUI）。
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Layout

/// 面板几何。列宽是硬值：窗口尺寸由它算出，SwiftUI 也按它排版，两边共用同一份
/// 数字，展开右侧详情列时列表才不会跟着挪位。
enum ClipboardPanelLayout {
    static let listColumnWidth: CGFloat = 400
    static let previewColumnWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 20
    static let rowHeight: CGFloat = 30
    static let minimumHeight: CGFloat = 190
    static let maximumHeight: CGFloat = 460

    static func width(showsPreview: Bool) -> CGFloat {
        showsPreview ? listColumnWidth + previewColumnWidth : listColumnWidth
    }
}

// MARK: - Panel

/// 非激活浮动面板：打开时不抢占前台应用焦点，失焦自动关闭。
final class ClipboardPanel: NSPanel {
    private(set) var isPresented = false
    let onClose: () -> Void

    /// 搜索框是否聚焦（由内容视图同步，用于键盘事件分流）。
    var isSearchFocused = false

    private var keyMonitor: Any?
    private var pendingResignClose: DispatchWorkItem?
    private let contentHostingView: NSHostingView<ClipboardPanelContent>

    init(
        onClose: @escaping () -> Void,
        content: @escaping () -> ClipboardPanelContent
    ) {
        self.onClose = onClose
        self.contentHostingView = NSHostingView(rootView: content())

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ClipboardPanelLayout.listColumnWidth, height: 420),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false

        contentView = contentHostingView
    }

    func open() {
        pendingResignClose?.cancel()
        pendingResignClose = nil
        isPresented = true
        model?.preview.reset()
        positionOnScreen()
        orderFrontRegardless()
        makeKey()
        installKeyMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented else { return }
            self.makeFirstResponder(self.contentHostingView)
        }
    }

    override func close() {
        pendingResignClose?.cancel()
        pendingResignClose = nil
        removeKeyMonitor()
        isPresented = false
        model?.preview.reset()
        super.close()
        onClose()
    }

    override func resignKey() {
        super.resignKey()
        guard isPresented else { return }

        // Ending an NSMenu tracking loop can briefly make the panel resign
        // before AppKit finishes promoting it to the key window. Closing
        // synchronously here makes the menu action appear to do nothing.
        pendingResignClose?.cancel()
        let closeWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented, !self.isKeyWindow else { return }
            self.close()
        }
        pendingResignClose = closeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: closeWorkItem)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 详情列展开/收起时同步窗口宽度：左边缘钉住，列表原地不动，详情列向右生长。
    func resize(showsPreview: Bool) {
        guard isPresented else { return }
        let available = (screen ?? NSScreen.main)?.visibleFrame
        var next = frame
        next.size.width = min(
            ClipboardPanelLayout.width(showsPreview: showsPreview),
            (available?.width ?? next.width) - 24
        )
        guard abs(next.width - frame.width) > 0.5 else { return }
        if let limit = available.map({ $0.maxX - 12 }), next.maxX > limit {
            next.origin.x = limit - next.width
        }
        setFrame(next, display: true, animate: true)
    }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = contentView?.fittingSize ?? NSSize(width: ClipboardPanelLayout.listColumnWidth, height: 420)
        // 列表内容会让 fittingSize 随历史长度增长，这里给面板一个
        // 有上限的合理尺寸：内容较少时贴合内容，较多时固定并滚动。
        let height = min(
            max(panelSize.height, ClipboardPanelLayout.minimumHeight),
            ClipboardPanelLayout.maximumHeight,
            visibleFrame.height - 60
        )
        let width = ClipboardPanelLayout.width(showsPreview: false)
        // 宁可让面板偏左，也要给详情列留出展开的空间，展开时才不会被顶到屏幕右边缘。
        let roomForExpansion = visibleFrame.maxX - 12 - ClipboardPanelLayout.width(showsPreview: true)
        let x = min(visibleFrame.midX - width / 2, max(roomForExpansion, visibleFrame.minX + 12))
        setContentSize(NSSize(width: width, height: height))
        setFrameOrigin(NSPoint(x: x, y: visibleFrame.maxY - height - 12))
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// 返回 nil 表示事件已被处理；否则放行。
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }

        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)

        switch keyCode {
        case UInt16(kVK_Escape):
            model.closePanel()
            return nil
        case UInt16(kVK_Return):
            model.performActionOnSelection()
            return nil
        case UInt16(kVK_UpArrow):
            model.history.moveSelectionUp()
            model.preview.followSelection(model.history.selectedItem)
            return nil
        case UInt16(kVK_DownArrow):
            model.history.moveSelectionDown()
            model.preview.followSelection(model.history.selectedItem)
            return nil
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            // 搜索框聚焦时退格用于编辑搜索词，不删除历史条目。
            guard !isSearchFocused else { return event }
            model.history.deleteSelected()
            model.preview.followSelection(model.history.selectedItem)
            return nil
        default:
            break
        }

        // 数字键 1-9 选择第 N 条未固定条目；搜索框聚焦时放行用于输入。
        if !isSearchFocused, let digit = Self.digit(for: keyCode) {
            model.history.selectUnpinnedItem(at: digit)
            model.preview.followSelection(model.history.selectedItem)
            return nil
        }

        // 字母键选择固定条目（仅当搜索框未聚焦时，避免干扰输入）。
        if !isSearchFocused, flags.isEmpty || flags == [.shift],
           let character = Self.character(for: keyCode) {
            if model.history.selectPinnedItem(withPin: character.lowercased()) {
                model.preview.followSelection(model.history.selectedItem)
                return nil
            }
        }

        return event
    }

    private var model: ClipboardModel? {
        (contentHostingView.rootView as ClipboardPanelContent).model
    }

    private static func digit(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1): return 0
        case UInt16(kVK_ANSI_2): return 1
        case UInt16(kVK_ANSI_3): return 2
        case UInt16(kVK_ANSI_4): return 3
        case UInt16(kVK_ANSI_5): return 4
        case UInt16(kVK_ANSI_6): return 5
        case UInt16(kVK_ANSI_7): return 6
        case UInt16(kVK_ANSI_8): return 7
        case UInt16(kVK_ANSI_9): return 8
        default: return nil
        }
    }

    private static func character(for keyCode: UInt16) -> String? {
        let mapping: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c",
            UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f",
            UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i",
            UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
            UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
            UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
            UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_U): "u",
            UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
            UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z"
        ]
        return mapping[keyCode]
    }
}

// MARK: - Panel content

struct ClipboardPanelContent: View {
    @ObservedObject var model: ClipboardModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: ClipboardPanelLayout.listColumnWidth)
            if let previewed = model.preview.item {
                ClipboardPreviewColumn(model: model, item: previewed)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: ClipboardPanelLayout.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ClipboardPanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        // 窗口逐帧变宽时，内容始终按自己的完整宽度排版并左对齐，超出窗口的部分被裁掉，
        // 于是列表纹丝不动，详情列像被「揭开」一样出现。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .ignoresSafeArea(.container)
        .onChange(of: searchFocused) { _, focused in
            if let panel = windowPanel {
                panel.isSearchFocused = focused
            }
        }
        .onAppear {
            model.history.selectFirst()
            if model.settings.showSearch {
                // 延迟一拍再聚焦：open() 会在异步块里把宿主视图设为
                // first responder，同步设置焦点会被它覆盖，搜索框就无法输入。
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if model.settings.showSearch {
                searchField
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            historyList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 9)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "clipboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.t("clipboard"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            ClipboardKeyCap(model.settings.hotkey.displayName)
        }
    }

    private var windowPanel: ClipboardPanel? {
        NSApp.keyWindow as? ClipboardPanel
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                model.t("clipboardSearchPlaceholder"),
                text: Binding(
                    get: { model.history.searchQuery },
                    set: { model.history.searchQuery = $0 }
                )
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.history.searchQuery.isEmpty {
                Button {
                    model.history.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        )
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.history.items.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.history.items.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemRow(
                                item: item,
                                shortcut: shortcutLabels[item.id],
                                isSelected: index == model.history.selectedIndex,
                                imageLabel: model.t("clipboardImageLabel")
                            ) {
                                model.performAction(on: item, modifierFlags: NSEvent.modifierFlags)
                            }
                            .id(item.id)
                            // 悬停判定挂在带横向留白的整体上：卡片视觉左右各缩进 8pt，
                            // 但触发区铺满整列宽度，指针划向详情列时不会穿过一段「死区」
                            // 而提前开始收起。
                            .padding(.horizontal, 8)
                            .onHover { hovering in
                                if hovering {
                                    model.history.selectItem(at: index)
                                    model.preview.beginHover(item)
                                } else {
                                    model.preview.endHover(item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .onChange(of: model.history.scrollFollowItemID) { _, itemID in
                guard let itemID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "clipboard")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.t("clipboardHistoryEmpty"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 26)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(model.t("clipboardItemCount", model.history.items.count))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            ClipboardKeyHint(keys: "↑↓", label: model.t("clipboardHintSelect"))
            ClipboardKeyHint(
                keys: "⏎",
                label: model.t(model.settings.pasteByDefault ? "clipboardHintPaste" : "clipboardHintCopy")
            )
            ClipboardKeyHint(
                keys: "⌘⏎",
                label: model.t(model.settings.pasteByDefault ? "clipboardHintCopy" : "clipboardHintPaste")
            )
            ClipboardKeyHint(keys: "⌫", label: model.t("clipboardHintDelete"))
        }
    }

    /// 快捷键标签：固定条目用字母，未固定条目按顺序用 1-9。
    /// 整表一次算完，避免每行都重扫一遍历史。
    private var shortcutLabels: [ClipboardItem.ID: String] {
        var labels: [ClipboardItem.ID: String] = [:]
        labels.reserveCapacity(model.history.items.count)
        var unpinnedSlot = 0
        for item in model.history.items {
            if let pin = item.pin {
                labels[item.id] = pin.uppercased()
            } else {
                if unpinnedSlot < 9 {
                    labels[item.id] = "\(unpinnedSlot + 1)"
                }
                unpinnedSlot += 1
            }
        }
        return labels
    }
}

// MARK: - Item row

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let shortcut: String?
    let isSelected: Bool
    let imageLabel: String
    let onSelect: () -> Void

    // 渲染缓存：缩略图解码、磁盘读取与应用名查询开销较大，
    // 首帧之后改用缓存，选中态切换时不再重复做 IO。
    @State private var cachedThumbnail: NSImage?
    @State private var cachedText: String?
    @State private var cachedFileURL: URL?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                leadingVisual
                Text(displayText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
                if let appName {
                    Text(appName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let shortcut {
                    ClipboardKeyCap(shortcut, prominent: isSelected)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: ClipboardPanelLayout.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            cachedThumbnail = item.thumbnailImage
            cachedText = item.text
            cachedFileURL = item.fileURLs.first
        }
    }

    /// 行首的 20pt 视觉锚点：图片放缩略图，其余放内容类型图标。
    /// 两者都占满同一个槽位，列表左侧不会再出现空档。
    @ViewBuilder
    private var leadingVisual: some View {
        if let image = cachedThumbnail ?? item.thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                )
        } else {
            Image(systemName: item.displayKind.symbolName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.10 : 0.06))
                )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected
                  ? Color(nsColor: .controlAccentColor).opacity(0.22)
                  : Color.primary.opacity(0.045))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.55), lineWidth: 1)
                }
            }
    }

    private var displayText: String {
        if let text = cachedText ?? item.text {
            return text
        }
        if let url = cachedFileURL ?? item.fileURLs.first {
            return url.path
        }
        if !item.title.isEmpty {
            return item.title
        }
        return imageLabel
    }

    private var appName: String? {
        ClipboardAppNames.displayName(for: item.application, shortenedTo: 16)
    }
}

// MARK: - Key hints

/// 键帽：面板里所有快捷键提示共用的最小视觉单元。
struct ClipboardKeyCap: View {
    private let text: String
    private let prominent: Bool

    init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(prominent ? Color(nsColor: .controlAccentColor) : Color.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18)
            .frame(height: 17)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(prominent
                          ? Color(nsColor: .controlAccentColor).opacity(0.20)
                          : Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// 键帽 + 说明文字（「⏎ 粘贴」）。
struct ClipboardKeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ClipboardKeyCap(keys)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
