import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation
import IOKit
import IOKit.hid
import SwiftUI

// MARK: - Input source data

/// A stable, Codable description of a macOS keyboard input source.
///
/// Carbon can expose the same source more than once when an input method has
/// multiple modes. The input mode is therefore part of the persisted identity.
struct MacPilotInputSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    let sourceID: String
    let inputModeID: String?
    let name: String
    let isCJKV: Bool

    var persistentIdentifier: String {
        guard let inputModeID, !inputModeID.isEmpty else { return sourceID }
        return "\(sourceID)::\(inputModeID)"
    }

    var id: String { persistentIdentifier }
}

enum InputSourceFunctionKeyMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case mediaKeys
    case functionKeys

    var id: Self { self }
}

enum InputSourceIndicatorPosition: String, CaseIterable, Codable, Identifiable, Sendable {
    case nearCursor
    case screenCenter

    var id: Self { self }
}

struct InputSourceShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ eventModifiers: NSEvent.ModifierFlags) {
        var modifiers: Self = []
        if eventModifiers.contains(.shift) { modifiers.insert(.shift) }
        if eventModifiers.contains(.control) { modifiers.insert(.control) }
        if eventModifiers.contains(.option) { modifiers.insert(.option) }
        if eventModifiers.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }

    init(_ eventFlags: CGEventFlags) {
        var modifiers: Self = []
        if eventFlags.contains(.maskShift) { modifiers.insert(.shift) }
        if eventFlags.contains(.maskControl) { modifiers.insert(.control) }
        if eventFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        if eventFlags.contains(.maskCommand) { modifiers.insert(.command) }
        self = modifiers
    }

    var symbolDescription: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        return symbols
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt8.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct InputSourceShortcutBinding: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var inputSourceIdentifier: String
    var keyCode: UInt16
    var modifiers: InputSourceShortcutModifiers

    var displayName: String {
        modifiers.symbolDescription + MacPilotKeyCode.displayName(for: keyCode)
    }
}

enum MacPilotKeyCode {
    private static let labels: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_D): "D",
        UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F", UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H",
        UInt16(kVK_ANSI_I): "I", UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O", UInt16(kVK_ANSI_P): "P",
        UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R", UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T",
        UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z", UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1",
        UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_Escape): "Esc", UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]

    static func displayName(for keyCode: UInt16) -> String {
        labels[keyCode] ?? "Key \(keyCode)"
    }
}

struct InputSourceAppRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String
    var bundlePath: String?
    var inputSourceIdentifier: String
    var isEnabled = true
    var forceEnglishPunctuation = false
    var functionKeyMode: InputSourceFunctionKeyMode?

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        bundlePath: String? = nil,
        inputSourceIdentifier: String,
        isEnabled: Bool = true,
        forceEnglishPunctuation: Bool = false,
        functionKeyMode: InputSourceFunctionKeyMode? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.inputSourceIdentifier = inputSourceIdentifier
        self.isEnabled = isEnabled
        self.forceEnglishPunctuation = forceEnglishPunctuation
        self.functionKeyMode = functionKeyMode
    }
}

enum InputSourceBrowserRuleType: String, CaseIterable, Codable, Identifiable, Sendable {
    case domainSuffix
    case domain
    case urlRegex

    var id: Self { self }
}

private final class MacPilotInputSourceRegexCache: @unchecked Sendable {
    static let shared = MacPilotInputSourceRegexCache()

    private let cache: NSCache<NSString, NSRegularExpression>

    private init() {
        cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 128
    }

    func expression(for pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        cache.setObject(expression, forKey: key)
        return expression
    }
}

struct InputSourceBrowserRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var browserBundleIdentifier: String?
    var type: InputSourceBrowserRuleType = .domainSuffix
    var value: String
    var inputSourceIdentifier: String
    var isEnabled = true

    init(
        id: UUID = UUID(),
        browserBundleIdentifier: String? = nil,
        type: InputSourceBrowserRuleType = .domainSuffix,
        value: String,
        inputSourceIdentifier: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.browserBundleIdentifier = browserBundleIdentifier
        self.type = type
        self.value = value
        self.inputSourceIdentifier = inputSourceIdentifier
        self.isEnabled = isEnabled
    }

    func matches(url: URL, browserBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard isEnabled else { return false }
        if let expected = browserBundleIdentifier,
           !expected.isEmpty,
           expected.caseInsensitiveCompare(bundleIdentifier ?? "") != .orderedSame {
            return false
        }

        switch type {
        case .domainSuffix:
            guard let expected = Self.normalizedDomain(value),
                  let host = Self.normalizedDomain(url.host)
            else { return false }
            return host == expected || host.hasSuffix(".\(expected)")
        case .domain:
            guard let expected = Self.normalizedDomain(value),
                  let host = Self.normalizedDomain(url.host)
            else { return false }
            return host == expected
        case .urlRegex:
            guard let expression = MacPilotInputSourceRegexCache.shared.expression(for: value) else {
                return false
            }
            let absoluteString = url.absoluteString
            let range = NSRange(location: 0, length: absoluteString.utf16.count)
            return expression.firstMatch(in: absoluteString, options: [], range: range) != nil
        }
    }

    private static func normalizedDomain(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }
}

struct InputSourceSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var defaultInputSourceIdentifier: String?
    var appRules: [InputSourceAppRule] = []
    var browserRules: [InputSourceBrowserRule] = []
    var showIndicator = true
    var indicatorDuration = 0.9
    var indicatorPosition: InputSourceIndicatorPosition = .nearCursor
    var globalShortcutEnabled = true
    var shortcuts: [InputSourceShortcutBinding] = []
    var defaultFunctionKeyMode: InputSourceFunctionKeyMode?

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case defaultInputSourceIdentifier
        case appRules
        case browserRules
        case showIndicator
        case indicatorDuration
        case indicatorPosition
        case globalShortcutEnabled
        case shortcuts
        case defaultFunctionKeyMode
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        defaultInputSourceIdentifier = try container.decodeIfPresent(String.self, forKey: .defaultInputSourceIdentifier)
        appRules = try container.decodeIfPresent([InputSourceAppRule].self, forKey: .appRules) ?? []
        browserRules = try container.decodeIfPresent([InputSourceBrowserRule].self, forKey: .browserRules) ?? []
        showIndicator = try container.decodeIfPresent(Bool.self, forKey: .showIndicator) ?? true
        indicatorDuration = min(max(try container.decodeIfPresent(Double.self, forKey: .indicatorDuration) ?? 0.9, 0.2), 5)
        indicatorPosition = try container.decodeIfPresent(InputSourceIndicatorPosition.self, forKey: .indicatorPosition) ?? .nearCursor
        globalShortcutEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? true
        shortcuts = try container.decodeIfPresent([InputSourceShortcutBinding].self, forKey: .shortcuts) ?? []
        defaultFunctionKeyMode = try container.decodeIfPresent(InputSourceFunctionKeyMode.self, forKey: .defaultFunctionKeyMode)
    }
}

enum InputSourceRuleEngine {
    static func appRule(
        bundleIdentifier: String?,
        rules: [InputSourceAppRule]
    ) -> InputSourceAppRule? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return rules.first {
            $0.isEnabled && $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    static func browserRule(
        url: URL?,
        bundleIdentifier: String?,
        rules: [InputSourceBrowserRule]
    ) -> InputSourceBrowserRule? {
        guard let url else { return nil }
        return rules.first { $0.matches(url: url, browserBundleIdentifier: bundleIdentifier) }
    }

    static func effectiveInputSourceIdentifier(
        bundleIdentifier: String?,
        browserURL: URL?,
        settings: InputSourceSettings
    ) -> String? {
        if let browserRule = browserRule(url: browserURL, bundleIdentifier: bundleIdentifier, rules: settings.browserRules) {
            return browserRule.inputSourceIdentifier
        }
        if let appRule = appRule(bundleIdentifier: bundleIdentifier, rules: settings.appRules) {
            return appRule.inputSourceIdentifier
        }
        return settings.defaultInputSourceIdentifier
    }
}

// MARK: - Carbon input source access

enum MacPilotInputSourceCatalog {
    private static let identifierSeparator = "::"

    static func all() -> [MacPilotInputSource] {
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        let sources = (list as? [TISInputSource]) ?? []
        var seen = Set<String>()

        return sources.compactMap { source in
            guard property(source, kTISPropertyInputSourceCategory) as? String == kTISCategoryKeyboardInputSource as String,
                  property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true,
                  let sourceID = property(source, kTISPropertyInputSourceID) as? String,
                  let name = property(source, kTISPropertyLocalizedName) as? String
            else { return nil }

            let modeID = property(source, kTISPropertyInputModeID) as? String
            let identifier = modeID.map { "\(sourceID)\(identifierSeparator)\($0)" } ?? sourceID
            guard seen.insert(identifier).inserted else { return nil }

            let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
            let isCJKV = languages.contains { language in
                language == "ru" || language == "ko" || language == "ja" || language == "vi" || language.hasPrefix("zh")
            }
            return MacPilotInputSource(sourceID: sourceID, inputModeID: modeID, name: name, isCJKV: isCJKV)
        }
    }

    static func current() -> MacPilotInputSource? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let sourceID = property(source, kTISPropertyInputSourceID) as? String,
              let name = property(source, kTISPropertyLocalizedName) as? String
        else { return nil }
        let modeID = property(source, kTISPropertyInputModeID) as? String
        let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
        let isCJKV = languages.contains { $0 == "ru" || $0 == "ko" || $0 == "ja" || $0 == "vi" || $0.hasPrefix("zh") }
        return MacPilotInputSource(sourceID: sourceID, inputModeID: modeID, name: name, isCJKV: isCJKV)
    }

    @discardableResult
    static func select(identifier: String) -> Bool {
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        let sources = (list as? [TISInputSource]) ?? []
        guard let source = sources.first(where: { source in
            guard property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true,
                  let sourceID = property(source, kTISPropertyInputSourceID) as? String
            else { return false }
            let modeID = property(source, kTISPropertyInputModeID) as? String
            let persistentIdentifier = modeID.map { "\(sourceID)\(identifierSeparator)\($0)" } ?? sourceID
            return persistentIdentifier == identifier || sourceID == identifier
        }) else { return false }

        return TISSelectInputSource(source) == noErr
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
    }
}

// MARK: - Browser context lookup

enum MacPilotBrowserURLResolver {
    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "com.dia.browser"
    ]

    static func currentURL(for application: NSRunningApplication) -> URL? {
        guard let bundleIdentifier = application.bundleIdentifier,
              browserBundleIdentifiers.contains(bundleIdentifier)
        else { return nil }

        return currentURL(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    static func currentURL(processIdentifier: pid_t, bundleIdentifier: String) -> URL? {
        guard browserBundleIdentifiers.contains(bundleIdentifier) else { return nil }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focusedElementValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
           let focusedElementValue {
            let focusedElement = unsafeDowncast(focusedElementValue, to: AXUIElement.self)
            if let url = url(from: focusedElement) { return url }
        }

        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindowValue else { return nil }
        let focusedWindow = unsafeDowncast(focusedWindowValue, to: AXUIElement.self)
        return url(from: focusedWindow)
    }

    private static func url(from element: AXUIElement) -> URL? {
        for attribute in [kAXURLAttribute, kAXDocumentAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let value else { continue }
            if let url = value as? URL { return url }
            if let string = value as? String,
               let url = URL(string: string),
               url.host != nil {
                return url
            }
        }
        return nil
    }
}

// MARK: - Function-key mode

enum MacPilotFunctionKeyManager {
    static func currentMode() -> InputSourceFunctionKeyMode? {
        let registry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard registry != .zero else { return nil }
        defer { IOObjectRelease(registry) }

        guard let value = IORegistryEntryCreateCFProperty(
            registry,
            "HIDParameters" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSDictionary,
        let mode = value["HIDFKeyMode"] as? Int
        else { return nil }
        return mode == 1 ? .functionKeys : (mode == 0 ? .mediaKeys : nil)
    }

    @discardableResult
    static func apply(_ mode: InputSourceFunctionKeyMode) -> Bool {
        let registry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard registry != .zero else { return false }
        defer { IOObjectRelease(registry) }

        var service: io_connect_t = .zero
        guard IOServiceOpen(registry, mach_task_self_, UInt32(kIOHIDParamConnectType), &service) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(service) }

        let value = mode == .functionKeys ? 1 : 0
        return IOHIDSetCFTypeParameter(service, kIOHIDFKeyModeKey as CFString, value as CFNumber) == KERN_SUCCESS
    }
}

// MARK: - Indicator and global shortcut

private let macPilotEnglishPunctuationMap: [String: String] = [
    "，": ",", "。": ".", "；": ";", "：": ":", "！": "!", "？": "?",
    "（": "(", "）": ")", "【": "[", "】": "]", "「": "[", "」": "]",
    "、": "\\", "‘": "'", "’": "'", "“": "\"", "”": "\"", "～": "~",
    "－": "-", "＿": "_", "＋": "+", "＝": "=", "／": "/", "＼": "\\",
    "｜": "|", "＜": "<", "＞": ">", "＂": "\"", "＇": "'", "＠": "@",
    "＃": "#", "％": "%", "＆": "&", "＊": "*", "＄": "$", "＾": "^", "｀": "`"
]

final class InputSourceEventTapContext: @unchecked Sendable {
    let owner: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var globalShortcutEnabled = true
    private var forceEnglishPunctuation = false
    private var shortcutBindings: [InputSourceShortcutBinding] = []
    private var eventTap: CFMachPort?

    init(owner: UnsafeMutableRawPointer) {
        self.owner = owner
    }

    func update(
        globalShortcutEnabled: Bool,
        forceEnglishPunctuation: Bool,
        shortcutBindings: [InputSourceShortcutBinding]
    ) {
        lock.lock()
        self.globalShortcutEnabled = globalShortcutEnabled
        self.forceEnglishPunctuation = forceEnglishPunctuation
        self.shortcutBindings = shortcutBindings
        lock.unlock()
    }

    func shouldForceEnglishPunctuation() -> Bool {
        lock.lock()
        let value = forceEnglishPunctuation
        lock.unlock()
        return value
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

    func matchesCycleShortcut(_ event: CGEvent) -> Bool {
        lock.lock()
        let globalShortcutEnabled = self.globalShortcutEnabled
        lock.unlock()
        guard globalShortcutEnabled else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_ANSI_I) else { return false }
        let flags = event.flags
        guard flags.contains(.maskAlternate), flags.contains(.maskCommand) else { return false }
        return !flags.contains(.maskControl) && !flags.contains(.maskShift)
    }

    func matchingShortcutIdentifier(for event: CGEvent) -> String? {
        lock.lock()
        let globalShortcutEnabled = self.globalShortcutEnabled
        let shortcutBindings = self.shortcutBindings
        lock.unlock()
        guard globalShortcutEnabled else { return nil }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = InputSourceShortcutModifiers(event.flags)
        return shortcutBindings.first {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        }?.inputSourceIdentifier
    }
}

private let macPilotInputSourceEventMarker: Int64 = 0x4D_5049_5352_4345 // "MPISRCE"

private func macPilotInputSourceEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent?,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let event, let refcon else { return event.map(Unmanaged.passUnretained) }
    let context = Unmanaged<InputSourceEventTapContext>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        context.reenableEventTap()
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          event.getIntegerValueField(.eventSourceUserData) != macPilotInputSourceEventMarker
    else { return Unmanaged.passUnretained(event) }

    let owner = Unmanaged<InputSourceModel>.fromOpaque(context.owner).takeUnretainedValue()
    if let identifier = context.matchingShortcutIdentifier(for: event) {
        Task { @MainActor in _ = owner.selectInputSource(identifier: identifier) }
        return nil
    }
    if context.matchesCycleShortcut(event) {
        Task { @MainActor in owner.cycleInputSource() }
        return nil
    }

    guard context.shouldForceEnglishPunctuation(),
          let nsEvent = NSEvent(cgEvent: event),
          let original = nsEvent.characters,
          let replacement = macPilotEnglishPunctuationMap[original],
          !event.flags.contains(.maskCommand),
          !event.flags.contains(.maskControl),
          !event.flags.contains(.maskAlternate)
    else { return Unmanaged.passUnretained(event) }

    let source = CGEventSource(stateID: .hidSystemState)
    guard let replacementEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
        return Unmanaged.passUnretained(event)
    }
    replacementEvent.flags = event.flags
    replacementEvent.setIntegerValueField(.eventSourceUserData, value: macPilotInputSourceEventMarker)
    let utf16 = Array(replacement.utf16)
    utf16.withUnsafeBufferPointer { buffer in
        replacementEvent.keyboardSetUnicodeString(
            stringLength: utf16.count,
            unicodeString: buffer.baseAddress
        )
    }
    replacementEvent.post(tap: .cghidEventTap)
    return nil
}

@MainActor
private final class MacPilotInputSourceIndicatorController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(source: MacPilotInputSource, position: InputSourceIndicatorPosition, duration: TimeInterval) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: MacPilotInputSourceIndicatorView(source: source))
        panel.setFrame(frame(for: panel, position: position), display: true)
        panel.orderFrontRegardless()
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            self?.panel?.orderOut(nil)
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }

    private func frame(for panel: NSPanel, position: InputSourceIndicatorPosition) -> NSRect {
        let size = panel.frame.size
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin: NSPoint
        switch position {
        case .nearCursor:
            origin = NSPoint(
                x: min(max(mouseLocation.x + 18, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12),
                y: min(max(mouseLocation.y - size.height - 18, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
            )
        case .screenCenter:
            origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        }
        return NSRect(origin: origin, size: size)
    }
}

private struct MacPilotInputSourceIndicatorView: View {
    let source: MacPilotInputSource

    var body: some View {
        HStack(spacing: 12) {
            Text(source.isCJKV ? "文" : "A")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 250, height: 88)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2)))
    }
}

// MARK: - Runtime model

@MainActor
final class InputSourceModel: ObservableObject {
    @Published private(set) var settings = InputSourceSettings()
    @Published private(set) var availableSources: [MacPilotInputSource] = []
    @Published private(set) var currentSource: MacPilotInputSource?
    @Published private(set) var activeApplicationName: String?
    @Published private(set) var activeRuleIdentifier: UUID?
    @Published private(set) var activeBrowserRuleIdentifier: UUID?
    @Published private(set) var lastOperationError: String?

    var persist: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var browserPollingTask: Task<Void, Never>?
    private var lastBrowserPollingSignature: String?
    private var isActive = false
    private var originalFunctionKeyMode: InputSourceFunctionKeyMode?
    private var indicatorController: MacPilotInputSourceIndicatorController?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapContext: InputSourceEventTapContext?

    private var hasEnabledBrowserRules: Bool {
        settings.browserRules.contains { $0.isEnabled }
    }

    init() {
        refreshSources()
        currentSource = MacPilotInputSourceCatalog.current()
    }

    func applyLoadedSettings(_ settings: InputSourceSettings) {
        self.settings = settings
        if isActive {
            refreshSources()
            refreshEventTap()
            refreshBrowserPolling()
            evaluateCurrentApplication()
        }
    }

    func activateFromConfiguration() {
        guard !isActive else { return }
        isActive = true
        indicatorController = MacPilotInputSourceIndicatorController()
        originalFunctionKeyMode = MacPilotFunctionKeyManager.currentMode()
        refreshSources()
        installObservers()
        refreshEventTap()
        refreshBrowserPolling()
        evaluateCurrentApplication()
    }

    func refreshSources() {
        availableSources = MacPilotInputSourceCatalog.all()
        currentSource = MacPilotInputSourceCatalog.current()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            refreshSources()
            refreshEventTap()
            refreshBrowserPolling()
            evaluateCurrentApplication()
        } else {
            stopBrowserPolling()
            removeEventTap()
            indicatorController?.hide()
            activeApplicationName = nil
            activeRuleIdentifier = nil
            activeBrowserRuleIdentifier = nil
            restoreOriginalFunctionKeyMode()
        }
        persist?()
    }

    func setDefaultInputSource(_ source: MacPilotInputSource?) {
        settings.defaultInputSourceIdentifier = source?.persistentIdentifier
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func setShowIndicator(_ enabled: Bool) {
        settings.showIndicator = enabled
        if !enabled { indicatorController?.hide() }
        persist?()
    }

    func setIndicatorPosition(_ position: InputSourceIndicatorPosition) {
        settings.indicatorPosition = position
        persist?()
    }

    func setIndicatorDuration(_ duration: Double) {
        settings.indicatorDuration = min(max(duration, 0.2), 5)
        persist?()
    }

    func setGlobalShortcutEnabled(_ enabled: Bool) {
        settings.globalShortcutEnabled = enabled
        refreshEventTap()
        if settings.isEnabled { evaluateCurrentApplication() }
        persist?()
    }

    func addShortcut(_ binding: InputSourceShortcutBinding) {
        settings.shortcuts.removeAll {
            $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers
        }
        settings.shortcuts.append(binding)
        refreshEventTap()
        if settings.isEnabled { evaluateCurrentApplication() }
        persist?()
    }

    func updateShortcut(_ binding: InputSourceShortcutBinding) {
        guard settings.shortcuts.contains(where: { $0.id == binding.id }) else { return }
        settings.shortcuts.removeAll {
            $0.id != binding.id && $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers
        }
        guard let updatedIndex = settings.shortcuts.firstIndex(where: { $0.id == binding.id }) else { return }
        settings.shortcuts[updatedIndex] = binding
        refreshEventTap()
        if settings.isEnabled { evaluateCurrentApplication() }
        persist?()
    }

    func removeShortcut(_ binding: InputSourceShortcutBinding) {
        settings.shortcuts.removeAll { $0.id == binding.id }
        refreshEventTap()
        if settings.isEnabled { evaluateCurrentApplication() }
        persist?()
    }

    func setDefaultFunctionKeyMode(_ mode: InputSourceFunctionKeyMode?) {
        settings.defaultFunctionKeyMode = mode
        if settings.isEnabled { evaluateCurrentApplication() }
        persist?()
    }

    @discardableResult
    func selectInputSource(_ source: MacPilotInputSource) -> Bool {
        selectInputSource(identifier: source.persistentIdentifier)
    }

    @discardableResult
    func selectInputSource(identifier: String) -> Bool {
        guard MacPilotInputSourceCatalog.select(identifier: identifier) else {
            lastOperationError = "The selected input source is no longer available."
            refreshSources()
            return false
        }
        currentSource = availableSources.first(where: { $0.persistentIdentifier == identifier })
            ?? MacPilotInputSourceCatalog.current()
        showIndicatorIfNeeded()
        return true
    }

    func cycleInputSource() {
        guard settings.isEnabled, !availableSources.isEmpty else { return }
        let currentIndex = availableSources.firstIndex { $0.persistentIdentifier == currentSource?.persistentIdentifier } ?? -1
        let nextIndex = (currentIndex + 1) % availableSources.count
        _ = selectInputSource(availableSources[nextIndex])
    }

    func addAppRule(
        appName: String,
        bundleIdentifier: String,
        bundlePath: String?,
        inputSource: MacPilotInputSource,
        forceEnglishPunctuation: Bool,
        functionKeyMode: InputSourceFunctionKeyMode?
    ) {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier) != .orderedSame
        else { return }

        let rule = InputSourceAppRule(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            inputSourceIdentifier: inputSource.persistentIdentifier,
            forceEnglishPunctuation: forceEnglishPunctuation,
            functionKeyMode: functionKeyMode
        )
        if let index = settings.appRules.firstIndex(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) {
            var replacement = rule
            replacement.id = settings.appRules[index].id
            settings.appRules[index] = replacement
        } else {
            settings.appRules.append(rule)
        }
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func updateAppRule(_ rule: InputSourceAppRule) {
        guard let index = settings.appRules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.appRules[index] = rule
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func removeAppRule(_ rule: InputSourceAppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func toggleAppRule(_ rule: InputSourceAppRule) {
        guard let index = settings.appRules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.appRules[index].isEnabled.toggle()
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func setAppRuleEnabled(_ enabled: Bool, for rule: InputSourceAppRule) {
        guard let index = settings.appRules.firstIndex(where: { $0.id == rule.id }),
              settings.appRules[index].isEnabled != enabled
        else { return }
        settings.appRules[index].isEnabled = enabled
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func addBrowserRule(_ rule: InputSourceBrowserRule) {
        guard !rule.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings.browserRules.append(rule)
        refreshBrowserPolling()
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func updateBrowserRule(_ rule: InputSourceBrowserRule) {
        guard let index = settings.browserRules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.browserRules[index] = rule
        refreshBrowserPolling()
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func removeBrowserRule(_ rule: InputSourceBrowserRule) {
        settings.browserRules.removeAll { $0.id == rule.id }
        refreshBrowserPolling()
        persist?()
        if settings.isEnabled { evaluateCurrentApplication() }
    }

    func source(for identifier: String?) -> MacPilotInputSource? {
        guard let identifier else { return nil }
        return availableSources.first { $0.persistentIdentifier == identifier }
    }

    func sourceName(for identifier: String?) -> String {
        source(for: identifier)?.name ?? "—"
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refreshEventTap()
    }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    private func installObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let applicationNames: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification
        ]
        for name in applicationNames {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSWorkspace.didWakeNotification {
                        self.refreshSources()
                    }
                    self.handleApplicationNotification(application)
                }
            })
        }

        let inputSourceNotification = Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
        observers.append(DistributedNotificationCenter.default().addObserver(forName: inputSourceNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSelectedInputSourceChanged() }
        })
    }

    private func refreshBrowserPolling() {
        guard isActive, settings.isEnabled, hasEnabledBrowserRules else {
            stopBrowserPolling()
            return
        }
        startBrowserPolling()
    }

    private func startBrowserPolling() {
        guard browserPollingTask == nil else { return }
        lastBrowserPollingSignature = nil
        browserPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.isActive, self.settings.isEnabled, self.hasEnabledBrowserRules,
                      let application = NSWorkspace.shared.frontmostApplication,
                      let bundleIdentifier = application.bundleIdentifier,
                      MacPilotBrowserURLResolver.browserBundleIdentifiers.contains(bundleIdentifier)
                else { continue }

                let processIdentifier = application.processIdentifier
                let url = await Task.detached(priority: .utility) {
                    MacPilotBrowserURLResolver.currentURL(
                        processIdentifier: processIdentifier,
                        bundleIdentifier: bundleIdentifier
                    )
                }.value
                guard !Task.isCancelled else { return }
                let signature = "\(bundleIdentifier)|\(url?.absoluteString ?? "")"
                let needsEventTap = self.settings.globalShortcutEnabled
                    || !self.settings.shortcuts.isEmpty
                    || self.settings.appRules.contains(where: { $0.forceEnglishPunctuation })
                guard signature != self.lastBrowserPollingSignature || (needsEventTap && self.eventTap == nil) else { continue }
                self.lastBrowserPollingSignature = signature
                self.evaluateApplication(application, knownBrowserURL: url, browserURLWasResolved: true)
            }
        }
    }

    private func stopBrowserPolling() {
        browserPollingTask?.cancel()
        browserPollingTask = nil
        lastBrowserPollingSignature = nil
    }

    private func handleApplicationNotification(_ application: NSRunningApplication?) {
        guard let application else {
            evaluateCurrentApplication()
            return
        }
        evaluateApplication(application)
    }

    private func evaluateCurrentApplication() {
        evaluateApplication(NSWorkspace.shared.frontmostApplication)
    }

    private func evaluateApplication(
        _ application: NSRunningApplication?,
        knownBrowserURL: URL? = nil,
        browserURLWasResolved: Bool = false
    ) {
        currentSource = MacPilotInputSourceCatalog.current() ?? currentSource
        activeApplicationName = application?.localizedName
        let bundleIdentifier = application?.bundleIdentifier
        let isBrowser = bundleIdentifier.map {
            MacPilotBrowserURLResolver.browserBundleIdentifiers.contains($0)
        } == true
        let shouldResolveBrowserURL = settings.isEnabled && hasEnabledBrowserRules && isBrowser
        let browserURL: URL?
        if shouldResolveBrowserURL {
            browserURL = browserURLWasResolved
                ? knownBrowserURL
                : application.flatMap { MacPilotBrowserURLResolver.currentURL(for: $0) }
            lastBrowserPollingSignature = "\(bundleIdentifier ?? "")|\(browserURL?.absoluteString ?? "")"
        } else {
            browserURL = nil
            lastBrowserPollingSignature = nil
        }
        if settings.isEnabled, eventTap == nil {
            refreshEventTap()
        }
        guard settings.isEnabled, application != nil else {
            activeRuleIdentifier = nil
            activeBrowserRuleIdentifier = nil
            eventTapContext?.update(
                globalShortcutEnabled: false,
                forceEnglishPunctuation: false,
                shortcutBindings: []
            )
            return
        }

        let appRule = InputSourceRuleEngine.appRule(bundleIdentifier: bundleIdentifier, rules: settings.appRules)
        let browserRule = InputSourceRuleEngine.browserRule(url: browserURL, bundleIdentifier: bundleIdentifier, rules: settings.browserRules)
        activeRuleIdentifier = appRule?.id
        activeBrowserRuleIdentifier = browserRule?.id

        let desiredIdentifier = browserRule?.inputSourceIdentifier
            ?? appRule?.inputSourceIdentifier
            ?? settings.defaultInputSourceIdentifier
        if let desiredIdentifier,
           desiredIdentifier != currentSource?.persistentIdentifier {
            _ = selectInputSource(identifier: desiredIdentifier)
        }

        let functionKeyMode = appRule?.functionKeyMode ?? settings.defaultFunctionKeyMode ?? originalFunctionKeyMode
        applyFunctionKeyMode(functionKeyMode)
        eventTapContext?.update(
            globalShortcutEnabled: settings.globalShortcutEnabled,
            forceEnglishPunctuation: appRule?.forceEnglishPunctuation == true,
            shortcutBindings: settings.shortcuts
        )
    }

    private func handleSelectedInputSourceChanged() {
        let previousIdentifier = currentSource?.persistentIdentifier
        currentSource = MacPilotInputSourceCatalog.current()
        if previousIdentifier != currentSource?.persistentIdentifier {
            showIndicatorIfNeeded()
        }
    }

    private func showIndicatorIfNeeded() {
        guard settings.isEnabled, settings.showIndicator, let currentSource else { return }
        indicatorController?.show(
            source: currentSource,
            position: settings.indicatorPosition,
            duration: settings.indicatorDuration
        )
    }

    private func applyFunctionKeyMode(_ mode: InputSourceFunctionKeyMode?) {
        guard let mode else { return }
        if MacPilotFunctionKeyManager.currentMode() != mode {
            _ = MacPilotFunctionKeyManager.apply(mode)
        }
    }

    private func restoreOriginalFunctionKeyMode() {
        guard let originalFunctionKeyMode else { return }
        _ = MacPilotFunctionKeyManager.apply(originalFunctionKeyMode)
    }

    private func refreshEventTap() {
        removeEventTap()
        guard settings.isEnabled,
              settings.globalShortcutEnabled || !settings.shortcuts.isEmpty || settings.appRules.contains(where: { $0.forceEnglishPunctuation }),
              AXIsProcessTrusted()
        else { return }

        let context = InputSourceEventTapContext(owner: Unmanaged.passUnretained(self).toOpaque())
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: macPilotInputSourceEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
            return
        }

        eventTapContext = context
        self.eventTap = eventTap
        eventTapSource = source
        context.setEventTap(eventTap)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func removeEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTapSource = nil
        eventTap = nil
        eventTapContext = nil
    }
}

// MARK: - Settings UI

struct InputSourcesView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var inputSources: InputSourceModel
    @State private var showingAppRuleEditor = false
    @State private var editingAppRule: InputSourceAppRule?
    @State private var showingBrowserRuleEditor = false
    @State private var editingBrowserRule: InputSourceBrowserRule?
    @State private var showingShortcutEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                enableCard
                currentSourceCard
                defaultSourceCard
                indicatorCard
                shortcutCard
                appRulesCard
                browserRulesCard
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingAppRuleEditor) {
            InputSourceAppRuleEditor(inputSources: inputSources, rule: nil)
                .environmentObject(model)
        }
        .sheet(item: $editingAppRule) { rule in
            InputSourceAppRuleEditor(inputSources: inputSources, rule: rule)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingBrowserRuleEditor) {
            InputSourceBrowserRuleEditor(inputSources: inputSources, rule: nil)
                .environmentObject(model)
        }
        .sheet(item: $editingBrowserRule) { rule in
            InputSourceBrowserRuleEditor(inputSources: inputSources, rule: rule)
                .environmentObject(model)
        }
        .sheet(isPresented: $showingShortcutEditor) {
            InputSourceShortcutEditor(inputSources: inputSources)
                .environmentObject(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.t("inputSources")).font(.system(size: 30, weight: .bold))
            Text(model.t("inputSourcesSubtitle")).foregroundStyle(.secondary)
        }
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("inputSourcesEnable")).font(.headline)
                    Text(inputSources.settings.isEnabled ? model.t("inputSourcesEnabled") : model.t("inputSourcesDisabled"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { inputSources.settings.isEnabled },
                    set: { inputSources.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
            }
            if inputSources.settings.isEnabled, inputSources.availableSources.isEmpty {
                Label(model.t("inputSourcesUnavailable"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var currentSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(model.t("inputSourcesCurrent"))
            HStack(spacing: 12) {
                Image(systemName: inputSources.currentSource?.isCJKV == true ? "character.textbox" : "keyboard")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(inputSources.currentSource?.name ?? model.t("inputSourcesNotDetected"))
                        .font(.body.weight(.medium))
                    if let activeApplicationName = inputSources.activeApplicationName {
                        Text(model.t("inputSourcesActiveApp", activeApplicationName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(model.t("refresh")) { inputSources.refreshSources() }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var defaultSourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(model.t("inputSourcesDefault"))
            Text(model.t("inputSourcesDefaultHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker(model.t("inputSourcesDefault"), selection: Binding(
                get: { inputSources.settings.defaultInputSourceIdentifier ?? "" },
                set: { value in inputSources.setDefaultInputSource(inputSources.source(for: value)) }
            )) {
                Text(model.t("inputSourcesNoDefault")).tag("")
                ForEach(inputSources.availableSources) { source in
                    Text(source.name).tag(source.persistentIdentifier)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 420)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var indicatorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(model.t("inputSourcesIndicator"))
            Toggle(model.t("inputSourcesShowIndicator"), isOn: Binding(
                get: { inputSources.settings.showIndicator },
                set: { inputSources.setShowIndicator($0) }
            ))
            HStack {
                Text(model.t("inputSourcesIndicatorPosition"))
                Picker("", selection: Binding(
                    get: { inputSources.settings.indicatorPosition },
                    set: { inputSources.setIndicatorPosition($0) }
                )) {
                    Text(model.t("inputSourcesNearCursor")).tag(InputSourceIndicatorPosition.nearCursor)
                    Text(model.t("inputSourcesScreenCenter")).tag(InputSourceIndicatorPosition.screenCenter)
                }
                .labelsHidden()
                .frame(width: 160)
            }
            HStack {
                Text(model.t("inputSourcesIndicatorDuration"))
                Slider(value: Binding(
                    get: { inputSources.settings.indicatorDuration },
                    set: { inputSources.setIndicatorDuration($0) }
                ), in: 0.2...5, step: 0.1)
                .frame(width: 180)
                Text(String(format: "%.1fs", inputSources.settings.indicatorDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(model.t("inputSourcesShortcuts"))
            Toggle(model.t("inputSourcesCycleShortcut"), isOn: Binding(
                get: { inputSources.settings.globalShortcutEnabled },
                set: { inputSources.setGlobalShortcutEnabled($0) }
            ))
            Text(model.t("inputSourcesCycleShortcutHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.t("inputSourcesCustomShortcuts"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button { showingShortcutEditor = true } label: {
                    Label(model.t("inputSourcesAddShortcut"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            if inputSources.settings.shortcuts.isEmpty {
                Text(model.t("inputSourcesNoShortcuts"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inputSources.settings.shortcuts) { binding in
                    InputSourceShortcutRow(binding: binding, inputSources: inputSources) {
                        inputSources.removeShortcut(binding)
                    }
                }
            }
            if inputSources.settings.globalShortcutEnabled, !inputSources.hasAccessibilityPermission {
                HStack(alignment: .top, spacing: 10) {
                    Label(model.t("inputSourcesAccessibilityRequired"), systemImage: "lock.shield")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(model.t("inputSourcesGrantAccessibility")) { inputSources.requestAccessibility() }
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var appRulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle(model.t("inputSourcesAppRules"))
                Spacer()
                Button { showingAppRuleEditor = true } label: {
                    Label(model.t("addRule"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            Text(model.t("inputSourcesAppRulesHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if inputSources.settings.appRules.isEmpty {
                Text(model.t("inputSourcesNoAppRules"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            } else {
                ForEach(inputSources.settings.appRules) { rule in
                    InputSourceAppRuleRow(
                        rule: rule,
                        inputSources: inputSources,
                        edit: { editingAppRule = rule },
                        remove: { inputSources.removeAppRule(rule) }
                    )
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var browserRulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle(model.t("inputSourcesBrowserRules"))
                Spacer()
                Button { showingBrowserRuleEditor = true } label: {
                    Label(model.t("addRule"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            Text(model.t("inputSourcesBrowserRulesHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if inputSources.settings.browserRules.isEmpty {
                Text(model.t("inputSourcesNoBrowserRules"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            } else {
                ForEach(inputSources.settings.browserRules) { rule in
                    InputSourceBrowserRuleRow(
                        rule: rule,
                        inputSources: inputSources,
                        edit: { editingBrowserRule = rule },
                        remove: { inputSources.removeBrowserRule(rule) }
                    )
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }
}

private struct InputSourceRunningAppChoice: Identifiable {
    let id: String
    let name: String
    let path: String?
}

private struct InputSourceAppRuleRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let rule: InputSourceAppRule
    @ObservedObject var inputSources: InputSourceModel
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { inputSources.setAppRuleEnabled($0, for: rule) }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.appName).font(.body.weight(.medium))
                Text(inputSources.sourceName(for: rule.inputSourceIdentifier))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if rule.forceEnglishPunctuation {
                        Label(model.t("inputSourcesEnglishPunctuation"), systemImage: "textformat")
                    }
                    if let functionKeyMode = rule.functionKeyMode {
                        Label(
                            functionKeyMode == .functionKeys ? model.t("inputSourcesFunctionKeys") : model.t("inputSourcesMediaKeys"),
                            systemImage: "fn"
                        )
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(model.t("edit"), action: edit)
                .buttonStyle(.borderless)
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}

private struct InputSourceBrowserRuleRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let rule: InputSourceBrowserRule
    @ObservedObject var inputSources: InputSourceModel
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in
                    var updated = rule
                    updated.isEnabled.toggle()
                    inputSources.updateBrowserRule(updated)
                }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.value).font(.body.weight(.medium))
                Text("\(typeName) · \(inputSources.sourceName(for: rule.inputSourceIdentifier))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.t("edit"), action: edit)
                .buttonStyle(.borderless)
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private var typeName: String {
        switch rule.type {
        case .domainSuffix: return model.t("inputSourcesDomainSuffix")
        case .domain: return model.t("inputSourcesDomain")
        case .urlRegex: return model.t("inputSourcesURLRegex")
        }
    }
}

private struct InputSourceShortcutRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let binding: InputSourceShortcutBinding
    @ObservedObject var inputSources: InputSourceModel
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(inputSources.sourceName(for: binding.inputSourceIdentifier))
                    .font(.body.weight(.medium))
                Text(binding.displayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(model.t("remove"))
        }
        .padding(.vertical, 4)
    }
}

private struct InputSourceShortcutEditor: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inputSources: InputSourceModel
    @State private var selectedSourceIdentifier: String
    @State private var recordedKeyCode: UInt16?
    @State private var recordedModifiers: InputSourceShortcutModifiers = []

    init(inputSources: InputSourceModel) {
        self.inputSources = inputSources
        _selectedSourceIdentifier = State(initialValue: inputSources.availableSources.first?.persistentIdentifier ?? "")
        _recordedKeyCode = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.t("inputSourcesAddShortcut"))
                .font(.title2.bold())
            Text(model.t("inputSourcesShortcutHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker(model.t("inputSourcesTarget"), selection: $selectedSourceIdentifier) {
                ForEach(inputSources.availableSources) { source in
                    Text(source.name).tag(source.persistentIdentifier)
                }
            }
            InputSourceShortcutRecorder(
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                placeholder: model.t("inputSourcesRecordShortcut")
            )
            HStack {
                Spacer()
                Button(model.t("cancel"), role: .cancel) { dismiss() }
                Button(model.t("save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedSourceIdentifier.isEmpty || recordedKeyCode == nil || recordedModifiers.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func save() {
        guard let recordedKeyCode, !selectedSourceIdentifier.isEmpty else { return }
        inputSources.addShortcut(InputSourceShortcutBinding(
            inputSourceIdentifier: selectedSourceIdentifier,
            keyCode: recordedKeyCode,
            modifiers: recordedModifiers
        ))
        dismiss()
    }
}

private struct InputSourceShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16?
    @Binding var modifiers: InputSourceShortcutModifiers
    let placeholder: String

    func makeNSView(context: Context) -> InputSourceShortcutRecorderNSView {
        let view = InputSourceShortcutRecorderNSView()
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.placeholder = placeholder
        view.onCapture = { keyCode, modifiers in
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
        return view
    }

    func updateNSView(_ nsView: InputSourceShortcutRecorderNSView, context: Context) {
        nsView.keyCode = keyCode
        nsView.modifiers = modifiers
        nsView.placeholder = placeholder
        nsView.needsDisplay = true
    }
}

@MainActor
private final class InputSourceShortcutRecorderNSView: NSView {
    var keyCode: UInt16?
    var modifiers: InputSourceShortcutModifiers = []
    var placeholder = ""
    var onCapture: ((UInt16, InputSourceShortcutModifiers) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifierKeys: Set<UInt16> = [
            UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), UInt16(kVK_RightCommand)
        ]
        guard !modifierKeys.contains(event.keyCode) else { return }
        let modifiers = InputSourceShortcutModifiers(event.modifierFlags)
        guard !modifiers.isEmpty else { return }
        onCapture?(event.keyCode, modifiers)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let title: String
        if let keyCode {
            title = modifiers.symbolDescription + MacPilotKeyCode.displayName(for: keyCode)
        } else {
            title = placeholder
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: keyCode == nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
    }
}

private struct InputSourceAppRuleEditor: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inputSources: InputSourceModel
    let rule: InputSourceAppRule?
    @State private var selectedBundleIdentifier: String
    @State private var selectedSourceIdentifier: String
    @State private var forceEnglishPunctuation: Bool
    @State private var functionKeyMode: String

    init(inputSources: InputSourceModel, rule: InputSourceAppRule?) {
        self.inputSources = inputSources
        self.rule = rule
        _selectedBundleIdentifier = State(initialValue: rule?.bundleIdentifier ?? "")
        _selectedSourceIdentifier = State(initialValue: rule?.inputSourceIdentifier ?? inputSources.availableSources.first?.persistentIdentifier ?? "")
        _forceEnglishPunctuation = State(initialValue: rule?.forceEnglishPunctuation ?? false)
        _functionKeyMode = State(initialValue: rule?.functionKeyMode?.rawValue ?? "system")
    }

    private var applications: [InputSourceRunningAppChoice] {
        let running = NSWorkspace.shared.runningApplications.compactMap { application -> InputSourceRunningAppChoice? in
            guard let bundleIdentifier = application.bundleIdentifier,
                  application.activationPolicy == .regular,
                  bundleIdentifier.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier) != .orderedSame
            else { return nil }
            return InputSourceRunningAppChoice(
                id: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                path: application.bundleURL?.path
            )
        }
        var result = running.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let rule, !result.contains(where: { $0.id.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame }) {
            result.insert(InputSourceRunningAppChoice(id: rule.bundleIdentifier, name: rule.appName, path: rule.bundlePath), at: 0)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(rule == nil ? model.t("inputSourcesAddAppRule") : model.t("inputSourcesEditAppRule"))
                .font(.title2.bold())
            Picker(model.t("application"), selection: $selectedBundleIdentifier) {
                Text(model.t("inputSourcesChooseApp")).tag("")
                ForEach(applications) { app in
                    Text(app.name).tag(app.id)
                }
            }
            Picker(model.t("inputSourcesTarget"), selection: $selectedSourceIdentifier) {
                ForEach(inputSources.availableSources) { source in
                    Text(source.name).tag(source.persistentIdentifier)
                }
            }
            Toggle(model.t("inputSourcesEnglishPunctuation"), isOn: $forceEnglishPunctuation)
            Picker(model.t("inputSourcesFunctionKeyMode"), selection: $functionKeyMode) {
                Text(model.t("inputSourcesUseSystemDefault")).tag("system")
                Text(model.t("inputSourcesMediaKeys")).tag(InputSourceFunctionKeyMode.mediaKeys.rawValue)
                Text(model.t("inputSourcesFunctionKeys")).tag(InputSourceFunctionKeyMode.functionKeys.rawValue)
            }
            HStack {
                Spacer()
                Button(model.t("cancel"), role: .cancel) { dismiss() }
                Button(model.t("save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedBundleIdentifier.isEmpty || selectedSourceIdentifier.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        guard let application = applications.first(where: { $0.id == selectedBundleIdentifier }),
              let source = inputSources.source(for: selectedSourceIdentifier)
        else { return }
        let mode = InputSourceFunctionKeyMode(rawValue: functionKeyMode)
        if var rule {
            rule.appName = application.name
            rule.bundleIdentifier = application.id
            rule.bundlePath = application.path
            rule.inputSourceIdentifier = source.persistentIdentifier
            rule.forceEnglishPunctuation = forceEnglishPunctuation
            rule.functionKeyMode = mode
            inputSources.updateAppRule(rule)
        } else {
            inputSources.addAppRule(
                appName: application.name,
                bundleIdentifier: application.id,
                bundlePath: application.path,
                inputSource: source,
                forceEnglishPunctuation: forceEnglishPunctuation,
                functionKeyMode: mode
            )
        }
        dismiss()
    }
}

private struct InputSourceBrowserRuleEditor: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inputSources: InputSourceModel
    let rule: InputSourceBrowserRule?
    @State private var browserBundleIdentifier: String
    @State private var type: InputSourceBrowserRuleType
    @State private var value: String
    @State private var selectedSourceIdentifier: String

    init(inputSources: InputSourceModel, rule: InputSourceBrowserRule?) {
        self.inputSources = inputSources
        self.rule = rule
        _browserBundleIdentifier = State(initialValue: rule?.browserBundleIdentifier ?? "")
        _type = State(initialValue: rule?.type ?? .domainSuffix)
        _value = State(initialValue: rule?.value ?? "")
        _selectedSourceIdentifier = State(initialValue: rule?.inputSourceIdentifier ?? inputSources.availableSources.first?.persistentIdentifier ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(rule == nil ? model.t("inputSourcesAddBrowserRule") : model.t("inputSourcesEditBrowserRule"))
                .font(.title2.bold())
            Picker(model.t("inputSourcesBrowser"), selection: $browserBundleIdentifier) {
                Text(model.t("inputSourcesAnyBrowser")).tag("")
                ForEach(MacPilotBrowserURLResolver.browserBundleIdentifiers.sorted(), id: \.self) { identifier in
                    Text(identifier).tag(identifier)
                }
            }
            Picker(model.t("inputSourcesRuleType"), selection: $type) {
                Text(model.t("inputSourcesDomainSuffix")).tag(InputSourceBrowserRuleType.domainSuffix)
                Text(model.t("inputSourcesDomain")).tag(InputSourceBrowserRuleType.domain)
                Text(model.t("inputSourcesURLRegex")).tag(InputSourceBrowserRuleType.urlRegex)
            }
            TextField(model.t("inputSourcesRuleValue"), text: $value)
                .textFieldStyle(.roundedBorder)
            Picker(model.t("inputSourcesTarget"), selection: $selectedSourceIdentifier) {
                ForEach(inputSources.availableSources) { source in
                    Text(source.name).tag(source.persistentIdentifier)
                }
            }
            HStack {
                Spacer()
                Button(model.t("cancel"), role: .cancel) { dismiss() }
                Button(model.t("save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSourceIdentifier.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func save() {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let newRule = InputSourceBrowserRule(
            id: rule?.id ?? UUID(),
            browserBundleIdentifier: browserBundleIdentifier.isEmpty ? nil : browserBundleIdentifier,
            type: type,
            value: value,
            inputSourceIdentifier: selectedSourceIdentifier
        )
        if rule == nil { inputSources.addBrowserRule(newRule) }
        else { inputSources.updateBrowserRule(newRule) }
        dismiss()
    }
}
