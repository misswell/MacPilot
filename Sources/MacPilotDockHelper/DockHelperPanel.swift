//
//  DockHelperPanel.swift
//  MacPilotDockHelper
//
//  需求第 7 节：点击 Dock 图标后显示一个轻量浮层——
//  无标题栏、无普通 Window Chrome、点击外部自动关闭、支持 ESC 与键盘导航、
//  支持深色模式与 Retina。视觉接近 macOS 原生 Dock Folder。
//
//  性能（见 SUMMARY「Dock 分组：点开即现」）：
//
//  * **面板先上屏**：`show()` 只做「读配置 → 算尺寸 → 建面板 → 显示」，
//    解析与图标交给 `model.loadContent()` 在显示之后跑。
//  * **进程留在原地**：浮层关掉只 `orderOut`，不 `terminate`。下一次点 Dock 图标
//    走 `applicationShouldHandleReopen` / `applicationDidBecomeActive`，实测 5ms 级；
//    冷启动要重新走 LaunchServices + 进程启动 + 解析，实测 0.25 秒起，机器忙时更久。
//    空转 `warmLifetime` 后自动退出，配合 `NSSupportsAutomaticTermination`
//    让系统在内存吃紧时提前回收，所以「不留后台进程」的约束仍在，只是有了时长上限。
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

    /// 浮层关掉之后进程继续待命的时长。
    /// 这段时间内再次点 Dock 图标是「热展开」——面板已经在内存里，直接显示。
    static let warmLifetime: TimeInterval = 5 * 60

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
    /// 空转退出的定时器（只在浮层关掉后跑）。
    private var warmExitTimer: Timer?
    private let model: DockHelperModel

    init(model: DockHelperModel) {
        self.model = model
    }

    /// 浮层当前是否在屏幕上（`main.swift` 用它判断「是 reopen 还是真的需要展开」）。
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func show() {
        cancelWarmExit()
        disableAutomaticTermination()

        // 配置可能刚在 MacPilot 里改过（改名 / 增删 App），每次都重新读一遍；
        // 这一步是毫秒级的，面板尺寸也由此确定。
        model.loadConfiguration()
        model.startRefreshing()

        let size = model.group.map { DockHelperLayout.size(for: $0) } ?? NSSize(width: 280, height: 190)

        if let panel {
            // 热路径：面板还在内存里，只需要按最新配置改一下尺寸、
            // 重新定位到这次点击的 Dock 图标旁边，再显示出来。
            if panel.frame.size != size {
                panel.contentView?.frame = NSRect(origin: .zero, size: size)
            }
            position(panel, size: size)
            observeDismissal(for: panel)
            present(panel)
            model.startLoadingContent()
            return
        }

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
        panel.onCancel = { [weak self] in self?.dismiss() }

        position(panel, size: size)

        self.panel = panel
        observeDismissal(for: panel)
        present(panel)

        // 面板已经上屏，版本 / 运行状态 / 图标随后补齐（每张图之间让出主线程）。
        model.startLoadingContent()
    }

    /// 把面板提到前面并成为 key window。启动手势的残留事件由闸门挡掉。
    private func present(_ panel: DockHelperPanel) {
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // 从这一刻起，真正的「点外部 / 失去 key」才算数。
        dismissalPolicy = DockGroupPanelDismissalPolicy(shownAt: ProcessInfo.processInfo.systemUptime)
    }

    /// 关闭浮层：只把面板收起来，进程留着待命（见 `warmLifetime`）。
    ///
    /// ESC、点外部、启动 App、打开设置都走这里。之所以不 `terminate`：
    /// 重新拉起一个进程是「点开后要等」的唯一来源，而面板本身在内存里几乎不花钱。
    func dismiss() {
        guard let panel else { return }
        dismissalPolicy = nil
        stopObservingDismissal(for: panel)
        panel.orderOut(nil)
        model.stopRefreshing()
        restoreAutomaticTermination()
        scheduleWarmExit()
        // 没有窗口的 accessory App 不该继续占着最前面：让焦点回到用户原来的 App。
        if NSApp.isActive {
            NSApp.hide(nil)
        }
    }

    /// 进程退出前的兜底清理（不触发 terminate，避免递归）。
    func shutdown() {
        stopObservingDismissal(for: panel)
        panel = nil
        dismissalPolicy = nil
        cancelWarmExit()
        model.stopRefreshing()
        restoreAutomaticTermination()
    }

    /// 空转到期：关掉 Helper，回到「不点就不占进程」的状态。
    private func terminate() {
        shutdown()
        NSApp.terminate(nil)
    }

    private func scheduleWarmExit() {
        warmExitTimer?.invalidate()
        warmExitTimer = Timer.scheduledTimer(withTimeInterval: Self.warmLifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.terminate() }
        }
    }

    private func cancelWarmExit() {
        warmExitTimer?.invalidate()
        warmExitTimer = nil
    }

    private func disableAutomaticTermination() {
        guard !disabledAutomaticTermination else { return }
        ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
        disabledAutomaticTermination = true
    }

    private func restoreAutomaticTermination() {
        guard disabledAutomaticTermination else { return }
        ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
        disabledAutomaticTermination = false
    }

    // MARK: - 关闭信号

    private func observeDismissal(for panel: NSPanel) {
        stopObservingDismissal(for: panel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        installOutsideClickMonitor(for: panel)
    }

    private func stopObservingDismissal(for panel: NSPanel?) {
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        }
        removeOutsideClickMonitor()
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        guard dismissalPolicy?.allowsDismissalForResignKey(now: ProcessInfo.processInfo.systemUptime) == true else {
            return
        }
        dismiss()
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
                    self.dismiss()
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

    // MARK: - 落点

    /// 始终贴在**被点击的那个 Dock 图标**旁边：沿 Dock 方向居中到图标中心，
    /// 垂直于 Dock 的方向紧贴 Dock 内侧（不再跟着鼠标跑）。
    ///
    /// 图标位置来自 `groups.json` 里的 `dockTile`——Helper 自己没有辅助功能授权，
    /// 算不出 Dock 图标在哪，只能由 MacPilot 读出来写进配置；
    /// 那份几何失效时（没授权 / 还没固定到 Dock / 布局刚变过）会自动退回按点击位置定位。
    /// 具体数学在 `DockHelperPanelPlacement` 里，由单元测试锁住。
    private func position(_ panel: NSPanel, size: NSSize) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? screenFrame

        let origin = DockHelperPanelPlacement.origin(
            panelSize: size,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            pointer: pointer,
            tile: model.group?.dockTile?.rect
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
