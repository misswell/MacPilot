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
final class ClipboardModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "Clipboard")

    @Published private(set) var settings = ClipboardSettings()
    @Published private(set) var hasAccessibilityPermission = false

    /// 界面语言（由 MacPilotModel 同步），用于面板内文案。
    var language: AppLanguage = .system

    let history = ClipboardHistory()
    private let monitor = ClipboardMonitor()
    private lazy var hotKeyCenter = ClipboardHotKeyCenter()

    var persist: (() -> Void)?

    private var panel: ClipboardPanel?

    init() {
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

    func applyLoadedSettings(_ loaded: ClipboardSettings) {
        settings = loaded
        history.storageLimit = loaded.storageLimit
        history.pinsAtTop = loaded.pinsAtTop
        refreshPermissionStatus()
        if settings.isEnabled {
            start()
        }
    }

    func activateFromConfiguration() {
        guard settings.isEnabled else { return }
        start()
    }

    func shutdown() {
        monitor.stop()
        hotKeyCenter.stop()
        closePanel()
        history.flush()
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    private func start() {
        monitor.start()
        hotKeyCenter.updateBinding(settings.hotkey)
    }

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
        hotKeyCenter.updateBinding(settings.hotkey)
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
