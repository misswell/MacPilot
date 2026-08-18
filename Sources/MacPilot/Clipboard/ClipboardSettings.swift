//
//  ClipboardSettings.swift
//  MacPilot
//
//  剪贴板功能设置（并入 config.json）。
//

import Carbon.HIToolbox
import Foundation

struct ClipboardSettings: Codable, Equatable, Sendable {
    /// 功能总开关。
    var isEnabled: Bool
    /// 历史记录条数上限。
    var storageLimit: Int
    /// 点击历史条目时默认粘贴（否则只复制）。
    var pasteByDefault: Bool
    /// 弹出面板时显示搜索框。
    var showSearch: Bool
    /// 清除历史时同时清空系统剪贴板。
    var clearSystemClipboardOnClear: Bool
    /// 固定条目置顶（否则置底）。
    var pinsAtTop: Bool
    /// 全局快捷键。
    var hotkey: SmartCaptureShortcutBinding

    static let defaultHotkey = SmartCaptureShortcutBinding(
        keyCode: UInt16(kVK_ANSI_V),
        modifiers: [.command, .shift]
    )

    init(
        isEnabled: Bool = false,
        storageLimit: Int = 100,
        pasteByDefault: Bool = true,
        showSearch: Bool = true,
        clearSystemClipboardOnClear: Bool = false,
        pinsAtTop: Bool = true,
        hotkey: SmartCaptureShortcutBinding = ClipboardSettings.defaultHotkey
    ) {
        self.isEnabled = isEnabled
        self.storageLimit = max(1, min(1_000, storageLimit))
        self.pasteByDefault = pasteByDefault
        self.showSearch = showSearch
        self.clearSystemClipboardOnClear = clearSystemClipboardOnClear
        self.pinsAtTop = pinsAtTop
        self.hotkey = hotkey.isValid ? hotkey : ClipboardSettings.defaultHotkey
    }

    static let storageLimitOptions = [50, 100, 200, 500, 1_000]
}
