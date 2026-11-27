import Carbon.HIToolbox
import Foundation

enum WindowSwitcherShortcutDirection: UInt32, CaseIterable, Sendable {
    case forward = 1
    case reverse = 2
}

struct WindowSwitcherShortcutRegistration: Equatable {
    var registered: Set<WindowSwitcherShortcutDirection> = []
    var conflicts: Set<WindowSwitcherShortcutDirection> = []
}

@MainActor
protocol WindowSwitcherHotKeyRegistering: AnyObject {
    func register(onPress: @escaping @MainActor (WindowSwitcherShortcutDirection) -> Void) -> WindowSwitcherShortcutRegistration
    func unregister()
}

@MainActor
final class WindowSwitcherHotKeys: WindowSwitcherHotKeyRegistering {
    nonisolated static let signature: OSType = 0x4D505753 // MPWS

    private var handler: EventHandlerRef?
    private var context: WindowSwitcherHotKeyContext?
    private var hotKeys: [WindowSwitcherShortcutDirection: EventHotKeyRef] = [:]
    private var refused: [WindowSwitcherShortcutDirection: OSStatus] = [:]

    func register(onPress: @escaping @MainActor (WindowSwitcherShortcutDirection) -> Void) -> WindowSwitcherShortcutRegistration {
        if handler == nil {
            let context = WindowSwitcherHotKeyContext(onPress: onPress)
            // Carbon owns this retain until it confirms the handler was removed.
            let pointer = Unmanaged.passRetained(context).toOpaque()
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var installed: EventHandlerRef?
            let status = InstallEventHandler(GetApplicationEventTarget(), windowSwitcherHotKeyEventHandler, 1, &eventType, pointer, &installed)
            guard status == noErr, let installed else {
                Unmanaged<WindowSwitcherHotKeyContext>.fromOpaque(pointer).release()
                for direction in WindowSwitcherShortcutDirection.allCases { markRefused(direction, status: status) }
                return WindowSwitcherShortcutRegistration()
            }
            self.handler = installed
            self.context = context
        }
        context?.onPress = onPress

        var conflicts: Set<WindowSwitcherShortcutDirection> = []
        for direction in WindowSwitcherShortcutDirection.allCases where hotKeys[direction] == nil {
            let modifiers = UInt32(optionKey) | (direction == .reverse ? UInt32(shiftKey) : 0)
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Tab), modifiers,
                EventHotKeyID(signature: Self.signature, id: direction.rawValue),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys[direction] = hotKey
                if refused.removeValue(forKey: direction) != nil {
                    DiagnosticLog.write("WindowSwitcher", "Hot key \(direction) available")
                }
            } else {
                if status == OSStatus(eventHotKeyExistsErr) { conflicts.insert(direction) }
                markRefused(direction, status: status)
            }
        }
        context?.activeDirections = Set(hotKeys.keys)
        return WindowSwitcherShortcutRegistration(registered: Set(hotKeys.keys), conflicts: conflicts)
    }

    func unregister() {
        context?.onPress = nil
        context?.activeDirections = []
        for (direction, hotKey) in hotKeys {
            if UnregisterEventHotKey(hotKey) == noErr { hotKeys[direction] = nil }
        }
        guard hotKeys.isEmpty, let handler else { return }
        if RemoveEventHandler(handler) == noErr {
            if let context { Unmanaged.passUnretained(context).release() }
            self.handler = nil
            context = nil
        }
    }

    private func markRefused(_ direction: WindowSwitcherShortcutDirection, status: OSStatus) {
        let failureStatus = status == noErr ? OSStatus(eventNotHandledErr) : status
        if refused[direction] != failureStatus {
            refused[direction] = failureStatus
            DiagnosticLog.write("WindowSwitcher", "Hot key \(direction) refused (\(failureStatus))")
        }
    }
}

@MainActor
final class WindowSwitcherHotKeyContext {
    var onPress: (@MainActor (WindowSwitcherShortcutDirection) -> Void)?
    var activeDirections: Set<WindowSwitcherShortcutDirection> = []

    init(onPress: @escaping @MainActor (WindowSwitcherShortcutDirection) -> Void) {
        self.onPress = onPress
    }
}

func windowSwitcherHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData,
          GetEventClass(event) == OSType(kEventClassKeyboard),
          GetEventKind(event) == UInt32(kEventHotKeyPressed) else {
        return OSStatus(eventNotHandledErr)
    }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == WindowSwitcherHotKeys.signature,
          let direction = WindowSwitcherShortcutDirection(rawValue: hotKeyID.id), Thread.isMainThread else {
        return OSStatus(eventNotHandledErr)
    }
    let context = Unmanaged<WindowSwitcherHotKeyContext>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        guard context.activeDirections.contains(direction), let onPress = context.onPress else {
            return OSStatus(eventNotHandledErr)
        }
        onPress(direction)
        return noErr
    }
}
