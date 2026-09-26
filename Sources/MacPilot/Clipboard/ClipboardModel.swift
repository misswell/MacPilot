//
//  ClipboardModel.swift
//  MacPilot
//
//  剪贴板功能模型：生命周期、设置、全局快捷键、面板控制与选择动作。
//

import AppKit
import ApplicationServices
import Combine
import OSLog
import SwiftUI

/// 用户对历史条目的选择动作（默认/修饰键组合决定）。
enum ClipboardAction {
    case copy
    case paste
    case pasteWithoutFormatting

    init(modifierFlags: NSEvent.ModifierFlags, pasteByDefault: Bool) {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        switch flags {
        case [.command] where !pasteByDefault:
            self = .copy
        case [.command] where pasteByDefault:
            self = .paste
        case [.option] where !pasteByDefault:
            self = .paste
        case [.option] where pasteByDefault:
            self = .copy
        case [.option, .shift]:
            self = .pasteWithoutFormatting
        case [.command, .shift]:
            self = pasteByDefault ? .pasteWithoutFormatting : .paste
        default:
            self = pasteByDefault ? .paste : .copy
        }
    }
}

@MainActor
final class ClipboardModel: ObservableObject, ManagedFeature, FeatureResourceReporting {
    let identifier = "clipboard"
    private(set) var isRunning = false
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "Clipboard")

    @Published private(set) var settings = ClipboardSettings()
    @Published private(set) var hasAccessibilityPermission = false

    /// 界面语言（由 MacPilotModel 同步），用于面板内文案。
    var language: AppLanguage = .system

    private var historyStorage: ClipboardHistory?
    var history: ClipboardHistory {
        if let historyStorage { return historyStorage }
        let loaded = ClipboardHistory()
        loaded.storageLimit = settings.storageLimit
        loaded.pinsAtTop = settings.pinsAtTop
        historyObservation = loaded.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        historyStorage = loaded
        return loaded
    }
    var hasLoadedHistory: Bool { historyStorage != nil }
    var loadedContentBytes: UInt64? {
        historyStorage.map { history in
            UInt64(history.allItems.flatMap(\.contents).reduce(0) { total, content in
                total + (content.file == nil ? 0 : content.size)
            })
        }
    }
    /// 悬停详情列的状态机。视图通过本模型观察它（见 `observations`）。
    let preview = ClipboardPreviewController()
    private let monitor = ClipboardMonitor()
    private let retentionTask = BackgroundTask()
    var diagnosticTaskCount: Int { (monitor.isRunning ? 1 : 0) + (retentionTask.isRunning ? 1 : 0) }
    var diagnosticObserverCount: Int { 0 }
    private lazy var hotKeyCenter = ClipboardHotKeyCenter()

    var persist: (() -> Void)?

    private var panel: ClipboardPanel?
    private var observations: [AnyCancellable] = []
    private var historyObservation: AnyCancellable?

    init() {
        // The history JSON and image references are loaded on first use, not
        // every time a menu-bar process launches with Clipboard disabled.
        observations = [preview.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }]
        monitor.settingsProvider = { [weak self] in self?.settings ?? ClipboardSettings() }
        monitor.onNewCopy { [weak self] item in
            self?.history.add(item)
        }
        hotKeyCenter.onToggle = { [weak self] in
            self?.togglePanel()
        }
        refreshPermissionStatus()
    }

    // MARK: - Lifecycle

    func applyLoadedSettings(_ loaded: ClipboardSettings, activate: Bool = true) {
        settings = loaded
        historyStorage?.storageLimit = loaded.storageLimit
        historyStorage?.pinsAtTop = loaded.pinsAtTop
        refreshPermissionStatus()
        if activate && settings.isEnabled {
            start()
        }
    }

    func activateFromConfiguration() {
        guard settings.isEnabled else { return }
        start()
    }

    func shutdown() {
        isRunning = false
        retentionTask.stop()
        monitor.stop()
        hotKeyCenter.stop()
        closePanel()
        historyStorage?.flush()
        historyObservation = nil
        historyStorage = nil
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        history.pruneExpiredContent()
        monitor.start()
        retentionTask.start(interval: .seconds(60 * 60)) { [weak self] in
            self?.historyStorage?.pruneExpiredContent()
        }
        hotKeyCenter.updateBinding(settings.hotkey)
    }

    func stop() { shutdown() }

    // MARK: - Settings setters

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            start()
        } else {
            shutdown()
        }
        persist?()
    }

    func setStorageLimit(_ value: Int) {
        let clamped = ClipboardSettings.clampedStorageLimit(value)
        guard settings.storageLimit != clamped else { return }
        settings.storageLimit = clamped
        history.storageLimit = clamped
        persist?()
    }

    func setPasteByDefault(_ enabled: Bool) {
        guard settings.pasteByDefault != enabled else { return }
        settings.pasteByDefault = enabled
        persist?()
    }

    func setShowSearch(_ enabled: Bool) {
        guard settings.showSearch != enabled else { return }
        settings.showSearch = enabled
        persist?()
    }

    func setClearSystemClipboardOnClear(_ enabled: Bool) {
        guard settings.clearSystemClipboardOnClear != enabled else { return }
        settings.clearSystemClipboardOnClear = enabled
        persist?()
    }

    func setPinsAtTop(_ enabled: Bool) {
        guard settings.pinsAtTop != enabled else { return }
        settings.pinsAtTop = enabled
        history.pinsAtTop = enabled
        persist?()
    }

    func setHotkey(_ binding: SmartCaptureShortcutBinding) {
        guard binding != settings.hotkey else { return }
        settings.hotkey = binding.isValid ? binding : ClipboardSettings.defaultHotkey
        // Editing the shortcut while the feature is off must not register a
        // system-wide hot key that swallows the combination for nothing.
        if isRunning {
            hotKeyCenter.updateBinding(settings.hotkey)
        } else {
            hotKeyCenter.stop()
        }
        persist?()
    }

    // MARK: - Permissions

    func refreshPermissionStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        refreshPermissionStatus()
    }

    // MARK: - Panel

    func togglePanel() {
        if let panel, panel.isPresented {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        guard settings.isEnabled else { return }
        refreshPermissionStatus()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        monitor.isSuspended = true
        panel.open()
    }

    func closePanel() {
        preview.reset()
        panel?.close()
        panel = nil
        monitor.isSuspended = false
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel { [weak self] in
            self?.monitor.isSuspended = false
        } content: {
            ClipboardPanelContent(model: self)
        }
        // 详情列是窗口的一部分，展开与收起都要跟着改窗口宽度。
        preview.onVisibilityChange = { [weak panel] expanded in
            panel?.resize(showsPreview: expanded)
        }
        return panel
    }

    // MARK: - Actions

    /// Return / 点击当前条目时执行的动作。
    func performActionOnSelection() {
        guard let item = history.selectedItem else {
            // 没有选中项时把当前搜索词复制进系统剪贴板。
            if !history.searchQuery.isEmpty {
                monitor.copy(history.searchQuery)
                history.searchQuery = ""
                closePanel()
            }
            return
        }
        performAction(on: item, modifierFlags: NSEvent.modifierFlags)
    }

    func performAction(on item: ClipboardItem, modifierFlags: NSEvent.ModifierFlags) {
        let action = ClipboardAction(modifierFlags: modifierFlags, pasteByDefault: settings.pasteByDefault)
        switch action {
        case .copy:
            closePanel()
            monitor.copy(item)
        case .paste:
            closePanel()
            monitor.copy(item)
            monitor.paste()
        case .pasteWithoutFormatting:
            closePanel()
            monitor.copy(item, removeFormatting: true)
            monitor.paste()
        }
        history.recordUse(of: item)
        history.searchQuery = ""
    }

    func clearHistory() {
        history.clear()
        if settings.clearSystemClipboardOnClear {
            monitor.clearSystemClipboard()
        }
    }

    func clearAllHistory() {
        history.clearAll()
        if settings.clearSystemClipboardOnClear {
            monitor.clearSystemClipboard()
        }
    }
}
