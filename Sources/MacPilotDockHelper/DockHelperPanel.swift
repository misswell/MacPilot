//
//  DockHelperPanel.swift
//  MacPilotDockHelper
//
//  需求第 7 节：点击 Dock 图标后显示一个轻量浮层——
//  无标题栏、无普通 Window Chrome、点击外部自动关闭、支持 ESC 与键盘导航、
//  支持深色模式与 Retina。视觉接近 macOS 原生 Dock Folder。
//

import AppKit
import MacPilotDockGroupsCore
import SwiftUI

/// 无标题栏、可成为 key window 的浮层（ESC / 键盘导航需要 key 状态）。
final class DockHelperPanel: NSPanel {
    /// ESC 关闭（需求第 7 节）。
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class DockHelperPanelController {
    static var shared: DockHelperPanelController?

    /// 自动终止（TAL, Transparent App Lifecycle）的说明字符串。
    /// 面板可见期间必须禁用：日志显示 macOS 会在浮层已经显示后
    /// （启动 5 秒）仍把 Helper 标记为「可被系统回收」，
    /// 于是用户什么都没做，进程也可能被系统自己收走。
    private static let automaticTerminationReason = "Dock group panel is open"

    private var panel: DockHelperPanel?
    private var outsideClickMonitor: Any?
    /// 「点外部 / 失去 key」的判定闸门（见 DockGroupPanelDismissalPolicy）。
    private var dismissalPolicy: DockGroupPanelDismissalPolicy?
    /// 只在真正禁用过自动终止之后才恢复，保证 disable/enable 成对。
    private var disabledAutomaticTermination = false
    private let model: DockHelperModel

    init(model: DockHelperModel) {
        self.model = model
    }

    func show() {
        // 已经有了就只把它重新提到前面，避免重复创建浮层。
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        model.start()

        // 浮层可见 = 这个进程必须活着；禁用自动终止，避免被系统回收。
        if !disabledAutomaticTermination {
            ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
            disabledAutomaticTermination = true
        }

        let group = model.group
        let size = group.map { DockHelperLayout.size(for: $0) } ?? NSSize(width: 280, height: 190)

        let hosting = NSHostingView(rootView: DockHelperView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)

        // 需求第 7 节：无标题栏、无普通 Window Chrome。
        // Helper 是 accessory 应用，激活它也不会产生第二个 Dock 图标，
        // 因此这里不需要 nonactivatingPanel —— 普通的 key window 更利于
        // ESC 与键盘导航（需求第 7 节要求支持）。
        let panel = DockHelperPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.close() }

        position(panel, size: size)

        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        // 从这一刻起，真正的「点外部 / 失去 key」才算数；启动手势的残留事件被挡掉。
        dismissalPolicy = DockGroupPanelDismissalPolicy(shownAt: ProcessInfo.processInfo.systemUptime)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        installOutsideClickMonitor(for: panel)
    }

    func close() {
        guard let panel else { return }
        dismissalPolicy = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        removeOutsideClickMonitor()
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        model.stop()
        // Helper 不常驻：浮层关闭后结束进程，保证「关闭后无额外后台开销」。
        restoreAutomaticTermination()
        NSApp.terminate(nil)
    }

    /// 进程退出前的兜底清理（不触发 terminate，避免递归）。
    func shutdown() {
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
            self.panel = nil
        }
        dismissalPolicy = nil
        removeOutsideClickMonitor()
        model.stop()
        restoreAutomaticTermination()
    }

    private func restoreAutomaticTermination() {
        guard disabledAutomaticTermination else { return }
        ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
        disabledAutomaticTermination = false
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        guard dismissalPolicy?.allowsDismissalForResignKey(now: ProcessInfo.processInfo.systemUptime) == true else {
            return
        }
        close()
    }

    // MARK: - 点击外部自动关闭

    /// 需求第 7 节「点击外部自动关闭」：mouseDown 级别的全局监听，
    /// 即使浮层因为某些原因没有成为 key window，也能保证点外面就关掉。
    /// 全局鼠标监听不需要任何隐私授权（键盘监听才需要）。
    private func installOutsideClickMonitor(for panel: NSPanel) {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // 启动手势的残留（双击的第二下、排队中的旧事件）不算「点了别处」。
                guard self.dismissalPolicy?
                    .allowsDismissalForOutsideClick(eventTimestamp: event.timestamp) == true
                else { return }
                if !panel.frame.contains(event.locationInWindow) {
                    self.close()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    /// 把浮层放在鼠标（也就是 Dock 图标）上方，并夹在各屏幕的可见区域内。
    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = screen?.frame ?? visible

        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 10)
        // 上方放不下时改放到下方。
        if origin.y + size.height > visible.maxY {
            origin.y = mouse.y - size.height - 10
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        // 夹取后仍可能越界（屏幕过小），以屏幕 frame 兜底。
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)

        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
