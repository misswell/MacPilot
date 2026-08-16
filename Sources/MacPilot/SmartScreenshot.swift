import AVFoundation
import AVKit
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import CoreImage
import Darwin
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

/// Screenshot entry points exposed by the capture settings. Smart Element
/// keeps the original F1 behaviour. The area/fullscreen defaults retain the
/// familiar 3/4 key positions but add Option, because macOS owns the plain
/// Command-Shift screenshot shortcuts.
enum ScreenCaptureShortcutKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case smartElement
    case area
    case repeatArea
    case applicationWindow
    case fullscreen
    case activeWindow
    case areaAnnotate
    case ocr
    case scrolling
    case objectCutout

    var defaultBinding: SmartCaptureShortcutBinding {
        switch self {
        case .smartElement:
            return .default
        case .area:
            return SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .option])
        case .repeatArea:
            return SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .option, .shift])
        case .applicationWindow:
            // A separate global entry point complements the in-overlay `A`
            // mode switch while keeping the action reachable from any app.
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_A),
                modifiers: [.control, .command]
            )
        case .fullscreen:
            return SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .option])
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
        case .scrolling:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_6),
                modifiers: [.command, .shift]
            )
        case .objectCutout:
            return SmartCaptureShortcutBinding(
                keyCode: UInt16(kVK_ANSI_1),
                modifiers: [.command, .shift]
            )
        }
    }

    /// Values written by the first configurable-screenshot releases used the
    /// macOS symbolic screenshot combinations. Migrate only those exact
    /// shipped defaults; a user-selected binding must remain untouched.
    func migratedBinding(_ binding: SmartCaptureShortcutBinding) -> SmartCaptureShortcutBinding {
        switch self {
        case .area where binding == SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift])
            || binding == SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .option, .control]):
            return defaultBinding
        case .repeatArea where binding == SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.control, .command, .shift])
            || binding == SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .option, .control, .shift]):
            return defaultBinding
        case .fullscreen where binding == SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .shift])
            || binding == SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .option, .control]):
            return defaultBinding
        default:
            return binding
        }
    }

    var titleKey: String {
        switch self {
        case .smartElement: return "scSmartCaptureShortcut"
        case .area: return "scAreaCaptureShortcut"
        case .repeatArea: return "scRepeatAreaShortcut"
        case .applicationWindow: return "scApplicationWindowShortcut"
        case .fullscreen: return "scFullscreenCaptureShortcut"
        case .activeWindow: return "scActiveWindowCaptureShortcut"
        case .areaAnnotate: return "scAreaAnnotateShortcut"
        case .ocr: return "scOCRShortcut"
        case .scrolling: return "scScrollingShortcut"
        case .objectCutout: return "scObjectCutoutShortcut"
        }
    }

    var editorTitleKey: String { "scChangeShortcut" }

    var id: String { rawValue }
}

enum SmartCaptureSelectionMode: Equatable, Sendable {
    case smartElement
    case manualArea
    case applicationWindow
    case recordingArea
    case recordingApplication
    case areaAnnotate
    case ocr
    case scrolling
    case objectCutout
}

enum SmartCaptureShortcutError: Error, Equatable {
    case reservedKey
    case modifierRequired
    case systemShortcutConflict
    case registrationFailed

    var messageKey: String {
        switch self {
        case .reservedKey: return "scShortcutReserved"
        case .modifierRequired: return "scShortcutModifierRequired"
        case .systemShortcutConflict: return "scShortcutSystemConflict"
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
        if mode == .applicationWindow {
            dragStart = nil
            selectionRect = nil
            isDragging = true
            isSpacePressed = false
            return .selectionChanged(.zero)
        }
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
        if mode == .applicationWindow {
            return .none
        }
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
        if mode == .applicationWindow {
            isDragging = false
            isSpacePressed = false
            dragStart = nil
            selectionRect = nil
            if let clickTarget, SmartCaptureSelectionGeometry.isMeaningful(clickTarget) {
                self.clickTarget = nil
                return .commit(clickTarget)
            }
            return .none
        }
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
    /// modifier transitions as well. This keeps the helper safe for any
    /// future non-system fallback without pretending it can override macOS's
    /// screenshot service.
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
    static let scrollingID: UInt32 = 8
    static let objectCutoutID: UInt32 = 9
    static let repeatAreaID: UInt32 = 10
    static let applicationWindowID: UInt32 = 11

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
        case .repeatArea: return identifier(repeatAreaID)
        case .applicationWindow: return identifier(applicationWindowID)
        case .fullscreen: return identifier(fullscreenID)
        case .activeWindow: return identifier(activeWindowID)
        case .areaAnnotate: return identifier(areaAnnotateID)
        case .ocr: return identifier(ocrID)
        case .scrolling: return identifier(scrollingID)
        case .objectCutout: return identifier(objectCutoutID)
        }
    }
}

/// macOS screenshot symbolic hotkeys use the same key combinations as the
/// Snapzy-style defaults. Carbon cannot claim those combinations, so the
/// settings UI reports the conflict and requires a different binding instead
/// of silently racing the system screenshot service.
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
    private let onRecordingSelection: (CGRect, SmartCaptureSelectionMode) -> Void
    private let onRepeatLastArea: () -> Void
    private let onFullscreenCapture: () -> Void
    private let onActiveWindowCapture: () -> Void
    private let onAreaAnnotateCapture: (CGImage) -> Void
    private let onOCRCapture: (CGImage) -> Void
    private let onScrollingCapture: (CGImage) -> Void
    private let onObjectCutoutCapture: (CGImage) -> Void
    private let screenCaptureAccessProvider: @Sendable () -> Bool
    private let initialTargetResolver: @Sendable (SmartCaptureSelectionMode, CGPoint) -> CGRect?
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
    private var mediaQuickAccessControllers: [UUID: SmartMediaQuickAccessWindowController] = [:]
    private var quickAccessStack = SmartQuickAccessStackState()
    private var mediaEditorControllers: [UUID: SmartMediaEditorWindowController] = [:]
    private var inlineAnnotationControllers: [UUID: SmartAnnotationWindowController] = [:]
    private var scrollingControllers: [UUID: SmartScrollingCaptureWindowController] = [:]
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
    nonisolated(unsafe) private var selectionLocalMonitor: Any?
    nonisolated(unsafe) private var selectionGlobalMonitor: Any?
    private var selectionMode: SmartCaptureSelectionMode = .smartElement
    private var selectionInteraction = SmartCaptureSelectionState()
    private var initialTargetUpdateTask: Task<Void, Never>?
    private var snapzyPreparationTask: Task<Void, Never>?
    private var snapzySessionID: UUID?
    private var snapzyFrozenSession: FrozenAreaCaptureSession?
    private var pendingSnapzyResult: (
        result: AreaSelectionResult,
        requestedMode: SmartCaptureSelectionMode,
        sessionID: UUID
    )?

    init(
        language: @escaping () -> AppLanguage,
        onCapture: @escaping (CGImage) -> Void,
        onError: @escaping (Error) -> Void,
        onSelectionRect: @escaping (CGRect) -> Void = { _ in },
        onRecordingSelection: @escaping (CGRect, SmartCaptureSelectionMode) -> Void = { _, _ in },
        onRepeatLastArea: @escaping () -> Void = {},
        shortcutBinding: SmartCaptureShortcutBinding = .default,
        additionalShortcutBindings: [ScreenCaptureShortcutKind: SmartCaptureShortcutBinding] = [:],
        onFullscreenCapture: @escaping () -> Void = {},
        onActiveWindowCapture: @escaping () -> Void = {},
        onAreaAnnotateCapture: @escaping (CGImage) -> Void = { _ in },
        onOCRCapture: @escaping (CGImage) -> Void = { _ in },
        onScrollingCapture: @escaping (CGImage) -> Void = { _ in },
        onObjectCutoutCapture: @escaping (CGImage) -> Void = { _ in },
        screenCaptureAccessProvider: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
        initialTargetResolver: @escaping @Sendable (SmartCaptureSelectionMode, CGPoint) -> CGRect? = {
            mode,
            point in
            switch mode {
            case .smartElement:
                SmartAXTargetQuery.target(at: point)
            case .applicationWindow, .recordingApplication:
                SmartAXTargetQuery.applicationWindowTarget(at: point)
            default:
                nil
            }
        }
    ) {
        self.language = language
        self.onCapture = onCapture
        self.onError = onError
        self.onSelectionRect = onSelectionRect
        self.onRecordingSelection = onRecordingSelection
        self.onRepeatLastArea = onRepeatLastArea
        self.shortcutBinding = shortcutBinding
        self.additionalShortcutBindings = additionalShortcutBindings
        self.onFullscreenCapture = onFullscreenCapture
        self.onActiveWindowCapture = onActiveWindowCapture
        self.onAreaAnnotateCapture = onAreaAnnotateCapture
        self.onOCRCapture = onOCRCapture
        self.onScrollingCapture = onScrollingCapture
        self.onObjectCutoutCapture = onObjectCutoutCapture
        self.screenCaptureAccessProvider = screenCaptureAccessProvider
        self.initialTargetResolver = initialTargetResolver
    }

    #if DEBUG
    var testOverlayCount: Int { overlays.count }
    #endif

    func start() {
        guard !shortcutSuspended else { return }
        shortcutRegistrationRequested = true
        guard shortcutHotKey == nil, shortcutEventHandler == nil, shortcutEventTap == nil else { return }
        fallbackShortcutBindings.removeAll(keepingCapacity: true)
        if let error = registerShortcut() {
            onError(error)
            return
        }
        // Optional entry points may be disabled by a system conflict; the
        // settings editor marks those bindings and lets the user replace them
        // without affecting the working primary shortcut.
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
        // Carbon cannot claim a shortcut that macOS owns for its screenshot
        // service.  Do not install an event-tap fallback here: on current
        // macOS releases the screenshot service can run before third-party
        // taps, which would make the setting look saved while the shortcut
        // still launches Apple's UI.  The editor asks the user to choose a
        // non-conflicting combination instead.
        guard SmartCaptureSystemShortcutDetector.conflicts(for: shortcutBinding).isEmpty else {
            Self.logger.error("System screenshot shortcut conflict for \(self.shortcutBinding.displayName, privacy: .public)")
            return .systemShortcutConflict
        }
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

        var hotKey: EventHotKeyRef?
        let hotKeyStatus: OSStatus = RegisterEventHotKey(
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

        if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
        shortcutEventHandler = nil
        shortcutContext = nil
        Self.logger.error("Could not register shortcut \(self.shortcutBinding.displayName, privacy: .public): \(hotKeyStatus, privacy: .public)")
        return .registrationFailed
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
        fallbackShortcutBindings.removeAll(keepingCapacity: true)
        unregisterAdditionalShortcuts()
        for kind in [ScreenCaptureShortcutKind.area, .repeatArea, .applicationWindow, .fullscreen, .activeWindow, .areaAnnotate, .ocr, .scrolling, .objectCutout] {
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
            case .repeatArea: id = SmartCaptureCarbonHotKey.repeatAreaID
            case .applicationWindow: id = SmartCaptureCarbonHotKey.applicationWindowID
            case .fullscreen: id = SmartCaptureCarbonHotKey.fullscreenID
            case .activeWindow: id = SmartCaptureCarbonHotKey.activeWindowID
            case .areaAnnotate: id = SmartCaptureCarbonHotKey.areaAnnotateID
            case .ocr: id = SmartCaptureCarbonHotKey.ocrID
            case .scrolling: id = SmartCaptureCarbonHotKey.scrollingID
            case .objectCutout: id = SmartCaptureCarbonHotKey.objectCutoutID
            case .smartElement: continue
            }
            let systemConflicts = SmartCaptureSystemShortcutDetector.conflicts(for: binding)
            if !systemConflicts.isEmpty {
                Self.logger.error("Skipping \(kind.rawValue, privacy: .public) shortcut \(binding.displayName, privacy: .public) because macOS owns it")
                continue
            }
            var hotKey: EventHotKeyRef?
            let status: OSStatus = RegisterEventHotKey(
                UInt32(binding.keyCode),
                SmartCaptureCarbonHotKey.modifiers(for: binding),
                SmartCaptureCarbonHotKey.identifier(id),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyNoOptions),
                &hotKey
            )
            guard status == noErr, let hotKey else {
                Self.logger.error("Could not register \(kind.rawValue) shortcut \(binding.displayName, privacy: .public): \(status, privacy: .public)")
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

    private func installSelectionEventMonitors() {
        guard selectionLocalMonitor == nil, selectionGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .keyDown,
            .keyUp
        ]
        selectionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handleSelectionMonitorEvent(event) ? nil : event
        }
        selectionGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleSelectionMonitorEvent(event)
        }
    }

    private func removeSelectionEventMonitors() {
        if let selectionLocalMonitor { NSEvent.removeMonitor(selectionLocalMonitor) }
        if let selectionGlobalMonitor { NSEvent.removeMonitor(selectionGlobalMonitor) }
        selectionLocalMonitor = nil
        selectionGlobalMonitor = nil
    }

    /// Routes monitor fallback events through the same selection state machine
    /// used by the CGEvent tap and overlay view. Global monitors are
    /// observe-only, while local events are consumed once handled.
    @discardableResult
    private func handleSelectionMonitorEvent(_ event: NSEvent) -> Bool {
        guard isSelecting else { return false }
        // `NSEvent.mouseLocation` is sampled at callback time and can lag a
        // queued drag event. Prefer the event's own window location when it
        // is available; global monitor events still use the current pointer.
        let point = event.window.map { window in
            let local = event.locationInWindow
            return window.convertPoint(toScreen: local)
        } ?? NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            updateTarget(at: point)
            return true
        case .leftMouseDown:
            handleSelectionMouseDown(atAppKitPoint: point)
            return true
        case .leftMouseDragged:
            handleSelectionMouseDragged(atAppKitPoint: point)
            return true
        case .leftMouseUp:
            handleSelectionMouseUp(atAppKitPoint: point)
            return true
        case .rightMouseDown:
            cancelSelection()
            return true
        case .keyDown:
            return handleSelectionKeyDown(
                keyCode: event.keyCode,
                modifiers: InputSourceShortcutModifiers(event.modifierFlags)
            )
        case .keyUp:
            return handleSelectionKeyUp(keyCode: event.keyCode)
        default:
            return false
        }
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
           !SmartCaptureSystemShortcutDetector.conflicts(for: candidate).isEmpty {
            return .systemShortcutConflict
        }
        if let requiredKind,
           let candidate = bindings[requiredKind],
           shortcutRegistrationRequested {
            if candidate == shortcutBinding {
                return .registrationFailed
            }
            if !probeShortcut(candidate, kind: requiredKind) {
                return .registrationFailed
            }
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
        return false
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
        if !SmartCaptureSystemShortcutDetector.conflicts(for: binding).isEmpty {
            return .systemShortcutConflict
        }
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
        // Optional entry points may be claimed by macOS. Keep the newly
        // registered primary shortcut usable even
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
        initialTargetUpdateTask?.cancel()
        initialTargetUpdateTask = nil
        snapzyPreparationTask?.cancel()
        snapzyPreparationTask = nil
        snapzySessionID = nil
        snapzyFrozenSession = nil
        pendingSnapzyResult = nil
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
        let mediaQuickAccessControllers = Array(self.mediaQuickAccessControllers.values)
        self.mediaQuickAccessControllers.removeAll(keepingCapacity: false)
        for controller in mediaQuickAccessControllers { controller.close() }
        quickAccessStack.removeAll()
        let mediaEditorControllers = Array(self.mediaEditorControllers.values)
        self.mediaEditorControllers.removeAll(keepingCapacity: false)
        for controller in mediaEditorControllers { controller.close() }
        let inlineAnnotationControllers = Array(self.inlineAnnotationControllers.values)
        self.inlineAnnotationControllers.removeAll(keepingCapacity: false)
        for controller in inlineAnnotationControllers { controller.close() }
        let scrollingControllers = Array(self.scrollingControllers.values)
        self.scrollingControllers.removeAll(keepingCapacity: false)
        for controller in scrollingControllers { controller.close() }
    }

    deinit {
        if let selectionEventTap { CGEvent.tapEnable(tap: selectionEventTap, enable: false) }
        if let shortcutEventTap { CGEvent.tapEnable(tap: shortcutEventTap, enable: false) }
        if let selectionLocalMonitor { NSEvent.removeMonitor(selectionLocalMonitor) }
        if let selectionGlobalMonitor { NSEvent.removeMonitor(selectionGlobalMonitor) }
        if let selectionCancelHotKey { UnregisterEventHotKey(selectionCancelHotKey) }
        if let shortcutHotKey { UnregisterEventHotKey(shortcutHotKey) }
        for hotKey in additionalShortcutHotKeys.values { UnregisterEventHotKey(hotKey) }
        if let shortcutEventHandler { RemoveEventHandler(shortcutEventHandler) }
    }

    func startSelection(mode: SmartCaptureSelectionMode = .smartElement) {
        // Manual/application screenshot and recording selection now use the
        // migrated Snapzy window/overlay source.  The smart-element, OCR,
        // annotation, scrolling and cutout modes keep their specialized
        // MacPilot flows because they need a post-capture editor.
        if mode == .manualArea || mode == .applicationWindow ||
            mode == .recordingArea || mode == .recordingApplication {
            startSnapzySelection(mode: mode)
            return
        }
        guard !isSelecting else { return }
        guard screenCaptureAccessProvider() else {
            Self.logger.error("Selection rejected because required permissions are unavailable")
            onError(ScreenCaptureError.permissionRequired)
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            Self.logger.error("Selection rejected because no display is available")
            onError(ScreenCaptureError.noDisplayFound)
            return
        }
        isSelecting = true
        selectionMode = mode
        let isApplicationMode = mode == .applicationWindow || mode == .recordingApplication
        selectionInteraction.reset(mode: isApplicationMode ? .applicationWindow : .area)
        manualSelectionCoordinateFailure = false
        lastSelectionCoordinateFailureLogAt = 0
        registerSelectionCancelShortcut()
        let initialPoint = NSEvent.mouseLocation
        currentTarget = nil
        Self.logger.info("Selection started; resolving initial target asynchronously")
        overlays = screens.map { screen in
            let panel = SmartCaptureOverlayPanel(screenFrame: screen.frame)
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
            // Observe both events delivered to the overlay app and events
            // delivered to the previously frontmost app. Without
            // Accessibility, the first drag/up from another app otherwise
            // bypasses the non-activating panel and never commits.
            Self.logger.warning("Selection event tap unavailable; using foreground overlay input")
            installSelectionEventMonitors()
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
        scheduleInitialTargetResolution(mode: mode, at: initialPoint)
    }

    private func scheduleInitialTargetResolution(
        mode: SmartCaptureSelectionMode,
        at point: CGPoint
    ) {
        initialTargetUpdateTask?.cancel()
        let resolver = initialTargetResolver
        initialTargetUpdateTask = Task { [weak self] in
            let target = await Task.detached(priority: .userInitiated) {
                resolver(mode, point)
            }.value
            guard !Task.isCancelled, let self,
                  self.isSelecting,
                  self.selectionMode == mode else { return }
            self.initialTargetUpdateTask = nil
            self.currentTarget = target
            for overlay in self.overlays {
                overlay.overlayView.targetFrame = target
            }
            Self.logger.info("Initial target resolution completed; target available: \(target != nil)")
        }
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
        if SnapzyAreaSelectionController.shared.isPresenting || snapzySessionID != nil {
            SnapzyAreaSelectionController.shared.cancelSelection()
            resetSnapzyPreparationState()
            QuickAccessManager.shared.resumeAfterCapture()
            return
        }
        guard isSelecting || !overlays.isEmpty else { return }
        isSelecting = false
        initialTargetUpdateTask?.cancel()
        initialTargetUpdateTask = nil
        pendingTargetUpdate?.cancel()
        pendingTargetUpdate = nil
        latestPointerLocation = nil
        manualSelectionStart = nil
        manualSelectionRect = nil
        selectionInteraction.reset()
        manualSelectionCoordinateFailure = false
        stopSelectionEventTap()
        removeSelectionEventMonitors()
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

    private func startSnapzySelection(mode: SmartCaptureSelectionMode) {
        guard !isSelecting, !SnapzyAreaSelectionController.shared.isPresenting else { return }
        guard screenCaptureAccessProvider() else {
            onError(ScreenCaptureError.permissionRequired)
            return
        }

        let interactionMode: AreaSelectionInteractionMode =
            mode == .applicationWindow || mode == .recordingApplication
                ? .applicationWindow
                : .manualRegion
        let applicationConfiguration: AreaSelectionApplicationConfiguration? =
            interactionMode == .applicationWindow
                ? AreaSelectionApplicationConfiguration(
                    prefetchedContentTask: SnapzyScreenCaptureManager.shared.prefetchShareableContent(),
                    excludeOwnApplication: true
                )
                : nil

        _ = startSnapzySelection(
            mode: mode,
            applicationConfiguration: applicationConfiguration
        ) {
            try await FrozenAreaCaptureSession.prepare(
                captureManager: SnapzyScreenCaptureManager.shared,
                showCursor: false,
                excludeDesktopIcons: false,
                excludeDesktopWidgets: false,
                excludeOwnApplication: true,
                prefetchedContentTask: applicationConfiguration?.prefetchedContentTask
            )
        }
    }

    /// Presents Snapzy's selection window before the expensive frozen-display
    /// capture finishes. The preparation closure is injectable so the ordering
    /// can be regression-tested without requiring a live ScreenCaptureKit
    /// permission or waiting for a real display snapshot.
    @discardableResult
    func startSnapzySelection(
        mode: SmartCaptureSelectionMode,
        applicationConfiguration providedApplicationConfiguration: AreaSelectionApplicationConfiguration? = nil,
        preparation: @escaping @MainActor () async throws -> FrozenAreaCaptureSession
    ) -> UUID? {
        guard !isSelecting, !SnapzyAreaSelectionController.shared.isPresenting else { return nil }
        resetSnapzyPreparationState()

        // Suspend the QuickAccess panel's hover monitors while the selection
        // overlay is up so it never competes for the user's pointer.
        QuickAccessManager.shared.suspendForCapture()

        let snapzyMode: SelectionMode =
            (mode == .recordingArea || mode == .recordingApplication) ? .recording : .screenshot
        let interactionMode: AreaSelectionInteractionMode =
            mode == .applicationWindow || mode == .recordingApplication
                ? .applicationWindow
                : .manualRegion
        let applicationConfiguration: AreaSelectionApplicationConfiguration? =
            providedApplicationConfiguration
            ?? (interactionMode == .applicationWindow
                ? AreaSelectionApplicationConfiguration(
                    prefetchedContentTask: SnapzyScreenCaptureManager.shared.prefetchShareableContent(),
                    excludeOwnApplication: true
                )
                : nil)

        let sessionID = UUID()
        SnapzyAreaSelectionController.shared.startSelection(
            mode: snapzyMode,
            backdrops: [:],
            applicationConfiguration: applicationConfiguration,
            initialInteractionMode: interactionMode,
            sessionID: sessionID
        ) { [weak self] result in
            self?.handleSnapzySelectionResult(
                result,
                requestedMode: mode,
                sessionID: sessionID
            )
        }
        snapzySessionID = sessionID

        snapzyPreparationTask = Task { [weak self] in
            do {
                let frozenSession = try await preparation()
                guard !frozenSession.backdrops.isEmpty else {
                    throw ScreenCaptureError.noDisplayFound
                }
                guard !Task.isCancelled,
                      let self,
                      self.snapzySessionID == sessionID
                else { return }

                self.snapzyFrozenSession = frozenSession
                self.snapzyPreparationTask = nil
                SnapzyAreaSelectionController.shared.updateBackdrops(
                    frozenSession.backdrops,
                    for: sessionID
                )
                if let pending = self.pendingSnapzyResult {
                    self.pendingSnapzyResult = nil
                    self.resetSnapzyPreparationState()
                    self.finishSnapzySelection(
                        pending.result,
                        requestedMode: pending.requestedMode,
                        frozenSession: frozenSession
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.snapzySessionID == sessionID else { return }
                self.resetSnapzyPreparationState()
                SnapzyAreaSelectionController.shared.cancelSelection()
                QuickAccessManager.shared.resumeAfterCapture()
                self.onError(error)
            }
        }
        return sessionID
    }

    private func handleSnapzySelectionResult(
        _ result: AreaSelectionResult?,
        requestedMode: SmartCaptureSelectionMode,
        sessionID: UUID
    ) {
        guard snapzySessionID == sessionID else { return }
        guard let result else {
            resetSnapzyPreparationState()
            QuickAccessManager.shared.resumeAfterCapture()
            return
        }
        guard let frozenSession = snapzyFrozenSession else {
            pendingSnapzyResult = (result, requestedMode, sessionID)
            return
        }
        resetSnapzyPreparationState()
        finishSnapzySelection(
            result,
            requestedMode: requestedMode,
            frozenSession: frozenSession
        )
    }

    private func resetSnapzyPreparationState() {
        snapzyPreparationTask?.cancel()
        snapzyPreparationTask = nil
        snapzySessionID = nil
        snapzyFrozenSession = nil
        pendingSnapzyResult = nil
    }

    private func finishSnapzySelection(
        _ result: AreaSelectionResult?,
        requestedMode: SmartCaptureSelectionMode,
        frozenSession: FrozenAreaCaptureSession
    ) {
        QuickAccessManager.shared.resumeAfterCapture()
        guard let result else { return }
        if requestedMode == .recordingArea || requestedMode == .recordingApplication {
            guard SmartCaptureCoordinateConversion.quartzRect(fromAppKitRect: result.rect) != nil else {
                onError(ScreenCaptureError.captureFailed(
                    AppText.value("scCaptureCoordinateUnavailable", language: language())
                ))
                return
            }
            onRecordingSelection(result.rect, requestedMode)
            return
        }

        Task { [weak self] in
            do {
                let crop: FrozenAreaCropResult
                if result.spansMultipleDisplays {
                    crop = try frozenSession.cropCompositeImage(for: result)
                } else {
                    crop = try frozenSession.cropImage(for: result)
                }
                guard let self else { return }
                switch requestedMode {
                case .applicationWindow, .manualArea:
                    if requestedMode == .manualArea { self.onSelectionRect(result.rect) }
                    self.onCapture(crop.image)
                default:
                    self.onCapture(crop.image)
                }
            } catch {
                self?.onError(error)
            }
        }
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

    /// Presents the annotation editor for a QuickAccess card item (Snapzy flow).
    /// The card's "标注" action routes here through `AnnotateManager`.
    func presentQuickAccessAnnotation(for item: QuickAccessItem) {
        guard let image = Self.loadImage(from: item.url) else {
            Self.logger.error("QuickAccess annotation failed to load image: \(item.url.lastPathComponent, privacy: .public)")
            return
        }

        QuickAccessManager.shared.setWindowOpen(id: item.id, isOpen: true)
        QuickAccessManager.shared.pauseCountdownForEditingItem(item.id)

        let id = UUID()
        let controller = SmartAnnotationWindowController(
            image: image,
            language: language(),
            onComplete: { [weak self] annotated in
                self?.saveQuickAccessAnnotatedImage(annotated, item: item)
                QuickAccessManager.shared.resumeCountdownForEditingItem(item.id)
                QuickAccessManager.shared.setWindowOpen(id: item.id, isOpen: false)
                self?.inlineAnnotationControllers.removeValue(forKey: id)
            },
            onClose: { [weak self] in
                QuickAccessManager.shared.resumeCountdownForEditingItem(item.id)
                QuickAccessManager.shared.setWindowOpen(id: item.id, isOpen: false)
                self?.inlineAnnotationControllers.removeValue(forKey: id)
            }
        )
        inlineAnnotationControllers[id] = controller
        controller.show()
    }

    private static func loadImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    private func saveQuickAccessAnnotatedImage(_ image: CGImage, item: QuickAccessItem) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: item.url, options: .atomic)
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        QuickAccessManager.shared.updateItemThumbnail(id: item.id, image: nsImage)
    }

    func showQuickAccess(
        image: CGImage,
        savedURL: URL? = nil,
        onSave: ((CGImage, URL?) -> Void)? = nil,
        onDelete: ((URL?) -> Void)? = nil
    ) {
        let id = UUID()
        let controller = SmartQuickAccessWindowController(
            image: image,
            language: language(),
            savedURL: savedURL,
            onPin: { [weak self] image in self?.pin(image: image) },
            onClose: { [weak self] in
                self?.removeQuickAccess(id: id)
            },
            onSave: onSave,
            onDelete: onDelete
        )
        quickAccessControllers[id] = controller
        let evictedID = quickAccessStack.insert(id)
        if let evictedID { closeQuickAccess(id: evictedID) }
        controller.show()
        layoutQuickAccessStack()
    }

    func showQuickAccess(mediaURL: URL) {
        let id = UUID()
        let controller = SmartMediaQuickAccessWindowController(
            url: mediaURL,
            language: language(),
            onEdit: { [weak self] in
                self?.setQuickAccessCountdownPaused(id: id, paused: true)
                self?.openMediaEditor(url: mediaURL) {
                    self?.setQuickAccessCountdownPaused(id: id, paused: false)
                }
            },
            onClose: { [weak self] in
                self?.removeQuickAccess(id: id)
            }
        )
        mediaQuickAccessControllers[id] = controller
        let evictedID = quickAccessStack.insert(id)
        if let evictedID { closeQuickAccess(id: evictedID) }
        controller.show()
        layoutQuickAccessStack()
    }

    func openMediaEditor(url: URL, onClose: (() -> Void)? = nil) {
        let id = UUID()
        let controller = SmartMediaEditorWindowController(
            url: url,
            language: language(),
            onExport: { [weak self] exportedURL in
                self?.showQuickAccess(mediaURL: exportedURL)
            },
            onClose: { [weak self] in
                self?.mediaEditorControllers.removeValue(forKey: id)
                onClose?()
            }
        )
        mediaEditorControllers[id] = controller
        controller.show()
    }

    private func removeQuickAccess(id: UUID) {
        quickAccessStack.remove(id)
        quickAccessControllers.removeValue(forKey: id)
        mediaQuickAccessControllers.removeValue(forKey: id)
        layoutQuickAccessStack()
    }

    private func setQuickAccessCountdownPaused(id: UUID, paused: Bool) {
        quickAccessControllers[id]?.setCountdownPaused(paused)
        mediaQuickAccessControllers[id]?.setCountdownPaused(paused)
    }

    private func closeQuickAccess(id: UUID) {
        if let controller = quickAccessControllers[id] {
            controller.close()
        } else if let controller = mediaQuickAccessControllers[id] {
            controller.close()
        } else {
            quickAccessStack.remove(id)
        }
    }

    private func layoutQuickAccessStack() {
        let ids = quickAccessStack.ids
        for (index, id) in ids.enumerated() {
            if let controller = quickAccessControllers[id] {
                controller.updateStackPosition(index: index)
            } else if let controller = mediaQuickAccessControllers[id] {
                controller.updateStackPosition(index: index)
            }
        }
        // The newest card is visually on top. Bring older cards forward first
        // so a later card cannot accidentally cover the newest one.
        for id in ids.reversed() {
            quickAccessControllers[id]?.bringToFront()
            mediaQuickAccessControllers[id]?.bringToFront()
        }
    }

    private func updateTarget(at appKitPoint: CGPoint) {
        guard isSelecting,
              (selectionMode == .smartElement || selectionMode == .applicationWindow || selectionMode == .recordingApplication),
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
        case SmartCaptureCarbonHotKey.repeatAreaID:
            onRepeatLastArea()
        case SmartCaptureCarbonHotKey.applicationWindowID:
            startSelection(mode: .applicationWindow)
        case SmartCaptureCarbonHotKey.fullscreenID:
            captureFullscreen()
        case SmartCaptureCarbonHotKey.activeWindowID:
            captureActiveWindow()
        case SmartCaptureCarbonHotKey.areaAnnotateID:
            startSelection(mode: .areaAnnotate)
        case SmartCaptureCarbonHotKey.ocrID:
            startSelection(mode: .ocr)
        case SmartCaptureCarbonHotKey.scrollingID:
            startSelection(mode: .scrolling)
        case SmartCaptureCarbonHotKey.objectCutoutID:
            startSelection(mode: .objectCutout)
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
        guard isSelecting, !selectionInteraction.isDragging else { return }
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
        guard isSelecting, !selectionInteraction.isDragging else { return }
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
        if keyCode == UInt16(kVK_ANSI_A),
           selectionMode == .recordingArea || selectionMode == .recordingApplication {
            return false
        }
        if keyCode == UInt16(kVK_ANSI_A),
           selectionMode != .manualArea,
           selectionMode != .applicationWindow {
            return false
        }
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
        case .applicationWindow, .recordingApplication:
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
            switch selectionMode {
            case .recordingArea, .recordingApplication:
                // Recording mode is selected in the pre-record controls. Do
                // not silently turn an area recording into a screenshot when
                // the user presses the shared `A` overlay key.
                return
            default:
                selectionMode = mode == .applicationWindow ? .applicationWindow : .manualArea
            }
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
        case .applicationWindow, .recordingApplication:
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
        if captureMode == .recordingArea || captureMode == .recordingApplication {
            onRecordingSelection(rect, captureMode)
            return
        }
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
                } else if captureMode == .scrolling {
                    self.presentScrollingCapture(
                        initialImage: image,
                        for: rect,
                        quartzClickPoint: quartzClickPoint
                    )
                } else if captureMode == .objectCutout {
                    self.onObjectCutoutCapture(image)
                } else {
                    self.onCapture(image)
                }
            } catch {
                self?.onError(error)
            }
        }
    }

    private func presentScrollingCapture(
        initialImage: CGImage,
        for rect: CGRect,
        quartzClickPoint: CGPoint
    ) {
        let id = UUID()
        let controller = SmartScrollingCaptureWindowController(
            initialImage: initialImage,
            rect: rect,
            quartzClickPoint: quartzClickPoint,
            language: language(),
            onComplete: { [weak self] image in
                guard let self else { return }
                self.scrollingControllers.removeValue(forKey: id)
                self.onScrollingCapture(image)
            },
            onClose: { [weak self] in
                self?.scrollingControllers.removeValue(forKey: id)
            }
        )
        scrollingControllers[id] = controller
        controller.show()
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// Coordinate conversion seam shared by screenshot and recording selection.
/// The AX/window resolver remains private; only this geometry helper is
/// exposed to the recording model.
enum SmartCaptureCoordinateConversion {
    static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect? {
        SmartAXTargetQuery.quartzRect(fromAppKitRect: rect)
    }
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

private final class SmartCaptureOverlayPanel: NSPanel {
    let overlayView: SmartCaptureOverlayView

    init(screenFrame: CGRect) {
        overlayView = SmartCaptureOverlayView(screenFrame: screenFrame)
        super.init(
            contentRect: screenFrame,
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
        setFrame(screenFrame, display: false)
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
        if event.keyCode == UInt16(kVK_Space) {
            onKeyUp?(event.keyCode)
        } else {
            super.keyUp(with: event)
        }
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

/// Snapzy-style scrolling capture HUD.  The selected region remains owned by
/// the foreground app while this small floating panel listens for wheel events
/// and samples the region after every scroll settle.  Completion stitches the
/// frames using `ScreenCaptureVerticalStitcher` and returns one image through
/// the normal post-capture pipeline.
@MainActor
private final class SmartScrollingCaptureWindowController: NSObject, NSWindowDelegate {
    private var frames: [CGImage]
    private let rect: CGRect
    private let quartzClickPoint: CGPoint
    private let language: AppLanguage
    private let onComplete: (CGImage) -> Void
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var settleTask: Task<Void, Never>?
    private var isCapturing = false

    init(
        initialImage: CGImage,
        rect: CGRect,
        quartzClickPoint: CGPoint,
        language: AppLanguage,
        onComplete: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.frames = [initialImage]
        self.rect = rect
        self.quartzClickPoint = quartzClickPoint
        self.language = language
        self.onComplete = onComplete
        self.onClose = onClose
    }

    func show() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 370, height: 148),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scScrollingTitle", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        installContent(in: panel)
        panel.setFrameOrigin(Self.panelOrigin(for: rect, size: panel.frame.size))
        panel.orderFrontRegardless()
        self.panel = panel
        installScrollMonitors()
    }

    func close() {
        settleTask?.cancel()
        settleTask = nil
        removeScrollMonitors()
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        settleTask?.cancel()
        settleTask = nil
        removeScrollMonitors()
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func installContent(in panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: SmartScrollingCaptureView(
            frameCount: frames.count,
            language: language,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.close() }
        ))
    }

    private func refreshContent() {
        guard let panel else { return }
        installContent(in: panel)
    }

    private func installScrollMonitors() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel]
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleScroll(event) }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleScroll(event) }
            return event
        }
    }

    private func removeScrollMonitors() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        scrollMonitor = nil
        localScrollMonitor = nil
    }

    private func handleScroll(_ event: NSEvent) {
        guard panel != nil,
              !isCapturing,
              rect.contains(NSEvent.mouseLocation),
              abs(event.scrollingDeltaY) > 0.1 || abs(event.scrollingDeltaX) > 0.1 else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.captureSettledFrame()
        }
    }

    private func captureSettledFrame() async {
        guard panel != nil, !isCapturing, frames.count < 30 else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await SmartScreenImageCapture.capture(
                appKitRect: rect,
                quartzClickPoint: quartzClickPoint
            )
            frames.append(image)
            refreshContent()
        } catch {
            let alert = NSAlert()
            alert.messageText = AppText.value("scScrollingTitle", language: language)
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: AppText.value("scOK", language: language))
            alert.runModal()
        }
    }

    private func finish() {
        guard let image = ScreenCaptureVerticalStitcher.stitch(frames) else {
            let alert = NSAlert()
            alert.messageText = AppText.value("scScrollingTitle", language: language)
            alert.informativeText = AppText.value("scScrollingStitchFailed", language: language)
            alert.addButton(withTitle: AppText.value("scOK", language: language))
            alert.runModal()
            close()
            return
        }
        close()
        onComplete(image)
    }

    private static func panelOrigin(for selection: CGRect, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(selection.maxX + 12, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(selection.maxY - size.height, visible.minY + 8), visible.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }
}

private struct SmartScrollingCaptureView: View {
    let frameCount: Int
    let language: AppLanguage
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.value("scScrollingHint", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(AppText.value("scScrollingFrames", language: language, frameCount), systemImage: "square.stack.3d.up")
                Spacer()
                Button(AppText.value("scCancel", language: language), action: onCancel)
                Button(AppText.value("scDone", language: language), action: onFinish)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private enum SmartScreenImageCapture {
    static func capture(appKitRect: CGRect, quartzClickPoint: CGPoint) async throws -> CGImage {
        // The previous implementation rebuilt the ScreenCaptureKit and
        // multi-display crop flow locally.  Route every interactive region
        // capture through Snapzy's migrated manager instead: it freezes the
        // displays, then uses the upstream FrozenAreaCaptureSession crop and
        // composite algorithms.
        _ = quartzClickPoint
        guard let image = try await SnapzyScreenCaptureManager.shared.captureAreaAsImage(
            rect: appKitRect
        ) else {
            throw ScreenCaptureError.captureFailed(
                AppText.value("scCaptureOutsideDisplay", language: .system)
            )
        }
        return image
    }

}

struct SmartDisplaySnapshot: @unchecked Sendable {
    let image: CGImage
    let screenFrame: CGRect
}

enum SmartDisplaySnapshotCrop {
    static func crop(image: CGImage, screenFrame: CGRect, selection: CGRect) -> CGImage? {
        let rect = pixelCropRect(image: image, screenFrame: screenFrame, selection: selection)
        guard !rect.isEmpty else { return nil }
        return image.cropping(to: rect)
    }

    static func composite(snapshots: [SmartDisplaySnapshot], selection: CGRect) -> CGImage? {
        let visible = snapshots.compactMap { snapshot -> (SmartDisplaySnapshot, CGRect, CGFloat)? in
            let intersection = snapshot.screenFrame.intersection(selection)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
            let scale = pixelScale(image: snapshot.image, frame: snapshot.screenFrame)
            return (snapshot, intersection, scale)
        }
        guard !visible.isEmpty else { return nil }
        let outputScale = visible.map(\.2).max() ?? 1
        let clippedSelection = visible.reduce(CGRect.null) { $0.union($1.1) }
        let outputWidth = max(1, Int((clippedSelection.width * outputScale).rounded()))
        let outputHeight = max(1, Int((clippedSelection.height * outputScale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        for (snapshot, intersection, _) in visible {
            guard let cropped = crop(image: snapshot.image, screenFrame: snapshot.screenFrame, selection: intersection) else { continue }
            let destination = CGRect(
                x: (intersection.minX - clippedSelection.minX) * outputScale,
                y: (intersection.minY - clippedSelection.minY) * outputScale,
                width: intersection.width * outputScale,
                height: intersection.height * outputScale
            )
            context.interpolationQuality = .none
            context.draw(cropped, in: destination)
        }
        return context.makeImage()
    }

    static func pixelCropRect(image: CGImage, screenFrame: CGRect, selection: CGRect) -> CGRect {
        let scale = pixelScale(image: image, frame: screenFrame)
        let relative = selection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let bounds = CGRect(origin: .zero, size: screenFrame.size)
        let clipped = relative.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .null }
        let flippedY = screenFrame.height - clipped.minY - clipped.height
        return CGRect(
            x: (clipped.minX * scale).rounded(.down),
            y: (flippedY * scale).rounded(.down),
            width: max(1, (clipped.width * scale).rounded(.up)),
            height: max(1, (clipped.height * scale).rounded(.up))
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private static func pixelScale(image: CGImage, frame: CGRect) -> CGFloat {
        max(1, CGFloat(image.width) / max(frame.width, 1), CGFloat(image.height) / max(frame.height, 1))
    }
}

enum SmartDisplaySnapshotCapture {
    typealias CaptureFunction = @convention(c) (CGDirectDisplayID) -> CGImage?
    private static let captureFunction: CaptureFunction? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CaptureFunction.self)
    }()

    static func capture(displayID: CGDirectDisplayID) -> CGImage? {
        captureFunction?(displayID)
    }
}

enum SmartWindowSnapshotCapture {
    typealias CaptureFunction = @convention(c) (
        CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
    ) -> CGImage?

    private static let captureFunction: CaptureFunction? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CaptureFunction.self)
    }()

    static func capture(windowID: CGWindowID) -> CGImage? {
        captureFunction?(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming])
    }

    static func frontmostWindowID(processID: pid_t) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let candidates: [(CGWindowID, CGFloat)] = info.compactMap { entry in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 80, rect.height >= 60 else { return nil }
            return (CGWindowID(windowID.uint32Value), rect.width * rect.height)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }
}

/// The lightweight state machine behind the Quick Access card stack. Keeping
/// this separate from AppKit windows makes the eviction/order rules testable
/// without creating panels or requiring screen-capture permissions.
struct SmartQuickAccessStackState: Equatable, Sendable {
    static let maxVisibleItems = 5

    /// IDs are ordered newest-first, matching the z-order of the floating
    /// cards and the order in which captures appear to the user.
    private(set) var ids: [UUID] = []

    @discardableResult
    mutating func insert(_ id: UUID) -> UUID? {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        guard ids.count > Self.maxVisibleItems else { return nil }
        return ids.removeLast()
    }

    mutating func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
    }

    mutating func removeAll() {
        ids.removeAll(keepingCapacity: false)
    }
}

@MainActor
private final class SmartQuickAccessWindowController: NSObject, NSWindowDelegate, ObservableObject {
    private static let autoDismissDelay: TimeInterval = 10

    private var image: CGImage
    private let language: AppLanguage
    private let savedURL: URL?
    private let onPin: (CGImage) -> Void
    private let onClose: () -> Void
    private let onSave: ((CGImage, URL?) -> Void)?
    private let onDelete: ((URL?) -> Void)?
    private var panel: NSPanel?
    private var annotationController: SmartAnnotationWindowController?
    private var countdownTimer: Timer?
    private var isHovered = false
    private var countdownPaused = false
    @Published private(set) var remainingTime = SmartQuickAccessWindowController.autoDismissDelay

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
        startCountdown()
    }

    func close() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        panel?.close()
        panel = nil
    }

    func updateStackPosition(index: Int) {
        guard let panel else { return }
        let visibleFrame = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let offset = CGFloat(index) * 14
        let margin: CGFloat = 24
        let x = visibleFrame.maxX - panel.frame.width - margin - offset
        let y = visibleFrame.minY + margin + offset
        panel.setFrameOrigin(NSPoint(x: max(visibleFrame.minX + margin, x), y: max(visibleFrame.minY + margin, y)))
        panel.alphaValue = max(0.58, 1 - CGFloat(index) * 0.08)
    }

    func bringToFront() {
        panel?.orderFrontRegardless()
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
    }

    func setCountdownPaused(_ paused: Bool) {
        countdownPaused = paused
    }

    func windowWillClose(_ notification: Notification) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        annotationController?.close()
        annotationController = nil
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func installContent(in panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: SmartQuickAccessView(
            controller: self,
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

    private func startCountdown() {
        countdownTimer?.invalidate()
        remainingTime = Self.autoDismissDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceCountdown()
            }
        }
    }

    private func advanceCountdown() {
        guard !isHovered, !countdownPaused else { return }
        remainingTime = max(0, remainingTime - 0.1)
        if remainingTime <= 0 { close() }
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
        setCountdownPaused(true)
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
                self?.setCountdownPaused(false)
                self?.panel?.orderFrontRegardless()
                self?.annotationController = nil
            }
        )
        annotationController = controller
        controller.show()
    }
}

private struct SmartQuickAccessView: View {
    @ObservedObject var controller: SmartQuickAccessWindowController
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
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(ceil(controller.remainingTime)))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
        .onHover { controller.setHovered($0) }
        .onTapGesture(count: 2, perform: onAnnotate)
    }
}

private struct SendableMediaThumbnail: @unchecked Sendable {
    let image: CGImage
}

@MainActor
private final class SmartMediaQuickAccessWindowController: NSObject, NSWindowDelegate, ObservableObject {
    private static let autoDismissDelay: TimeInterval = 10

    private let url: URL
    private let language: AppLanguage
    private let onEdit: () -> Void
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var countdownTimer: Timer?
    private var isHovered = false
    private var countdownPaused = false
    @Published private(set) var remainingTime = SmartMediaQuickAccessWindowController.autoDismissDelay

    init(url: URL, language: AppLanguage, onEdit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.url = url
        self.language = language
        self.onEdit = onEdit
        self.onClose = onClose
    }

    func show() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scRecordingActions", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SmartMediaQuickAccessView(
            controller: self,
            url: url,
            language: language,
            onCopy: { [weak self] in self?.copyMedia() },
            onOpen: { [weak self] in self?.openMedia() },
            onEdit: { [weak self] in self?.editMedia() },
            onReveal: { [weak self] in self?.revealMedia() },
            onClose: { [weak self] in self?.close() }
        ))
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        startCountdown()
    }

    func close() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        panel?.close()
        panel = nil
    }

    func updateStackPosition(index: Int) {
        guard let panel else { return }
        let visibleFrame = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let offset = CGFloat(index) * 14
        let margin: CGFloat = 24
        let x = visibleFrame.maxX - panel.frame.width - margin - offset
        let y = visibleFrame.minY + margin + offset
        panel.setFrameOrigin(NSPoint(x: max(visibleFrame.minX + margin, x), y: max(visibleFrame.minY + margin, y)))
        panel.alphaValue = max(0.58, 1 - CGFloat(index) * 0.08)
    }

    func bringToFront() {
        panel?.orderFrontRegardless()
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
    }

    func setCountdownPaused(_ paused: Bool) {
        countdownPaused = paused
    }

    func windowWillClose(_ notification: Notification) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        panel?.contentView = nil
        panel = nil
        onClose()
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        remainingTime = Self.autoDismissDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceCountdown()
            }
        }
    }

    private func advanceCountdown() {
        guard !isHovered, !countdownPaused else { return }
        remainingTime = max(0, remainingTime - 0.1)
        if remainingTime <= 0 { close() }
    }

    private func copyMedia() {
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.writeObjects([url as NSURL])
    }

    private func openMedia() {
        NSWorkspace.shared.open(url)
    }

    private func editMedia() {
        setCountdownPaused(true)
        onEdit()
    }

    private func revealMedia() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct SmartMediaQuickAccessView: View {
    @ObservedObject var controller: SmartMediaQuickAccessWindowController
    let url: URL
    let language: AppLanguage
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: url.pathExtension.lowercased() == "gif" ? "photo.on.rectangle" : "film")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black.opacity(0.06))

            HStack(spacing: 8) {
                Button(action: onCopy) { Label(AppText.value("scCopy", language: language), systemImage: "doc.on.doc") }
                Button(action: onOpen) { Label(AppText.value("scOpen", language: language), systemImage: "arrow.up.right.square") }
                Button(action: onEdit) { Label(AppText.value("scEditMedia", language: language), systemImage: "scissors") }
                Button(action: onReveal) { Label(AppText.value("scReveal", language: language), systemImage: "folder") }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(AppText.value("scClose", language: language))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(.ultraThinMaterial)
        }
        .task(id: url) {
            guard let loaded = await Self.loadThumbnail(from: url) else {
                thumbnail = nil
                return
            }
            thumbnail = NSImage(
                cgImage: loaded.image,
                size: NSSize(width: loaded.image.width, height: loaded.image.height)
            )
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(ceil(controller.remainingTime)))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
        .onHover { controller.setHovered($0) }
    }

    private static func loadThumbnail(from url: URL) async -> SendableMediaThumbnail? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 620)
            guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return SendableMediaThumbnail(image: image)
        }.value
    }
}

private enum SmartMediaEditingError: Error, Equatable {
    case unsupportedGIF
    case invalidRange
    case exporterUnavailable
    case exportFailed

    var messageKey: String {
        switch self {
        case .unsupportedGIF: return "scMediaGIFEditorHint"
        case .invalidRange: return "scMediaInvalidTrimRange"
        case .exporterUnavailable: return "scMediaExporterUnavailable"
        case .exportFailed: return "scMediaExportFailed"
        }
    }
}

/// AVFoundation's exporter is callback-based and is not annotated Sendable.
/// The export callback is invoked exactly once by AVFoundation, so keeping the
/// reference in this small unchecked wrapper lets Swift's continuation bridge
/// remain explicit without leaking the non-Sendable object through a task.
private final class SmartAssetExporterBox: @unchecked Sendable {
    let exporter: AVAssetExportSession

    init(_ exporter: AVAssetExportSession) {
        self.exporter = exporter
    }
}

@MainActor
private enum SmartMediaEditing {
    static func duration(of url: URL) async -> TimeInterval {
        let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    static func trim(url: URL, start: TimeInterval, end: TimeInterval) async throws -> URL {
        guard url.pathExtension.lowercased() != "gif" else {
            throw SmartMediaEditingError.unsupportedGIF
        }
        guard end > start, end - start >= 0.25 else {
            throw SmartMediaEditingError.invalidRange
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds > 0 else {
            throw SmartMediaEditingError.invalidRange
        }
        let clampedStart = max(0, min(start, duration.seconds))
        let clampedEnd = max(clampedStart, min(end, duration.seconds))
        guard clampedEnd - clampedStart >= 0.25 else {
            throw SmartMediaEditingError.invalidRange
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw SmartMediaEditingError.exporterUnavailable
        }
        let exporterBox = SmartAssetExporterBox(exporter)

        let fileExtension = url.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"
        let base = url.deletingPathExtension().appendingPathExtension("trimmed")
        var outputURL = base.appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = url.deletingPathExtension()
                .appendingPathExtension("trimmed-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = fileExtension == "mp4" ? .mp4 : .mov
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            duration: CMTime(seconds: clampedEnd - clampedStart, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporterBox.exporter.exportAsynchronously {
                switch exporterBox.exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed, .cancelled:
                    continuation.resume(throwing: SmartMediaEditingError.exportFailed)
                default:
                    continuation.resume(throwing: SmartMediaEditingError.exportFailed)
                }
            }
        }
        return outputURL
    }
}

@MainActor
private final class SmartMediaEditorWindowController: NSObject, NSWindowDelegate {
    private let url: URL
    private let language: AppLanguage
    private let onExport: (URL) -> Void
    private let onClose: () -> Void
    private var panel: NSPanel?

    init(
        url: URL,
        language: AppLanguage,
        onExport: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.language = language
        self.onExport = onExport
        self.onClose = onClose
    }

    func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.value("scMediaEditor", language: language)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SmartMediaEditorView(
            url: url,
            language: language,
            onExport: { [weak self] exportedURL in
                self?.onExport(exportedURL)
            },
            onClose: { [weak self] in self?.close() }
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel?.contentView = nil
        panel = nil
        onClose()
    }
}

private struct SmartMediaEditorView: View {
    let url: URL
    let language: AppLanguage
    let onExport: (URL) -> Void
    let onClose: () -> Void
    @State private var startSeconds: Double
    @State private var endSeconds: Double
    @State private var mediaDuration: Double = 0
    @State private var isExporting = false
    @State private var message: String?
    @State private var player: AVPlayer

    init(
        url: URL,
        language: AppLanguage,
        onExport: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.language = language
        self.onExport = onExport
        self.onClose = onClose
        _startSeconds = State(initialValue: 0)
        _endSeconds = State(initialValue: 0)
        _player = State(initialValue: AVPlayer(url: url))
    }

    private var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
    private var duration: Double { max(mediaDuration, 0.25) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppText.value("scMediaEditor", language: language))
                        .font(.title2.bold())
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(url.pathExtension.uppercased())
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            if isGIF {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(AppText.value("scMediaGIFEditorHint", language: language))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(AppText.value("scMediaTrimStart", language: language))
                        Slider(value: $startSeconds, in: 0...max(0.25, duration), step: 0.05)
                        Text(formatTime(startSeconds))
                            .font(.system(.caption, design: .monospaced))
                    }
                    HStack {
                        Text(AppText.value("scMediaTrimEnd", language: language))
                        Slider(value: $endSeconds, in: 0...max(0.25, duration), step: 0.05)
                        Text(formatTime(endSeconds))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .onChange(of: startSeconds) { _, value in
                    if value >= endSeconds { endSeconds = min(duration, value + 0.25) }
                }
                .onChange(of: endSeconds) { _, value in
                    if value <= startSeconds { startSeconds = max(0, value - 0.25) }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(AppText.value("cancel", language: language), role: .cancel, action: onClose)
                Spacer()
                if !isGIF {
                    Button(
                        isExporting
                            ? AppText.value("scMediaExporting", language: language)
                            : AppText.value("scMediaExportTrim", language: language)
                    ) {
                        exportTrim()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || endSeconds <= startSeconds)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500)
        .onDisappear { player.pause() }
        .task {
            guard !isGIF else { return }
            let loadedDuration = await SmartMediaEditing.duration(of: url)
            mediaDuration = loadedDuration
            if endSeconds <= 0 {
                endSeconds = loadedDuration
            }
        }
    }

    private func exportTrim() {
        isExporting = true
        message = nil
        Task { @MainActor in
            do {
                let output = try await SmartMediaEditing.trim(
                    url: url,
                    start: startSeconds,
                    end: endSeconds
                )
                isExporting = false
                message = AppText.value("scMediaExported", language: language, arguments: [output.lastPathComponent])
                onExport(output)
                NSWorkspace.shared.open(output)
            } catch {
                isExporting = false
                let key = (error as? SmartMediaEditingError)?.messageKey ?? "scMediaExportFailed"
                message = AppText.value(key, language: language)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
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
    case filledRectangle
    case ellipse
    case arrow
    case line
    case blur
    case spotlight
    case counter
    case highlighter
    case pencil
    case text
    case watermark
    case crop

    var id: String { rawValue }

    /// SF Symbols used by the annotation tool picker. Keeping the symbol next
    /// to the tool definition makes it impossible for the picker and the
    /// renderer to drift apart when another tool is added.
    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "oval"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .blur: return "eye.slash"
        case .spotlight: return "circle.dashed.inset.filled"
        case .counter: return "3.circle"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .text: return "textformat"
        case .watermark: return "text.badge.plus"
        case .crop: return "crop"
        }
    }

    var titleKey: String {
        switch self {
        case .rectangle: return "scAnnotationRectangle"
        case .filledRectangle: return "scAnnotationFilledRectangle"
        case .ellipse: return "scAnnotationEllipse"
        case .arrow: return "scAnnotationArrow"
        case .line: return "scAnnotationLine"
        case .blur: return "scAnnotationBlur"
        case .spotlight: return "scAnnotationSpotlight"
        case .counter: return "scAnnotationCounter"
        case .highlighter: return "scAnnotationHighlighter"
        case .pencil: return "scAnnotationPencil"
        case .text: return "scAnnotationText"
        case .watermark: return "scAnnotationWatermark"
        case .crop: return "scAnnotationCrop"
        }
    }

    func title(language: AppLanguage) -> String {
        AppText.value(titleKey, language: language)
    }
}

enum SmartAnnotation: Equatable {
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case ellipse(CGRect)
    case arrow(CGPoint, CGPoint)
    case line(CGPoint, CGPoint)
    case blur(CGRect)
    case spotlight(CGRect)
    case counter(Int, CGPoint)
    case highlighter(CGPoint, CGPoint)
    case pencil([CGPoint])
    case text(String, CGPoint)
    case watermark(String, CGPoint)
    case crop(CGRect)
}

/// A small value-type history seam used by the annotation editor and tests.
/// New edits invalidate the redo stack, matching standard editor behaviour.
struct SmartAnnotationHistory: Equatable {
    private(set) var annotations: [SmartAnnotation] = []
    private var redoAnnotations: [SmartAnnotation] = []

    mutating func append(_ annotation: SmartAnnotation) {
        annotations.append(annotation)
        redoAnnotations.removeAll(keepingCapacity: true)
    }

    @discardableResult
    mutating func undo() -> SmartAnnotation? {
        guard let annotation = annotations.popLast() else { return nil }
        redoAnnotations.append(annotation)
        return annotation
    }

    @discardableResult
    mutating func redo() -> SmartAnnotation? {
        guard let annotation = redoAnnotations.popLast() else { return nil }
        annotations.append(annotation)
        return annotation
    }

    mutating func removeAll() {
        annotations.removeAll(keepingCapacity: true)
        redoAnnotations.removeAll(keepingCapacity: true)
    }
}

@MainActor
private final class SmartAnnotationModel: ObservableObject {
    @Published var tool: SmartAnnotationTool = .rectangle
    @Published private(set) var annotations: [SmartAnnotation] = []
    @Published private(set) var canRedo = false
    private var redoAnnotations: [SmartAnnotation] = []
    private(set) var nextCounter = 1

    func append(_ annotation: SmartAnnotation) {
        annotations.append(annotation)
        redoAnnotations.removeAll(keepingCapacity: true)
        canRedo = false
        if case .counter = annotation { nextCounter += 1 }
    }

    func undo() {
        guard let annotation = annotations.popLast() else { return }
        redoAnnotations.append(annotation)
        canRedo = true
        if case .counter = annotation { nextCounter = max(1, nextCounter - 1) }
    }

    func redo() {
        guard let annotation = redoAnnotations.popLast() else { return }
        annotations.append(annotation)
        canRedo = !redoAnnotations.isEmpty
        if case .counter = annotation { nextCounter += 1 }
    }

    func removeAll() {
        annotations.removeAll(keepingCapacity: true)
        redoAnnotations.removeAll(keepingCapacity: true)
        canRedo = false
        nextCounter = 1
    }
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
    @State private var dragPoints: [CGPoint] = []
    @State private var showingTextEntry = false
    @State private var pendingText = ""
    @State private var textPoint = CGPoint.zero
    @State private var pendingTextTool: SmartAnnotationTool = .text

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                annotationToolPalette
                Button(AppText.value("scUndo", language: language), action: model.undo)
                    .disabled(model.annotations.isEmpty)
                Button(AppText.value("scRedo", language: language), action: model.redo)
                    .disabled(!model.canRedo)
                if !model.annotations.isEmpty {
                    Button(AppText.value("scClearAnnotations", language: language)) {
                        model.removeAll()
                    }
                }
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
                            if dragStart == nil {
                                dragStart = value.startLocation
                                dragPoints = [value.startLocation]
                            }
                            dragCurrent = value.location
                            dragPoints.append(value.location)
                        }
                        .onEnded { value in finishDrag(value.location, fitted: fitted) })
                }
            }
        }
        .sheet(isPresented: $showingTextEntry) {
            VStack(spacing: 16) {
                Text(AppText.value(
                    pendingTextTool == .watermark ? "scAnnotationWatermarkTitle" : "scAnnotationTextTitle",
                    language: language
                )).font(.headline)
                TextField(AppText.value("scText", language: language), text: $pendingText).textFieldStyle(.roundedBorder)
                HStack {
                    Button(AppText.value("scCancel", language: language)) { showingTextEntry = false }
                    Button(AppText.value("scAdd", language: language)) {
                        if !pendingText.isEmpty {
                            let annotation: SmartAnnotation = pendingTextTool == .watermark
                                ? .watermark(pendingText, textPoint)
                                : .text(pendingText, textPoint)
                            model.append(annotation)
                        }
                        pendingText = ""
                        showingTextEntry = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private var annotationToolPalette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(SmartAnnotationTool.allCases) { tool in
                    let isSelected = model.tool == tool
                    Button {
                        model.tool = tool
                    } label: {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 28)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(tool.title(language: language))
                    .accessibilityLabel(tool.title(language: language))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .help(AppText.value("scAnnotationTool", language: language))
    }

    private func fittedRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func finishDrag(_ end: CGPoint, fitted: CGRect) {
        guard let start = dragStart, fitted.contains(start), fitted.contains(end) else {
            resetDrag(); return
        }
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        switch model.tool {
        case .rectangle:
            if rect.width > 3, rect.height > 3 { model.append(.rectangle(normalized(rect, in: fitted))) }
        case .filledRectangle:
            if rect.width > 3, rect.height > 3 { model.append(.filledRectangle(normalized(rect, in: fitted))) }
        case .ellipse:
            if rect.width > 3, rect.height > 3 { model.append(.ellipse(normalized(rect, in: fitted))) }
        case .blur:
            if rect.width > 3, rect.height > 3 { model.append(.blur(normalized(rect, in: fitted))) }
        case .spotlight:
            if rect.width > 3, rect.height > 3 { model.append(.spotlight(normalized(rect, in: fitted))) }
        case .crop:
            if rect.width > 3, rect.height > 3 { model.append(.crop(normalized(rect, in: fitted))) }
        case .arrow, .line, .highlighter:
            if hypot(end.x - start.x, end.y - start.y) > 4 {
                let startPoint = normalized(start, in: fitted)
                let endPoint = normalized(end, in: fitted)
                switch model.tool {
                case .arrow: model.append(.arrow(startPoint, endPoint))
                case .line: model.append(.line(startPoint, endPoint))
                case .highlighter: model.append(.highlighter(startPoint, endPoint))
                default: break
                }
            }
        case .pencil:
            let points = (dragPoints + [end]).map { normalized($0, in: fitted) }
            if points.count > 1 { model.append(.pencil(points)) }
        case .counter:
            model.append(.counter(model.nextCounter, normalized(end, in: fitted)))
        case .text:
            textPoint = normalized(end, in: fitted)
            pendingTextTool = .text
            showingTextEntry = true
        case .watermark:
            textPoint = normalized(end, in: fitted)
            pendingTextTool = .watermark
            showingTextEntry = true
        }
        resetDrag()
    }

    private func resetDrag() {
        dragStart = nil
        dragCurrent = nil
        dragPoints.removeAll(keepingCapacity: true)
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
        case .rectangle, .filledRectangle, .ellipse, .blur, .crop:
            let value = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            if model.tool == .ellipse {
                context.stroke(Path(ellipseIn: value), with: .color(.red), lineWidth: 3)
            } else {
                context.stroke(Path(value), with: .color(.red), lineWidth: 3)
            }
        case .spotlight:
            let value = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            var mask = Path()
            mask.addRect(rect)
            mask.addRect(value)
            context.fill(mask, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
            context.stroke(Path(value), with: .color(.red), lineWidth: 3)
        case .arrow, .line, .highlighter:
            drawLineLike(model.tool, from: start, to: end, context: &context)
        case .pencil:
            drawPencil(dragPoints + [end], context: &context)
        case .counter:
            drawCounter(model.nextCounter, at: end, context: &context)
        case .text, .watermark:
            break
        }
    }

    private func draw(_ annotation: SmartAnnotation, context: inout GraphicsContext, in rect: CGRect) {
        switch annotation {
        case .rectangle(let value):
            let denormalized = denormalized(value, in: rect)
            context.stroke(Path(denormalized), with: .color(.red), lineWidth: 3)
        case .filledRectangle(let value):
            let denormalized = denormalized(value, in: rect)
            context.fill(Path(denormalized), with: .color(.red.opacity(0.35)))
            context.stroke(Path(denormalized), with: .color(.red), lineWidth: 3)
        case .ellipse(let value):
            context.stroke(Path(ellipseIn: denormalized(value, in: rect)), with: .color(.red), lineWidth: 3)
        case .arrow(let start, let end):
            drawArrow(from: denormalized(start, in: rect), to: denormalized(end, in: rect), context: &context)
        case .line(let start, let end):
            drawLineLike(.line, from: denormalized(start, in: rect), to: denormalized(end, in: rect), context: &context)
        case .blur(let value):
            let denormalized = denormalized(value, in: rect)
            context.fill(Path(denormalized), with: .color(.gray.opacity(0.35)))
        case .spotlight(let value):
            var mask = Path()
            mask.addRect(rect)
            mask.addRect(denormalized(value, in: rect))
            context.fill(mask, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
        case .counter(let value, let point):
            drawCounter(value, at: denormalized(point, in: rect), context: &context)
        case .highlighter(let start, let end):
            drawLineLike(.highlighter, from: denormalized(start, in: rect), to: denormalized(end, in: rect), context: &context)
        case .pencil(let points):
            drawPencil(points.map { denormalized($0, in: rect) }, context: &context)
        case .text(let text, let point):
            context.draw(Text(text).font(.system(size: 18, weight: .bold)).foregroundColor(.red), at: denormalized(point, in: rect), anchor: .topLeading)
        case .watermark(let text, let point):
            context.draw(Text(text).font(.system(size: 16, weight: .medium)).foregroundColor(.white.opacity(0.75)), at: denormalized(point, in: rect), anchor: .topLeading)
        case .crop:
            break
        }
    }

    private func denormalized(_ value: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + value.minX * rect.width, y: rect.minY + value.minY * rect.height, width: value.width * rect.width, height: value.height * rect.height)
    }

    private func denormalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func drawLineLike(_ tool: SmartAnnotationTool, from start: CGPoint, to end: CGPoint, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let color: Color = tool == .highlighter ? .yellow.opacity(0.45) : .red
        let width: CGFloat = tool == .highlighter ? 14 : 3
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        if tool == .arrow { drawArrow(from: start, to: end, context: &context) }
    }

    private func drawPencil(_ points: [CGPoint], context: inout GraphicsContext) {
        guard let first = points.first, points.count > 1 else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    private func drawCounter(_ value: Int, at point: CGPoint, context: inout GraphicsContext) {
        let radius: CGFloat = 14
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: circle), with: .color(.red))
        context.draw(Text(String(value)).font(.system(size: 13, weight: .bold)).foregroundColor(.white), at: point, anchor: .center)
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
        let width = image.width
        let height = image.height
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let crop = annotations.reversed().compactMap { annotation -> CGRect? in
            guard case .crop(let rect) = annotation else { return nil }
            return rect.standardized.intersection(unitRect)
        }.first

        let source: CGImage
        let normalizedCanvas: CGRect
        if let crop, crop.width > 0, crop.height > 0,
           let cropped = image.cropping(to: pixelRect(for: crop, width: width, height: height)) {
            source = cropped
            normalizedCanvas = crop
        } else {
            source = image
            normalizedCanvas = unitRect
        }

        let outputWidth = source.width
        let outputHeight = source.height
        let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(source, in: bounds)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setFillColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(3, CGFloat(outputWidth) / 350))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for annotation in annotations {
            guard case .crop = annotation else {
                draw(annotation, in: context, bounds: bounds, canvas: normalizedCanvas)
                continue
            }
        }
        return context.makeImage()
    }

    private static func pixelRect(for normalized: CGRect, width: Int, height: Int) -> CGRect {
        let minX = (normalized.minX * CGFloat(width)).rounded()
        let minY = ((1 - normalized.maxY) * CGFloat(height)).rounded()
        let maxX = (normalized.maxX * CGFloat(width)).rounded()
        let maxY = ((1 - normalized.minY) * CGFloat(height)).rounded()
        return CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

    private static func rect(_ normalized: CGRect, in bounds: CGRect, canvas: CGRect) -> CGRect {
        let value = normalized.standardized
        let x = (value.minX - canvas.minX) / canvas.width
        let y = (value.minY - canvas.minY) / canvas.height
        return CGRect(
            x: x * bounds.width,
            y: (1 - y - value.height / canvas.height) * bounds.height,
            width: value.width / canvas.width * bounds.width,
            height: value.height / canvas.height * bounds.height
        )
    }

    private static func point(_ normalized: CGPoint, in bounds: CGRect, canvas: CGRect) -> CGPoint {
        let x = (normalized.x - canvas.minX) / canvas.width
        let y = (normalized.y - canvas.minY) / canvas.height
        return CGPoint(x: x * bounds.width, y: (1 - y) * bounds.height)
    }

    private static func points(_ values: [CGPoint], in bounds: CGRect, canvas: CGRect) -> [CGPoint] {
        values.map { point($0, in: bounds, canvas: canvas) }
    }

    private static func draw(
        _ annotation: SmartAnnotation,
        in context: CGContext,
        bounds: CGRect,
        canvas: CGRect
    ) {
        switch annotation {
        case .rectangle(let value):
            context.stroke(rect(value, in: bounds, canvas: canvas))
        case .filledRectangle(let value):
            let target = rect(value, in: bounds, canvas: canvas)
            context.setFillColor(NSColor.systemRed.withAlphaComponent(0.35).cgColor)
            context.fill(target)
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.stroke(target)
        case .ellipse(let value):
            context.strokeEllipse(in: rect(value, in: bounds, canvas: canvas))
        case .arrow(let start, let end):
            drawArrow(from: point(start, in: bounds, canvas: canvas), to: point(end, in: bounds, canvas: canvas), in: context, width: bounds.width)
        case .line(let start, let end):
            drawLine(from: point(start, in: bounds, canvas: canvas), to: point(end, in: bounds, canvas: canvas), in: context)
        case .blur(let value):
            applyBlur(to: context, rect: rect(value, in: bounds, canvas: canvas), bounds: bounds)
        case .spotlight(let value):
            let target = rect(value, in: bounds, canvas: canvas)
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
            context.addRect(bounds)
            context.addRect(target)
            context.drawPath(using: .eoFill)
            context.restoreGState()
        case .counter(let value, let location):
            drawCounter(value, at: point(location, in: bounds, canvas: canvas), in: context, width: bounds.width)
        case .highlighter(let start, let end):
            context.saveGState()
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.48).cgColor)
            context.setLineWidth(max(10, bounds.width / 25))
            context.setLineCap(.round)
            context.move(to: point(start, in: bounds, canvas: canvas))
            context.addLine(to: point(end, in: bounds, canvas: canvas))
            context.strokePath()
            context.restoreGState()
        case .pencil(let values):
            let values = points(values, in: bounds, canvas: canvas)
            guard let first = values.first, values.count > 1 else { return }
            context.saveGState()
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(max(2, bounds.width / 350))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: first)
            for value in values.dropFirst() { context.addLine(to: value) }
            context.strokePath()
            context.restoreGState()
        case .text(let text, let location):
            drawText(text, at: point(location, in: bounds, canvas: canvas), in: context, color: .systemRed, width: bounds.width)
        case .watermark(let text, let location):
            drawText(text, at: point(location, in: bounds, canvas: canvas), in: context, color: .white.withAlphaComponent(0.76), width: bounds.width, watermark: true)
        case .crop:
            break
        }
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(3, context.boundingBoxOfClipPath.width / 350))
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, in context: CGContext, width: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = max(14, width / 45)
        context.saveGState()
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(3, width / 350))
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawCounter(_ value: Int, at point: CGPoint, in context: CGContext, width: CGFloat) {
        let radius = max(14, width / 55)
        context.saveGState()
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        drawText(String(value), at: point, in: context, color: .white, width: width, counter: true)
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        in context: CGContext,
        color: NSColor,
        width: CGFloat,
        watermark: Bool = false,
        counter: Bool = false
    ) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let fontSize = counter ? max(12, width / 70) : (watermark ? max(16, width / 42) : max(18, width / 35))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: (counter ? NSFont.boldSystemFont(ofSize: fontSize) : (watermark ? NSFont.systemFont(ofSize: fontSize, weight: .medium) : NSFont.boldSystemFont(ofSize: fontSize))),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let originY = counter ? point.y - size.height / 2 : point.y - size.height
        (text as NSString).draw(at: CGPoint(x: point.x, y: originY), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func applyBlur(to context: CGContext, rect: CGRect, bounds: CGRect) {
        guard rect.width > 0, rect.height > 0, let current = context.makeImage() else { return }
        let input = CIImage(cgImage: current)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(5, bounds.width / 80), forKey: kCIInputRadiusKey)
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: current.width, height: current.height)
        guard let output = filter.outputImage?.cropped(to: extent),
              let blurred = ciContext.createCGImage(output, from: extent) else { return }
        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.draw(blurred, in: bounds)
        context.restoreGState()
    }
}
