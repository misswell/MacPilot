//
//  QuickSearchPanel.swift
//  MacPilot
//
//  快速搜索的浮层：独立 NSPanel + NSHostingView。
//
//  焦点与窗口生命周期沿用 `ClipboardPanel` 的经验（非激活面板、延迟一拍再聚焦、
//  resignKey 后延迟关闭以免被菜单跟踪误杀），但不共用它的业务模型。
//
//  键盘分流是这里的关键：输入法组词（marked text）期间，Enter / Esc / 方向键
//  属于文本输入系统，不能被当成启动器的执行与导航。
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 面板几何

enum QuickSearchPanelLayout {
    /// 默认宽度；屏幕不够宽时按可用宽度收缩。
    static let defaultWidth: CGFloat = 620
    static let minimumWidth: CGFloat = 400
    static let minimumHeight: CGFloat = 180
    /// 边框多宽算「拖到了边上」。6pt 与系统窗口的可拖边一致，不抢内容区的点击。
    static let resizeMargin: CGFloat = 6
    /// 行高固定：键盘导航与滚动位置才可预测。
    static let rowHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 16
    /// 结果区一屏大致能放下的行数，用来算初始高度。
    static let preferredVisibleRows = 9
    /// 顶部搜索行：上下留白 + 行高。拖动抓手就在这一行左端，不再单独占一条
    /// 顶栏——那条 16pt 的空带只会把输入框顶成「大额头」。
    static let searchRowTopPadding: CGFloat = 10
    static let searchRowHeight: CGFloat = 36
    static let searchRowBottomPadding: CGFloat = 8
    /// 顶部搜索区总高（含上下留白），面板高度按它计算。
    static var searchFieldHeight: CGFloat {
        searchRowTopPadding + searchRowHeight + searchRowBottomPadding
    }
    static let footerHeight: CGFloat = 34
}

// MARK: - 按键分流

/// 面板的显示/收起接口。模型只依赖这个协议，自动化测试才能用不显示真实窗口、
/// 不抢占用户焦点的替身来验证生命周期。
@MainActor
protocol QuickSearchPanelPresenting: AnyObject {
    var isPresented: Bool { get }
    func open()
    func close()
    /// 位置变了（用户拖动过、或回到默认位置）之后按当前设置重新落一次。
    func applyPlacement()
}

/// `resignKey` 后的关闭判定。激活尚未完成时 AppKit 还没挑完 key window，
/// 此刻关闭会杀掉本应被重新拿回焦点的面板；其余情况照旧只关仍然失焦的面板。
enum QuickSearchPanelResignPolicy {
    static func shouldClose(
        isPresented: Bool,
        isKeyWindow: Bool,
        isRecoveringActivation: Bool
    ) -> Bool {
        isPresented && !isKeyWindow && !isRecoveringActivation
    }
}

/// 一次按键应该做什么。纯函数，可脱离真实窗口验证——输入法那条规则必须能被测试覆盖。
enum QuickSearchKeyAction: Equatable {
    case openSelection
    case revealInFinder
    case closePanel
    case moveSelection(Int)
    /// 交给输入系统：文本编辑、输入法组词、Cmd+A/C/V 等原生快捷键。
    case passThrough
}

enum QuickSearchKeyRouter {
    static func action(
        command: Selector,
        commandHeld: Bool,
        controlHeld: Bool,
        isComposingText: Bool
    ) -> QuickSearchKeyAction {
        let keyCode: UInt16
        switch NSStringFromSelector(command) {
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:": keyCode = UInt16(kVK_Return)
        case "cancelOperation:": keyCode = UInt16(kVK_Escape)
        case "moveUp:": keyCode = UInt16(kVK_UpArrow)
        case "moveDown:": keyCode = UInt16(kVK_DownArrow)
        default: return .passThrough
        }
        return action(keyCode: keyCode, commandHeld: commandHeld, controlHeld: controlHeld, isComposingText: isComposingText)
    }

    static func action(
        keyCode: UInt16,
        commandHeld: Bool,
        controlHeld: Bool,
        isComposingText: Bool
    ) -> QuickSearchKeyAction {
        // 输入法有候选词/marked text 时，Enter、Esc、方向键都属于文本输入流程。
        guard !isComposingText else { return .passThrough }
        switch keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            return commandHeld ? .revealInFinder : .openSelection
        case UInt16(kVK_Escape):
            return .closePanel
        case UInt16(kVK_UpArrow) where !commandHeld && !controlHeld:
            return .moveSelection(-1)
        case UInt16(kVK_DownArrow) where !commandHeld && !controlHeld:
            return .moveSelection(1)
        default:
            return .passThrough
        }
    }
}

// MARK: - 面板

/// 应用激活是异步完成的，而 AppKit 在这段异步激活落地时自己挑 key window：
/// 多显示器下，它优先选另一块屏上的普通窗口（设置页），而不是刚 order-front
/// 的浮层。浮层因此失 key，`resignKey` 的延迟关闭随后把面板收掉——表现为
/// 「闪一下消失」。这里在激活真正完成时把面板重新拿回 key；只认这次打开
/// 之前 arm 的激活通知，关闭面板立即解除。
@MainActor
final class QuickSearchPanelActivationRecovery {
    private let notificationCenter: NotificationCenter
    private let applicationIsActive: () -> Bool
    private let scheduleSettle: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var observer: NSObjectProtocol?
    private(set) var isRecovering = false
    var onActivated: (() -> Void)?
    var onSettled: (() -> Void)?

    init(
        notificationCenter: NotificationCenter = .default,
        applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        scheduleSettle: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    ) {
        self.notificationCenter = notificationCenter
        self.applicationIsActive = applicationIsActive
        self.scheduleSettle = scheduleSettle
    }

    /// 仅在这次打开需要激活本进程时 arm。激活已经完成时不必再抢一次 key。
    func armIfApplicationIsInactive() {
        guard !applicationIsActive(), !isRecovering, observer == nil else { return }
        isRecovering = true
        observer = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidBecomeActive()
            }
        }
    }

    func disarm() {
        isRecovering = false
        removeObserver()
    }

    private func removeObserver() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    /// AppKit 在 `didBecomeActive` 之后还会继续排定窗口，普通窗口可能在这一拍
    /// 才抢走 key。保持 recovery 一段时间，让面板在 settle 结束前反复重拿 key；
    /// 结束后仍未拿到 key 才交给面板关闭。
    private func handleApplicationDidBecomeActive() {
        guard isRecovering else { return }
        removeObserver()
        scheduleSettle { [weak self] in
            guard let self, self.isRecovering else { return }
            self.isRecovering = false
            self.onSettled?()
        }
        onActivated?()
    }
}

/// 非激活面板本身不会让 AppKit 激活文本输入上下文：英文按键能直接插入，
/// 中文输入法的拼音、候选词和提交则全被吞掉。呼出面板时临时激活本进程，
/// 关闭时再交还焦点；只在面板自己仍是前台时交还，避免把用户刚点到的 App 抢回来。
@MainActor
protocol QuickSearchApplicationActivating: AnyObject {
    func activateForPanel()
    func restoreAfterPanel(preservingApplicationFocus: Bool)
}

@MainActor
final class SystemQuickSearchApplicationActivation: QuickSearchApplicationActivating {
    @MainActor
    struct Environment {
        var isActive: () -> Bool
        var capturePreviousApplication: () -> (() -> Void)?
        var activate: () -> Void
        var deactivate: () -> Void

        static var live: Self {
            Self(
                isActive: { NSApp.isActive },
                capturePreviousApplication: {
                    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
                    return { _ = application.activate(options: [.activateAllWindows]) }
                },
                activate: { SystemQuickSearchApplicationActivation.activateApplication() },
                deactivate: { NSApp.deactivate() }
            )
        }
    }

    private let environment: Environment
    private var restorePreviousApplication: (() -> Void)?
    private var didActivate = false

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func activateForPanel() {
        guard !environment.isActive() else { return }
        restorePreviousApplication = environment.capturePreviousApplication()
        didActivate = true
        environment.activate()
    }

    private static func activateApplication() {
        let current = NSRunningApplication.current
        if !current.activate(options: [.activateAllWindows]) {
            NSApp.activate()
        }
        // Cooperative activation refuses a background LSUIElement app: both
        // `NSRunningApplication.activate` and `NSApp.activate()` answer false
        // and the window keeps taking Latin keystrokes without an IME. Setting
        // our own AX frontmost attribute is the documented escape hatch and is
        // what actually makes the input context live here.
        guard !NSApp.isActive else { return }
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFrontmostAttribute as CFString,
            true as CFTypeRef
        )
    }

    func restoreAfterPanel(preservingApplicationFocus: Bool) {
        guard didActivate else { return }
        didActivate = false
        defer { restorePreviousApplication = nil }
        guard environment.isActive(), !preservingApplicationFocus else { return }
        environment.deactivate()
        restorePreviousApplication?()
    }
}

/// 呼出即可输入的搜索面板：输入法需要本进程处于激活状态，所以它只在面板
/// 存续期间临时激活；点到别处自动收起并把焦点还给原来的应用。
///
/// 位置是用户拖动出来的：面板可以拖（顶栏上的抓手），拖完记住，下次呼出回到同一处；
/// 「回到默认位置」清掉记录即可。与 `ClipboardPanel` 一套做法。
final class QuickSearchPanel: NSPanel, QuickSearchPanelPresenting, NSWindowDelegate {
    private(set) var isPresented = false
    private let onClose: () -> Void
    private weak var model: QuickSearchModel?
    private let applicationActivation: any QuickSearchApplicationActivating

    private let hostingView: NSHostingView<QuickSearchPanelContent>
    private var pendingResignClose: DispatchWorkItem?
    private var pendingActivationTimeout: DispatchWorkItem?
    private(set) var isHandlingComposedKey = false
    private var pendingPositionSave: DispatchWorkItem?
    private var isDraggingFromHeader = false
    private lazy var activationRecovery: QuickSearchPanelActivationRecovery = {
        let recovery = QuickSearchPanelActivationRecovery()
        recovery.onActivated = { [weak self] in self?.reclaimKeyAfterActivation() }
        recovery.onSettled = { [weak self] in
            guard let self, self.isPresented, !self.isKeyWindow else { return }
            self.close()
        }
        return recovery
    }()

    init(
        model: QuickSearchModel,
        onClose: @escaping () -> Void,
        applicationActivation: any QuickSearchApplicationActivating = SystemQuickSearchApplicationActivation()
    ) {
        self.model = model
        self.onClose = onClose
        self.applicationActivation = applicationActivation
        self.hostingView = NSHostingView(rootView: QuickSearchPanelContent(model: model))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: QuickSearchPanelLayout.defaultWidth, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        // 跟随当前 Space、能盖在全屏 App 上、不参与 Exposé 抖动。
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        // 只有抓手会主动发起拖动；开着 isMovable 是为了让 AppKit 认这条拖动路径。
        isMovable = true
        delegate = self
        contentView = hostingView
        // 窗口阴影按内容层的可见轮廓生成。hosting view 自己按圆角裁一次，
        // 系统就不会再给整块矩形窗口描一圈直角边。
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = QuickSearchPanelLayout.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        // Activating the process is what makes AppKit activate the field
        // editor's input context. Do it again once the panel is actually key:
        // an IME composition must never start against a stale context.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, self.isKeyWindow,
                  let textView = self.firstResponder as? NSTextView else { return }
            textView.inputContext?.activate()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { super.sendEvent(event); return }
        let previous = isHandlingComposedKey
        isHandlingComposedKey = isComposingText
        defer { isHandlingComposedKey = previous }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isPresented, event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let action = QuickSearchKeyRouter.action(
            keyCode: event.keyCode, commandHeld: true,
            controlHeld: event.modifierFlags.contains(.control),
            isComposingText: isComposingText || isHandlingComposedKey
        )
        guard action == .revealInFinder else { return super.performKeyEquivalent(with: event) }
        model?.handleSearchKeyAction(action)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        guard isPresented, !isComposingText, !isHandlingComposedKey else {
            super.cancelOperation(sender)
            return
        }
        model?.closePanel()
    }

    // MARK: 显示与关闭

    func open() {
        pendingResignClose?.cancel()
        pendingResignClose = nil
        isPresented = true
        applyPlacement()
        orderFrontRegardless()
        // Register before asking for activation: a regular window on another
        // display wins the key-window race when activation completes, and this
        // notification is the first moment the panel can take it back.
        activationRecovery.armIfApplicationIsInactive()
        scheduleActivationTimeoutIfNeeded()
        applicationActivation.activateForPanel()
        makeKey()
    }

    override func close() {
        finishHeaderDrag()
        activationRecovery.disarm()
        pendingActivationTimeout?.cancel()
        pendingActivationTimeout = nil
        pendingResignClose?.cancel()
        pendingResignClose = nil
        isPresented = false
        // Capture ownership before close changes AppKit's key window. A
        // settings window the user selected now owns this app's activation.
        let preservingApplicationFocus = NSApp.keyWindow.map { $0 !== self } ?? false
        super.close()
        applicationActivation.restoreAfterPanel(preservingApplicationFocus: preservingApplicationFocus)
        onClose()
    }

    override func resignKey() {
        super.resignKey()
        guard isPresented else { return }
        // 结束菜单跟踪会让面板短暂失去 key，紧接着又被重新提上来；
        // 同步关闭会让「点了菜单项却没反应」。给它 0.1 秒确认。
        scheduleResignClose()
    }

    private func scheduleResignClose(after delay: TimeInterval = 0.1) {
        pendingResignClose?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.activationRecovery.isRecovering {
                // AppKit 在 didBecomeActive 前后还会重新排 key window。等待
                // settle 期间每次失 key 都重抢一次，不把面板提前关掉。
                guard self.isPresented, NSApp.isActive, !self.isKeyWindow else { return }
                self.makeKeyAndOrderFront(nil)
                self.scheduleResignClose()
                return
            }
            guard QuickSearchPanelResignPolicy.shouldClose(
                isPresented: self.isPresented,
                isKeyWindow: self.isKeyWindow,
                isRecoveringActivation: false
            ) else { return }
            self.close()
        }
        pendingResignClose = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 激活完成后把面板重新拿回 key。AppKit 在多显示器下会把另一块屏上的
    /// 普通窗口选成 key window；这里显式把刚打开的面板排回前面。
    private func reclaimKeyAfterActivation() {
        pendingActivationTimeout?.cancel()
        pendingActivationTimeout = nil
        guard isPresented else { return }
        makeKeyAndOrderFront(nil)
        // 兜底再抢一拍：有的机器 didBecomeActive 回调返回后才真正切 key。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, NSApp.isActive, !self.isKeyWindow else { return }
            self.makeKeyAndOrderFront(nil)
        }
    }

    /// 激活通知没来之前 `resignKey` 不关面板；但激活本身失败时不能留下一个
    /// 永远拿不到键盘的浮层，超时后解除等待并让正常失焦关闭路径接手。
    private func scheduleActivationTimeoutIfNeeded() {
        pendingActivationTimeout?.cancel()
        guard activationRecovery.isRecovering else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isPresented, self.activationRecovery.isRecovering else { return }
            self.activationRecovery.disarm()
            if !self.isKeyWindow { self.close() }
        }
        pendingActivationTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    // MARK: 落点与拖动

    /// 按当前设置落一次：有记住的位置就原样放回，没有就用默认落点。
    /// 结果行数变了也要重算——面板高度跟着行数走，锚点固定在左上角。
    func applyPlacement() {
        let preferred = screenForPointer()
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let next = QuickSearchPanelLayout.positionedFrame(
            rowCount: model?.results.count ?? 0,
            savedPosition: model?.panelPosition,
            visibleFrames: visibleFrames,
            preferredFrame: preferred?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900),
            savedSize: model?.panelSize
        )
        setContentSize(next.size)
        setFrame(next, display: isPresented, animate: false)
    }

    /// 拖完边框：尺寸和左上角一起记。从左边/上边拖会同时改变两者，
    /// 只写一次配置，避免两个字段各自落盘。
    func finishBorderResize() {
        guard let model else { return }
        model.rememberPanelFrame(
            size: QuickSearchPanelSize(size: frame.size),
            position: QuickSearchPanelPosition(frame: frame)
        )
    }

    /// 顶栏抓手发起的拖动。松手之后才写位置：WindowServer 接管这段拖动，
    /// mouseUp 不保证回到视图，所以改成轮询按键状态。
    func dragFromHeader(with event: NSEvent) {
        isDraggingFromHeader = true
        performDrag(with: event)
        schedulePositionSave()
    }

    func windowDidMove(_ notification: Notification) {
        guard isDraggingFromHeader else { return }
        schedulePositionSave()
    }

    private func schedulePositionSave() {
        pendingPositionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDraggingFromHeader else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.schedulePositionSave()
            } else {
                self.finishHeaderDrag()
            }
        }
        pendingPositionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func finishHeaderDrag() {
        pendingPositionSave?.cancel()
        pendingPositionSave = nil
        guard isDraggingFromHeader else { return }
        isDraggingFromHeader = false
        model?.rememberPanelPosition(QuickSearchPanelPosition(frame: frame))
    }

    /// 用指针位置选屏，而不是「主屏」：多显示器下呼出应该出现在手边。
    private func screenForPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: 键盘

    /// 输入法是否正在组词（有 marked text / 候选词）。
    /// 原生输入框使用窗口的字段编辑器，它就是一个 `NSTextView`。
    private var isComposingText: Bool {
        guard let textView = firstResponder as? NSTextView else { return false }
        // AppKit can retain {insertion point, 0} after composition ends.
        // A non-NSNotFound location alone does not mean there is marked text.
        return textView.hasMarkedText()
    }
}

// MARK: - 轻量失败提示

/// 失败提示的显示出口。测试注入替身，避免自动化测试在用户桌面上闪出真窗口。
@MainActor
protocol QuickSearchNoticePresenting: AnyObject {
    func present(_ text: String)
    func dismiss()
}

/// 面板关闭后的失败反馈。不复用主窗口，也不把它调出来——需求明确要求启动失败
/// 不能把 MacPilot 的设置界面拽到前台。
final class QuickSearchNoticePanel: NSPanel, QuickSearchNoticePresenting {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
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
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        isMovable = false
        // 只读提示：不抢键盘焦点，否则刚关掉的搜索又把焦点从用户的 App 手里拿走。
        becomesKeyOnlyIfNeeded = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.backgroundColor = .clear

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 44))
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(_ text: String) {
        label.stringValue = text
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: 420, height: 44)
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 72
        ))
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}
