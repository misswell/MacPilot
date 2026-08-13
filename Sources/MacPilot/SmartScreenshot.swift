import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Vision

struct SmartCaptureElement: Equatable, Sendable {
    let role: String
    let frame: CGRect
}

enum SmartCaptureTargetResolver {
    private static let acceptedRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXPopUpButton", "AXMenuItem", "AXImage", "AXCell", "AXStaticText", "AXGroup",
        "AXScrollArea", "AXSheet", "AXWebArea", "AXMenu", "AXMenuBar", "AXSplitGroup",
        "AXTable", "AXOutline", "AXRow", "AXColumn", "AXToolbar", "AXHeading", "AXParagraph",
        "AXList", "AXForm", "AXGrid", "AXDocument", "AXLandmark", "AXRegion", "AXBlockQuote",
        "AXComboBox", "AXSlider", "AXDisclosureTriangle", "AXTabGroup"
    ]

    static func resolve(elementChain: [SmartCaptureElement], windowFrame: CGRect?) -> CGRect? {
        for element in elementChain where acceptedRoles.contains(element.role) {
            guard element.frame.width >= 12, element.frame.height >= 12 else { continue }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                let ratio = element.frame.width * element.frame.height
                    / (windowFrame.width * windowFrame.height)
                guard ratio <= 0.95 else { continue }
            }
            return element.frame.integral
        }
        return windowFrame?.integral
    }
}

struct SmartCaptureShortcutBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: InputSourceShortcutModifiers

    static let `default` = Self(keyCode: UInt16(kVK_F1), modifiers: [])

    init(keyCode: UInt16 = UInt16(kVK_F1), modifiers: InputSourceShortcutModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayName: String {
        modifiers.symbolDescription + MacPilotKeyCode.displayName(for: keyCode)
    }

    var validationError: SmartCaptureShortcutError? {
        // Escape is reserved by every selection overlay for cancellation;
        // keeping it unavailable with modifiers avoids an ambiguous cancel
        // versus capture gesture while a selection is active.
        if keyCode == UInt16(kVK_Escape) {
            return .reservedKey
        }
        if modifiers.isEmpty && !Self.functionKeyCodes.contains(keyCode) {
            return .modifierRequired
        }
        return nil
    }

    var isValid: Bool { validationError == nil }

    private static let functionKeyCodes: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
        UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16),
        UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20)
    ]

    func matches(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        guard self.keyCode == keyCode, !isRepeat else { return false }
        return InputSourceShortcutModifiers(flags) == modifiers
    }
}

/// Screenshot entry points exposed by the capture settings.  Smart Element
/// keeps the original F1 behaviour, while the remaining defaults mirror the
/// familiar macOS/Snapzy capture workflow.
enum ScreenCaptureShortcutKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case smartElement
    case area
    case fullscreen
    case activeWindow
    case areaAnnotate
    case ocr

    var defaultBinding: SmartCaptureShortcutBinding {
        switch self {
        case .smartElement:
            return .default
        case .area:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_4),
                modifiers: [.command, .shift]
            )
        case .fullscreen:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_3),
                modifiers: [.command, .shift]
            )
        case .activeWindow:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_9),
                modifiers: [.command, .shift]
            )
        case .areaAnnotate:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_7),
                modifiers: [.command, .shift]
            )
        case .ocr:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_2),
                modifiers: [.command, .shift]
            )
        }
    }

    var titleKey: String {
        switch self {
        case .smartElement: return "scSmartCaptureShortcut"
        case .area: return "scAreaCaptureShortcut"
        case .fullscreen: return "scFullscreenCaptureShortcut"
        case .activeWindow: return "scActiveWindowCaptureShortcut"
        case .areaAnnotate: return "scAreaAnnotateShortcut"
        case .ocr: return "scOCRShortcut"
        }
    }

    var editorTitleKey: String { "scChangeShortcut" }

    var id: String { rawValue }
}

enum SmartCaptureSelectionMode: Equatable, Sendable {
    case smartElement
    case manualArea
    case applicationWindow
    case areaAnnotate
    case ocr
}

enum SmartCaptureShortcutError: Error, Equatable {
    case reservedKey
    case modifierRequired
    case registrationFailed

    var messageKey: String {
        switch self {
        case .reservedKey: return "scShortcutReserved"
        case .modifierRequired: return "scShortcutModifierRequired"
        case .registrationFailed: return "scShortcutRegistrationFailed"
        }
    }
}

struct SmartCaptureStoredRect: Codable, Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 4 && height >= 4
    }
}

enum SmartCaptureSelectionGeometry {
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).integral
    }

    static func isMeaningful(_ rect: CGRect, minimumSize: CGFloat = 4) -> Bool {
        rect.width >= minimumSize && rect.height >= minimumSize
    }
}

/// The small, platform-independent state machine behind the live area
/// selection gesture.  Snapzy keeps the overlay visible while the user is
/// drawing, moving, or switching to application-window mode; keeping those
/// transitions in a value type makes the same behaviour available to both the
/// CGEvent tap and the AppKit fallback view.
enum SmartCaptureSelectionInteractionMode: Equatable, Sendable {
    case area
    case applicationWindow
}

enum SmartCaptureSelectionAction: Equatable, Sendable {
    case none
    case selectionChanged(CGRect)
    case commit(CGRect)
    case cancel
    case repeatLastArea
    case modeChanged(SmartCaptureSelectionInteractionMode)
}

struct SmartCaptureSelectionState: Equatable, Sendable {
    private(set) var mode: SmartCaptureSelectionInteractionMode = .area
    private(set) var selectionRect: CGRect?
    private(set) var dragStart: CGPoint?
    private(set) var lastPointer: CGPoint?
    private(set) var isDragging = false
    private var isSpacePressed = false
    private var clickTarget: CGRect?
    private var hasDrawnSelection = false
    private var nudgeOffset = CGPoint.zero

    mutating func reset(mode: SmartCaptureSelectionInteractionMode = .area) {
        self.mode = mode
        selectionRect = nil
        dragStart = nil
        lastPointer = nil
        isDragging = false
        isSpacePressed = false
        clickTarget = nil
        hasDrawnSelection = false
        nudgeOffset = .zero
    }

    mutating func pointerDown(at point: CGPoint, target: CGRect?) -> SmartCaptureSelectionAction {
        lastPointer = point
        clickTarget = target?.integral
        dragStart = point
        selectionRect = CGRect(origin: point, size: .zero)
        isDragging = true
        isSpacePressed = false
        nudgeOffset = .zero
        return .selectionChanged(.zero)
    }

    mutating func pointerDragged(to point: CGPoint) -> SmartCaptureSelectionAction {
        guard isDragging else { return .none }
        let previous = lastPointer ?? point
        lastPointer = point
        if isSpacePressed, let selectionRect, !selectionRect.isEmpty {
            let delta = CGPoint(x: point.x - previous.x, y: point.y - previous.y)
            let moved = selectionRect.offsetBy(dx: delta.x, dy: delta.y)
            self.selectionRect = moved
            if let dragStart {
                self.dragStart = CGPoint(x: dragStart.x + delta.x, y: dragStart.y + delta.y)
            }
            return .selectionChanged(moved)
        }
        guard let dragStart else { return .none }
        let rect = SmartCaptureSelectionGeometry.rect(from: dragStart, to: point)
            .offsetBy(dx: nudgeOffset.x, dy: nudgeOffset.y)
        selectionRect = rect
        hasDrawnSelection = !rect.isEmpty
        return .selectionChanged(rect)
    }

    mutating func pointerUp(at point: CGPoint) -> SmartCaptureSelectionAction {
        lastPointer = point
        guard isDragging else { return .none }
        _ = pointerDragged(to: point)
        isDragging = false
        isSpacePressed = false
        dragStart = nil
        guard let selectionRect,
              SmartCaptureSelectionGeometry.isMeaningful(selectionRect) else {
            if let clickTarget, SmartCaptureSelectionGeometry.isMeaningful(clickTarget) {
                self.clickTarget = nil
                return .commit(clickTarget)
            }
            if hasDrawnSelection {
                clickTarget = nil
                return .none
            }
            return .none
        }
        clickTarget = nil
        hasDrawnSelection = false
        return .commit(selectionRect.integral)
    }

    mutating func keyDown(keyCode: UInt16, modifiers: InputSourceShortcutModifiers = []) -> SmartCaptureSelectionAction {
        switch keyCode {
        case UInt16(kVK_Escape):
            return .cancel
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            guard !isDragging, mode == .area else { return .none }
            return .repeatLastArea
        case UInt16(kVK_Space):
            guard isDragging else { return .none }
            isSpacePressed = true
            return .none
        case UInt16(kVK_ANSI_A):
            guard !isDragging else { return .none }
            mode = mode == .area ? .applicationWindow : .area
            selectionRect = nil
            return .modeChanged(mode)
        case UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow):
            guard isDragging, let selectionRect, !selectionRect.isEmpty else { return .none }
            let distance: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let dx: CGFloat = keyCode == UInt16(kVK_LeftArrow) ? -distance : keyCode == UInt16(kVK_RightArrow) ? distance : 0
            let dy: CGFloat = keyCode == UInt16(kVK_DownArrow) ? -distance : keyCode == UInt16(kVK_UpArrow) ? distance : 0
            nudgeOffset.x += dx
            nudgeOffset.y += dy
            let moved = selectionRect.offsetBy(dx: dx, dy: dy)
            self.selectionRect = moved
            return .selectionChanged(moved)
        default:
            return .none
        }
    }

    mutating func keyUp(keyCode: UInt16) {
        if keyCode == UInt16(kVK_Space) {
            isSpacePressed = false
        }
    }
}

enum SmartCaptureClipboard {
    static func copy(image: CGImage, to pasteboard: NSPasteboard = .general) {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
}

enum SmartCaptureShortcut {
    static func matches(
        keyCode: UInt16,
        flags: CGEventFlags,
        isRepeat: Bool,
        binding: SmartCaptureShortcutBinding = .default
    ) -> Bool {
        binding.matches(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }
}

/// A shortcut binding paired with the Carbon/event-tap identifier used to
/// dispatch it. Keeping this tiny value type separate from the registration
/// handles makes the fallback path deterministic and unit-testable.
struct SmartCaptureShortcutEventBinding: Equatable, Sendable {
    let id: UInt32
    let binding: SmartCaptureShortcutBinding
}

enum SmartCaptureShortcutRouting {
    static let eventMask: CGEventMask = {
        var mask: CGEventMask = 0
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            mask |= CGEventMask(1) << type.rawValue
        }
        return mask
    }()

    static func matchingID(
        keyCode: UInt16,
        flags: CGEventFlags,
        isRepeat: Bool,
        bindings: [SmartCaptureShortcutEventBinding]
    ) -> UInt32? {
        bindings.first {
            $0.binding.matches(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }?.id
    }
}

private final class SmartShortcutContext: @unchecked Sendable {
    weak var controller: SmartScreenshotController?

    init(controller: SmartScreenshotController) {
        self.controller = controller
    }
}

private final class SmartCaptureShortcutEventTapContext: @unchecked Sendable {
    weak var controller: SmartScreenshotController?
    private let lock = NSLock()
    private var bindings: [SmartCaptureShortcutEventBinding]
    private var eventTap: CFMachPort?
    private var suppressedKeyCode: UInt16?
    private var suppressedModifiers: CGEventFlags = []
    private var suppressedKeyUpReceived = false
    private var suppressionDeadline: CFAbsoluteTime = 0

    init(
        controller: SmartScreenshotController,
        bindings: [SmartCaptureShortcutEventBinding]
    ) {
        self.controller = controller
        self.bindings = bindings
    }

    func update(bindings: [SmartCaptureShortcutEventBinding]) {
        lock.lock()
        self.bindings = bindings
        suppressedKeyCode = nil
        suppressedModifiers = []
        suppressedKeyUpReceived = false
        suppressionDeadline = 0
        lock.unlock()
    }

    func matchingID(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> UInt32? {
        lock.lock()
        let bindings = self.bindings
        lock.unlock()
        return SmartCaptureShortcutRouting.matchingID(
            keyCode: keyCode,
            flags: flags,
            isRepeat: isRepeat,
            bindings: bindings
        )
    }

    /// Once a fallback shortcut has matched, consume the matching key-up and
    /// modifier transitions as well. This prevents the same sequence from
    /// leaking to ordinary applications; macOS's own screenshot service may
    /// still require the user to disable its symbolic hotkey in System Settings.
    func beginSuppressing(keyCode: UInt16, flags: CGEventFlags) {
        lock.lock()
        suppressedKeyCode = keyCode
        suppressedModifiers = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        suppressedKeyUpReceived = false
        suppressionDeadline = CFAbsoluteTimeGetCurrent() + 1.0
        lock.unlock()
    }

    func shouldConsumeKeyDown(keyCode: UInt16) -> Bool {
        lock.lock()
        clearExpiredSuppressionIfNeeded()
        let shouldConsume = suppressedKeyCode == keyCode
        lock.unlock()
        return shouldConsume
    }

    func finishSuppressing(keyCode: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        clearExpiredSuppressionIfNeeded()
        guard suppressedKeyCode == keyCode else { return false }
        suppressedKeyUpReceived = true
        if suppressedModifiers.isEmpty {
            suppressedKeyCode = nil
        }
        return true
    }

    func consumeModifierTransition(flags: CGEventFlags) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        clearExpiredSuppressionIfNeeded()
        guard suppressedKeyCode != nil else { return false }
        if suppressedKeyUpReceived,
           flags.intersection(suppressedModifiers).isEmpty {
            suppressedKeyCode = nil
            suppressedModifiers = []
            suppressedKeyUpReceived = false
        }
        return true
    }

    func resetSuppression() {
        lock.lock()
        suppressedKeyCode = nil
        suppressedModifiers = []
        suppressedKeyUpReceived = false
        suppressionDeadline = 0
        lock.unlock()
    }

    private func clearExpiredSuppressionIfNeeded() {
        guard suppressedKeyCode != nil, suppressionDeadline > 0,
              CFAbsoluteTimeGetCurrent() >= suppressionDeadline else { return }
        suppressedKeyCode = nil
        suppressedModifiers = []
        suppressedKeyUpReceived = false
        suppressionDeadline = 0
    }

    func setEventTap(_ eventTap: CFMachPort?) {
        lock.lock()
        self.eventTap = eventTap
        lock.unlock()
    }

    func reenableEventTap() {
        lock.lock()
        let eventTap = self.eventTap
        lock.unlock()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }
}

private final class SmartCaptureSelectionEventTapContext: @unchecked Sendable {
    weak var controller: SmartScreenshotController?
    private let lock = NSLock()
    private var eventTap: CFMachPort?

    init(controller: SmartScreenshotController) {
        self.controller = controller
    }

    func setEventTap(_ eventTap: CFMachPort?) {
        lock.lock()
        self.eventTap = eventTap
        lock.unlock()
    }

    func reenableEventTap() {
        lock.lock()
        let eventTap = self.eventTap
        lock.unlock()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }
}

private enum SmartCaptureCarbonHotKey {
    static let signature: OSType = 0x4D504341 // "MPCA"
    static let captureID: UInt32 = 1
    static let cancelID: UInt32 = 2
    static let areaID: UInt32 = 3
    static let fullscreenID: UInt32 = 4
    static let ocrID: UInt32 = 5
    static let activeWindowID: UInt32 = 6
    static let areaAnnotateID: UInt32 = 7

    static func identifier(_ id: UInt32) -> EventHotKeyID {
        EventHotKeyID(signature: signature, id: id)
    }

    static func modifiers(for binding: SmartCaptureShortcutBinding) -> UInt32 {
        var modifiers: UInt32 = 0
        if binding.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if binding.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if binding.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    static func identifier(for kind: ScreenCaptureShortcutKind) -> EventHotKeyID {
        switch kind {
        case .smartElement: return identifier(captureID)
        case .area: return identifier(areaID)
        case .fullscreen: return identifier(fullscreenID)
        case .activeWindow: return identifier(activeWindowID)
        case .areaAnnotate: return identifier(areaAnnotateID)
        case .ocr: return identifier(ocrID)
        }
    }
}

/// macOS screenshot symbolic hotkeys use the same key combinations as the
/// Snapzy-style defaults. Carbon registration cannot claim those combinations;
/// the fallback event tap can, but the settings UI should still explain the
/// conflict instead of silently racing the system screenshot service.
enum SmartCaptureSystemShortcutConflict: Equatable {
    case area
    case fullscreen
    case screenshotOptions

    var titleKey: String {
        switch self {
        case .area: return "scSystemShortcutArea"
        case .fullscreen: return "scSystemShortcutFullscreen"
        case .screenshotOptions: return "scSystemShortcutOptions"
        }
    }
}

enum SmartCaptureSystemShortcutDetector {
    enum SystemHotkeyID: Int, CaseIterable {
        case saveAreaToFile = 28
        case copyAreaToClipboard = 29
        case saveScreenToFile = 30
        case copyScreenToClipboard = 31
        case screenshotOptions = 184
    }

    static func conflicts(for candidate: SmartCaptureShortcutBinding) -> [SmartCaptureSystemShortcutConflict] {
        guard let hotkeys = readHotkeys() else { return [] }
        return conflicts(for: candidate, hotkeys: hotkeys)
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Screenshots",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    private static func readHotkeys() -> [String: Any]? {
        if let prefs = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
           let hotkeys = prefs.dictionary(forKey: "AppleSymbolicHotKeys") {
            return hotkeys
        }
        guard let value = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) else { return nil }
        return value as? [String: Any]
    }

    private static func isEnabled(id: SystemHotkeyID, in hotkeys: [String: Any]) -> Bool {
        guard let entry = hotkeys[String(id.rawValue)] as? [String: Any] else { return false }
        if let enabled = entry["enabled"] as? Bool { return enabled }
        if let enabled = entry["enabled"] as? NSNumber { return enabled.boolValue }
        return true
    }

    private static func binding(for id: SystemHotkeyID, in hotkeys: [String: Any]) -> SmartCaptureShortcutBinding? {
        guard let entry = hotkeys[String(id.rawValue)] as? [String: Any],
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = integerValue(parameters[1]),
              let flags = integerValue(parameters[2]) else {
            return id.defaultBinding
        }
        // AppleSymbolicHotKeys stores modifier flags as NSEvent raw values
        // (e.g. 1_179_648 for ⌘⇧), not Carbon's cmdKey/shiftKey bits.
        return SmartCaptureShortcutBinding(
            keyCode: UInt16(clamping: keyCode),
            modifiers: modifiers(fromSystemFlags: UInt64(flags))
        )
    }

    private static func integerValue(_ value: Any) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let value as Int: return value
        case let value as Int32: return Int(value)
        case let value as UInt32: return Int(value)
        case let value as UInt64: return Int(value)
        default: return nil
        }
    }

    private static func modifiers(fromSystemFlags flags: UInt64) -> InputSourceShortcutModifiers {
        var result: InputSourceShortcutModifiers = []
        if flags & UInt64(NSEvent.ModifierFlags.shift.rawValue) != 0 { result.insert(.shift) }
        if flags & UInt64(NSEvent.ModifierFlags.control.rawValue) != 0 { result.insert(.control) }
        if flags & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 { result.insert(.option) }
        if flags & UInt64(NSEvent.ModifierFlags.command.rawValue) != 0 { result.insert(.command) }
        return result
    }
}

extension SmartCaptureSystemShortcutDetector {
    /// Test seam for symbolic-hotkey dictionaries. The production detector
    /// reads the same AppleSymbolicHotKeys structure via UserDefaults/CFPreferences.
    static func conflicts(
        for candidate: SmartCaptureShortcutBinding,
        hotkeys: [String: Any]
    ) -> [SmartCaptureSystemShortcutConflict] {
        var conflicts: [SmartCaptureSystemShortcutConflict] = []
        for id in SystemHotkeyID.allCases {
            guard isEnabled(id: id, in: hotkeys),
                  let systemBinding = binding(for: id, in: hotkeys),
                  systemBinding == candidate else { continue }
            let conflict: SmartCaptureSystemShortcutConflict
            switch id {
            case .saveAreaToFile, .copyAreaToClipboard: conflict = .area
            case .saveScreenToFile, .copyScreenToClipboard: conflict = .fullscreen
            case .screenshotOptions: conflict = .screenshotOptions
            }
            if !conflicts.contains(conflict) { conflicts.append(conflict) }
        }
        return conflicts
    }
}

private extension SmartCaptureSystemShortcutDetector.SystemHotkeyID {
    var defaultBinding: SmartCaptureShortcutBinding {
        switch self {
        case .saveAreaToFile, .copyAreaToClipboard:
            var modifiers: InputSourceShortcutModifiers = [.command, .shift]
            if self == .copyAreaToClipboard { modifiers.insert(.control) }
            return SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: modifiers)
        case .saveScreenToFile, .copyScreenToClipboard:
            var modifiers: InputSourceShortcutModifiers = [.command, .shift]
            if self == .copyScreenToClipboard { modifiers.insert(.control) }
            return SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: modifiers)
        case .screenshotOptions:
            return SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_5), modifiers: [.command, .shift])
        }
    }
}

private func smartCaptureShortcutEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent?,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return event.map(Unmanaged.passUnretained) }
    let context = Unmanaged<SmartCaptureShortcutEventTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        context.resetSuppression()
        context.reenableEventTap()
        return event.map(Unmanaged.passUnretained)
    }
    guard let event else {
        return event.map(Unmanaged.passUnretained)
    }
    switch type {
    case .keyDown:
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if let id = context.matchingID(keyCode: keyCode, flags: event.flags, isRepeat: isRepeat) {
            context.beginSuppressing(keyCode: keyCode, flags: event.flags)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    context.controller?.handleShortcutEvent(id: id)
                }
            } else {
                Task { @MainActor in
                    context.controller?.handleShortcutEvent(id: id)
                }
            }
            return nil
        }
        // A held fallback key can generate repeat key-down events. They must
        // not leak to the system after the first event was consumed.
        return context.shouldConsumeKeyDown(keyCode: keyCode)
            ? nil
            : Unmanaged.passUnretained(event)
    case .keyUp:
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        return context.finishSuppressing(keyCode: keyCode)
            ? nil
            : Unmanaged.passUnretained(event)
    case .flagsChanged:
        return context.consumeModifierTransition(flags: event.flags)
            ? nil
            : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

private func smartCaptureSelectionEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent?,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return event.map(Unmanaged.passUnretained) }
    let context = Unmanaged<SmartCaptureSelectionEventTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        context.reenableEventTap()
        return event.map(Unmanaged.passUnretained)
    }
    guard let event else { return nil }
    let controller = context.controller
    switch type {
    case .mouseMoved:
        let point = event.location
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller?.handleSelectionMouseMoved(atQuartzPoint: point) }
        } else {
            Task { @MainActor in controller?.handleSelectionMouseMoved(atQuartzPoint: point) }
        }
        return nil
    case .leftMouseDown:
        let point = event.location
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller?.handleSelectionMouseDown(atQuartzPoint: point) }
        } else {
            Task { @MainActor in controller?.handleSelectionMouseDown(atQuartzPoint: point) }
        }
        return nil
    case .leftMouseDragged:
        let point = event.location
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller?.handleSelectionMouseDragged(atQuartzPoint: point) }
        } else {
            Task { @MainActor in controller?.handleSelectionMouseDragged(atQuartzPoint: point) }
        }
        return nil
    case .leftMouseUp:
        let point = event.location
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller?.handleSelectionMouseUp(atQuartzPoint: point) }
        } else {
            Task { @MainActor in controller?.handleSelectionMouseUp(atQuartzPoint: point) }
        }
        return nil
    case .rightMouseDown:
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller?.cancelSelection() }
        } else {
            Task { @MainActor in controller?.cancelSelection() }
        }
        return nil
    case .keyDown:
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = InputSourceShortcutModifiers(event.flags)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _ = controller?.handleSelectionKeyDown(keyCode: keyCode, modifiers: modifiers)
            }
            return nil
        }
        Task { @MainActor in
            _ = controller?.handleSelectionKeyDown(keyCode: keyCode, modifiers: modifiers)
        }
        return nil
    case .keyUp:
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _ = controller?.handleSelectionKeyUp(keyCode: keyCode)
            }
            return nil
        }
        Task { @MainActor in controller?.handleSelectionKeyUp(keyCode: keyCode) }
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

private func smartShortcutCarbonEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let context = Unmanaged<SmartShortcutContext>.fromOpaque(userData).takeUnretainedValue()
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
          hotKeyID.signature == SmartCaptureCarbonHotKey.signature
    else { return status == noErr ? noErr : status }

    Task { @MainActor in context.controller?.handleShortcutEvent(id: hotKeyID.id) }
    return noErr
}

@MainActor
final class SmartScreenshotController {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    private let language: () -> AppLanguage
    private let onCapture: (CGImage) -> Void
    private let onError: (Error) -> Void
    private let onSelectionRect: (CGRect) -> Void
    private let onRepeatLastArea: () -> Void
    private let onFullscreenCapture: () -> Void
    private let onActiveWindowCapture: () -> Void
    private let onAreaAnnotateCapture: (CGImage) -> Void
    private let onOCRCapture: (CGImage) -> Void
    private var shortcutContext: SmartShortcutContext?
    nonisolated(unsafe) private var shortcutHotKey: EventHotKeyRef?
    nonisolated(unsafe) private var selectionCancelHotKey: EventHotKeyRef?
    nonisolated(unsafe) private var shortcutEventHandler: EventHandlerRef?
    private var shortcutEventHandlerIsTransient = false
    private var overlays: [SmartCaptureOverlayPanel] = []
    private var currentTarget: CGRect?
    private var manualSelectionStart: CGPoint?
    private var manualSelectionRect: CGRect?
    private var pinControllers: [UUID: SmartPinWindowController] = [:]
    private var quickAccessControllers: [UUID: SmartQuickAccessWindowController] = [:]
    private var inlineAnnotationControllers: [UUID: SmartAnnotationWindowController] = [:]
    private var isSelecting = false
    private var pendingTargetUpdate: DispatchWorkItem?
    private var latestPointerLocation: CGPoint?
    private var lastSelectionCoordinateFailureLogAt: CFAbsoluteTime = 0
    private var manualSelectionCoordinateFailure = false
    private var shortcutBinding: SmartCaptureShortcutBinding
    private var shortcutSuspended = false
    /// Whether the feature is enabled and expects a Carbon registration.
    /// This is distinct from the registration handles because registration
    /// can fail when another app or macOS already owns the combination.
    private var shortcutRegistrationRequested = false
    private var additionalShortcutBindings: [ScreenCaptureShortcutKind: SmartCaptureShortcutBinding]
    nonisolated(unsafe) private var additionalShortcutHotKeys: [ScreenCaptureShortcutKind: EventHotKeyRef] = [:]
    private var fallbackShortcutBindings: [SmartCaptureShortcutEventBinding] = []
    nonisolated(unsafe) private var shortcutEventTap: CFMachPort?
    nonisolated(unsafe) private var shortcutEventTapSource: CFRunLoopSource?
    nonisolated(unsafe) private var shortcutEventTapContext: SmartCaptureShortcutEventTapContext?
    nonisolated(unsafe) private var selectionEventTap: CFMachPort?
    nonisolated(unsafe) private var selectionEventTapSource: CFRunLoopSource?
    nonisolated(unsafe) private var selectionEventTapContext: SmartCaptureSelectionEventTapContext?
    private var selectionMode: SmartCaptureSelectionMode = .smartElement
    private var selectionInteraction = SmartCaptureSelectionState()

    init(
        language: @escaping () -> AppLanguage,
        onCapture: @escaping (CGImage) -> Void,
        onError: @escaping (Error) -> Void,
        onSelectionRect: @escaping (CGRect) -> Void = { _ in },
        onRepeatLastArea: @escaping () -> Void = {},
        shortcutBinding: SmartCaptureShortcutBinding = .default,
        additionalShortcutBindings: [ScreenCaptureShortcutKind: SmartCaptureShortcutBinding] = [:],
        onFullscreenCapture: @escaping () -> Void = {},
        onActiveWindowCapture: @escaping () -> Void = {},
        onAreaAnnotateCapture: @escaping (CGImage) -> Void = { _ in },
        onOCRCapture: @escaping (CGImage) -> Void = { _ in }
    ) {
        self.language = language
        self.onCapture = onCapture
        self.onError = onError
        self.onSelectionRect = onSelectionRect
        self.onRepeatLastArea = onRepeatLastArea
        self.shortcutBinding = shortcutBinding
        self.additionalShortcutBindings = additionalShortcutBindings
        self.onFullscreenCapture = onFullscreenCapture
        self.onActiveWindowCapture = onActiveWindowCapture
        self.onAreaAnnotateCapture = onAreaAnnotateCapture
        self.onOCRCapture = onOCRCapture
    }

    func start() {
        guard !shortcutSuspended else { return }
        shortcutRegistrationRequested = true
        guard shortcutHotKey == nil, shortcutEventHandler == nil, shortcutEventTap == nil else { return }
        fallbackShortcutBindings.removeAll(keepingCapacity: true)
        if let error = registerShortcut() {
            onError(error)
            return
        }
        // Keep the primary smart-capture shortcut usable even when a system
        // shortcut (for example ⌘⇧3/4) prevents one of the optional entry
        // points from being registered. The settings editor can then be used
        // to replace the conflicting entry without losing the working one.
        _ = registerAdditionalShortcuts()
        _ = refreshShortcutEventTap()
    }

    /// Temporarily releases the global registration while the shortcut recorder
    /// is focused, so recording the current shortcut cannot also start capture.
    func suspendShortcut() {
        shortcutSuspended = true
        unregisterShortcut()
        unregisterAdditionalShortcuts()
    }

    /// Ends shortcut-editing mode. Registration is optional because the
    /// settings sheet can also be opened while the feature itself is off.
    /// In that case we must not silently re-enable the global shortcut when
    /// the sheet is dismissed.
    func resumeShortcut(register: Bool = true) {
        shortcutSuspended = false
        if register {
            start()
        }
    }

    private func registerShortcut() -> SmartCaptureShortcutError? {
        guard let validationError = shortcutBinding.validationError else {
            return registerValidatedShortcut()
        }
        return validationError
    }

    private func registerValidatedShortcut() -> SmartCaptureShortcutError? {
        let context = SmartShortcutContext(controller: self)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            smartShortcutCarbonEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(context).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr, let handler else {
            Self.logger.error("Could not install Carbon shortcut event handler: \(handlerStatus, privacy: .public)")
            return .registrationFailed
        }

        let systemConflict = !SmartCaptureSystemShortcutDetector.conflicts(for: shortcutBinding).isEmpty
        var hotKey: EventHotKeyRef?
        let hotKeyStatus: OSStatus = systemConflict
            ? OSStatus(-9876)
            : RegisterEventHotKey(
                UInt32(shortcutBinding.keyCode),
                SmartCaptureCarbonHotKey.modifiers(for: shortcutBinding),
                SmartCaptureCarbonHotKey.identifier(SmartCaptureCarbonHotKey.captureID),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyNoOptions),
                &hotKey
            )
        shortcutContext = context
        shortcutEventHandler = handler
        shortcutEventHandlerIsTransient = false
        if hotKeyStatus == noErr, let hotKey {
            shortcutHotKey = hotKey
            Self.logger.info("Global shortcut registered: \(self.shortcutBinding.displayName, privacy: .public)")
            return nil
        }

        // Do not use a CGEvent tap to steal a shortcut owned by another app.
        // The fallback is reserved for macOS screenshot symbolic hotkeys that
        // Carbon intentionally refuses; the editor warns users that macOS's
        // own action may still need to be disabled in System Settings.
        guard AXIsProcessTrusted(),
              !SmartCaptureSystemShortcutDetector.conflicts(for: shortcutBinding).isEmpty else {
            if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
            shortcutEventHandler = nil
            shortcutContext = nil
            Self.logger.error("Could not register shortcut \(self.shortcutBinding.displayName, privacy: .public): \(hotKeyStatus, privacy: .public)")
            return .registrationFailed
        }

        // macOS owns ⌘⇧3/4 (and users may have other system shortcuts). Carbon
        // refuses those combinations; use the tap as a targeted fallback for
        // our action while the editor guides the user through disabling the
        // duplicate system shortcut.
        fallbackShortcutBindings = [SmartCaptureShortcutEventBinding(
            id: SmartCaptureCarbonHotKey.captureID,
            binding: shortcutBinding
        )]
        guard refreshShortcutEventTap() else {
            if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
            shortcutEventHandler = nil
            shortcutContext = nil
            fallbackShortcutBindings.removeAll(keepingCapacity: false)
            Self.logger.error("Could not register shortcut \(self.shortcutBinding.displayName, privacy: .public): \(hotKeyStatus, privacy: .public)")
            return .registrationFailed
        }
        Self.logger.info("Global shortcut registered through event tap: \(self.shortcutBinding.displayName, privacy: .public)")
        return nil
    }

    private func unregisterShortcut() {
        unregisterSelectionCancelShortcut()
        unregisterAdditionalShortcuts()
        stopShortcutEventTap()
        fallbackShortcutBindings.removeAll(keepingCapacity: false)
        if let shortcutHotKey {
            UnregisterEventHotKey(shortcutHotKey)
        }
        if let shortcutEventHandler {
            RemoveEventHandler(shortcutEventHandler)
        }
        shortcutHotKey = nil
        shortcutEventHandler = nil
        shortcutContext = nil
    }

    func updateAdditionalShortcutBindings(_ bindings: [ScreenCaptureShortcutKind: SmartCaptureShortcutBinding]) {
        _ = updateAdditionalShortcutBindingsReturningError(bindings)
    }

    @discardableResult
    private func registerAdditionalShortcuts() -> Set<ScreenCaptureShortcutKind> {
        guard shortcutContext != nil, shortcutEventHandler != nil else { return [] }
        var registeredBindings: [SmartCaptureShortcutBinding] = []
        var registeredKinds: Set<ScreenCaptureShortcutKind> = []
        fallbackShortcutBindings.removeAll { $0.id != SmartCaptureCarbonHotKey.captureID }
        unregisterAdditionalShortcuts()
        for kind in [ScreenCaptureShortcutKind.area, .fullscreen, .activeWindow, .areaAnnotate, .ocr] {
            guard let binding = additionalShortcutBindings[kind], binding.isValid else { continue }
            guard !registeredBindings.contains(binding), binding != shortcutBinding else {
                Self.logger.error("Skipping duplicate screenshot shortcut \(kind.rawValue, privacy: .public)")
                continue
            }
            // Track both Carbon and fallback registrations so a malformed
            // legacy config cannot install the same key sequence twice.
            registeredBindings.append(binding)
            let id: UInt32
            switch kind {
            case .area: id = SmartCaptureCarbonHotKey.areaID
            case .fullscreen: id = SmartCaptureCarbonHotKey.fullscreenID
            case .activeWindow: id = SmartCaptureCarbonHotKey.activeWindowID
            case .areaAnnotate: id = SmartCaptureCarbonHotKey.areaAnnotateID
            case .ocr: id = SmartCaptureCarbonHotKey.ocrID
            case .smartElement: continue
            }
            let systemConflict = !SmartCaptureSystemShortcutDetector.conflicts(for: binding).isEmpty
            var hotKey: EventHotKeyRef?
            let status: OSStatus = systemConflict
                ? OSStatus(-9876)
                : RegisterEventHotKey(
                    UInt32(binding.keyCode),
                    SmartCaptureCarbonHotKey.modifiers(for: binding),
                    SmartCaptureCarbonHotKey.identifier(id),
                    GetApplicationEventTarget(),
                    OptionBits(kEventHotKeyNoOptions),
                    &hotKey
                )
            guard status == noErr, let hotKey else {
                Self.logger.error("Could not register \(kind.rawValue) shortcut \(binding.displayName, privacy: .public): \(status, privacy: .public)")
                if AXIsProcessTrusted(),
                   !SmartCaptureSystemShortcutDetector.conflicts(for: binding).isEmpty {
                    fallbackShortcutBindings.append(SmartCaptureShortcutEventBinding(id: id, binding: binding))
                    // A system screenshot symbolic hotkey is intentionally
                    // accepted when Accessibility is available; the editor
                    // warns that macOS's own shortcut may also run.
                    registeredKinds.insert(kind)
                }
                continue
            }
            additionalShortcutHotKeys[kind] = hotKey
            registeredKinds.insert(kind)
        }
        return registeredKinds
    }

    private func unregisterAdditionalShortcuts() {
        for hotKey in additionalShortcutHotKeys.values { UnregisterEventHotKey(hotKey) }
        additionalShortcutHotKeys.removeAll(keepingCapacity: false)
    }

    private func refreshShortcutEventTap() -> Bool {
        let bindings = fallbackShortcutBindings
        guard !bindings.isEmpty else {
            stopShortcutEventTap()
            return true
        }
        guard AXIsProcessTrusted() else {
            Self.logger.error("Shortcut fallback requires Accessibility permission")
            stopShortcutEventTap()
            return false
        }
        if let context = shortcutEventTapContext {
            context.update(bindings: bindings)
            return true
        }
        let context = SmartCaptureShortcutEventTapContext(controller: self, bindings: bindings)
        guard let eventTap = CGEvent.tapCreate(
            // Use the HID tap for the earliest possible observation. Some
            // macOS symbolic hotkeys still run before third-party taps; the UI
            // therefore offers a direct link to disable the system shortcut.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: SmartCaptureShortcutRouting.eventMask,
            callback: smartCaptureShortcutEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
            Self.logger.error("Could not create screenshot shortcut fallback event tap")
            return false
        }
        shortcutEventTapContext = context
        shortcutEventTap = eventTap
        shortcutEventTapSource = source
        context.setEventTap(eventTap)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func stopShortcutEventTap() {
        if let source = shortcutEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let eventTap = shortcutEventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        shortcutEventTapSource = nil
        shortcutEventTap = nil
        shortcutEventTapContext = nil
    }

    private func refreshSelectionEventTap() -> Bool {
        guard isSelecting else {
            stopSelectionEventTap()
            return true
        }
        guard AXIsProcessTrusted() else { return false }
        guard selectionEventTap == nil else { return true }
        let context = SmartCaptureSelectionEventTapContext(controller: self)
        var eventMask: CGEventMask = 0
        for type in [
            CGEventType.mouseMoved,
            CGEventType.leftMouseDown,
            CGEventType.leftMouseDragged,
            CGEventType.leftMouseUp,
            CGEventType.rightMouseDown,
            CGEventType.keyDown,
            CGEventType.keyUp
        ] {
            eventMask |= CGEventMask(1) << type.rawValue
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: smartCaptureSelectionEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
            Self.logger.error("Could not create screenshot selection event tap")
            return false
        }
        selectionEventTapContext = context
        selectionEventTap = eventTap
        selectionEventTapSource = source
        context.setEventTap(eventTap)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func stopSelectionEventTap() {
        if let source = selectionEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let eventTap = selectionEventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        selectionEventTapSource = nil
        selectionEventTap = nil
        selectionEventTapContext = nil
    }

    @discardableResult
    func updateAdditionalShortcutBindingsReturningError(
        _ bindings: [ScreenCaptureShortcutKind: SmartCaptureShortcutBinding],
        requiredKind: ScreenCaptureShortcutKind? = nil
    ) -> SmartCaptureShortcutError? {
        for binding in bindings.values {
            if let error = binding.validationError { return error }
        }
        if let requiredKind,
           let candidate = bindings[requiredKind],
           shortcutRegistrationRequested,
           (candidate == shortcutBinding || !probeShortcut(candidate, kind: requiredKind)) {
            return .registrationFailed
        }
        let previous = additionalShortcutBindings
        additionalShortcutBindings = bindings
        // When the feature is disabled, or when its primary shortcut could
        // not be registered, keep the new value in memory and let a later
        // activation retry registration. This makes shortcut editing usable
        // even if another app temporarily owns the old combination.
        guard !shortcutSuspended,
              shortcutRegistrationRequested,
              shortcutContext != nil,
              shortcutEventHandler != nil else { return nil }
        unregisterAdditionalShortcuts()
        let registeredKinds = registerAdditionalShortcuts()
        let fallbackReady = refreshShortcutEventTap()
        if let requiredKind,
           bindings[requiredKind] != nil,
           (!registeredKinds.contains(requiredKind) || !fallbackReady) {
            additionalShortcutBindings = previous
            _ = registerAdditionalShortcuts()
            _ = refreshShortcutEventTap()
            return .registrationFailed
        }
        return nil
    }

    /// Probe a candidate while the shortcut editor has suspended all live
    /// registrations. Carbon lets us reserve the combination briefly without
    /// installing a handler; immediately releasing it leaves the editor
    /// suspended while still detecting macOS/other-app conflicts.
    private func probeShortcut(_ binding: SmartCaptureShortcutBinding, kind: ScreenCaptureShortcutKind) -> Bool {
        guard binding.isValid, binding != shortcutBinding else { return false }
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            SmartCaptureCarbonHotKey.modifiers(for: binding),
            SmartCaptureCarbonHotKey.identifier(for: kind),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if status == noErr { return true }
        // Carbon deliberately refuses the combinations reserved by macOS's
        // screenshot service (⌘⇧3/4 by default). They are still safe for our
        // event-tap fallback when Accessibility is trusted.
        return AXIsProcessTrusted() && !SmartCaptureSystemShortcutDetector.conflicts(for: binding).isEmpty
    }

    private func registerSelectionCancelShortcut() {
        guard selectionCancelHotKey == nil else { return }
        if shortcutContext == nil || shortcutEventHandler == nil {
            let context = SmartShortcutContext(controller: self)
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            var handler: EventHandlerRef?
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                smartShortcutCarbonEventHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(context).toOpaque(),
                &handler
            )
            guard status == noErr, let handler else { return }
            shortcutContext = context
            shortcutEventHandler = handler
            shortcutEventHandlerIsTransient = true
        }
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            SmartCaptureCarbonHotKey.identifier(SmartCaptureCarbonHotKey.cancelID),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKey
        )
        guard status == noErr, let hotKey else {
            Self.logger.error("Could not register Escape cancellation shortcut: \(status, privacy: .public)")
            if shortcutEventHandlerIsTransient {
                if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
                shortcutEventHandler = nil
                shortcutContext = nil
                shortcutEventHandlerIsTransient = false
            }
            return
        }
        selectionCancelHotKey = hotKey
    }

    private func unregisterSelectionCancelShortcut() {
        if let selectionCancelHotKey {
            UnregisterEventHotKey(selectionCancelHotKey)
        }
        selectionCancelHotKey = nil
        if shortcutEventHandlerIsTransient {
            if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
            shortcutEventHandler = nil
            shortcutContext = nil
            shortcutEventHandlerIsTransient = false
        }
    }

    func updateShortcutBinding(_ binding: SmartCaptureShortcutBinding) {
        _ = updateShortcutBindingReturningError(binding)
    }

    @discardableResult
    func updateShortcutBindingReturningError(_ binding: SmartCaptureShortcutBinding) -> SmartCaptureShortcutError? {
        guard binding.validationError == nil else { return binding.validationError }
        guard binding != shortcutBinding else { return nil }
        let previousBinding = shortcutBinding
        let wasRegistered = shortcutHotKey != nil || shortcutEventHandler != nil
        if shortcutSuspended {
            guard shortcutRegistrationRequested else {
                shortcutBinding = binding
                return nil
            }
            shortcutBinding = binding
            if let error = registerShortcut() {
                shortcutBinding = previousBinding
                return error
            }
            unregisterShortcut()
            return nil
        }
        // If the feature is enabled but its previous registration failed,
        // changing the binding must still probe/register the new candidate.
        // Otherwise a conflicting shortcut could be persisted as if it had
        // been activated successfully.
        guard wasRegistered || shortcutRegistrationRequested else {
            shortcutBinding = binding
            return nil
        }
        if wasRegistered { unregisterShortcut() }
        shortcutBinding = binding
        if let error = registerShortcut() {
            shortcutBinding = previousBinding
            if wasRegistered {
                _ = registerShortcut()
                if isSelecting { registerSelectionCancelShortcut() }
            }
            return error
        }
        // Optional entry points may be claimed by macOS (⌘⇧3/4, for
        // example). Keep the newly registered primary shortcut usable even
        // when one of those optional registrations cannot be restored.
        _ = registerAdditionalShortcuts()
        _ = refreshShortcutEventTap()
        if isSelecting {
            registerSelectionCancelShortcut()
        }
        return nil
    }

    func stop() {
        shortcutRegistrationRequested = false
        cancelSelection()
        pendingTargetUpdate?.cancel()
        pendingTargetUpdate = nil
        latestPointerLocation = nil
        manualSelectionStart = nil
        manualSelectionRect = nil
        selectionMode = .smartElement
        unregisterShortcut()
        let controllers = Array(pinControllers.values)
        pinControllers.removeAll(keepingCapacity: false)
        for controller in controllers { controller.close() }
        let quickAccessControllers = Array(self.quickAccessControllers.values)
        self.quickAccessControllers.removeAll(keepingCapacity: false)
        for controller in quickAccessControllers { controller.close() }
        let inlineAnnotationControllers = Array(self.inlineAnnotationControllers.values)
        self.inlineAnnotationControllers.removeAll(keepingCapacity: false)
        for controller in inlineAnnotationControllers { controller.close() }
    }

    deinit {
        if let selectionEventTap { CGEvent.tapEnable(tap: selectionEventTap, enable: false) }
        if let shortcutEventTap { CGEvent.tapEnable(tap: shortcutEventTap, enable: false) }
        if let selectionCancelHotKey { UnregisterEventHotKey(selectionCancelHotKey) }
        if let shortcutHotKey { UnregisterEventHotKey(shortcutHotKey) }
        for hotKey in additionalShortcutHotKeys.values { UnregisterEventHotKey(hotKey) }
        if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
    }

    func startSelection(mode: SmartCaptureSelectionMode = .smartElement) {
        guard !isSelecting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            Self.logger.error("Selection rejected because required permissions are unavailable")
            onError(ScreenCaptureError.permissionRequired)
            return
        }
        isSelecting = true
        selectionMode = mode
        selectionInteraction.reset(mode: mode == .applicationWindow ? .applicationWindow : .area)
        manualSelectionCoordinateFailure = false
        lastSelectionCoordinateFailureLogAt = 0
        registerSelectionCancelShortcut()
        let initialPoint = NSEvent.mouseLocation
        currentTarget = mode == .smartElement ? SmartAXTargetQuery.target(at: initialPoint) : nil
        if mode == .applicationWindow {
            currentTarget = SmartAXTargetQuery.applicationWindowTarget(at: initialPoint)
        }
        Self.logger.info("Selection started; initial target available: \(self.currentTarget != nil)")
        overlays = NSScreen.screens.map { screen in
            let panel = SmartCaptureOverlayPanel(screen: screen)
            panel.overlayView.targetFrame = currentTarget
            panel.overlayView.onMove = { [weak self] point in self?.updateTarget(at: point) }
            panel.overlayView.onMouseDown = { [weak self] point in self?.handleSelectionMouseDown(atAppKitPoint: point) }
            panel.overlayView.onMouseDragged = { [weak self] point in self?.handleSelectionMouseDragged(atAppKitPoint: point) }
            panel.overlayView.onMouseUp = { [weak self] point in self?.handleSelectionMouseUp(atAppKitPoint: point) }
            panel.overlayView.onCancel = { [weak self] in self?.cancelSelection() }
            panel.overlayView.onKeyDown = { [weak self] keyCode, modifiers in
                _ = self?.handleSelectionKeyDown(keyCode: keyCode, modifiers: modifiers)
            }
            panel.overlayView.onKeyUp = { [weak self] keyCode in
                _ = self?.handleSelectionKeyUp(keyCode: keyCode)
            }
            panel.orderFrontRegardless()
            return panel
        }
        let selectionEventTapReady = refreshSelectionEventTap()
        if !selectionEventTapReady {
            // The overlay itself remains a usable fallback when Accessibility
            // is unavailable (for example when capture was started from the
            // settings window).  A global capture started from another app
            // may otherwise leave the non-activating panel without a reliable
            // event source. Prefer the panel's own key-window path and only
            // activate MacPilot if the panel still cannot receive input.
            Self.logger.warning("Selection event tap unavailable; using foreground overlay input")
        }
        if let activePanel = overlays.first(where: { $0.frame.contains(initialPoint) }) ?? overlays.first {
            activePanel.makeKeyAndOrderFront(nil)
            activePanel.makeFirstResponder(activePanel.overlayView)
            if !selectionEventTapReady {
                // Give the non-activating panel a run-loop turn to become key
                // before taking the app foreground. This avoids stealing the
                // user's active app when the panel can already receive input.
                DispatchQueue.main.async { [weak activePanel] in
                    guard let activePanel, !activePanel.isKeyWindow else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    activePanel.makeKeyAndOrderFront(nil)
                    activePanel.makeFirstResponder(activePanel.overlayView)
                }
            }
        }
        NSCursor.crosshair.set()
    }

    func captureStoredRect(_ rect: CGRect) {
        guard SmartCaptureSelectionGeometry.isMeaningful(rect),
              NSScreen.screens.contains(where: { $0.frame.intersection(rect).width > 0 && $0.frame.intersection(rect).height > 0 }) else {
            onError(ScreenCaptureError.captureFailed(AppText.value("scCaptureAreaUnavailable", language: language())))
            return
        }
        guard let quartzPoint = SmartAXTargetQuery.quartzPoint(fromAppKitPoint: CGPoint(x: rect.midX, y: rect.midY)) else {
            reportSelectionCoordinateFailure()
            return
        }
        selectionMode = .manualArea
        finishCapture(rect: rect, quartzClickPoint: quartzPoint)
    }

    func captureFullscreen() {
        guard !isSelecting else { cancelSelection(); return }
        onFullscreenCapture()
    }

    func captureActiveWindow() {
        guard !isSelecting else { cancelSelection(); return }
        onActiveWindowCapture()
    }

    func cancelSelection() {
        guard isSelecting || !overlays.isEmpty else { return }
        isSelecting = false
        pendingTargetUpdate?.cancel()
        pendingTargetUpdate = nil
        latestPointerLocation = nil
        manualSelectionStart = nil
        manualSelectionRect = nil
        selectionInteraction.reset()
        manualSelectionCoordinateFailure = false
        stopSelectionEventTap()
        unregisterSelectionCancelShortcut()
        currentTarget = nil
        let current = overlays
        overlays.removeAll(keepingCapacity: false)
        for panel in current {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        NSCursor.arrow.set()
    }

    func pin(image: CGImage) {
        let id = UUID()
        let controller = SmartPinWindowController(image: image, language: language()) { [weak self] in
            Self.logger.info("Pin controller removed")
            self?.pinControllers.removeValue(forKey: id)
        }
        pinControllers[id] = controller
        controller.show()
    }

    func presentInlineAnnotation(for image: CGImage) {
        let id = UUID()
        let controller = SmartAnnotationWindowController(
            image: image,
            language: language(),
            onComplete: { [weak self] annotated in
                guard let self else { return }
                self.inlineAnnotationControllers.removeValue(forKey: id)
                self.onCapture(annotated)
            },
            onClose: { [weak self] in
                self?.inlineAnnotationControllers.removeValue(forKey: id)
            }
        )
        inlineAnnotationControllers[id] = controller
        controller.show()
    }

    func showQuickAccess(
        image: CGImage,
        savedURL: URL? = nil,
        onSave: ((CGImage, URL?) -> Void)? = nil,
        onDelete: ((URL?) -> Void)? = nil
    ) {
        // Keep only the latest result preview alive. This bounds retained image
        // memory when the user captures repeatedly without opening the actions.
        let previous = Array(quickAccessControllers.values)
        quickAccessControllers.removeAll(keepingCapacity: false)
        for controller in previous { controller.close() }
        let id = UUID()
        let controller = SmartQuickAccessWindowController(
            image: image,
            language: language(),
            savedURL: savedURL,
            onPin: { [weak self] image in self?.pin(image: image) },
            onClose: { [weak self] in
                self?.quickAccessControllers.removeValue(forKey: id)
            },
            onSave: onSave,
            onDelete: onDelete
        )
        quickAccessControllers[id] = controller
        controller.show()
    }

    private func updateTarget(at appKitPoint: CGPoint) {
        guard isSelecting,
              (selectionMode == .smartElement || selectionMode == .applicationWindow),
              manualSelectionStart == nil else { return }
        latestPointerLocation = appKitPoint
        guard pendingTargetUpdate == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isSelecting, let point = self.latestPointerLocation else { return }
            self.pendingTargetUpdate = nil
            self.resolveTarget(at: point)
        }
        pendingTargetUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    func handleShortcutEvent(id: UInt32) {
        switch id {
        case SmartCaptureCarbonHotKey.cancelID:
            cancelSelection()
        case SmartCaptureCarbonHotKey.captureID:
            startSelection(mode: .smartElement)
        case SmartCaptureCarbonHotKey.areaID:
            startSelection(mode: .manualArea)
        case SmartCaptureCarbonHotKey.fullscreenID:
            captureFullscreen()
        case SmartCaptureCarbonHotKey.activeWindowID:
            captureActiveWindow()
        case SmartCaptureCarbonHotKey.areaAnnotateID:
            startSelection(mode: .areaAnnotate)
        case SmartCaptureCarbonHotKey.ocrID:
            startSelection(mode: .ocr)
        default:
            break
        }
    }

    func handleSelectionMouseMoved(atQuartzPoint point: CGPoint) {
        guard isSelecting else { return }
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else {
            logSelectionCoordinateFailureIfNeeded()
            return
        }
        updateTarget(at: appKitPoint)
    }

    func handleSelectionMouseDown(atQuartzPoint point: CGPoint) {
        guard isSelecting else { return }
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else {
            reportSelectionCoordinateFailure()
            cancelSelection()
            return
        }
        manualSelectionCoordinateFailure = false
        let target = selectionMode == .smartElement || selectionMode == .applicationWindow ? currentTarget : nil
        applySelectionAction(selectionInteraction.pointerDown(at: appKitPoint, target: target))
    }

    private func handleSelectionMouseDown(atAppKitPoint point: CGPoint) {
        guard isSelecting else { return }
        let target = selectionMode == .smartElement || selectionMode == .applicationWindow ? currentTarget : nil
        applySelectionAction(selectionInteraction.pointerDown(at: point, target: target))
    }

    func handleSelectionMouseDragged(atQuartzPoint point: CGPoint) {
        guard isSelecting else { return }
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else {
            logSelectionCoordinateFailureIfNeeded()
            if manualSelectionStart != nil {
                manualSelectionCoordinateFailure = true
            }
            return
        }
        applySelectionAction(selectionInteraction.pointerDragged(to: appKitPoint))
    }

    private func handleSelectionMouseDragged(atAppKitPoint point: CGPoint) {
        guard isSelecting else { return }
        applySelectionAction(selectionInteraction.pointerDragged(to: point))
    }

    func handleSelectionMouseUp(atQuartzPoint point: CGPoint) {
        guard isSelecting else { return }
        guard !manualSelectionCoordinateFailure else {
            reportSelectionCoordinateFailure()
            cancelSelection()
            return
        }
        guard let appKitPoint = SmartAXTargetQuery.appKitPoint(fromQuartzPoint: point) else {
            reportSelectionCoordinateFailure()
            cancelSelection()
            return
        }
        let action = selectionInteraction.pointerUp(at: appKitPoint)
        if action == .none, selectionMode == .smartElement {
            commit(at: appKitPoint)
        } else {
            applySelectionAction(action)
        }
    }

    private func handleSelectionMouseUp(atAppKitPoint point: CGPoint) {
        guard isSelecting else { return }
        let action = selectionInteraction.pointerUp(at: point)
        if action == .none, selectionMode == .smartElement {
            commit(at: point)
        } else {
            applySelectionAction(action)
        }
    }

    @discardableResult
    func handleSelectionKeyDown(keyCode: UInt16, modifiers: InputSourceShortcutModifiers = []) -> Bool {
        guard isSelecting else { return false }
        let action = selectionInteraction.keyDown(keyCode: keyCode, modifiers: modifiers)
        applySelectionAction(action)
        return action != .none
    }

    @discardableResult
    func handleSelectionKeyUp(keyCode: UInt16) -> Bool {
        guard isSelecting else { return false }
        selectionInteraction.keyUp(keyCode: keyCode)
        return keyCode == UInt16(kVK_Space)
    }

    private func reportSelectionCoordinateFailure() {
        Self.logger.error("Selection pointer could not be mapped to a display")
        lastSelectionCoordinateFailureLogAt = CFAbsoluteTimeGetCurrent()
        onError(ScreenCaptureError.captureFailed(
            AppText.value("scCaptureCoordinateUnavailable", language: language())
        ))
    }

    private func logSelectionCoordinateFailureIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSelectionCoordinateFailureLogAt >= 1 else { return }
        lastSelectionCoordinateFailureLogAt = now
        Self.logger.error("Selection pointer could not be mapped to a display")
    }

    private func resolveTarget(at appKitPoint: CGPoint) {
        let target: CGRect?
        switch selectionMode {
        case .smartElement:
            target = SmartAXTargetQuery.target(at: appKitPoint)
        case .applicationWindow:
            target = SmartAXTargetQuery.applicationWindowTarget(at: appKitPoint)
        default:
            target = nil
        }
        guard target != currentTarget else { return }
        currentTarget = target
        for overlay in overlays { overlay.overlayView.targetFrame = target }
    }

    private func applySelectionAction(_ action: SmartCaptureSelectionAction) {
        switch action {
        case .none:
            updateOverlaySelection()
        case .selectionChanged(let rect):
            manualSelectionRect = rect.isEmpty ? nil : rect
            manualSelectionStart = selectionInteraction.dragStart
            if selectionInteraction.mode == .area {
                currentTarget = nil
            }
            updateOverlaySelection()
        case .commit(let rect):
            manualSelectionRect = nil
            manualSelectionStart = nil
            if selectionMode == .manualArea { onSelectionRect(rect) }
            guard let quartzPoint = SmartAXTargetQuery.quartzPoint(fromAppKitPoint: CGPoint(x: rect.midX, y: rect.midY)) else {
                reportSelectionCoordinateFailure()
                cancelSelection()
                return
            }
            finishCapture(rect: rect, quartzClickPoint: quartzPoint)
        case .cancel:
            cancelSelection()
        case .repeatLastArea:
            onRepeatLastArea()
        case .modeChanged(let mode):
            selectionMode = mode == .applicationWindow ? .applicationWindow : .manualArea
            currentTarget = nil
            manualSelectionRect = nil
            manualSelectionStart = nil
            updateOverlaySelection()
            if selectionMode == .applicationWindow, let point = latestPointerLocation {
                resolveTarget(at: point)
            }
        }
    }

    private func updateOverlaySelection() {
        for overlay in overlays {
            overlay.overlayView.selectionRect = manualSelectionRect
            overlay.overlayView.targetFrame = manualSelectionRect == nil ? currentTarget : nil
        }
    }

    private func commit(at point: CGPoint) {
        let target: CGRect?
        switch selectionMode {
        case .applicationWindow:
            target = currentTarget.flatMap { $0.contains(point) ? $0 : nil }
                ?? SmartAXTargetQuery.applicationWindowTarget(at: point)
        default:
            target = currentTarget.flatMap { $0.contains(point) ? $0 : nil }
                ?? SmartAXTargetQuery.target(at: point)
        }
        guard let target else {
            Self.logger.error("Selection click had no capture target")
            return
        }
        guard let quartzPoint = SmartAXTargetQuery.quartzPoint(fromAppKitPoint: point) else {
            reportSelectionCoordinateFailure()
            cancelSelection()
            return
        }
        Self.logger.info("Committing smart capture target \(String(describing: target), privacy: .public)")
        finishCapture(rect: target, quartzClickPoint: quartzPoint)
    }

    private func finishCapture(rect: CGRect, quartzClickPoint: CGPoint) {
        guard !rect.isEmpty else {
            cancelSelection()
            return
        }
        let captureMode = selectionMode
        cancelSelection()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            do {
                let image = try await SmartScreenImageCapture.capture(
                    appKitRect: rect,
                    quartzClickPoint: quartzClickPoint
                )
                guard let self else { return }
                if captureMode == .ocr {
                    self.onOCRCapture(image)
                } else if captureMode == .areaAnnotate {
                    self.onAreaAnnotateCapture(image)
                } else {
                    self.onCapture(image)
                }
            } catch {
                self?.onError(error)
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

private enum SmartAXTargetQuery {
    private static let maximumDepth = 25

    static func target(at appKitPoint: CGPoint) -> CGRect? {
        guard let quartzPoint = quartzPoint(fromAppKitPoint: appKitPoint) else { return windowFrame(at: appKitPoint) }
        let system = AXUIElementCreateSystemWide()
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(quartzPoint.x), Float(quartzPoint.y), &rawElement) == .success,
              let rawElement else { return windowFrame(at: appKitPoint) }
        let window = windowFrame(at: appKitPoint)
        var chain: [SmartCaptureElement] = []
        var current: AXUIElement? = rawElement
        var depth = 0
        while let element = current, depth < maximumDepth {
            if let candidate = snapshot(element) { chain.append(candidate) }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parentValue, to: AXUIElement.self)
            depth += 1
        }
        return SmartCaptureTargetResolver.resolve(elementChain: chain, windowFrame: window)
    }

    static func applicationWindowTarget(at appKitPoint: CGPoint) -> CGRect? {
        windowFrame(at: appKitPoint)?.integral
    }

    private static func snapshot(_ element: AXUIElement) -> SmartCaptureElement? {
        var roleValue: CFTypeRef?
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let role = roleValue as? String,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size),
              let frame = appKitRect(fromQuartzRect: CGRect(origin: origin, size: size)) else { return nil }
        return SmartCaptureElement(role: role, frame: frame)
    }

    private static func windowFrame(at point: CGPoint) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID != getpid(),
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let frame = appKitRect(fromQuartzRect: bounds), frame.contains(point),
                  frame.width >= 40, frame.height >= 40 else { continue }
            return frame.integral
        }
        return nil
    }

    static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint? {
        guard let mapping = DisplayMapping.best(forAppKitPoint: point) else { return nil }
        return PiPCoordinateSpace.quartzPoint(
            fromAppKit: point,
            quartzScreen: mapping.quartzFrame,
            appKitScreen: mapping.appKitFrame
        )
    }

    static func appKitPoint(fromQuartzPoint point: CGPoint) -> CGPoint? {
        guard let mapping = DisplayMapping.best(forQuartzPoint: point) else { return nil }
        return CGPoint(
            x: mapping.appKitFrame.minX + point.x - mapping.quartzFrame.minX,
            y: mapping.appKitFrame.maxY - (point.y - mapping.quartzFrame.minY)
        )
    }

    static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect? {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        let converted = points.compactMap { point -> CGPoint? in
            guard let mapping = DisplayMapping.best(forAppKitPoint: point) else { return nil }
            return CGPoint(
                x: mapping.quartzFrame.minX + point.x - mapping.appKitFrame.minX,
                y: mapping.quartzFrame.maxY - (point.y - mapping.appKitFrame.minY)
            )
        }
        guard converted.count == points.count else { return nil }
        return boundingRect(of: converted)
    }

    static func displayCount(intersectingAppKitRect rect: CGRect) -> Int {
        NSScreen.screens.reduce(into: 0) { count, screen in
            let intersection = screen.frame.intersection(rect)
            if intersection.width > 0, intersection.height > 0 { count += 1 }
        }
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect? {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        let converted = points.compactMap { point -> CGPoint? in
            guard let mapping = DisplayMapping.best(forQuartzPoint: point) else { return nil }
            return CGPoint(
                x: mapping.appKitFrame.minX + point.x - mapping.quartzFrame.minX,
                y: mapping.appKitFrame.maxY - (point.y - mapping.quartzFrame.minY)
            )
        }
        guard converted.count == points.count else { return nil }
        return boundingRect(of: converted)
    }

    private static func boundingRect(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    private struct DisplayMapping {
        let quartzFrame: CGRect
        let appKitFrame: CGRect

        static func all() -> [Self] {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return Self(
                    quartzFrame: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                    appKitFrame: screen.frame
                )
            }
        }

        static func best(forAppKitPoint point: CGPoint) -> Self? {
            all().min { distance(point, to: $0.appKitFrame) < distance(point, to: $1.appKitFrame) }
        }

        static func best(forQuartzPoint point: CGPoint) -> Self? {
            all().min { distance(point, to: $0.quartzFrame) < distance(point, to: $1.quartzFrame) }
        }

        private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class SmartCaptureOverlayPanel: NSPanel {
    let overlayView: SmartCaptureOverlayView

    init(screen: NSScreen) {
        overlayView = SmartCaptureOverlayView(screenFrame: screen.frame)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        contentView = overlayView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class SmartCaptureOverlayView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var onKeyDown: ((UInt16, InputSourceShortcutModifiers) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    var targetFrame: CGRect? { didSet { needsDisplay = true } }
    var selectionRect: CGRect? { didSet { needsDisplay = true } }
    private let screenFrame: CGRect
    private var trackingAreaReference: NSTrackingArea?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) { onMove?(globalPoint(event)) }
    override func mouseDown(with event: NSEvent) { onMouseDown?(globalPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let modifiers = InputSourceShortcutModifiers(event.modifierFlags)
        if keyCode == UInt16(kVK_Escape) || keyCode == UInt16(kVK_Space) ||
            keyCode == UInt16(kVK_ANSI_A) || keyCode == UInt16(kVK_Return) ||
            keyCode == UInt16(kVK_ANSI_KeypadEnter) ||
            [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow)].contains(keyCode) {
            onKeyDown?(keyCode, modifiers)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(event.keyCode)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let selectionRect, !selectionRect.isEmpty {
            let local = selectionRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            NSGraphicsContext.current?.saveGraphicsState()
            NSColor.clear.setFill()
            local.fill(using: .copy)
            NSGraphicsContext.current?.restoreGraphicsState()
            let path = NSBezierPath(rect: local.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            NSColor.white.setStroke()
            path.stroke()
            let label = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
            label.draw(
                at: CGPoint(x: local.minX + 8, y: max(8, local.minY - 24)),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.65)
                ]
            )
            return
        }
        guard let targetFrame else { return }
        let local = targetFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        NSGraphicsContext.current?.saveGraphicsState()
        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSGraphicsContext.current?.restoreGraphicsState()
        let path = NSBezierPath(roundedRect: local.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
        path.lineWidth = 3
        NSColor.systemBlue.setStroke()
        path.stroke()
        let label = "\(Int(targetFrame.width)) × \(Int(targetFrame.height))"
        label.draw(
            at: CGPoint(x: local.minX + 8, y: max(8, local.minY - 24)),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.65)
            ]
        )
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: screenFrame.minX + local.x, y: screenFrame.minY + local.y)
    }
}

@MainActor
private enum SmartScreenImageCapture {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")

    static func capture(appKitRect: CGRect, quartzClickPoint: CGPoint) async throws -> CGImage {
        guard let quartzRect = SmartAXTargetQuery.quartzRect(fromAppKitRect: appKitRect) else {
            throw ScreenCaptureError.noDisplayFound
        }
        if #unavailable(macOS 15.2), SmartAXTargetQuery.displayCount(intersectingAppKitRect: appKitRect) > 1 {
            throw ScreenCaptureError.captureFailed(
                "The selected region spans multiple displays. Multi-display region capture requires macOS 15.2 or later."
            )
        }
        if #available(macOS 15.2, *) {
            do {
                return try await captureDisplayAgnosticRect(quartzRect)
            } catch {
                Self.logger.error("Display-agnostic region capture failed; trying display enumeration: \(error.localizedDescription, privacy: .public)")
            }
        }

        var displays: [SCDisplay] = []
        for delay in [0, 80, 160, 320] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            let content = try await SCShareableContent.current
            displays = content.displays
            if !displays.isEmpty { break }
        }
        Self.logger.info("ScreenCaptureKit returned \(displays.count) displays")
        let intersectingDisplays = displays.filter { display in
            let intersection = display.frame.intersection(quartzRect)
            return intersection.width > 0 && intersection.height > 0
        }
        guard !intersectingDisplays.isEmpty else {
            throw ScreenCaptureError.noDisplayFound
        }
        if intersectingDisplays.count > 1 {
            return try await captureCompositeRegion(quartzRect, displays: intersectingDisplays)
        }
        guard let display = intersectingDisplays.max(by: { lhs, rhs in
            lhs.frame.intersection(quartzRect).area < rhs.frame.intersection(quartzRect).area
        }) else {
            throw ScreenCaptureError.noDisplayFound
        }
        return try await captureRegionOnDisplay(quartzRect, display: display)
    }

    private static func captureRegionOnDisplay(_ quartzRect: CGRect, display: SCDisplay) async throws -> CGImage {
        let clippedRect = quartzRect.intersection(display.frame)
        let sourceRect = clippedRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard !sourceRect.isEmpty else {
            throw ScreenCaptureError.captureFailed(AppText.value("scCaptureOutsideDisplay", language: .system))
        }
        let configuration = SCStreamConfiguration()
        let scaleX = CGFloat(display.width) / max(1, display.frame.width)
        let scaleY = CGFloat(display.height) / max(1, display.frame.height)
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * scaleX).rounded()))
        configuration.height = max(1, Int((sourceRect.height * scaleY).rounded()))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
    }

    private static func captureCompositeRegion(_ quartzRect: CGRect, displays: [SCDisplay]) async throws -> CGImage {
        let outputScale = displays.reduce(CGFloat(1)) { scale, display in
            max(scale, CGFloat(display.width) / max(1, display.frame.width), CGFloat(display.height) / max(1, display.frame.height))
        }
        let outputWidth = max(1, Int((quartzRect.width * outputScale).rounded()))
        let outputHeight = max(1, Int((quartzRect.height * outputScale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureError.captureFailed(AppText.value("scCaptureMultiDisplayAllocationFailed", language: .system))
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        for display in displays {
            let clippedRect = quartzRect.intersection(display.frame)
            guard clippedRect.width > 0, clippedRect.height > 0 else { continue }
            let image = try await captureRegionOnDisplay(quartzRect, display: display)
            let destination = CGRect(
                x: (clippedRect.minX - quartzRect.minX) * outputScale,
                y: (clippedRect.minY - quartzRect.minY) * outputScale,
                width: clippedRect.width * outputScale,
                height: clippedRect.height * outputScale
            )
            context.interpolationQuality = .high
            context.draw(image, in: destination)
        }
        guard let image = context.makeImage() else {
            throw ScreenCaptureError.captureFailed(AppText.value("scCaptureMultiDisplayCompositionFailed", language: .system))
        }
        return image
    }

    @available(macOS 15.2, *)
    private static func captureDisplayAgnosticRect(_ rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(
                        error?.localizedDescription ?? "ScreenCaptureKit returned no image."
                    ))
                }
            }
        }
    }
}

@MainActor
private final class SmartQuickAccessWindowController: NSObject, NSWindowDelegate {
    private var image: CGImage
    private let language: AppLanguage
    private let savedURL: URL?
    private let onPin: (CGImage) -> Void
    private let onClose: () -> Void
    private let onSave: ((CGImage, URL?) -> Void)?
    private let onDelete: ((URL?) -> Void)?
    private var panel: NSPanel?
    private var annotationController: SmartAnnotationWindowController?

    init(
        image: CGImage,
        language: AppLanguage,
        savedURL: URL?,
        onPin: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void,
        onSave: ((CGImage, URL?) -> Void)?,
        onDelete: ((URL?) -> Void)?
    ) {
        self.image = image
        self.language = language
        self.savedURL = savedURL
        self.onPin = onPin
        self.onClose = onClose
        self.onSave = onSave
        self.onDelete = onDelete
    }

    func show() {
        let maxSize = CGSize(width: 420, height: 320)
        let scale = min(1, maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
        let size = CGSize(
            width: max(260, CGFloat(image.width) * scale),
            height: max(190, CGFloat(image.height) * scale + 48)
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scQuickAccessTitle", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        installContent(in: panel)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        annotationController?.close()
        annotationController = nil
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func installContent(in panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: SmartQuickAccessView(
            image: image,
            language: language,
            onCopy: { [weak self] in self?.copyImage() },
            onOCR: { [weak self] in self?.recognizeText() },
            onAnnotate: { [weak self] in self?.openAnnotation() },
            onPin: { [weak self] in self?.pinImage() },
            onReveal: savedURL.map { _ in { [weak self] in self?.revealSavedImage() } },
            onDelete: { [weak self] in self?.deleteCapture() },
            onClose: { [weak self] in self?.close() }
        ))
    }

    private func copyImage() {
        SmartCaptureClipboard.copy(image: image)
    }

    private func recognizeText() {
        let sendableImage = SendableSmartImage(value: image)
        Task { [weak self] in
            guard let self else { return }
            guard let text = try? await SmartOCRService.recognize(image: sendableImage), !text.isEmpty else {
                showMessage(
                    title: AppText.value("scOCR", language: language),
                    message: AppText.value("scOCRNoText", language: language)
                )
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showMessage(
                title: AppText.value("scOCRCopied", language: language),
                message: text
            )
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(message.prefix(1_000))
        alert.addButton(withTitle: AppText.value("scOK", language: language))
        alert.runModal()
    }

    private func revealSavedImage() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    private func deleteCapture() {
        let url = savedURL
        close()
        onDelete?(url)
    }

    private func pinImage() {
        let image = image
        close()
        onPin(image)
    }

    private func openAnnotation() {
        annotationController?.close()
        panel?.orderOut(nil)
        let controller = SmartAnnotationWindowController(
            image: image,
            language: language,
            onComplete: { [weak self] annotated in
                guard let self else { return }
                self.image = annotated
                self.onSave?(annotated, self.savedURL)
                if let panel = self.panel { self.installContent(in: panel) }
            },
            onClose: { [weak self] in
                self?.panel?.orderFrontRegardless()
                self?.annotationController = nil
            }
        )
        annotationController = controller
        controller.show()
    }
}

private struct SmartQuickAccessView: View {
    let image: CGImage
    let language: AppLanguage
    let onCopy: () -> Void
    let onOCR: () -> Void
    let onAnnotate: () -> Void
    let onPin: () -> Void
    let onReveal: (() -> Void)?
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCopy) { Label(AppText.value("scCopy", language: language), systemImage: "doc.on.doc") }
                Button(action: onOCR) { Label(AppText.value("scOCR", language: language), systemImage: "text.viewfinder") }
                Button(action: onAnnotate) { Label(AppText.value("scAnnotate", language: language), systemImage: "pencil.tip.crop.circle") }
                Button(action: onPin) { Label(AppText.value("scPin", language: language), systemImage: "pin") }
                if let onReveal {
                    Button(action: onReveal) { Label(AppText.value("scReveal", language: language), systemImage: "folder") }
                }
                Button(role: .destructive, action: onDelete) {
                    Label(AppText.value("scDelete", language: language), systemImage: "trash")
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(AppText.value("scClose", language: language))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(.ultraThinMaterial)

            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .background(Color.black.opacity(0.04))
        }
    }
}

@MainActor
private final class SmartPinWindowController: NSObject, NSWindowDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    private var image: CGImage
    private let language: AppLanguage
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var annotationController: SmartAnnotationWindowController?

    init(image: CGImage, language: AppLanguage, onClose: @escaping () -> Void) {
        self.image = image
        self.language = language
        self.onClose = onClose
    }

    func show() {
        let maxSize = CGSize(width: 720, height: 520)
        let scale = min(1, maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
        let size = CGSize(width: max(180, CGFloat(image.width) * scale), height: max(120, CGFloat(image.height) * scale))
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scPinTitle", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        installContent(in: panel)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        Self.logger.info("Pin window shown")
    }

    func close() {
        Self.logger.info("Pin close requested")
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.logger.info("Pin window will close")
        annotationController?.close()
        annotationController = nil
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func installContent(in panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: SmartPinView(
            image: image,
            language: language,
            onCopy: { [weak self] in self?.copyImage() },
            onOCR: { [weak self] in self?.recognizeText() },
            onAnnotate: { [weak self] in self?.openAnnotation() },
            onClose: { [weak self] in self?.close() }
        ))
    }

    private func copyImage() {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }

    private func recognizeText() {
        let sendableImage = SendableSmartImage(value: image)
        Task { [weak self] in
            guard let text = try? await SmartOCRService.recognize(image: sendableImage), !text.isEmpty else {
                self?.showMessage(title: AppText.value("scOCR", language: self?.language ?? .system), message: AppText.value("scOCRNoText", language: self?.language ?? .system))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.showMessage(title: AppText.value("scOCRCopied", language: self?.language ?? .system), message: text)
        }
    }

    private func openAnnotation() {
        Self.logger.info("Annotation requested; hiding pin window")
        annotationController?.close()
        panel?.orderOut(nil)
        let controller = SmartAnnotationWindowController(
            image: image,
            language: language,
            onComplete: { [weak self] annotated in
                Self.logger.info("Annotation completed; updating pin image")
                guard let self else { return }
                self.image = annotated
                if let panel = self.panel { self.installContent(in: panel) }
            },
            onClose: { [weak self] in
                Self.logger.info("Annotation closed; restoring pin window")
                self?.panel?.orderFrontRegardless()
                self?.annotationController = nil
            }
        )
        annotationController = controller
        controller.show()
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(message.prefix(1_000))
        alert.addButton(withTitle: AppText.value("scOK", language: language))
        alert.runModal()
    }
}

private struct SmartPinView: View {
    let image: CGImage
    let language: AppLanguage
    let onCopy: () -> Void
    let onOCR: () -> Void
    let onAnnotate: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCopy) { Label(AppText.value("scCopy", language: language), systemImage: "doc.on.doc") }
                Button(action: onOCR) { Label(AppText.value("scOCR", language: language), systemImage: "text.viewfinder") }
                Button(action: onAnnotate) { Label(AppText.value("scAnnotate", language: language), systemImage: "pencil.tip.crop.circle") }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.help(AppText.value("scClose", language: language))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.ultraThinMaterial)

            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .background(Color.black.opacity(0.04))
        }
    }
}

private struct SendableSmartImage: @unchecked Sendable {
    let value: CGImage
}

private enum SmartOCRService {
    static func recognize(image: SendableSmartImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                let handler = VNImageRequestHandler(cgImage: image.value, options: [:])
                try handler.perform([request])
                return (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            }
        }.value
    }
}

private enum SmartAnnotationTool: String, CaseIterable, Identifiable {
    case rectangle
    case arrow
    case text

    var id: String { rawValue }
    func title(language: AppLanguage) -> String {
        switch self {
        case .rectangle: AppText.value("scAnnotationRectangle", language: language)
        case .arrow: AppText.value("scAnnotationArrow", language: language)
        case .text: AppText.value("scAnnotationText", language: language)
        }
    }
}

enum SmartAnnotation: Equatable {
    case rectangle(CGRect)
    case arrow(CGPoint, CGPoint)
    case text(String, CGPoint)
}

@MainActor
private final class SmartAnnotationModel: ObservableObject {
    @Published var tool: SmartAnnotationTool = .rectangle
    @Published var annotations: [SmartAnnotation] = []

    func undo() { if !annotations.isEmpty { annotations.removeLast() } }
}

@MainActor
private final class SmartAnnotationWindowController: NSObject, NSWindowDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    private let image: CGImage
    private let language: AppLanguage
    private let onComplete: (CGImage) -> Void
    private let onClose: () -> Void
    private let model = SmartAnnotationModel()
    private var window: NSWindow?
    private var didNotifyClose = false

    init(
        image: CGImage,
        language: AppLanguage,
        onComplete: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.image = image
        self.language = language
        self.onComplete = onComplete
        self.onClose = onClose
    }

    func show() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.value("scAnnotateTitle", language: language)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SmartAnnotationEditor(
            image: image,
            language: language,
            model: model,
            onCancel: { [weak self] in self?.close() },
            onComplete: { [weak self] in self?.complete() }
        ))
        window.center()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }

    private func complete() {
        Self.logger.info("Rendering annotations")
        guard let rendered = SmartAnnotationRenderer.render(image: image, annotations: model.annotations) else { return }
        onComplete(rendered)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.logger.info("Annotation window will close")
        window?.contentView = nil
        window = nil
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}

private struct SmartAnnotationEditor: View {
    let image: CGImage
    let language: AppLanguage
    @ObservedObject var model: SmartAnnotationModel
    let onCancel: () -> Void
    let onComplete: () -> Void
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var showingTextEntry = false
    @State private var pendingText = ""
    @State private var textPoint = CGPoint.zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(AppText.value("scAnnotationTool", language: language), selection: $model.tool) {
                    ForEach(SmartAnnotationTool.allCases) { Text($0.title(language: language)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Button(AppText.value("scUndo", language: language), action: model.undo).disabled(model.annotations.isEmpty)
                Spacer()
                Button(AppText.value("scCancel", language: language), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(AppText.value("scDone", language: language), action: onComplete)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)

            GeometryReader { geometry in
                let fitted = fittedRect(imageSize: CGSize(width: image.width, height: image.height), in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.08)
                    Image(decorative: image, scale: 1).resizable().frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                    Canvas { context, _ in
                        drawAnnotations(context: &context, in: fitted)
                        drawDraft(context: &context, in: fitted)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard fitted.contains(value.location) else { return }
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                        .onEnded { value in finishDrag(value.location, fitted: fitted) })
                }
            }
        }
        .sheet(isPresented: $showingTextEntry) {
            VStack(spacing: 16) {
                Text(AppText.value("scAnnotationTextTitle", language: language)).font(.headline)
                TextField(AppText.value("scText", language: language), text: $pendingText).textFieldStyle(.roundedBorder)
                HStack {
                    Button(AppText.value("scCancel", language: language)) { showingTextEntry = false }
                    Button(AppText.value("scAdd", language: language)) {
                        if !pendingText.isEmpty { model.annotations.append(.text(pendingText, textPoint)) }
                        pendingText = ""
                        showingTextEntry = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private func fittedRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func finishDrag(_ end: CGPoint, fitted: CGRect) {
        guard let start = dragStart, fitted.contains(start), fitted.contains(end) else {
            dragStart = nil; dragCurrent = nil; return
        }
        switch model.tool {
        case .rectangle:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            if rect.width > 3, rect.height > 3 { model.annotations.append(.rectangle(normalized(rect, in: fitted))) }
        case .arrow:
            if hypot(end.x - start.x, end.y - start.y) > 4 {
                model.annotations.append(.arrow(normalized(start, in: fitted), normalized(end, in: fitted)))
            }
        case .text:
            textPoint = normalized(end, in: fitted)
            showingTextEntry = true
        }
        dragStart = nil
        dragCurrent = nil
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private func normalized(_ value: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: (value.minX - rect.minX) / rect.width, y: (value.minY - rect.minY) / rect.height, width: value.width / rect.width, height: value.height / rect.height)
    }

    private func drawAnnotations(context: inout GraphicsContext, in rect: CGRect) {
        for annotation in model.annotations { draw(annotation, context: &context, in: rect) }
    }

    private func drawDraft(context: inout GraphicsContext, in rect: CGRect) {
        guard let start = dragStart, let end = dragCurrent else { return }
        switch model.tool {
        case .rectangle:
            let value = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            context.stroke(Path(value), with: .color(.red), lineWidth: 3)
        case .arrow: drawArrow(from: start, to: end, context: &context)
        case .text: break
        }
    }

    private func draw(_ annotation: SmartAnnotation, context: inout GraphicsContext, in rect: CGRect) {
        switch annotation {
        case .rectangle(let value):
            let denormalized = CGRect(x: rect.minX + value.minX * rect.width, y: rect.minY + value.minY * rect.height, width: value.width * rect.width, height: value.height * rect.height)
            context.stroke(Path(denormalized), with: .color(.red), lineWidth: 3)
        case .arrow(let start, let end):
            drawArrow(from: CGPoint(x: rect.minX + start.x * rect.width, y: rect.minY + start.y * rect.height), to: CGPoint(x: rect.minX + end.x * rect.width, y: rect.minY + end.y * rect.height), context: &context)
        case .text(let text, let point):
            context.draw(Text(text).font(.system(size: 18, weight: .bold)).foregroundColor(.red), at: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height), anchor: .topLeading)
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, context: inout GraphicsContext) {
        var path = Path(); path.move(to: start); path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 14
        path.move(to: end); path.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
        path.move(to: end); path.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

enum SmartAnnotationRenderer {
    static func render(image: CGImage, annotations: [SmartAnnotation]) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setFillColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(3, CGFloat(width) / 350))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in annotations {
            switch annotation {
            case .rectangle(let rect):
                context.stroke(CGRect(x: rect.minX * bounds.width, y: (1 - rect.maxY) * bounds.height, width: rect.width * bounds.width, height: rect.height * bounds.height))
            case .arrow(let start, let end):
                let a = CGPoint(x: start.x * bounds.width, y: (1 - start.y) * bounds.height)
                let b = CGPoint(x: end.x * bounds.width, y: (1 - end.y) * bounds.height)
                context.move(to: a); context.addLine(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x), head = max(14, CGFloat(width) / 45)
                context.move(to: b); context.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6)))
                context.move(to: b); context.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6)))
                context.strokePath()
            case .text(let text, let point):
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
                let fontSize = max(18, CGFloat(width) / 35)
                (text as NSString).draw(at: CGPoint(x: point.x * bounds.width, y: (1 - point.y) * bounds.height - fontSize), withAttributes: [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.systemRed])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return context.makeImage()
    }
}
