//
//  ScreenRecordingHotKeys.swift
//  MacPilot
//
//  Carbon global-hot-key plumbing for the recording model: the event
//  handler that fans hot key IDs out to the model, and the registration
//  helpers the model calls on every settings change.
//

import Carbon.HIToolbox
import Foundation

final class ScreenRecordingShortcutContext: @unchecked Sendable {
    weak var model: ScreenRecordingModel?

    init(model: ScreenRecordingModel) {
        self.model = model
    }
}

enum ScreenRecordingCarbonHotKey {
    static let signature: OSType = 0x4D505245 // "MPRE"

    static func modifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
        var result: UInt32 = 0
        if binding.modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if binding.modifiers.contains(.option) { result |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { result |= UInt32(controlKey) }
        if binding.modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func id(for index: UInt32) -> EventHotKeyID {
        EventHotKeyID(signature: signature, id: index)
    }
}

func screenRecordingCarbonEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let context = Unmanaged<ScreenRecordingShortcutContext>
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
          hotKeyID.signature == ScreenRecordingCarbonHotKey.signature else {
        return status == noErr ? noErr : status
    }
    Task { @MainActor in context.model?.handleHotKey(index: Int(hotKeyID.id)) }
    return noErr
}

