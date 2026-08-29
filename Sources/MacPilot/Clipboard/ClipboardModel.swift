//
//  ClipboardModel.swift
//  MacPilot
//
//  剪贴板功能模型：生命周期、设置、全局快捷键、面板控制与选择动作。
//  行为参照 Maccy（MIT License, https://github.com/p0deje/Maccy）。
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
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

    var persist: (() -> Void)?

    private var panel: ClipboardPanel?

    // 全局快捷键（Carbon）。
    nonisolated static let hotKeySignature: OSType = 0x4D50434C // "MPCL"
    nonisolated static let hotKeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var hotKeyContext: ClipboardHotKeyContext?

    init() {
        monitor.settingsProvider = { [weak self] in self?.settings ?? ClipboardSettings() }
        monitor.onNewCopy { [weak self] item in
            self?.history.add(item)
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
        unregisterHotKey()
        closePanel()
        history.flush()
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    private func start() {
        monitor.start()
        registerHotKey()
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
        let clamped = max(1, min(1_000, value))
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
        unregisterHotKey()
        registerHotKey()
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

    // MARK: - Global hotkey

    private func registerHotKey() {
        guard hotKeyRef == nil, hotKeyEventHandler == nil else { return }
        let binding = settings.hotkey
        guard binding.isValid else { return }

        let context = ClipboardHotKeyContext(model: self)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(context).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr, let handler else { return }

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            Self.hotKeyModifiers(for: binding),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        guard status == noErr, let hotKey else {
            RemoveEventHandler(handler)
            return
        }

        hotKeyContext = context
        hotKeyEventHandler = handler
        hotKeyRef = hotKey
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyEventHandler { RemoveEventHandler(hotKeyEventHandler) }
        hotKeyRef = nil
        hotKeyEventHandler = nil
        hotKeyContext = nil
    }

    private static func hotKeyModifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
        var result: UInt32 = 0
        if binding.modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if binding.modifiers.contains(.option) { result |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { result |= UInt32(controlKey) }
        if binding.modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

@MainActor
private final class ClipboardHotKeyContext {
    weak var model: ClipboardModel?

    init(model: ClipboardModel) {
        self.model = model
    }
}

private func clipboardHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let context = Unmanaged<ClipboardHotKeyContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == ClipboardModel.hotKeySignature,
          hotKeyID.id == ClipboardModel.hotKeyIdentifier else {
        return status == noErr ? noErr : status
    }
    Task { @MainActor in
        context.model?.togglePanel()
    }
    return noErr
}
