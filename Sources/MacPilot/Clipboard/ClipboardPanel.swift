//
//  ClipboardPanel.swift
//  MacPilot
//
//  剪贴板历史弹出面板（NSPanel + SwiftUI）。
//  改编自 Maccy（MIT License, https://github.com/p0deje/Maccy）：
//  - Maccy/FloatingPanel.swift
//  - Maccy/Views/*.swift
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Panel

/// 非激活浮动面板：打开时不抢占前台应用焦点，失焦自动关闭。
final class ClipboardPanel: NSPanel {
    private(set) var isPresented = false
    let onClose: () -> Void

    /// 搜索框是否聚焦（由内容视图同步，用于键盘事件分流）。
    var isSearchFocused = false

    private var keyMonitor: Any?
    private let contentHostingView: NSHostingView<ClipboardPanelContent>

    init(
        onClose: @escaping () -> Void,
        content: @escaping () -> ClipboardPanelContent
    ) {
        self.onClose = onClose
        self.contentHostingView = NSHostingView(rootView: content())

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
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
        positionOnScreen()
        orderFrontRegardless()
        makeKey()
        isPresented = true
        installKeyMonitor()
        DispatchQueue.main.async {
            self.makeFirstResponder(self.contentHostingView)
        }
    }

    override func close() {
        removeKeyMonitor()
        isPresented = false
        super.close()
        onClose()
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = contentView?.fittingSize ?? NSSize(width: 420, height: 420)
        let width = min(max(panelSize.width, 360), visibleFrame.width - 24)
        let height = min(max(panelSize.height, 120), visibleFrame.height - 60)
        setContentSize(NSSize(width: width, height: height))
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.maxY - height - 12
        setFrameOrigin(NSPoint(x: x, y: y))
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
        guard let model = clipboardModel else { return event }

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
            return nil
        case UInt16(kVK_DownArrow):
            model.history.moveSelectionDown()
            return nil
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            model.history.deleteSelected()
            return nil
        default:
            break
        }

        // 数字键 1-9 选择第 N 条未固定条目。
        if let digit = Self.digit(for: keyCode) {
            model.history.selectUnpinnedItem(at: digit)
            return nil
        }

        // 字母键选择固定条目（仅当搜索框未聚焦时，避免干扰输入）。
        if !isSearchFocused, flags.isEmpty || flags == [.shift],
           let character = Self.character(for: keyCode) {
            if model.history.selectPinnedItem(withPin: character.lowercased()) {
                return nil
            }
        }

        return event
    }

    private var clipboardModel: ClipboardModel? {
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

    private static let cornerRadius: CGFloat = 12
    private static let horizontalPadding: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            if model.settings.showSearch {
                searchField
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }

            historyList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
        )
        .onChange(of: searchFocused) { _, focused in
            if let panel = windowPanel {
                panel.isSearchFocused = focused
            }
        }
        .onAppear {
            model.history.selectFirst()
            if model.settings.showSearch {
                searchFocused = true
            }
        }
    }

    private var windowPanel: ClipboardPanel? {
        NSApp.keyWindow as? ClipboardPanel
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(
                "搜索剪贴板历史…",
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
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.history.items.enumerated()), id: \.element.id) { index, item in
                        ClipboardItemRow(
                            item: item,
                            shortcut: Self.shortcutLabel(for: item, in: model.history.items),
                            isSelected: index == model.history.selectedIndex
                        ) {
                            model.performAction(on: item, modifierFlags: NSEvent.modifierFlags)
                        }
                        .id(item.id)
                        .onHover { hovering in
                            if hovering {
                                model.history.selectItem(at: index)
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, 2)
            }
            .onChange(of: model.history.selectedIndex) { _, newIndex in
                guard let item = model.history.selectedItem else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack {
            if model.history.items.isEmpty {
                Text("剪贴板历史为空")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.history.items.count) 条 · ↑↓ 选择 · ⏎ 粘贴 · ⌘⏎ 复制 · ⌫ 删除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let hotkey = model.settings.hotkey.displayName
            if !hotkey.isEmpty {
                Text("快捷键 \(hotkey)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func shortcutLabel(for item: ClipboardItem, in items: [ClipboardItem]) -> String? {
        if let pin = item.pin {
            return pin.uppercased()
        }
        let unpinned = items.filter { !$0.isPinned }
        guard let index = unpinned.firstIndex(where: { $0.id == item.id }), index < 9 else {
            return nil
        }
        return "\(index + 1)"
    }

}

// MARK: - Item row

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let shortcut: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                shortcutBadge
                thumbnail
                titleView
                Spacer(minLength: 4)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                if let appName = appName {
                    Text(appName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var shortcutBadge: some View {
        if let shortcut {
            Text(shortcut)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        } else {
            Color.clear.frame(width: 16)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Color.clear.frame(width: 20, height: 20)
        }
    }

    private var titleView: some View {
        Group {
            if let text = item.text {
                Text(text)
            } else if let url = item.fileURLs.first {
                Text(url.path)
            } else if !item.title.isEmpty {
                Text(item.title)
            } else {
                Text("图片")
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var appName: String? {
        guard let application = item.application else { return nil }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application)?
            .deletingPathExtension().lastPathComponent
        return name?.shortened(to: 16)
    }
}
