// PictureInPicture.swift
// ScreenCaptureKit-backed floating panels inspired by the public Pipiri feature set.

import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreMedia
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Configuration

enum PiPPanelPosition: String, CaseIterable, Codable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
}

enum PiPSourceFocusBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    case doNothing
    case hidePanel
    case closePanel

    var id: String { rawValue }
}

enum PiPShortcutModifier: String, CaseIterable, Codable, Identifiable, Sendable {
    case commandOption
    case commandControl
    case controlOption
    case commandControlOption

    var id: String { rawValue }

    var symbolDescription: String {
        switch self {
        case .commandOption: "⌥⌘"
        case .commandControl: "⌃⌘"
        case .controlOption: "⌃⌥"
        case .commandControlOption: "⌃⌥⌘"
        }
    }

    var titleKey: String {
        switch self {
        case .commandOption: "pipShortcutCommandOption"
        case .commandControl: "pipShortcutCommandControl"
        case .controlOption: "pipShortcutControlOption"
        case .commandControlOption: "pipShortcutCommandControlOption"
        }
    }

    var cocoaFlags: NSEvent.ModifierFlags {
        switch self {
        case .commandOption: [.command, .option]
        case .commandControl: [.command, .control]
        case .controlOption: [.control, .option]
        case .commandControlOption: [.command, .control, .option]
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .commandOption: [.maskCommand, .maskAlternate]
        case .commandControl: [.maskCommand, .maskControl]
        case .controlOption: [.maskControl, .maskAlternate]
        case .commandControlOption: [.maskCommand, .maskControl, .maskAlternate]
        }
    }

    func matches(_ flags: NSEvent.ModifierFlags, allowingShift: Bool = true) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let actual = flags.intersection(relevant)
        let expected = cocoaFlags
        if actual == expected { return true }
        return allowingShift && actual == expected.union(.shift)
    }

    func matches(_ flags: CGEventFlags, allowingShift: Bool = true) -> Bool {
        Self.matches(flags, required: cgEventFlags, allowingShift: allowingShift)
    }

    static func matches(
        _ flags: CGEventFlags,
        required: CGEventFlags,
        allowingShift: Bool = true
    ) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let actual = flags.intersection(relevant)
        let expected = required
        if actual == expected { return true }
        return allowingShift && actual == expected.union(.maskShift)
    }
}

enum PiPDetectionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case idle
    case change

    var id: String { rawValue }
}

private enum PiPTriggerKeyCode {
    private static let values: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50
    ]

    static func value(for key: String) -> CGKeyCode? {
        values[key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}

final class PiPEventTapContext: @unchecked Sendable {
    let owner: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var triggerKeyCode: CGKeyCode
    private var triggerModifierFlags: CGEventFlags
    private var eventTap: CFMachPort?

    init(
        owner: UnsafeMutableRawPointer,
        triggerKeyCode: CGKeyCode,
        triggerModifierFlags: CGEventFlags = PiPShortcutModifier.commandOption.cgEventFlags
    ) {
        self.owner = owner
        self.triggerKeyCode = triggerKeyCode
        self.triggerModifierFlags = triggerModifierFlags
    }

    func updateTriggerKeyCode(_ value: CGKeyCode) {
        lock.lock()
        triggerKeyCode = value
        lock.unlock()
    }

    func updateTriggerModifierFlags(_ value: CGEventFlags) {
        lock.lock()
        triggerModifierFlags = value
        lock.unlock()
    }

    func matches(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        lock.lock()
        let expectedFlags = triggerModifierFlags
        let matches = keyCode == triggerKeyCode
            && PiPShortcutModifier.matches(flags, required: expectedFlags)
        lock.unlock()
        return matches
    }

    func setEventTap(_ eventTap: CFMachPort?) {
        lock.lock()
        self.eventTap = eventTap
        lock.unlock()
    }

    func reenableEventTap() {
        lock.lock()
        let tap = eventTap
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private struct PiPKeyInput: Sendable {
    let keyCode: UInt16
    let characters: String
    let modifierFlagsRawValue: UInt

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        modifierFlagsRawValue = event.modifierFlags.rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }
}

private func pictureInPictureEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent?,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let event, let refcon else { return event.map(Unmanaged.passUnretained) }

    let context = Unmanaged<PiPEventTapContext>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // The system may disable a tap that takes too long. Re-enable it so a
        // transient input stall does not permanently break the global hotkey.
        context.reenableEventTap()
        return Unmanaged.passUnretained(event)
    }

    return pictureInPictureShouldSuppressEvent(type, event: event, context: context)
        ? nil
        : Unmanaged.passUnretained(event)
}

func pictureInPictureShouldSuppressEvent(
    _ type: CGEventType,
    event: CGEvent,
    context: PiPEventTapContext
) -> Bool {
    if event.getIntegerValueField(.eventSourceUserData) == 0x4D_50_50_49_50 {
        return false
    }

    let owner = Unmanaged<PictureInPictureModel>.fromOpaque(context.owner).takeUnretainedValue()
    if type == .keyDown,
       context.matches(
           CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
           flags: event.flags
       ) {
        let shift = event.flags.contains(.maskShift)
        Task { @MainActor in owner.handleEventTapTrigger(shift: shift) }
        return true
    }

    guard (type == .keyDown || type == .keyUp),
          Thread.isMainThread,
          let nsEvent = NSEvent(cgEvent: event) else {
        return false
    }
    let keyInput = PiPKeyInput(nsEvent)
    let handled = MainActor.assumeIsolated {
        type == .keyDown
            ? owner.handleKeyEvent(keyInput, suppress: true)
            : owner.handleKeyUpEvent(keyInput)
    }
    return handled
}

private func pictureInPictureFocusedWindowCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var processID: pid_t = 0
    AXUIElementGetPid(element, &processID)
    let owner = Unmanaged<PictureInPictureModel>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        owner.handleSourceWindowFocusChanged(processID)
    }
}

struct PictureInPictureSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var triggerKey: String
    var triggerModifier: PiPShortcutModifier
    var showMenuBarIcon: Bool
    var launchAtLogin: Bool
    var position: PiPPanelPosition
    var autoHideOnHover: Bool
    var clickToFocusSource: Bool
    var sourceFocusBehavior: PiPSourceFocusBehavior
    var showOnFullscreenSpaces: Bool
    var multiWindowMode: Bool
    var showHoverHints: Bool
    var dimOnHover: Bool
    var blurAmount: Double
    var cornerRadius: Double
    var quickLookWithSpace: Bool
    var defaultFrameRate: Int
    var enhanceContrast: Double
    var quickRegionCapture: Bool
    var aspectRatioLimit: Double
    var mediaControls: Bool
    var seekBar: Bool
    var spacePlayPause: Bool
    var youtubeCaptions: Bool
    var detectionThresholdSeconds: Int
    var sensitiveDetection: Bool
    var detectionScript: String
    var detectionScriptTimeoutSeconds: Int
    var frameRatesByBundleIdentifier: [String: Int]
    var detectionModesByBundleIdentifier: [String: PiPDetectionMode]
    var detectionSensitiveByBundleIdentifier: [String: Bool]
    var detectionThresholdsByBundleIdentifier: [String: Int]
    var occlusionFixBundleIdentifiers: Set<String>
    var occlusionAutoApply: Bool
    var occlusionCustomApplicationPaths: [String: String]

    init(
        isEnabled: Bool = true,
        triggerKey: String = "p",
        triggerModifier: PiPShortcutModifier = .commandOption,
        showMenuBarIcon: Bool = false,
        launchAtLogin: Bool = false,
        position: PiPPanelPosition = .bottomRight,
        autoHideOnHover: Bool = false,
        clickToFocusSource: Bool = true,
        sourceFocusBehavior: PiPSourceFocusBehavior = .doNothing,
        showOnFullscreenSpaces: Bool = true,
        multiWindowMode: Bool = false,
        showHoverHints: Bool = true,
        dimOnHover: Bool = true,
        blurAmount: Double = 0.7,
        cornerRadius: Double = 14,
        quickLookWithSpace: Bool = true,
        defaultFrameRate: Int = 10,
        enhanceContrast: Double = 0,
        quickRegionCapture: Bool = false,
        aspectRatioLimit: Double = 5,
        mediaControls: Bool = true,
        seekBar: Bool = true,
        spacePlayPause: Bool = true,
        youtubeCaptions: Bool = true,
        detectionThresholdSeconds: Int = 5,
        sensitiveDetection: Bool = false,
        detectionScript: String = "",
        detectionScriptTimeoutSeconds: Int = 5,
        frameRatesByBundleIdentifier: [String: Int] = [:],
        detectionModesByBundleIdentifier: [String: PiPDetectionMode] = [:],
        detectionSensitiveByBundleIdentifier: [String: Bool] = [:],
        detectionThresholdsByBundleIdentifier: [String: Int] = [:],
        occlusionFixBundleIdentifiers: Set<String> = [],
        occlusionAutoApply: Bool = true,
        occlusionCustomApplicationPaths: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        let normalizedKey = triggerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.triggerKey = normalizedKey.isEmpty ? "p" : String(normalizedKey.prefix(1))
        self.triggerModifier = triggerModifier
        self.showMenuBarIcon = showMenuBarIcon
        self.launchAtLogin = launchAtLogin
        self.position = position
        self.autoHideOnHover = autoHideOnHover
        self.clickToFocusSource = clickToFocusSource
        self.sourceFocusBehavior = sourceFocusBehavior
        self.showOnFullscreenSpaces = showOnFullscreenSpaces
        self.multiWindowMode = multiWindowMode
        self.showHoverHints = showHoverHints
        self.dimOnHover = dimOnHover
        self.blurAmount = min(1, max(0, blurAmount))
        self.cornerRadius = min(40, max(0, cornerRadius))
        self.quickLookWithSpace = quickLookWithSpace
        self.defaultFrameRate = min(60, max(1, defaultFrameRate))
        self.enhanceContrast = min(1, max(0, enhanceContrast))
        self.quickRegionCapture = quickRegionCapture
        self.aspectRatioLimit = min(20, max(1, aspectRatioLimit))
        self.mediaControls = mediaControls
        self.seekBar = seekBar
        self.spacePlayPause = spacePlayPause
        self.youtubeCaptions = youtubeCaptions
        self.detectionThresholdSeconds = min(60, max(1, detectionThresholdSeconds))
        self.sensitiveDetection = sensitiveDetection
        self.detectionScript = detectionScript
        self.detectionScriptTimeoutSeconds = min(60, max(1, detectionScriptTimeoutSeconds))
        self.frameRatesByBundleIdentifier = frameRatesByBundleIdentifier.mapValues { min(60, max(1, $0)) }
        self.detectionModesByBundleIdentifier = detectionModesByBundleIdentifier
        self.detectionSensitiveByBundleIdentifier = detectionSensitiveByBundleIdentifier
        self.detectionThresholdsByBundleIdentifier = detectionThresholdsByBundleIdentifier.mapValues { min(60, max(1, $0)) }
        self.occlusionFixBundleIdentifiers = occlusionFixBundleIdentifiers
        self.occlusionAutoApply = occlusionAutoApply
        self.occlusionCustomApplicationPaths = occlusionCustomApplicationPaths
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, triggerKey, triggerModifier, showMenuBarIcon, launchAtLogin
        case position, autoHideOnHover, clickToFocusSource, sourceFocusBehavior
        case showOnFullscreenSpaces, multiWindowMode, showHoverHints, dimOnHover
        case blurAmount, cornerRadius, quickLookWithSpace, defaultFrameRate
        case enhanceContrast, quickRegionCapture, aspectRatioLimit
        case mediaControls, seekBar, spacePlayPause, youtubeCaptions
        case detectionThresholdSeconds, sensitiveDetection, detectionScript
        case detectionScriptTimeoutSeconds, frameRatesByBundleIdentifier
        case detectionModesByBundleIdentifier, detectionSensitiveByBundleIdentifier
        case detectionThresholdsByBundleIdentifier
        case occlusionFixBundleIdentifiers, occlusionAutoApply, occlusionCustomApplicationPaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            triggerKey: try c.decodeIfPresent(String.self, forKey: .triggerKey) ?? "p",
            triggerModifier: try c.decodeIfPresent(PiPShortcutModifier.self, forKey: .triggerModifier) ?? .commandOption,
            showMenuBarIcon: try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? false,
            launchAtLogin: try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            position: try c.decodeIfPresent(PiPPanelPosition.self, forKey: .position) ?? .bottomRight,
            autoHideOnHover: try c.decodeIfPresent(Bool.self, forKey: .autoHideOnHover) ?? false,
            clickToFocusSource: try c.decodeIfPresent(Bool.self, forKey: .clickToFocusSource) ?? true,
            sourceFocusBehavior: try c.decodeIfPresent(PiPSourceFocusBehavior.self, forKey: .sourceFocusBehavior) ?? .doNothing,
            showOnFullscreenSpaces: try c.decodeIfPresent(Bool.self, forKey: .showOnFullscreenSpaces) ?? true,
            multiWindowMode: try c.decodeIfPresent(Bool.self, forKey: .multiWindowMode) ?? false,
            showHoverHints: try c.decodeIfPresent(Bool.self, forKey: .showHoverHints) ?? true,
            dimOnHover: try c.decodeIfPresent(Bool.self, forKey: .dimOnHover) ?? true,
            blurAmount: try c.decodeIfPresent(Double.self, forKey: .blurAmount) ?? 0.7,
            cornerRadius: try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 14,
            quickLookWithSpace: try c.decodeIfPresent(Bool.self, forKey: .quickLookWithSpace) ?? true,
            defaultFrameRate: try c.decodeIfPresent(Int.self, forKey: .defaultFrameRate) ?? 10,
            enhanceContrast: Self.decodeContrast(from: c),
            quickRegionCapture: try c.decodeIfPresent(Bool.self, forKey: .quickRegionCapture) ?? false,
            aspectRatioLimit: try c.decodeIfPresent(Double.self, forKey: .aspectRatioLimit) ?? 5,
            mediaControls: try c.decodeIfPresent(Bool.self, forKey: .mediaControls) ?? true,
            seekBar: try c.decodeIfPresent(Bool.self, forKey: .seekBar) ?? true,
            spacePlayPause: try c.decodeIfPresent(Bool.self, forKey: .spacePlayPause) ?? true,
            youtubeCaptions: try c.decodeIfPresent(Bool.self, forKey: .youtubeCaptions) ?? true,
            detectionThresholdSeconds: try c.decodeIfPresent(Int.self, forKey: .detectionThresholdSeconds) ?? 5,
            sensitiveDetection: try c.decodeIfPresent(Bool.self, forKey: .sensitiveDetection) ?? false,
            detectionScript: try c.decodeIfPresent(String.self, forKey: .detectionScript) ?? "",
            detectionScriptTimeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .detectionScriptTimeoutSeconds) ?? 5,
            frameRatesByBundleIdentifier: try c.decodeIfPresent([String: Int].self, forKey: .frameRatesByBundleIdentifier) ?? [:],
            detectionModesByBundleIdentifier: try c.decodeIfPresent([String: PiPDetectionMode].self, forKey: .detectionModesByBundleIdentifier) ?? [:],
            detectionSensitiveByBundleIdentifier: try c.decodeIfPresent([String: Bool].self, forKey: .detectionSensitiveByBundleIdentifier) ?? [:],
            detectionThresholdsByBundleIdentifier: try c.decodeIfPresent([String: Int].self, forKey: .detectionThresholdsByBundleIdentifier) ?? [:],
            occlusionFixBundleIdentifiers: try c.decodeIfPresent(Set<String>.self, forKey: .occlusionFixBundleIdentifiers) ?? [],
            occlusionAutoApply: try c.decodeIfPresent(Bool.self, forKey: .occlusionAutoApply) ?? true,
            occlusionCustomApplicationPaths: try c.decodeIfPresent([String: String].self, forKey: .occlusionCustomApplicationPaths) ?? [:]
        )
    }

    private static func decodeContrast(from container: KeyedDecodingContainer<CodingKeys>) -> Double {
        if let value = try? container.decodeIfPresent(Double.self, forKey: .enhanceContrast) {
            return min(1, max(0, value))
        }
        if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .enhanceContrast) {
            return legacy ? 0.15 : 0
        }
        return 0
    }

    var triggerShortcutDescription: String {
        "\(triggerModifier.symbolDescription)\(triggerKey.uppercased())"
    }

    func matchesTrigger(keyCode: CGKeyCode, flags: NSEvent.ModifierFlags) -> Bool {
        guard PiPTriggerKeyCode.value(for: triggerKey) == keyCode else { return false }
        return triggerModifier.matches(flags)
    }

    func matchesTrigger(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard PiPTriggerKeyCode.value(for: triggerKey) == keyCode else { return false }
        return triggerModifier.matches(flags)
    }

    func frameRate(for bundleIdentifier: String?) -> Int {
        guard let bundleIdentifier, let value = frameRatesByBundleIdentifier[bundleIdentifier] else {
            return defaultFrameRate
        }
        return min(60, max(1, value))
    }

    func detectionMode(for source: PiPSource) -> PiPDetectionMode {
        detectionModesByBundleIdentifier[source.bundleIdentifier ?? source.appName] ?? .off
    }

    func detectionIsSensitive(for source: PiPSource) -> Bool {
        detectionSensitiveByBundleIdentifier[source.bundleIdentifier ?? source.appName] ?? sensitiveDetection
    }

    func detectionThreshold(for source: PiPSource) -> Int {
        let value = detectionThresholdsByBundleIdentifier[source.bundleIdentifier ?? source.appName] ?? detectionThresholdSeconds
        return min(60, max(1, value))
    }
}

struct PiPRegion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        let safeWidth = min(1, max(0.001, width))
        let safeHeight = min(1, max(0.001, height))
        self.width = safeWidth
        self.height = safeHeight
        self.x = min(1 - safeWidth, max(0, x))
        self.y = min(1 - safeHeight, max(0, y))
    }

    static let fullWindow = PiPRegion(x: 0, y: 0, width: 1, height: 1)

    func cropRect(in size: CGSize) -> CGRect {
        CGRect(
            x: size.width * x,
            y: size.height * (1 - y - height),
            width: size.width * width,
            height: size.height * height
        )
    }

    static func fromScreenRect(_ rect: CGRect, in windowFrame: CGRect) -> PiPRegion? {
        guard windowFrame.width >= 2, windowFrame.height >= 2 else { return nil }
        let intersection = rect.intersection(windowFrame)
        guard !intersection.isNull, intersection.width >= 2, intersection.height >= 2 else { return nil }
        return PiPRegion(
            x: (intersection.minX - windowFrame.minX) / windowFrame.width,
            y: (windowFrame.maxY - intersection.maxY) / windowFrame.height,
            width: intersection.width / windowFrame.width,
            height: intersection.height / windowFrame.height
        )
    }

    static func fromSelectionRect(_ rect: CGRect, windowSize: CGSize) -> PiPRegion? {
        let bounds = CGRect(origin: .zero, size: windowSize)
        guard windowSize.width >= 2, windowSize.height >= 2 else { return nil }
        let selection = rect.intersection(bounds)
        guard !selection.isNull, selection.width >= 2, selection.height >= 2 else { return nil }
        return PiPRegion(
            x: selection.minX / windowSize.width,
            y: (windowSize.height - selection.maxY) / windowSize.height,
            width: selection.width / windowSize.width,
            height: selection.height / windowSize.height
        )
    }

    func limited(aspectRatioLimit: Double) -> PiPRegion {
        let limit = max(1, aspectRatioLimit)
        let ratio = width / height
        if ratio > limit {
            let newWidth = height * limit
            return PiPRegion(x: x + (width - newWidth) / 2, y: y, width: newWidth, height: height)
        }
        if ratio < 1 / limit {
            let newHeight = width * limit
            return PiPRegion(x: x, y: y + (height - newHeight) / 2, width: width, height: newHeight)
        }
        return self
    }
}

struct PiPSource: Equatable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let appName: String
    let bundleIdentifier: String?
    let title: String
    let frame: CGRect
}

struct PiPWindowCandidate: Equatable {
    let windowID: CGWindowID
    let frame: CGRect
}

enum PiPWindowSelection {
    static func isPlausibleCaptureWindow(_ frame: CGRect) -> Bool {
        frame.width >= 80 && frame.height >= 60 && frame.width * frame.height >= 8_000
    }

    /// Input is expected in front-to-back window order. Tiny utility windows
    /// (tooltips, drag badges, transient controls) must not win over the app's
    /// actual document window merely because ScreenCaptureKit lists them first.
    static func orderedCaptureWindowIDs(from candidates: [PiPWindowCandidate]) -> [CGWindowID] {
        let plausible = candidates.filter { isPlausibleCaptureWindow($0.frame) }
        if !plausible.isEmpty {
            return plausible.map(\.windowID)
        }
        return candidates
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .map(\.windowID)
    }
}

enum PiPCoordinateSpace {
    static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        guard let mapping = screenMappings().max(by: {
            intersectionArea(rect, $0.quartzFrame) < intersectionArea(rect, $1.quartzFrame)
        }) else { return rect }
        return appKitRect(fromQuartz: rect, quartzScreen: mapping.quartzFrame, appKitScreen: mapping.appKitFrame)
    }

    static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        guard let mapping = screenMappings().first(where: { $0.appKitFrame.contains(point) })
                ?? screenMappings().first else { return point }
        return quartzPoint(fromAppKit: point, quartzScreen: mapping.quartzFrame, appKitScreen: mapping.appKitFrame)
    }

    static func screen(containingQuartz rect: CGRect) -> NSScreen? {
        let mapping = screenMappings().max(by: {
            intersectionArea(rect, $0.quartzFrame) < intersectionArea(rect, $1.quartzFrame)
        })
        return mapping?.screen
    }

    static func appKitRect(fromQuartz rect: CGRect, quartzScreen: CGRect, appKitScreen: CGRect) -> CGRect {
        CGRect(
            x: appKitScreen.minX + rect.minX - quartzScreen.minX,
            y: appKitScreen.maxY - (rect.minY - quartzScreen.minY) - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func quartzPoint(fromAppKit point: CGPoint, quartzScreen: CGRect, appKitScreen: CGRect) -> CGPoint {
        CGPoint(
            x: quartzScreen.minX + point.x - appKitScreen.minX,
            y: quartzScreen.maxY - (point.y - appKitScreen.minY)
        )
    }

    private struct ScreenMapping {
        let screen: NSScreen
        let quartzFrame: CGRect
        let appKitFrame: CGRect
    }

    private static func screenMappings() -> [ScreenMapping] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenMapping(
                screen: screen,
                quartzFrame: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                appKitFrame: screen.frame
            )
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

struct PiPSessionSummary: Identifiable, Equatable {
    let id: UUID
    let appName: String
    let title: String
    let region: PiPRegion
    let isIdle: Bool
}

// MARK: - Stream processing

private enum PiPInitialFrameCapture {
    // CGWindowListCreateImage was obsoleted in macOS 15, but remains the only
    // reliable synchronous seed on macOS versions where ScreenCaptureKit
    // reports an initial idle frame without a pixel buffer. Keep this narrow
    // compatibility path limited to the first frame; all live updates still
    // come from ScreenCaptureKit.
    static func image(for windowID: CGWindowID) -> CGImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
        ) -> CGImage?

        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        return capture(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }
}

private final class PiPFrameProcessor: @unchecked Sendable {
    let region: PiPRegion
    let enhanceContrast: Double
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(region: PiPRegion, enhanceContrast: Double) {
        self.region = region
        self.enhanceContrast = enhanceContrast
    }

    func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        image(from: CIImage(cvPixelBuffer: pixelBuffer))
    }

    func image(from cgImage: CGImage) -> CGImage? {
        image(from: CIImage(cgImage: cgImage))
    }

    func image(from cgImage: CGImage, targetSize: CGSize) -> CGImage? {
        let source = CIImage(cgImage: cgImage)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaleX = targetSize.width / extent.width
        let scaleY = targetSize.height / extent.height
        let scaled = source.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .scaledBy(x: scaleX, y: scaleY)
        )
        return image(from: scaled)
    }

    private func image(from source: CIImage) -> CGImage? {
        var image = source
        if enhanceContrast > 0 {
            if let colorControls = CIFilter(name: "CIColorControls") {
                colorControls.setValue(image, forKey: kCIInputImageKey)
                colorControls.setValue(1 + enhanceContrast * 0.75, forKey: kCIInputContrastKey)
                colorControls.setValue(enhanceContrast * 0.03, forKey: kCIInputBrightnessKey)
                image = colorControls.outputImage ?? image
            }
            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(image, forKey: kCIInputImageKey)
                sharpen.setValue(enhanceContrast * 0.5, forKey: kCIInputSharpnessKey)
                image = sharpen.outputImage ?? image
            }
        }

        let extent = image.extent.integral
        if region != .fullWindow {
            image = image.cropped(to: region.cropRect(in: extent.size).offsetBy(dx: extent.minX, dy: extent.minY))
        }
        return context.createCGImage(image, from: image.extent)
    }
}

enum PiPFrameDifference {
    private static let width = 64
    private static let height = 36

    static func signature(for image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    static func hasMeaningfulChange(from previous: [UInt8], to current: [UInt8], sensitive: Bool) -> Bool {
        guard previous.count == current.count, !current.isEmpty else { return true }
        let intensityThreshold = sensitive ? 8 : 18
        let minimumChangedSamples = sensitive ? 1 : 8
        var changedSamples = 0
        for (old, new) in zip(previous, current) {
            if abs(Int(old) - Int(new)) >= intensityThreshold {
                changedSamples += 1
                if changedSamples >= minimumChangedSamples { return true }
            }
        }
        return false
    }
}

private struct PiPProcessedFrame: @unchecked Sendable {
    let image: CGImage
    let fingerprint: [UInt8]
}

@MainActor
private final class PiPStreamOutput: NSObject, SCStreamOutput {
    let processor: PiPFrameProcessor
    private let frameContinuation: AsyncStream<PiPProcessedFrame>.Continuation
    private var deliveryTask: Task<Void, Never>?

    init(processor: PiPFrameProcessor, session: PiPSession) {
        self.processor = processor
        var continuation: AsyncStream<PiPProcessedFrame>.Continuation?
        let frames = AsyncStream<PiPProcessedFrame>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.frameContinuation = continuation!
        super.init()
        deliveryTask = Task { @MainActor [weak session] in
            for await frame in frames {
                guard !Task.isCancelled, let session else { return }
                session.receive(image: frame.image, fingerprint: frame.fingerprint)
            }
        }
    }

    deinit {
        frameContinuation.finish()
        deliveryTask?.cancel()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard let image = processor.image(from: pixelBuffer) else { return }
        let frame = PiPProcessedFrame(image: image, fingerprint: PiPFrameDifference.signature(for: image))
        frameContinuation.yield(frame)
    }
}

@MainActor
private final class PiPStreamDelegate: NSObject, SCStreamDelegate {
    weak var session: PiPSession?

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.session?.streamStopped(with: error)
        }
    }
}

// MARK: - Floating panel

final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? NSHostingView<PiPPanelView>)?.rootView.session.close()
    }
}

private final class PiPQuickLookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        contentView = nil
    }
}

private struct PiPWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> PiPWindowDragHandleView {
        PiPWindowDragHandleView()
    }

    func updateNSView(_ nsView: PiPWindowDragHandleView, context: Context) {}
}

private final class PiPWindowDragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Session

@MainActor
final class PiPSession: ObservableObject, Identifiable {
    enum HiddenReason: Equatable {
        case manual
        case hover
        case sourceFocused
    }

    let id: UUID
    let source: PiPSource
    let region: PiPRegion
    @Published private(set) var presentationSettings: PictureInPictureSettings
    private(set) var frameRate: Int

    @Published private(set) var image: CGImage?
    @Published private(set) var isIdle = false
    @Published private(set) var detectionMode: PiPDetectionMode
    @Published private(set) var detectionIsSensitive: Bool
    @Published private(set) var isHidden = false
    @Published private(set) var isStalled = false
    @Published private(set) var isHovering = false
    @Published private(set) var showsHoverHints = false
    @Published private(set) var zoomFactor: CGFloat = 1 {
        didSet {
            panel?.isMovableByWindowBackground = zoomFactor <= 1
        }
    }
    @Published private(set) var zoomOffset: CGSize = .zero
    @Published private(set) var zoomSelection: CGRect?
    @Published private(set) var errorMessage: String?
    @Published private(set) var mediaSnapshot: PiPNowPlayingSnapshot?

    weak var owner: PictureInPictureModel?
    private(set) var panel: PiPPanel?
    private var stream: SCStream?
    private var streamOutput: PiPStreamOutput?
    private var streamDelegate: PiPStreamDelegate?
    private var lastFingerprint: [UInt8]?
    private var lastChangeDate = Date()
    private var idleNotificationSent = false
    private(set) var hiddenReason: HiddenReason?
    private var hoverHintTask: Task<Void, Never>?
    private var hoverHintDisplayCount = 0
    private var captureStartTask: Task<Void, Never>?
    private var stallMonitorTask: Task<Void, Never>?
    private var captureToken = UUID()
    private var zoomSelectionStart: CGPoint?
    private var pinchZoomStart: CGFloat?
    private var hasObservedMotion = false
    private var lastContentChangeDate = Date()
    private let stallThreshold: TimeInterval

    init(
        source: PiPSource,
        region: PiPRegion,
        settings: PictureInPictureSettings,
        owner: PictureInPictureModel,
        stallThreshold: TimeInterval = 3
    ) {
        self.id = UUID()
        self.source = source
        self.region = region
        self.presentationSettings = settings
        self.frameRate = settings.frameRate(for: source.bundleIdentifier)
        self.detectionMode = settings.detectionMode(for: source)
        self.detectionIsSensitive = settings.detectionIsSensitive(for: source)
        self.owner = owner
        self.stallThreshold = max(0.1, stallThreshold)
    }

    deinit {
        hoverHintTask?.cancel()
        captureStartTask?.cancel()
        stallMonitorTask?.cancel()
    }

    func start() {
        guard stream == nil, captureStartTask == nil, !isHidden else { return }
        configurePanelIfNeeded()
        isStalled = false
        hasObservedMotion = false
        lastContentChangeDate = Date()
        startStallMonitor()
        let token = UUID()
        captureToken = token
        captureStartTask = Task { [weak self] in
            await self?.startCapture(token: token)
        }
    }

    func stop() {
        captureToken = UUID()
        captureStartTask?.cancel()
        captureStartTask = nil
        stallMonitorTask?.cancel()
        stallMonitorTask = nil
        let currentStream = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        if let currentStream {
            Task {
                try? await currentStream.stopCapture()
            }
        }
    }

    func close() {
        releaseResources()
        owner?.removeSession(id: id)
    }

    fileprivate func releaseResources() {
        stop()
        hoverHintTask?.cancel()
        hoverHintTask = nil
        showsHoverHints = false
        image = nil
        lastFingerprint = nil
        let currentPanel = panel
        panel = nil
        currentPanel?.orderOut(nil)
        currentPanel?.contentView = nil
        currentPanel?.close()
    }

    func receive(image: CGImage, fingerprint suppliedFingerprint: [UInt8]? = nil) {
        guard !isHidden else { return }
        self.image = image
        let now = Date()
        let fingerprint = suppliedFingerprint ?? PiPFrameDifference.signature(for: image)
        let previousFingerprint = lastFingerprint
        let stallContentChanged = previousFingerprint.map {
            PiPFrameDifference.hasMeaningfulChange(from: $0, to: fingerprint, sensitive: false)
        } ?? true
        if stallContentChanged {
            if previousFingerprint != nil { hasObservedMotion = true }
            lastContentChangeDate = now
            if isStalled {
                isStalled = false
                owner?.sessionDidChange()
            }
        }
        lastFingerprint = fingerprint
        guard detectionMode != .off else { return }
        let oldIdle = isIdle
        let detectionContentChanged = previousFingerprint.map {
            PiPFrameDifference.hasMeaningfulChange(from: $0, to: fingerprint, sensitive: detectionIsSensitive)
        } ?? true
        if detectionContentChanged {
            let wasIdle = isIdle
            lastChangeDate = now
            idleNotificationSent = false
            if isIdle { isIdle = false }
            if wasIdle, detectionMode == .change { runDetectionScript(event: "change") }
        } else if !isIdle && Date().timeIntervalSince(lastChangeDate) >= Double(presentationSettings.detectionThreshold(for: source)) {
            isIdle = true
            if detectionMode == .idle, !idleNotificationSent {
                idleNotificationSent = true
                runDetectionScript(event: "idle")
            }
        }
        if oldIdle != isIdle { owner?.sessionDidChange() }
    }

    func streamStopped(with error: Error) {
        guard !isHidden else { return }
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        Task { [weak self] in
            guard let self else { return }
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled else { return }
            if content?.windows.contains(where: { $0.windowID == self.source.windowID }) == true {
                self.isStalled = true
                self.errorMessage = error.localizedDescription
                self.owner?.sessionDidChange()
            } else {
                self.close()
            }
        }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering && presentationSettings.autoHideOnHover && !isHidden {
            hide(reason: .hover)
            return
        }
        hoverHintTask?.cancel()
        showsHoverHints = false
        guard hovering, presentationSettings.showHoverHints, hoverHintDisplayCount < 3 else { return }
        hoverHintDisplayCount += 1
        showsHoverHints = true
        hoverHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.showsHoverHints = false
        }
    }

    func hide(reason: HiddenReason = .manual) {
        guard !isHidden else { return }
        isHidden = true
        hiddenReason = reason
        hoverHintTask?.cancel()
        showsHoverHints = false
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        stop()
    }

    func show() {
        guard isHidden else { return }
        isHidden = false
        hiddenReason = nil
        panel?.alphaValue = 1
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        start()
    }

    func toggleHidden() {
        if isHidden { show() } else { hide(reason: .manual) }
    }

    func resetZoom() {
        zoomFactor = 1
        zoomOffset = .zero
        zoomSelection = nil
        zoomSelectionStart = nil
    }

    func setZoomFactor(_ factor: CGFloat) {
        zoomFactor = min(12, max(1, factor))
        if zoomFactor == 1 { zoomOffset = .zero }
    }

    func changeZoom(by amount: CGFloat) {
        zoomFactor = min(12, max(1, zoomFactor + amount))
        if zoomFactor == 1 { zoomOffset = .zero }
    }

    func changeZoom(by amount: CGFloat, around anchor: CGPoint, in viewportSize: CGSize) {
        let oldFactor = zoomFactor
        let newFactor = min(12, max(1, oldFactor + amount))
        guard oldFactor != newFactor, oldFactor > 0, viewportSize.width > 0, viewportSize.height > 0 else { return }

        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let ratio = newFactor / oldFactor
        let contentOffsetAtAnchor = CGPoint(
            x: anchor.x - center.x - zoomOffset.width,
            y: anchor.y - center.y - zoomOffset.height
        )
        zoomOffset = CGSize(
            width: zoomOffset.width + (1 - ratio) * contentOffsetAtAnchor.x,
            height: zoomOffset.height + (1 - ratio) * contentOffsetAtAnchor.y
        )
        zoomFactor = newFactor
        if zoomFactor == 1 { zoomOffset = .zero }
    }

    func applyScrollWheel(
        deltaX: CGFloat,
        deltaY: CGFloat,
        commandPressed: Bool,
        mousePoint: CGPoint? = nil,
        viewportSize: CGSize? = nil
    ) {
        if commandPressed {
            pan(by: CGSize(width: deltaX, height: deltaY))
        } else if abs(deltaY) > 0.001 {
            if let mousePoint, let viewportSize {
                changeZoom(by: deltaY / 20, around: mousePoint, in: viewportSize)
            } else {
                changeZoom(by: deltaY / 20)
            }
        } else {
            pan(by: CGSize(width: deltaX, height: 0))
        }
    }

    func pan(by delta: CGSize) {
        guard zoomFactor > 1 else { return }
        zoomOffset = CGSize(width: zoomOffset.width + delta.width, height: zoomOffset.height + delta.height)
    }

    func toggleIdleDetection() {
        setDetectionMode(detectionMode == .idle ? .off : .idle)
    }

    func toggleChangeDetection() {
        setDetectionMode(detectionMode == .change ? .off : .change)
    }

    func cycleDetectionMode() {
        switch detectionMode {
        case .off: setDetectionMode(.idle)
        case .idle: setDetectionMode(.change)
        case .change: setDetectionMode(.off)
        }
    }

    func toggleSensitiveDetection() {
        detectionIsSensitive.toggle()
        owner?.setDetectionSensitive(detectionIsSensitive, for: self)
        resetDetectionState()
    }

    private func setDetectionMode(_ mode: PiPDetectionMode) {
        detectionMode = mode
        owner?.setDetectionMode(mode, for: self)
        resetDetectionState()
    }

    private func resetDetectionState() {
        isIdle = false
        lastFingerprint = nil
        lastChangeDate = Date()
        idleNotificationSent = false
        owner?.sessionDidChange()
    }

    var isYouTubeSource: Bool {
        source.title.localizedCaseInsensitiveContains("youtube")
    }

    func updateMediaSnapshot(_ snapshot: PiPNowPlayingSnapshot?) {
        mediaSnapshot = snapshot
    }

    func toggleMediaPlayback() {
        if owner?.toggleMediaPlayback(for: self) != true {
            sendKeyPress(49)
        }
    }

    func seekMedia(to position: Double) {
        guard let snapshot = mediaSnapshot else { return }
        let constrained = min(snapshot.duration ?? position, max(0, position))
        owner?.seekMedia(to: constrained, for: self)
    }

    func seekMedia(by seconds: Double) {
        guard let elapsed = mediaSnapshot?.liveElapsedTime() else {
            sendKeyPress(seconds < 0 ? 123 : 124)
            return
        }
        seekMedia(to: elapsed + seconds)
    }

    func toggleYouTubeCaptions() {
        guard isYouTubeSource else { return }
        sendKeyPress(8)
    }

    func beginZoomSelection(at point: CGPoint) {
        zoomSelectionStart = point
        zoomSelection = CGRect(origin: point, size: .zero)
    }

    func updateZoomSelection(to point: CGPoint, in size: CGSize) {
        guard let start = zoomSelectionStart else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let constrainedStart = CGPoint(
            x: min(bounds.maxX, max(bounds.minX, start.x)),
            y: min(bounds.maxY, max(bounds.minY, start.y))
        )
        let constrainedPoint = CGPoint(
            x: min(bounds.maxX, max(bounds.minX, point.x)),
            y: min(bounds.maxY, max(bounds.minY, point.y))
        )
        zoomSelection = CGRect(
            x: min(constrainedStart.x, constrainedPoint.x),
            y: min(constrainedStart.y, constrainedPoint.y),
            width: abs(constrainedPoint.x - constrainedStart.x),
            height: abs(constrainedPoint.y - constrainedStart.y)
        )
    }

    func endZoomSelection(in size: CGSize) {
        defer {
            zoomSelection = nil
            zoomSelectionStart = nil
        }
        guard let selection = zoomSelection,
              selection.width >= 8, selection.height >= 8,
              size.width > 0, size.height > 0 else { return }
        let factor = min(12, max(1, min(size.width / selection.width, size.height / selection.height)))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        zoomFactor = factor
        zoomOffset = CGSize(
            width: (center.x - selection.midX) * factor,
            height: (center.y - selection.midY) * factor
        )
    }

    func beginPinchZoom() {
        if pinchZoomStart == nil { pinchZoomStart = zoomFactor }
    }

    func updatePinchZoom(magnification: CGFloat) {
        beginPinchZoom()
        guard let pinchZoomStart else { return }
        setZoomFactor(pinchZoomStart * magnification)
    }

    func endPinchZoom() {
        pinchZoomStart = nil
    }

    func focusSource() {
        let app = NSRunningApplication(processIdentifier: source.processID)
        app?.activate(options: [])

        let appElement = AXUIElementCreateApplication(source.processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var titleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = titleValue as? String ?? ""
            guard title == source.title || title.contains(source.title) || source.title.contains(title) else { continue }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
            break
        }
    }

    func sendKeyPress(_ keyCode: CGKeyCode) {
        focusSource()
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        keyDown.setIntegerValueField(.eventSourceUserData, value: 0x4D_50_50_49_50)
        keyUp.setIntegerValueField(.eventSourceUserData, value: 0x4D_50_50_49_50)
        keyDown.postToPid(source.processID)
        keyUp.postToPid(source.processID)
    }

    func handleSingleClick() {
        guard presentationSettings.clickToFocusSource else { return }
        focusSource()
    }

    func updateFrameRate(_ value: Int) {
        frameRate = min(60, max(1, value))
        restartCapture()
    }

    func applyPresentationSettings(_ newSettings: PictureInPictureSettings) {
        let oldRate = frameRate
        let oldContrast = presentationSettings.enhanceContrast
        let oldPosition = presentationSettings.position
        presentationSettings = newSettings
        frameRate = newSettings.frameRate(for: source.bundleIdentifier)
        detectionMode = newSettings.detectionMode(for: source)
        detectionIsSensitive = newSettings.detectionIsSensitive(for: source)
        panel?.collectionBehavior = newSettings.showOnFullscreenSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .ignoresCycle]
        if oldPosition != newSettings.position, let panel {
            panel.setFrame(initialPanelFrame(), display: true)
        }
        if !newSettings.autoHideOnHover, isHidden, hiddenReason == .hover { show() }
        if newSettings.sourceFocusBehavior != .hidePanel,
           isHidden, hiddenReason == .sourceFocused { show() }
        if !newSettings.showHoverHints {
            hoverHintTask?.cancel()
            showsHoverHints = false
        }
        if oldRate != frameRate || oldContrast != newSettings.enhanceContrast {
            restartCapture()
        }
    }

    private func configurePanelIfNeeded() {
        guard panel == nil else { return }
        let panel = PiPPanel(
            contentRect: initialPanelFrame(),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = source.title.isEmpty ? source.appName : source.title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 180, height: 120)
        panel.contentAspectRatio = NSSize(width: max(1, source.frame.width * region.width), height: max(1, source.frame.height * region.height))
        panel.collectionBehavior = presentationSettings.showOnFullscreenSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PiPPanelView(session: self))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func initialPanelFrame() -> NSRect {
        let screen = PiPCoordinateSpace.screen(containingQuartz: source.frame) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let aspect = max(0.25, min(4, source.frame.width * region.width / max(1, source.frame.height * region.height)))
        let margin: CGFloat = 24
        let maximumWidth = min(420, max(240, visible.width * 0.27))
        let maximumHeight = max(120, visible.height - margin * 2)
        let width = min(maximumWidth, maximumHeight * aspect)
        let height = min(maximumHeight, width / aspect)
        let x = presentationSettings.position == .topLeft || presentationSettings.position == .bottomLeft
            ? visible.minX + margin
            : visible.maxX - width - margin
        let y = presentationSettings.position == .topLeft || presentationSettings.position == .topRight
            ? visible.maxY - height - margin
            : visible.minY + margin
        return NSRect(x: x, y: y, width: width, height: min(height, visible.height - margin * 2))
    }

    private func startCapture(token: UUID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled, token == captureToken, !isHidden else { return }
            guard let window = content.windows.first(where: { $0.windowID == source.windowID }) else {
                throw PictureInPictureError.windowUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = Self.captureConfiguration(
                sourceFrame: source.frame,
                region: region,
                frameRate: frameRate
            )

            let processor = PiPFrameProcessor(region: region, enhanceContrast: presentationSettings.enhanceContrast)
            if let initialImage = PiPInitialFrameCapture.image(for: source.windowID),
               let processedImage = processor.image(
                   from: initialImage,
                   targetSize: CGSize(width: configuration.width, height: configuration.height)
               ) {
                receive(image: processedImage)
            }
            let output = PiPStreamOutput(processor: processor, session: self)
            let delegate = PiPStreamDelegate()
            delegate.session = self
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.misswell.macpilot.pip.frames"))
            try await stream.startCapture()
            guard !Task.isCancelled, token == captureToken, !isHidden else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            self.streamOutput = output
            self.streamDelegate = delegate
            errorMessage = nil
            // macOS may send only SCFrameStatusIdle samples when a window is
            // static. Those samples are valid but intentionally have no pixel
            // buffer, so seed the panel with an immediate still image before
            // waiting for the next changed video frame.
            captureInitialImage(filter: filter, configuration: configuration, processor: processor, token: token)
        } catch {
            if !Task.isCancelled, token == captureToken {
                errorMessage = error.localizedDescription
            }
        }
        if token == captureToken {
            captureStartTask = nil
        }
    }

    static func captureConfiguration(
        sourceFrame: CGRect,
        region: PiPRegion = .fullWindow,
        frameRate: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Capture the full source window and crop the selected region after the
        // frame arrives. This keeps the region coordinates stable across
        // ScreenCaptureKit's scaling behavior.
        let pixelSize = capturePixelSize(sourceFrame: sourceFrame, region: region)
        configuration.width = max(1, Int(pixelSize.width.rounded()))
        configuration.height = max(1, Int(pixelSize.height.rounded()))
        // SCScreenshotManager otherwise preserves the window's native point
        // size inside the larger pixel buffer, leaving the live content in the
        // top-left quarter with black padding.
        configuration.scalesToFit = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    static func capturePixelSize(sourceFrame: CGRect, region: PiPRegion) -> CGSize {
        // A normal PiP is at most 420 points wide and Quick Look rarely needs
        // more than 1,600 pixels on its longest edge. Calculate the scale from
        // the selected region, then cap it at Retina 2x. A narrow crop keeps
        // enough detail to enlarge while a full 4K/5K window avoids processing
        // its entire backing store for a small floating panel.
        let selectedWidth = max(1, sourceFrame.width * region.width)
        let selectedHeight = max(1, sourceFrame.height * region.height)
        let selectedDetailScale = 1_600 / max(selectedWidth, selectedHeight)
        let backingStoreScale = 2_048 / max(sourceFrame.width, sourceFrame.height)
        let scale = min(2, selectedDetailScale, backingStoreScale)
        return CGSize(
            width: max(1, sourceFrame.width * scale),
            height: max(1, sourceFrame.height * scale)
        )
    }

    // SCScreenshotManager invokes its completion handler on the replayd XPC
    // queue. Keep this entry point nonisolated so the callback does not inherit
    // PiPSession's MainActor isolation and trip Swift's executor assertion.
    private nonisolated func captureInitialImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        processor: PiPFrameProcessor,
        token: UUID
    ) {
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
            guard let image, let processedImage = processor.image(from: image) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      token == self.captureToken,
                      !self.isHidden else { return }
                self.receive(image: processedImage)
            }
        }
    }

    private func restartCapture() {
        guard stream != nil else { return }
        stop()
        start()
    }

    private func startStallMonitor() {
        guard stallMonitorTask == nil else { return }
        stallMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = min(1, max(0.1, (self?.stallThreshold ?? 1) / 2))
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.updateStallState()
            }
        }
    }

    private func updateStallState() {
        guard !isHidden, image != nil, hasObservedMotion else { return }
        let stalled = Date().timeIntervalSince(lastContentChangeDate) >= stallThreshold
        guard stalled != isStalled else { return }
        isStalled = stalled
        owner?.sessionDidChange()
    }

    private func runDetectionScript(event: String) {
        let script = presentationSettings.detectionScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        var environment = ProcessInfo.processInfo.environment
        environment.merge([
            "PIPIRI_EVENT": event,
            "PIPIRI_APP": source.appName,
            "PIPIRI_BUNDLE_ID": source.bundleIdentifier ?? "",
            "PIPIRI_WINDOW_ID": String(source.windowID)
        ]) { _, newValue in newValue }
        process.environment = environment
        do {
            try process.run()
            let timeout = DispatchWorkItem { [weak process] in
                guard process?.isRunning == true else { return }
                process?.terminate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(presentationSettings.detectionScriptTimeoutSeconds), execute: timeout)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Panel UI

struct PiPPanelView: View {
    @ObservedObject var session: PiPSession
    @State private var panTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = session.image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(session.zoomFactor)
                        .offset(session.zoomOffset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if let error = session.errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).multilineTextAlignment(.center).padding(.horizontal, 14)
                    }
                    .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }

                if isMediaPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(13)
                        .background(.black.opacity(0.58), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .accessibilityLabel("Media paused")
                }

                if session.presentationSettings.dimOnHover && session.isHovering {
                    if session.presentationSettings.blurAmount > 0 {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(session.presentationSettings.blurAmount * 0.32)
                    }
                    LinearGradient(
                        colors: [.black.opacity(0.52), .clear, .black.opacity(0.48)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                if session.zoomFactor > 1 {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(contentPanGesture)
                        .accessibilityHidden(true)
                }

                if session.isHovering {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            if session.presentationSettings.showHoverHints || session.zoomFactor > 1 {
                                sourceBadge
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            Spacer(minLength: 8)
                            hudButton(icon: "xmark", help: "Close Picture-in-Picture") {
                                session.close()
                            }
                        }
                        Spacer()
                        if session.presentationSettings.mediaControls,
                           session.mediaSnapshot != nil {
                            PiPMediaTransportControls(session: session)
                                .frame(maxWidth: 360)
                        } else if session.presentationSettings.showHoverHints {
                            actionDock
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(10)
                }

                if let selection = session.zoomSelection {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .overlay(Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: session.presentationSettings.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: session.presentationSettings.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if session.zoomFactor > 1 {
                    PiPWindowDragHandle()
                        .frame(width: min(240, max(110, geometry.size.width * 0.65)), height: 56)
                        .accessibilityHidden(true)
                }
            }
            .onHover { session.setHovering($0) }
            .onTapGesture(count: 2) {
                if NSEvent.modifierFlags.contains(.command) {
                    session.resetZoom()
                } else {
                    session.focusSource()
                    session.close()
                }
            }
            .onTapGesture { session.handleSingleClick() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .modifiers(.command)
                    .onChanged { value in
                        if session.zoomSelection == nil { session.beginZoomSelection(at: value.startLocation) }
                        session.updateZoomSelection(to: value.location, in: geometry.size)
                    }
                    .onEnded { _ in session.endZoomSelection(in: geometry.size) }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        session.updatePinchZoom(magnification: value.magnification)
                    }
                    .onEnded { _ in session.endPinchZoom() }
            )
            .contextMenu {
                Button("聚焦源窗口") { session.focusSource() }
                if session.mediaSnapshot != nil {
                    Button("播放 / 暂停") { session.toggleMediaPlayback() }
                }
                Button("重置缩放") { session.resetZoom() }
                Divider()
                Button("关闭 PiP", role: .destructive) { session.close() }
            }
            .animation(.easeOut(duration: 0.16), value: session.isHovering)
        }
    }

    private var contentPanGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - panTranslation.width,
                    height: value.translation.height - panTranslation.height
                )
                panTranslation = value.translation
                session.pan(by: delta)
            }
            .onEnded { _ in
                panTranslation = .zero
            }
    }

    private var sourceBadge: some View {
        HStack(spacing: 7) {
            if let icon = NSRunningApplication(processIdentifier: session.source.processID)?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 17, height: 17)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(session.source.appName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Circle()
                .fill(session.image == nil ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
        }
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
    }

    private var actionDock: some View {
        HStack(spacing: 4) {
            hudButton(icon: detectionIcon, help: detectionIndicatorHelp) {
                session.cycleDetectionMode()
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(detectionIndicatorColor)
                    .frame(width: 6, height: 6)
                    .overlay {
                        if session.detectionIsSensitive {
                            Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                        }
                    }
                    .offset(x: -4, y: 4)
            }
            Divider()
                .frame(height: 18)
                .overlay(.white.opacity(0.18))
                .padding(.horizontal, 3)
            hudButton(icon: "arrow.up.forward.app", help: "Focus source window") {
                session.focusSource()
            }
            hudButton(icon: "arrow.counterclockwise", help: "Reset zoom") {
                session.resetZoom()
            }
            Text(zoomLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .frame(minWidth: 32)
                .padding(.horizontal, 4)
        }
        .padding(5)
        .background(.black.opacity(0.62), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func hudButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.08), in: Circle())
        .help(help)
    }

    private var zoomLabel: String {
        let rounded = session.zoomFactor.rounded()
        if abs(session.zoomFactor - rounded) < 0.01 {
            return "\(Int(rounded))×"
        }
        return String(format: "%.1f×", session.zoomFactor)
    }

    private var detectionIcon: String {
        switch session.detectionMode {
        case .off: "waveform.slash"
        case .idle: "moon.zzz.fill"
        case .change: "waveform.path.ecg"
        }
    }

    private var detectionIndicatorColor: Color {
        switch session.detectionMode {
        case .off: .gray
        case .idle: session.isIdle ? .green : .orange
        case .change: session.isIdle ? .blue : .purple
        }
    }

    private var detectionIndicatorHelp: String {
        switch session.detectionMode {
        case .off: "Detection off · click for idle detection"
        case .idle: "Idle detection · click for change detection"
        case .change: "Change detection · click to turn off"
        }
    }

    private var isMediaPaused: Bool {
        guard let snapshot = session.mediaSnapshot,
              snapshot.isPlaying == false else { return false }
        return (snapshot.duration ?? 0) > 0
    }
}

private struct PiPQuickLookView: View {
    @ObservedObject var session: PiPSession
    let image: CGImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Image(systemName: "pip.enter")
                Text(session.source.appName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Space 关闭")
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.55))
        }
    }
}

// MARK: - Region selection overlay

private final class PiPRegionSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        dirtyRect.fill()
        guard !currentRect.isEmpty else { return }
        NSColor.clear.setFill()
        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        currentRect.fill()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !currentRect.isEmpty, currentRect.width >= 2, currentRect.height >= 2 else {
            onComplete?(nil)
            return
        }
        onComplete?(currentRect)
    }
}

private final class PiPRegionSelectionPanel: NSPanel {
    private let selectionView = PiPRegionSelectionView()
    private let onComplete: (CGRect?) -> Void

    init(frame: NSRect, onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        selectionView.frame = NSRect(origin: .zero, size: frame.size)
        selectionView.autoresizingMask = [.width, .height]
        selectionView.onComplete = { [weak self] localRect in
            guard let self else { return }
            if let localRect {
                onComplete(localRect)
            } else {
                onComplete(nil)
            }
            orderOut(nil)
        }
        contentView = selectionView
        makeFirstResponder(selectionView)
    }

    override func cancelOperation(_ sender: Any?) {
        onComplete(nil)
        orderOut(nil)
    }
}

// MARK: - Model

enum PictureInPictureError: LocalizedError {
    case permissionRequired
    case noFocusedWindow
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "需要屏幕录制权限才能创建画中画。"
        case .noFocusedWindow: "没有找到可捕获的前台窗口。"
        case .windowUnavailable: "源窗口已关闭或不可捕获。"
        }
    }
}

@MainActor
final class PictureInPictureModel: ObservableObject {
    @Published private(set) var settings = PictureInPictureSettings()
    @Published private(set) var summaries: [PiPSessionSummary] = []
    @Published private(set) var hasScreenPermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var errorMessage: String?
    let occlusionController = PiPOcclusionController()

    var persist: (() -> Void)?
    private var sessions: [UUID: PiPSession] = [:]
    private let mediaRemote = PiPMediaRemoteBridge()
    private var mediaPollingTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyUpMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapContext: PiPEventTapContext?
    private var activationObserver: NSObjectProtocol?
    private var focusObservers: [pid_t: AXObserver] = [:]
    private var selectionPanel: PiPRegionSelectionPanel?
    private var quickLookPanel: PiPQuickLookPanel?
    private var spaceSession: PiPSession?
    private var spaceQuickLookWasShown = false
    private var spaceQuickLookWasVisible = false
    private var spaceTask: Task<Void, Never>?
    private var isLoading = false
    private var isMonitoring = false
    private var threeFingerGestureActive = false

    func applyLoadedSettings(_ newSettings: PictureInPictureSettings) {
        isLoading = true
        settings = newSettings
        occlusionController.applySettings(
            enabledBundleIdentifiers: newSettings.occlusionFixBundleIdentifiers,
            autoApply: newSettings.occlusionAutoApply,
            customApplicationPaths: newSettings.occlusionCustomApplicationPaths
        )
        eventTapContext?.updateTriggerKeyCode(PiPTriggerKeyCode.value(for: newSettings.triggerKey) ?? 35)
        eventTapContext?.updateTriggerModifierFlags(newSettings.triggerModifier.cgEventFlags)
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        isLoading = false
    }

    func activateFromConfiguration() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        guard settings.isEnabled else { return }
        occlusionController.activate()
        startMonitoring()
        handleLaunchArguments()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        updateSettings { $0.isEnabled = enabled }
        if enabled {
            occlusionController.activate()
            startMonitoring()
        } else {
            occlusionController.shutdown()
            stopMonitoring()
            closeAll()
        }
    }

    func shutdown() {
        occlusionController.shutdown()
        stopMonitoring()
        closeAll()
        hideQuickLook()
        spaceTask?.cancel()
    }

    func requestScreenPermission() {
        if CGPreflightScreenCaptureAccess() {
            hasScreenPermission = true
            return
        }
        _ = CGRequestScreenCaptureAccess()
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary)
        if hasAccessibilityPermission {
            if installEventTapIfPossible() {
                removeKeyboardFallbackMonitors()
            }
            rebuildFocusObservers()
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func setTriggerKey(_ key: String) {
        updateSettings { $0.triggerKey = key }
        let keyCode = PiPTriggerKeyCode.value(for: settings.triggerKey) ?? 35
        eventTapContext?.updateTriggerKeyCode(keyCode)
    }
    func setTriggerModifier(_ modifier: PiPShortcutModifier) {
        updateSettings { $0.triggerModifier = modifier }
        eventTapContext?.updateTriggerModifierFlags(modifier.cgEventFlags)
    }
    func setShowMenuBarIcon(_ value: Bool) { updateSettings { $0.showMenuBarIcon = value } }
    func setLaunchAtLogin(_ value: Bool) { updateSettings { $0.launchAtLogin = value } }
    func setPosition(_ value: PiPPanelPosition) { updateSettings { $0.position = value } }
    func setAutoHideOnHover(_ value: Bool) { updateSettings { $0.autoHideOnHover = value } }
    func setClickToFocusSource(_ value: Bool) { updateSettings { $0.clickToFocusSource = value } }
    func setSourceFocusBehavior(_ value: PiPSourceFocusBehavior) {
        updateSettings { $0.sourceFocusBehavior = value }
        rebuildFocusObservers()
        handleSourceWindowFocusChanged(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }
    func setShowOnFullscreenSpaces(_ value: Bool) {
        updateSettings { $0.showOnFullscreenSpaces = value }
        for session in sessions.values { session.panel?.collectionBehavior = value ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.moveToActiveSpace, .ignoresCycle] }
    }
    func setMultiWindowMode(_ value: Bool) { updateSettings { $0.multiWindowMode = value } }
    func setShowHoverHints(_ value: Bool) { updateSettings { $0.showHoverHints = value } }
    func setDimOnHover(_ value: Bool) { updateSettings { $0.dimOnHover = value } }
    func setBlurAmount(_ value: Double) { updateSettings { $0.blurAmount = value } }
    func setCornerRadius(_ value: Double) { updateSettings { $0.cornerRadius = value } }
    func setQuickLookWithSpace(_ value: Bool) { updateSettings { $0.quickLookWithSpace = value } }
    func setDefaultFrameRate(_ value: Int) { updateSettings { $0.defaultFrameRate = value } }
    func setEnhanceContrast(_ value: Double) { updateSettings { $0.enhanceContrast = value } }
    func setQuickRegionCapture(_ value: Bool) {
        updateSettings { $0.quickRegionCapture = value }
        updateMouseMonitoring()
    }
    func setAspectRatioLimit(_ value: Double) { updateSettings { $0.aspectRatioLimit = value } }
    func setMediaControls(_ value: Bool) {
        updateSettings { $0.mediaControls = value }
        if value {
            startMediaPollingIfNeeded()
        } else {
            stopMediaPolling()
        }
    }
    func setSeekBar(_ value: Bool) { updateSettings { $0.seekBar = value } }
    func setSpacePlayPause(_ value: Bool) { updateSettings { $0.spacePlayPause = value } }
    func setYoutubeCaptions(_ value: Bool) { updateSettings { $0.youtubeCaptions = value } }
    func setDetectionThresholdSeconds(_ value: Int) { updateSettings { $0.detectionThresholdSeconds = value } }
    func setSensitiveDetection(_ value: Bool) { updateSettings { $0.sensitiveDetection = value } }
    func setDetectionScript(_ value: String) { updateSettings { $0.detectionScript = value } }
    func setDetectionScriptTimeoutSeconds(_ value: Int) { updateSettings { $0.detectionScriptTimeoutSeconds = value } }

    func setOcclusionFixEnabled(_ enabled: Bool, for bundleIdentifier: String) {
        updateSettings {
            if enabled {
                $0.occlusionFixBundleIdentifiers.insert(bundleIdentifier)
            } else {
                $0.occlusionFixBundleIdentifiers.remove(bundleIdentifier)
            }
        }
        synchronizeOcclusionSettings()
    }

    func setOcclusionAutoApply(_ value: Bool) {
        updateSettings { $0.occlusionAutoApply = value }
        synchronizeOcclusionSettings()
    }

    func addCustomOcclusionApplication(at url: URL) {
        guard let identity = PiPOcclusionAppPatchService.applicationIdentity(at: url) else { return }
        updateSettings { $0.occlusionCustomApplicationPaths[identity.bundleIdentifier] = url.path }
        synchronizeOcclusionSettings()
    }

    func removeCustomOcclusionApplication(bundleIdentifier: String) {
        updateSettings {
            $0.occlusionCustomApplicationPaths.removeValue(forKey: bundleIdentifier)
            $0.occlusionFixBundleIdentifiers.remove(bundleIdentifier)
        }
        synchronizeOcclusionSettings()
    }

    func setFrameRate(for bundleIdentifier: String, value: Int) {
        updateSettings { $0.frameRatesByBundleIdentifier[bundleIdentifier] = min(60, max(1, value)) }
    }

    func setDetectionMode(_ mode: PiPDetectionMode, for session: PiPSession) {
        let key = session.source.bundleIdentifier ?? session.source.appName
        updateSettings { $0.detectionModesByBundleIdentifier[key] = mode }
    }

    func setDetectionSensitive(_ value: Bool, for session: PiPSession) {
        let key = session.source.bundleIdentifier ?? session.source.appName
        updateSettings { $0.detectionSensitiveByBundleIdentifier[key] = value }
    }

    func removeSession(id: UUID) {
        if quickLookSessionID == id { hideQuickLook() }
        sessions.removeValue(forKey: id)
        if sessions.isEmpty { stopMediaPolling() }
        updateMouseMonitoring()
        rebuildFocusObservers()
        refreshSummaries()
    }

    func closeSession(id: UUID) {
        sessions[id]?.close()
    }

    func sessionDidChange() {
        refreshSummaries()
    }

    func closeAll() {
        let current = Array(sessions.values)
        sessions.removeAll()
        stopMediaPolling()
        hideQuickLook()
        updateMouseMonitoring()
        for session in current { session.releaseResources() }
        rebuildFocusObservers()
        refreshSummaries()
    }

    @discardableResult
    func toggleMediaPlayback(for session: PiPSession) -> Bool {
        guard session.mediaSnapshot != nil else { return false }
        let sent = mediaRemote.togglePlayPause(for: session.source.processID)
        if sent { refreshMediaSnapshotsSoon() }
        return sent
    }

    func seekMedia(to position: Double, for session: PiPSession) {
        guard session.mediaSnapshot != nil else { return }
        if mediaRemote.seek(to: position, for: session.source.processID) {
            refreshMediaSnapshotsSoon()
        }
    }

    func captureFocusedWindowNow() {
        guard settings.isEnabled else { return }
        captureFocusedWindow()
    }

    private func updateSettings(_ mutate: (inout PictureInPictureSettings) -> Void) {
        guard !isLoading else { return }
        mutate(&settings)
        for session in sessions.values { session.applyPresentationSettings(settings) }
        persist?()
    }

    private func synchronizeOcclusionSettings() {
        occlusionController.applySettings(
            enabledBundleIdentifiers: settings.occlusionFixBundleIdentifiers,
            autoApply: settings.occlusionAutoApply,
            customApplicationPaths: settings.occlusionCustomApplicationPaths
        )
    }

    private func startMediaPollingIfNeeded() {
        guard settings.mediaControls,
              !sessions.isEmpty,
              mediaRemote.isAvailable,
              mediaPollingTask == nil else { return }
        mediaPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshots = await self.mediaRemote.snapshots()
                guard !Task.isCancelled else { return }
                self.applyMediaSnapshots(snapshots)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopMediaPolling() {
        mediaPollingTask?.cancel()
        mediaPollingTask = nil
        for session in sessions.values { session.updateMediaSnapshot(nil) }
    }

    private func applyMediaSnapshots(_ snapshots: [PiPNowPlayingSnapshot]) {
        for session in sessions.values {
            session.updateMediaSnapshot(snapshots.first(where: { $0.belongs(to: session.source) }))
        }
    }

    private func refreshMediaSnapshotsSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.applyMediaSnapshots(await self.mediaRemote.snapshots())
        }
    }

    // MARK: Hotkeys and mouse tracking

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        hasAccessibilityPermission = AXIsProcessTrusted()
        if !installEventTapIfPossible() {
            installKeyboardFallbackMonitors()
        }
        updateMouseMonitoring()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processID = application.processIdentifier
            Task { @MainActor [weak self] in
                self?.handleSourceApplicationActivation(processID)
            }
        }
    }

    private func installKeyboardFallbackMonitors() {
        guard keyMonitor == nil else { return }
        let keyMask: NSEvent.EventTypeMask = [.keyDown]
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: keyMask) { [weak self] event in
            _ = self?.handleKeyEvent(PiPKeyInput(event), suppress: false)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.handleKeyEvent(PiPKeyInput(event), suppress: true) == true ? nil : event
        }
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleKeyUpEvent(PiPKeyInput(event))
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleKeyUpEvent(PiPKeyInput(event)) == true ? nil : event
        }
    }

    private func stopMonitoring() {
        isMonitoring = false
        removeKeyboardFallbackMonitors()
        stopMouseMonitoring()
        removeEventTap()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        removeFocusObservers()
        threeFingerGestureActive = false
    }

    private func removeKeyboardFallbackMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        if let localKeyUpMonitor { NSEvent.removeMonitor(localKeyUpMonitor) }
        keyMonitor = nil
        localKeyMonitor = nil
        keyUpMonitor = nil
        localKeyUpMonitor = nil
    }

    private func updateMouseMonitoring() {
        let isNeeded = isMonitoring && (settings.quickRegionCapture || !sessions.isEmpty)
        if isNeeded {
            startMouseMonitoring()
        } else {
            stopMouseMonitoring()
        }
    }

    private func startMouseMonitoring() {
        guard mouseMonitor == nil, localMouseMonitor == nil else { return }
        let mouseMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .otherMouseDown, .scrollWheel, .beginGesture, .endGesture
        ]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        threeFingerGestureActive = false
    }

    @discardableResult
    private func installEventTapIfPossible() -> Bool {
        if eventTap != nil { return true }
        guard isMonitoring, AXIsProcessTrusted() else { return false }
        let context = PiPEventTapContext(
            owner: Unmanaged.passUnretained(self).toOpaque(),
            triggerKeyCode: PiPTriggerKeyCode.value(for: settings.triggerKey) ?? 35,
            triggerModifierFlags: settings.triggerModifier.cgEventFlags
        )
        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: pictureInPictureEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        eventTapContext = context
        eventTap = tap
        eventTapSource = source
        context.setEventTap(tap)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTapSource = nil
        eventTap = nil
        eventTapContext = nil
    }

    fileprivate func handleEventTapTrigger(shift: Bool) {
        guard settings.isEnabled else { return }
        if shift {
            captureFocusedRegion()
        } else {
            captureFocusedWindow()
        }
    }

    fileprivate func handleKeyEvent(_ event: PiPKeyInput, suppress: Bool) -> Bool {
        let key = event.characters
        let flags = event.modifierFlags
        if settings.matchesTrigger(keyCode: CGKeyCode(event.keyCode), flags: flags) {
            if flags.contains(.shift) {
                captureFocusedRegion()
            } else {
                captureFocusedWindow()
            }
            return suppress
        }

        if event.keyCode == 53, quickLookPanel?.isVisible == true {
            hideQuickLook()
            return suppress
        }
        guard let session = sessionUnderMouse() else { return false }
        if event.keyCode == 51 || event.keyCode == 53 {
            session.close()
            return suppress
        }
        if key == "=" || key == "+" {
            session.changeZoom(by: 0.5)
            return suppress
        }
        if key == "-" || key == "_" {
            session.changeZoom(by: -0.5)
            return suppress
        }
        if flags.contains(.command), key == "c" {
            session.resetZoom()
            return suppress
        }
        // Synthetic/global events can have an empty character string even
        // though the physical Space key code is present. Pipiri treats both
        // representations as the same hold-to-preview action.
        if key == " " || event.keyCode == 49 {
            if flags.contains(.command) {
                session.sendKeyPress(49)
            } else {
                beginSpaceAction(for: session)
            }
            return suppress
        }
        if settings.mediaControls && settings.seekBar && (key == "h" || key == "l" || event.keyCode == 123 || event.keyCode == 124) {
            session.seekMedia(by: (key == "h" || event.keyCode == 123) ? -5 : 5)
            return suppress
        }
        let looksLikeYouTube = session.source.title.localizedCaseInsensitiveContains("youtube")
        if settings.youtubeCaptions && looksLikeYouTube && key == "c" {
            session.toggleYouTubeCaptions()
            return suppress
        }
        if key == "c" {
            session.toggleChangeDetection()
            return suppress
        }
        if key == "f" {
            let values = [1, 5, 10, 30, 60]
            let current = settings.frameRate(for: session.source.bundleIdentifier)
            let next = values.first(where: { $0 > current }) ?? values[0]
            setFrameRate(for: session.source.bundleIdentifier ?? session.source.appName, value: next)
            session.updateFrameRate(next)
            return suppress
        }
        if key == "d" {
            session.toggleIdleDetection()
            return suppress
        }
        if key == "s" {
            session.toggleSensitiveDetection()
            return suppress
        }
        return false
    }

    @discardableResult
    fileprivate func handleKeyUpEvent(_ event: PiPKeyInput) -> Bool {
        guard event.keyCode == 49 || event.characters == " " else { return false }
        let wasHandlingSpace = spaceSession != nil
        finishSpaceAction()
        return wasHandlingSpace
    }

    private func handleSourceApplicationActivation(_ processID: pid_t) {
        handleSourceWindowFocusChanged(processID)
    }

    fileprivate func handleSourceWindowFocusChanged(_ processID: pid_t) {
        guard settings.sourceFocusBehavior != .doNothing else { return }
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedWindowID = frontmostProcessID.flatMap(focusedWindowID(for:))
        for session in Array(sessions.values) {
            let sourceIsFocused = frontmostProcessID == session.source.processID
                && focusedWindowID == session.source.windowID
            if sourceIsFocused {
                switch settings.sourceFocusBehavior {
                case .doNothing: break
                case .hidePanel: session.hide(reason: .sourceFocused)
                case .closePanel: session.close()
                }
            } else if session.isHidden, session.hiddenReason == .sourceFocused {
                session.show()
            }
        }
    }

    private func focusedWindowID(for processID: pid_t) -> CGWindowID? {
        PiPWindowSelection.orderedCaptureWindowIDs(
            from: orderedWindowCandidates(for: processID)
        ).first
    }

    private func orderedWindowCandidates(for processID: pid_t) -> [PiPWindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }
        return windowInfo.compactMap { window in
            guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let number = (window[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return PiPWindowCandidate(windowID: CGWindowID(number), frame: frame)
        }
    }

    private func rebuildFocusObservers() {
        removeFocusObservers()
        guard settings.sourceFocusBehavior != .doNothing, AXIsProcessTrusted() else { return }
        for processID in Set(sessions.values.map { $0.source.processID }) where processID > 0 {
            var observer: AXObserver?
            guard AXObserverCreate(processID, pictureInPictureFocusedWindowCallback, &observer) == .success,
                  let observer else { continue }
            let application = AXUIElementCreateApplication(processID)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let focusedResult = AXObserverAddNotification(
                observer, application, kAXFocusedWindowChangedNotification as CFString, refcon
            )
            let mainResult = AXObserverAddNotification(
                observer, application, kAXMainWindowChangedNotification as CFString, refcon
            )
            guard focusedResult == .success || mainResult == .success else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            focusObservers[processID] = observer
        }
    }

    private func removeFocusObservers() {
        for observer in focusObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        focusObservers.removeAll()
    }

    private func handleMouseEvent(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        for session in sessions.values {
            let inside = session.panel?.frame.contains(location) == true
            if session.isHidden && session.hiddenReason == .hover && !inside { session.show() }
            if inside && !session.isHidden {
                session.setHovering(true)
            } else if !inside {
                session.setHovering(false)
            }
        }

        if event.type == .otherMouseDown,
           event.buttonNumber == 2,
           let session = sessionUnderMouse() {
            session.toggleHidden()
            return
        }

        if event.type == .beginGesture {
            let touchCount = event.touches(matching: .touching, in: nil).count
            if touchCount >= 3, !threeFingerGestureActive, let session = sessionUnderMouse() {
                threeFingerGestureActive = true
                session.toggleHidden()
            }
            return
        }
        if event.type == .endGesture {
            threeFingerGestureActive = false
            return
        }

        if event.type == .scrollWheel, let session = sessionUnderMouse() {
            let panelFrame = session.panel?.frame
            let mousePoint = panelFrame.map { frame in
                CGPoint(
                    x: location.x - frame.minX,
                    y: frame.maxY - location.y
                )
            }
            session.applyScrollWheel(
                deltaX: CGFloat(event.scrollingDeltaX),
                deltaY: CGFloat(event.scrollingDeltaY),
                commandPressed: event.modifierFlags.contains(.command),
                mousePoint: mousePoint,
                viewportSize: session.panel?.contentView?.bounds.size ?? panelFrame?.size
            )
            return
        }

        guard settings.quickRegionCapture,
              event.type == .leftMouseDown,
              event.clickCount >= 2,
              settings.triggerModifier.matches(event.modifierFlags, allowingShift: false),
              sessionUnderMouse() == nil else { return }
        captureQuickRegion(at: location)
    }

    private func sessionUnderMouse() -> PiPSession? {
        let location = NSEvent.mouseLocation
        return sessions.values.first(where: { $0.panel?.frame.contains(location) == true })
    }

    private func showQuickLook(for session: PiPSession) {
        guard let image = session.image else { return }
        let screen = PiPCoordinateSpace.screen(containingQuartz: session.source.frame) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 32, dy: 32)
        let aspect = max(0.25, min(4, session.source.frame.width * session.region.width / max(1, session.source.frame.height * session.region.height)))
        let maximumWidth = min(visible.width, max(480, session.source.frame.width * session.region.width))
        let maximumHeight = visible.height
        let width = min(maximumWidth, maximumHeight * aspect)
        let height = min(maximumHeight, width / aspect)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        let panel = quickLookPanel ?? PiPQuickLookPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.isOpaque = false
        panel.backgroundColor = .black
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.collectionBehavior = settings.showOnFullscreenSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: PiPQuickLookView(session: session, image: image))
        quickLookPanel = panel
        panel.orderFrontRegardless()
    }

    private func beginSpaceAction(for session: PiPSession) {
        guard spaceSession == nil else { return }
        spaceSession = session
        spaceQuickLookWasShown = false
        spaceQuickLookWasVisible = quickLookIsVisible(for: session)
        spaceTask?.cancel()
        spaceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let session = self.spaceSession else { return }
                if self.settings.quickLookWithSpace, !self.spaceQuickLookWasVisible {
                    self.spaceQuickLookWasShown = true
                    self.showQuickLook(for: session)
                }
            }
        }
    }

    private func finishSpaceAction() {
        guard let session = spaceSession else { return }
        spaceTask?.cancel()
        spaceTask = nil
        if spaceQuickLookWasShown {
            hideQuickLook()
        } else if settings.mediaControls && settings.spacePlayPause,
                  session.mediaSnapshot?.isPlaying == true {
            session.toggleMediaPlayback()
        } else if settings.quickLookWithSpace {
            if spaceQuickLookWasVisible {
                hideQuickLook()
            } else {
                showQuickLook(for: session)
            }
        }
        spaceSession = nil
        spaceQuickLookWasShown = false
        spaceQuickLookWasVisible = false
    }

    private func quickLookIsVisible(for session: PiPSession) -> Bool {
        guard quickLookPanel?.isVisible == true,
              let hostingView = quickLookPanel?.contentView as? NSHostingView<PiPQuickLookView> else {
            return false
        }
        return hostingView.rootView.session.id == session.id
    }

    private var quickLookSessionID: UUID? {
        (quickLookPanel?.contentView as? NSHostingView<PiPQuickLookView>)?.rootView.session.id
    }

    private func hideQuickLook() {
        quickLookPanel?.orderOut(nil)
        quickLookPanel?.contentView = nil
    }

    // MARK: Capture creation

    private func captureFocusedWindow() {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let source = try await self.focusedSource() else { throw PictureInPictureError.noFocusedWindow }
                _ = await MainActor.run { self.createSession(source: source, region: .fullWindow) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func captureFocusedRegion() {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let source = try await self.focusedSource() else { throw PictureInPictureError.noFocusedWindow }
                await MainActor.run { self.presentSelection(for: source) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func captureQuickRegion(at point: CGPoint) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let quartzPoint = PiPCoordinateSpace.quartzPoint(fromAppKit: point)
                guard let source = try await self.source(at: quartzPoint) else { throw PictureInPictureError.noFocusedWindow }
                let width = max(120, min(source.frame.width * 0.45, 520))
                let height = max(90, min(source.frame.height * 0.45, 360))
                let rect = CGRect(x: quartzPoint.x - width / 2, y: quartzPoint.y - height / 2, width: width, height: height)
                _ = await MainActor.run { self.createSession(source: source, region: PiPRegion.fromScreenRect(rect, in: source.frame) ?? .fullWindow) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func presentSelection(for source: PiPSource) {
        let panelFrame = PiPCoordinateSpace.appKitRect(fromQuartz: source.frame)
        let panel = PiPRegionSelectionPanel(frame: panelFrame) { [weak self] rect in
            guard let self else { return }
            self.selectionPanel = nil
            guard let rect, let region = PiPRegion.fromSelectionRect(rect, windowSize: source.frame.size) else { return }
            self.createSession(source: source, region: region)
        }
        selectionPanel = panel
        panel.orderFrontRegardless()
    }

    @discardableResult
    func createSession(source: PiPSource, region: PiPRegion) -> PiPSession? {
        guard hasScreenPermission || CGPreflightScreenCaptureAccess() else {
            errorMessage = PictureInPictureError.permissionRequired.localizedDescription
            return nil
        }
        hasScreenPermission = true
        errorMessage = nil
        if let existing = sessions.values.first(where: { $0.source.windowID == source.windowID }) {
            if existing.isHidden {
                existing.show()
            }
            existing.panel?.orderFrontRegardless()
            return existing
        }
        if !settings.multiWindowMode {
            let oldSessions = sessions.values.filter { $0.source.windowID != source.windowID }
            for session in oldSessions {
                session.close()
            }
        }
        let constrainedRegion = region.limited(aspectRatioLimit: settings.aspectRatioLimit)
        let session = PiPSession(source: source, region: constrainedRegion, settings: settings, owner: self)
        sessions[session.id] = session
        updateMouseMonitoring()
        rebuildFocusObservers()
        refreshSummaries()
        session.start()
        startMediaPollingIfNeeded()
        return session
    }

    private func handleLaunchArguments() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--app") || arguments.contains("--window") else { return }

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
            return arguments[arguments.index(after: index)]
        }

        let appQuery = value(after: "--app")
        let windowQuery = value(after: "--window")
        let zoomSpec = value(after: "--zoom")
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let matches = content.windows.filter { window in
                    guard window.isOnScreen, window.windowID != 0 else { return false }
                    let appMatches = appQuery.map { window.owningApplication?.applicationName.localizedCaseInsensitiveContains($0) == true } ?? true
                    let titleMatches = windowQuery.map { window.title?.localizedCaseInsensitiveContains($0) == true || String(window.windowID) == $0 } ?? true
                    return appMatches && titleMatches
                }
                guard let processID = matches.first?.owningApplication?.processID,
                      let window = preferredWindow(
                          from: matches.filter { $0.owningApplication?.processID == processID },
                          processID: processID
                      ) else { throw PictureInPictureError.noFocusedWindow }
                let source = source(from: window)
                await MainActor.run {
                    guard let session = self.createSession(source: source, region: .fullWindow) else { return }
                    guard let zoomSpec,
                          let separator = zoomSpec.firstIndex(of: ":"),
                          let factor = Double(zoomSpec[zoomSpec.index(after: separator)...].replacingOccurrences(of: "x", with: "")) else { return }
                    session.setZoomFactor(CGFloat(factor))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func focusedSource() async throws -> PiPSource? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid, pid != getpid() else { return nil }
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.isOnScreen && window.windowID != 0
        }
        guard let window = preferredWindow(from: candidates, processID: pid) else { return nil }
        return source(from: window)
    }

    private func preferredWindow(from candidates: [SCWindow], processID: pid_t) -> SCWindow? {
        let orderedWindowIDs = PiPWindowSelection.orderedCaptureWindowIDs(
            from: orderedWindowCandidates(for: processID)
        )
        if let window = orderedWindowIDs.lazy.compactMap({ windowID in
            candidates.first(where: { $0.windowID == windowID })
        }).first {
            return window
        }

        let plausible = candidates.filter { PiPWindowSelection.isPlausibleCaptureWindow($0.frame) }
        let titled = plausible.filter { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        return titled.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            ?? plausible.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private func source(at point: CGPoint) async throws -> PiPSource? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windowID = topWindowID(at: point)
        let window = content.windows.first(where: { $0.windowID == windowID })
            ?? content.windows.first(where: { $0.isOnScreen && $0.frame.contains(point) })
        guard let window else { return nil }
        return source(from: window)
    }

    private func source(from window: SCWindow) -> PiPSource {
        PiPSource(
            windowID: window.windowID,
            processID: window.owningApplication?.processID ?? 0,
            appName: window.owningApplication?.applicationName ?? "Window",
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            title: window.title ?? "",
            frame: window.frame
        )
    }

    private func topWindowID(at point: CGPoint) -> CGWindowID? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in infos {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point) else { continue }
            return number
        }
        return nil
    }

    private func refreshSummaries() {
        summaries = sessions.values.map {
            PiPSessionSummary(id: $0.id, appName: $0.source.appName, title: $0.source.title, region: $0.region, isIdle: $0.isIdle)
        }.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }
}

// MARK: - Settings UI

private enum PiPSettingsPage: String, CaseIterable, Identifiable {
    case general
    case window
    case panel
    case capture
    case media
    case detection
    case patches

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general: "pipGeneral"
        case .window: "pipWindowBehavior"
        case .panel: "pipPanelUI"
        case .capture: "pipCapture"
        case .media: "pipMedia"
        case .detection: "pipDetection"
        case .patches: "pipPatches"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .window: "macwindow"
        case .panel: "sparkles"
        case .capture: "record.circle"
        case .media: "play.rectangle"
        case .detection: "chart.line.uptrend.xyaxis"
        case .patches: "link"
        }
    }
}

struct PictureInPictureView: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @ObservedObject var pictureInPicture: PictureInPictureModel
    @State private var page: PiPSettingsPage = .general

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader
            categoryBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: page.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t(page.titleKey))
                                .font(.title2.bold())
                            Text(page == .general ? t("pictureInPictureSubtitle") : t("pictureInPicture"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(pictureInPicture.summaries.count) PiP")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                    pageContent
                }
                .frame(maxWidth: 940)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.025), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            )
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.purple.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .shadow(color: Color.accentColor.opacity(0.25), radius: 9, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(t("pictureInPicture"))
                    .font(.headline)
                Text(t("pictureInPictureSubtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(pictureInPicture.settings.isEnabled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(pictureInPicture.settings.isEnabled ? t("pipEnabledStatus") : t("pipDisabledStatus"))
                    .font(.caption.weight(.semibold))
                Toggle("", isOn: Binding(
                    get: { pictureInPicture.settings.isEnabled },
                    set: { pictureInPicture.setEnabled($0) }
                ))
                .labelsHidden()
                .controlSize(.mini)
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: Capsule())
            Button(t("pipCloseAll")) { pictureInPicture.closeAll() }
                .disabled(pictureInPicture.summaries.isEmpty)
            Button {
                pictureInPicture.captureFocusedWindowNow()
            } label: {
                Label(t("pipCaptureFocused"), systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!pictureInPicture.settings.isEnabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(PiPSettingsPage.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon)
                            Text(t(item.titleKey))
                                .lineLimit(1)
                        }
                        .font(.caption.weight(page == item ? .semibold : .medium))
                        .foregroundStyle(page == item ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            page == item ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            if page == item {
                                Capsule().strokeBorder(Color.accentColor.opacity(0.2))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: generalPage
        case .window: windowPage
        case .panel: panelPage
        case .capture: capturePage
        case .media: mediaPage
        case .detection: detectionPage
        case .patches: patchesPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                settingRow(
                    t("pipGlobalShortcut"),
                    hint: t("pipGlobalShortcutHint", pictureInPicture.settings.triggerShortcutDescription)
                ) {
                    HStack(spacing: 6) {
                        Picker(t("pipShortcutModifier"), selection: Binding(
                            get: { pictureInPicture.settings.triggerModifier },
                            set: { pictureInPicture.setTriggerModifier($0) }
                        )) {
                            ForEach(PiPShortcutModifier.allCases) { modifier in
                                Text("\(modifier.symbolDescription)  \(t(modifier.titleKey))")
                                    .tag(modifier)
                            }
                        }
                        .frame(width: 220)
                        TextField(t("pipShortcutKey"), text: Binding(
                            get: { pictureInPicture.settings.triggerKey.uppercased() },
                            set: { pictureInPicture.setTriggerKey($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                        Text(pictureInPicture.settings.triggerShortcutDescription)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Divider()
                Toggle(t("pipLaunchAtLogin"), isOn: Binding(
                    get: { appModel.launchesAtLogin },
                    set: { value in
                        if appModel.launchesAtLogin != value { appModel.setLaunchAtLogin(value) }
                        pictureInPicture.setLaunchAtLogin(appModel.launchesAtLogin)
                    }
                ))
            }

            card {
                Text(t("pipCheatSheet")).font(.headline)
                Text(t(
                    "pipCheatSheetBody",
                    pictureInPicture.settings.triggerShortcutDescription,
                    pictureInPicture.settings.triggerShortcutDescription,
                    pictureInPicture.settings.triggerModifier.symbolDescription
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pictureInPicture.hasScreenPermission {
                card {
                    Label(t("pipPermissionRequired"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(t("pipGrantPermission")) { pictureInPicture.requestScreenPermission() }
                        .buttonStyle(.bordered)
                }
            }

            if !pictureInPicture.hasAccessibilityPermission {
                card {
                    Label(t("pipAccessibilityRequired"), systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    HStack {
                        Button(t("pipGrantAccessibility")) { pictureInPicture.requestAccessibilityPermission() }
                            .buttonStyle(.bordered)
                        Button(t("pipOpenAccessibility")) { pictureInPicture.openAccessibilitySettings() }
                            .buttonStyle(.link)
                    }
                }
            }

            if let error = pictureInPicture.errorMessage {
                card {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            sessionsCard
        }
    }

    private var windowPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                pickerRow(t("pipPosition"), selection: Binding(
                    get: { pictureInPicture.settings.position },
                    set: { pictureInPicture.setPosition($0) }
                )) {
                    ForEach(PiPPanelPosition.allCases) { position in
                        Text(positionLabel(position)).tag(position)
                    }
                }
                Divider()
                Toggle(t("pipAutoHide"), isOn: Binding(
                    get: { pictureInPicture.settings.autoHideOnHover },
                    set: { pictureInPicture.setAutoHideOnHover($0) }
                ))
                Text(t("pipAutoHideHint")).font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(t("pipClickToFocus"), isOn: Binding(
                    get: { pictureInPicture.settings.clickToFocusSource },
                    set: { pictureInPicture.setClickToFocusSource($0) }
                ))
                Text(t("pipClickToFocusHint")).font(.caption).foregroundStyle(.secondary)
                Divider()
                pickerRow(t("pipSourceFocused"), selection: Binding(
                    get: { pictureInPicture.settings.sourceFocusBehavior },
                    set: { pictureInPicture.setSourceFocusBehavior($0) }
                )) {
                    ForEach(PiPSourceFocusBehavior.allCases) { behavior in
                        Text(sourceFocusLabel(behavior)).tag(behavior)
                    }
                }
                Divider()
                Toggle(t("pipFullscreenSpaces"), isOn: Binding(
                    get: { pictureInPicture.settings.showOnFullscreenSpaces },
                    set: { pictureInPicture.setShowOnFullscreenSpaces($0) }
                ))
            }
            card {
                Toggle(t("pipMultiWindow"), isOn: Binding(
                    get: { pictureInPicture.settings.multiWindowMode },
                    set: { pictureInPicture.setMultiWindowMode($0) }
                ))
                Text(t("pipMultiWindowHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var panelPage: some View {
        card {
            Toggle(t("pipShowHoverHints"), isOn: Binding(
                get: { pictureInPicture.settings.showHoverHints },
                set: { pictureInPicture.setShowHoverHints($0) }
            ))
            Toggle(t("pipDimOnHover"), isOn: Binding(
                get: { pictureInPicture.settings.dimOnHover },
                set: { pictureInPicture.setDimOnHover($0) }
            ))
            sliderRow(t("pipBlur"), value: Binding(
                get: { pictureInPicture.settings.blurAmount },
                set: { pictureInPicture.setBlurAmount($0) }
            ), range: 0...1, valueText: "\(Int(pictureInPicture.settings.blurAmount * 100))%")
            sliderRow(t("pipCornerRadius"), value: Binding(
                get: { pictureInPicture.settings.cornerRadius },
                set: { pictureInPicture.setCornerRadius($0) }
            ), range: 0...30, valueText: "\(Int(pictureInPicture.settings.cornerRadius))")
            Divider()
            Toggle(t("pipQuickLook"), isOn: Binding(
                get: { pictureInPicture.settings.quickLookWithSpace },
                set: { pictureInPicture.setQuickLookWithSpace($0) }
            ))
        }
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                sliderRow(t("pipFrameRate"), value: Binding(
                    get: { Double(pictureInPicture.settings.defaultFrameRate) },
                    set: { pictureInPicture.setDefaultFrameRate(Int($0.rounded())) }
                ), range: 1...60, valueText: "\(pictureInPicture.settings.defaultFrameRate) fps")
                Text(t("pipFrameRateHint")).font(.caption).foregroundStyle(.secondary)
                Divider()
                sliderRow(t("pipEnhanceContrast"), value: Binding(
                    get: { pictureInPicture.settings.enhanceContrast },
                    set: { pictureInPicture.setEnhanceContrast($0) }
                ), range: 0...1, valueText: "\(Int(pictureInPicture.settings.enhanceContrast * 100))%")
            }
            card {
                Toggle(t("pipQuickRegion", pictureInPicture.settings.triggerModifier.symbolDescription), isOn: Binding(
                    get: { pictureInPicture.settings.quickRegionCapture },
                    set: { pictureInPicture.setQuickRegionCapture($0) }
                ))
                sliderRow(t("pipAspectLimit"), value: Binding(
                    get: { pictureInPicture.settings.aspectRatioLimit },
                    set: { pictureInPicture.setAspectRatioLimit($0) }
                ), range: 1...12, valueText: String(format: "%.1f:1", pictureInPicture.settings.aspectRatioLimit))
            }
        }
    }

    private var mediaPage: some View {
        card {
            Toggle(t("pipMediaControls"), isOn: Binding(
                get: { pictureInPicture.settings.mediaControls },
                set: { pictureInPicture.setMediaControls($0) }
            ))
            Divider()
            Toggle(t("pipSeekBar"), isOn: Binding(
                get: { pictureInPicture.settings.seekBar },
                set: { pictureInPicture.setSeekBar($0) }
            ))
            Toggle(t("pipSpacePlayPause"), isOn: Binding(
                get: { pictureInPicture.settings.spacePlayPause },
                set: { pictureInPicture.setSpacePlayPause($0) }
            ))
            Toggle(t("pipYoutubeCaptions"), isOn: Binding(
                get: { pictureInPicture.settings.youtubeCaptions },
                set: { pictureInPicture.setYoutubeCaptions($0) }
            ))
        }
    }

    private var detectionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                sliderRow(t("pipDetectionThreshold"), value: Binding(
                    get: { Double(pictureInPicture.settings.detectionThresholdSeconds) },
                    set: { pictureInPicture.setDetectionThresholdSeconds(Int($0.rounded())) }
                ), range: 1...60, valueText: "\(pictureInPicture.settings.detectionThresholdSeconds)s")
                Toggle(t("pipSensitiveDetection"), isOn: Binding(
                    get: { pictureInPicture.settings.sensitiveDetection },
                    set: { pictureInPicture.setSensitiveDetection($0) }
                ))
            }
            card {
                Text(t("pipDetectionScript")).font(.headline)
                TextEditor(text: Binding(
                    get: { pictureInPicture.settings.detectionScript },
                    set: { pictureInPicture.setDetectionScript($0) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .padding(5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Text(t("pipDetectionScriptHint")).font(.caption).foregroundStyle(.secondary)
                sliderRow(t("pipScriptTimeout"), value: Binding(
                    get: { Double(pictureInPicture.settings.detectionScriptTimeoutSeconds) },
                    set: { pictureInPicture.setDetectionScriptTimeoutSeconds(Int($0.rounded())) }
                ), range: 1...60, valueText: "\(pictureInPicture.settings.detectionScriptTimeoutSeconds)s")
            }
        }
    }

    private var patchesPage: some View {
        PiPOcclusionSettingsView(
            controller: pictureInPicture.occlusionController,
            language: appModel.language,
            autoApply: pictureInPicture.settings.occlusionAutoApply,
            setEnabled: { bundleIdentifier, enabled in
                pictureInPicture.setOcclusionFixEnabled(enabled, for: bundleIdentifier)
            },
            setAutoApply: pictureInPicture.setOcclusionAutoApply,
            addCustomApplication: pictureInPicture.addCustomOcclusionApplication,
            removeCustomApplication: pictureInPicture.removeCustomOcclusionApplication
        )
    }

    private var sessionsCard: some View {
        card {
            Text(t("pipCreate")).font(.headline)
            if pictureInPicture.summaries.isEmpty {
                Label(t("pipNoSessions"), systemImage: "pip.enter")
                    .foregroundStyle(.secondary)
                Text(t("pipNoSessionsDetail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pictureInPicture.summaries) { summary in
                    HStack(spacing: 10) {
                        Image(systemName: "pip.enter")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.appName).font(.subheadline.weight(.medium))
                            Text(summary.title.isEmpty ? "Window" : summary.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if summary.isIdle { Image(systemName: "moon.zzz.fill").foregroundStyle(.green) }
                        Button { pictureInPicture.closeSession(id: summary.id) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    if summary.id != pictureInPicture.summaries.last?.id { Divider() }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07))
            )
            .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
    }

    private func settingRow<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder control: () -> Content) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            control()
        }
    }

    private func pickerRow<Value: Hashable, Content: View>(_ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) -> some View where Content: View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(minWidth: 130)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func positionLabel(_ position: PiPPanelPosition) -> String {
        switch position {
        case .topLeft: t("pipPositionTopLeft")
        case .topRight: t("pipPositionTopRight")
        case .bottomLeft: t("pipPositionBottomLeft")
        case .bottomRight: t("pipPositionBottomRight")
        }
    }

    private func sourceFocusLabel(_ behavior: PiPSourceFocusBehavior) -> String {
        switch behavior {
        case .doNothing: t("pipDoNothing")
        case .hidePanel: t("pipHidePanel")
        case .closePanel: t("pipClosePanel")
        }
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: appModel.language, arguments: arguments)
    }
}

private struct PiPOcclusionSettingsView: View {
    @ObservedObject var controller: PiPOcclusionController
    let language: AppLanguage
    let autoApply: Bool
    let setEnabled: (String, Bool) -> Void
    let setAutoApply: (Bool) -> Void
    let addCustomApplication: (URL) -> Void
    let removeCustomApplication: (String) -> Void
    @State private var confirmation: PatchConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Label(t("pipPatchesTitle"), systemImage: "rectangle.on.rectangle.badge.gearshape")
                    .font(.headline)
                Text(t("pipPatchesBody"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                if controller.applications.isEmpty {
                    Label(t("pipPatchesNoApps"), systemImage: "app.dashed")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.applications) { application in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
                                .resizable()
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(application.isRunning ? t("pipPatchRunning") : application.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if application.isRunning && application.isEnabled {
                                Button(t("pipPatchRelaunch")) { controller.relaunch(application) }
                                    .controlSize(.small)
                                    .disabled(controller.busyBundleIdentifiers.contains(application.bundleIdentifier))
                            }
                            if controller.busyBundleIdentifiers.contains(application.bundleIdentifier) {
                                ProgressView().controlSize(.small)
                            }
                            Toggle("", isOn: Binding(
                                get: { application.isEnabled },
                                set: { setEnabled(application.bundleIdentifier, $0) }
                            ))
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                }

                Divider()
                Toggle(t("pipPatchAutoApply"), isOn: Binding(
                    get: { autoApply },
                    set: { value in setAutoApply(value) }
                ))
                Text(t("pipPatchAutoApplyHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            card {
                Label(t("pipCustomPatchTitle"), systemImage: "shippingbox.and.arrow.backward")
                    .font(.headline)
                Text(t("pipCustomPatchBody"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.customApplications.isEmpty {
                    Label(t("pipCustomPatchNoApps"), systemImage: "app.dashed")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.customApplications) { application in
                        Divider()
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
                                .resizable()
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.displayName).font(.subheadline.weight(.medium))
                                Text(customPatchStatus(application))
                                    .font(.caption)
                                    .foregroundStyle(application.isPatched ? .green : .secondary)
                            }
                            Spacer()
                            if application.isPatched {
                                Button(t("pipPatchRestore")) {
                                    confirmation = PatchConfirmation(kind: .restore, application: application)
                                }
                                .controlSize(.small)
                                .disabled(application.isRunning || controller.busyBundleIdentifiers.contains(application.id))
                            } else {
                                Button(t("pipPatchInstall")) {
                                    confirmation = PatchConfirmation(kind: .install, application: application)
                                }
                                .controlSize(.small)
                                .disabled(application.isRunning || controller.busyBundleIdentifiers.contains(application.id))
                            }
                            if controller.busyBundleIdentifiers.contains(application.id) {
                                ProgressView().controlSize(.small)
                            }
                            if application.isUserSelected {
                                Button {
                                    removeCustomApplication(application.bundleIdentifier)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .disabled(application.isPatched || application.hasBackup)
                                .help(t("pipPatchRemoveCustom"))
                            }
                            Toggle("", isOn: Binding(
                                get: { application.isEnabled },
                                set: { setEnabled(application.bundleIdentifier, $0) }
                            ))
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                }
                Button(t("pipPatchAnotherApp")) { chooseCustomApplication() }
                Text(t("pipCustomPatchWarning"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.errorMessage {
                card {
                    Label(t("pipPatchFailed"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error).font(.caption).textSelection(.enabled)
                    Button(t("dismiss")) { controller.clearError() }
                }
            }

            card {
                Text(t("pipPatchDetails")).font(.headline)
                Text(t("pipPatchDetailsBody"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PiPOcclusionController.renderingArgument)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .onAppear { controller.refresh() }
        .alert(
            confirmation?.kind == .install ? t("pipPatchConfirmTitle") : t("pipRestoreConfirmTitle"),
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { confirmation in
            Button(t("cancel"), role: .cancel) {}
            Button(
                confirmation.kind == .install ? t("pipPatchInstall") : t("pipPatchRestore"),
                role: .destructive
            ) {
                if confirmation.kind == .install {
                    setEnabled(confirmation.application.bundleIdentifier, true)
                    controller.patch(confirmation.application)
                } else {
                    setEnabled(confirmation.application.bundleIdentifier, false)
                    controller.restore(confirmation.application)
                }
            }
        } message: { confirmation in
            Text(confirmation.kind == .install
                ? t("pipPatchConfirmBody")
                : t("pipRestoreConfirmBody"))
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func t(_ key: String) -> String {
        AppText.value(key, language: language)
    }

    private func customPatchStatus(_ application: PiPCustomPatchApplication) -> String {
        if application.isRunning { return t("pipPatchQuitFirst") }
        if application.isPatched { return t("pipPatchInstalled") }
        if application.hasBackup { return t("pipPatchUpdateDetected") }
        return application.bundleIdentifier
    }

    private func chooseCustomApplication() {
        let panel = NSOpenPanel()
        panel.title = t("pipPatchAnotherApp")
        panel.prompt = t("choose")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { addCustomApplication(url) }
    }

    private struct PatchConfirmation: Identifiable {
        enum Kind { case install, restore }
        let kind: Kind
        let application: PiPCustomPatchApplication
        var id: String { "\(kind)-\(application.bundleIdentifier)" }
    }
}
