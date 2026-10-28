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
//  * 浮层关闭后释放内容并正常退出进程，不保留热待命窗口。
//    主功能关闭时，通过限定配置根目录和生命周期代际的通知退出正在使用的 Helper。
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

    /// 浮层关掉之后进程继续待命的时长。上界由 `DockHelperWarmLifetimePolicy`
    /// 和单元测试锁住：待命是为了热展开（重建面板只要毫秒级），不是为了常驻。
    static let warmLifetime = DockHelperWarmLifetimePolicy.seconds

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
    /// Invalidates a queued close when a reopen arrives before the run-loop returns.
    private var terminationGeneration = UUID()
    private let model: DockHelperModel
    private let startedAt = Date()
    private var lifecycleObserver: NSObjectProtocol?
    /// 系统选择面板打开期间，浮层会失去 key 状态；那不是「用户点了别处」。
    private var isPresentingModal = false

    init(model: DockHelperModel) {
        self.model = model
        lifecycleObserver = DistributedNotificationCenter.default().addObserver(
            forName: DockHelperLifecycle.shutdownNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let generation = notification.object as? String,
                  let root = notification.userInfo?["root"] as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, root == self.model.rootDirectory.standardizedFileURL.path,
                      DockHelperLifecycle.acceptsShutdown(generation: generation,
                          root: self.model.rootDirectory, startedAt: self.startedAt) else { return }
                self.terminate()
            }
        }
        model.onGroupChanged = { [weak self] in self?.resizePanelToFitGroup() }
        model.prepareForModalPresentation = { [weak self] in self?.beginModalPresentation() }
        model.modalPresentationDidFinish = { [weak self] in self?.endModalPresentation() }
    }

    /// 浮层当前是否在屏幕上（`main.swift` 用它判断「是 reopen 还是真的需要展开」）。
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard DockHelperLifecycle.permitsLaunch(root: model.rootDirectory) else { terminate(); return }
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
        // `dismiss()` closes it; the default would let AppKit release the panel
        // out from under the reference Swift still holds.
        panel.isReleasedWhenClosed = false
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

    /// 关闭浮层：收起并**释放**面板，进程留着待命（见 `warmLifetime`）。
    ///
    /// ESC、点外部、启动 App、打开设置都走这里。之所以不 `terminate`：
    /// 重新拉起一个进程才是「点开后要等」的来源；面板本身重建一次只要几毫秒，
    /// 留着一个看不见的面板却要把 SwiftUI 宿主和图标一直占在待命进程里。
    func dismiss() {
        guard let panel else { return }
        dismissalPolicy = nil
        stopObservingDismissal(for: panel)
        panel.orderOut(nil)
        model.stopRefreshing()
        self.panel = nil
        panel.contentView = nil
        panel.close()
        model.releaseContent()
        restoreAutomaticTermination()
        scheduleWarmExit()
        // 没有窗口的 accessory App 不该继续占着最前面：让焦点回到用户原来的 App。
        if NSApp.isActive {
            NSApp.hide(nil)
        }
    }

    /// 进程退出前的兜底清理（不触发 terminate，避免递归）。
    func shutdown() {
        if let lifecycleObserver {
            DistributedNotificationCenter.default().removeObserver(lifecycleObserver)
            self.lifecycleObserver = nil
        }
        stopObservingDismissal(for: panel)
        panel = nil
        dismissalPolicy = nil
        cancelWarmExit()
        model.stopRefreshing()
        model.releaseContent()
        restoreAutomaticTermination()
    }

    /// 空转到期：关掉 Helper，回到「不点就不占进程」的状态。
    private func terminate() {
        shutdown()
        NSApp.terminate(nil)
    }

    private func scheduleWarmExit() {
        let generation = UUID()
        terminationGeneration = generation
        // Finish AppKit's dismissal callback before terminating. A reopen or
        // modal picker owns the helper until its own operation finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.terminationGeneration == generation,
                  !self.isPanelVisible, !self.isPresentingModal else { return }
            self.terminate()
        }
    }

    private func cancelWarmExit() { terminationGeneration = UUID() }

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
        guard !isPresentingModal else { return }
        guard dismissalPolicy?.allowsDismissalForResignKey(now: ProcessInfo.processInfo.systemUptime) == true else {
            return
        }
        dismiss()
    }

    private func beginModalPresentation() {
        isPresentingModal = true
    }

    private func endModalPresentation() {
        isPresentingModal = false
        guard let panel, panel.isVisible else { return }
        // 选择面板关掉后把焦点还给浮层，并重新开始「点外部才关闭」的计时。
        panel.makeKeyAndOrderFront(nil)
        dismissalPolicy = DockGroupPanelDismissalPolicy(shownAt: ProcessInfo.processInfo.systemUptime)
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
                guard let self, let panel = self.panel, !self.isPresentingModal else { return }
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

    /// 增删成员后按新内容调整面板尺寸，同时保持浮层当前的锚边不跳走。
    private func resizePanelToFitGroup() {
        guard let panel, let group = model.group else { return }
        let size = DockHelperLayout.size(for: group)
        let current = panel.frame
        guard current.size != size else { return }

        let screen = NSScreen.screens.first { $0.frame.intersects(current) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? current
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let origin = DockHelperPanelPlacement.resizedOrigin(
            currentFrame: current,
            newSize: size,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            pointer: NSEvent.mouseLocation
        )
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

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
