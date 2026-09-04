//
//  ClipboardHotKeyCenter.swift
//  MacPilot
//
//  剪贴板面板全局快捷键（Carbon RegisterEventHotKey）。
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// 注册并管理剪贴板面板的全局快捷键；触发时回调 `onToggle`。
@MainActor
final class ClipboardHotKeyCenter {
    nonisolated static let hotKeySignature: OSType = 0x4D50434C // "MPCL"
    nonisolated static let hotKeyIdentifier: UInt32 = 1

    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var context: ClipboardHotKeyContext?
    private var registeredBinding: SmartCaptureShortcutBinding?

    /// 确保快捷键按 `binding` 注册；绑定相同则保持现状，绑定无效则注销。
    func updateBinding(_ binding: SmartCaptureShortcutBinding) {
        guard binding.isValid else {
            unregister()
            return
        }
        guard registeredBinding != binding || hotKeyRef == nil else { return }
        unregister()
        install(binding)
    }

    func stop() {
        unregister()
    }

    private func install(_ binding: SmartCaptureShortcutBinding) {
        let context = ClipboardHotKeyContext(onToggle: { [weak self] in
            self?.onToggle?()
        })
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

        self.context = context
        eventHandler = handler
        hotKeyRef = hotKey
        registeredBinding = binding
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
        context = nil
        registeredBinding = nil
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
    let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
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
          hotKeyID.signature == ClipboardHotKeyCenter.hotKeySignature,
          hotKeyID.id == ClipboardHotKeyCenter.hotKeyIdentifier else {
        return status == noErr ? noErr : status
    }
    Task { @MainActor in
        context.onToggle()
    }
    return noErr
}
