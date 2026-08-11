// WindowSwitcher.swift
//
// An independent window switcher for MacPilot. The interaction model is
// inspired by the user-facing behavior of alt-tab-macos, but this module does
// not copy or link GPL-3.0 source code. Window discovery uses public macOS
// Accessibility and WindowServer APIs.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import SwiftUI

// MARK: - Configuration and pure selection rules

struct WindowSwitcherSettings: Codable, Equatable, Sendable {
    var isEnabled = true
    var includeMinimizedWindows = true
    var includeHiddenApplications = false
    var showThumbnails = true
    var showWindowTitles = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        includeMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .includeMinimizedWindows) ?? true
        includeHiddenApplications = try container.decodeIfPresent(Bool.self, forKey: .includeHiddenApplications) ?? false
        showThumbnails = try container.decodeIfPresent(Bool.self, forKey: .showThumbnails) ?? true
        showWindowTitles = try container.decodeIfPresent(Bool.self, forKey: .showWindowTitles) ?? true
    }
}

enum WindowSwitcherSelection {
    static func initialIndex(count: Int, currentIndex: Int?, reverse: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        let current = currentIndex ?? (reverse ? 0 : -1)
        let offset = reverse ? -1 : 1
        return wrappedIndex(current + offset, count: count)
    }

    static func cycledIndex(current: Int, count: Int, offset: Int) -> Int? {
        guard count > 0 else { return nil }
        return wrappedIndex(current + offset, count: count)
    }

    private static func wrappedIndex(_ index: Int, count: Int) -> Int {
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }
}

enum WindowSwitcherOrdering {
    static func orderedIndices(
        processIDs: [pid_t],
        frontmostProcessID: pid_t?,
        recentProcessIDs: [pid_t]
    ) -> [Int] {
        let recentOrder = Dictionary(uniqueKeysWithValues: recentProcessIDs.enumerated().map { ($1, $0) })
        return processIDs.indices.sorted { lhs, rhs in
            let lhsPID = processIDs[lhs]
            let rhsPID = processIDs[rhs]
            if lhsPID == rhsPID { return lhs < rhs }
            if lhsPID == frontmostProcessID { return true }
            if rhsPID == frontmostProcessID { return false }
            let lhsOrder = recentOrder[lhsPID] ?? Int.max
            let rhsOrder = recentOrder[rhsPID] ?? Int.max
            return lhsOrder == rhsOrder ? lhs < rhs : lhsOrder < rhsOrder
        }
    }
}

enum WindowSwitcherThumbnailPriority {
    static func orderedIndices(count: Int, selectedIndex: Int) -> [Int] {
        guard count > 0 else { return [] }
        let selected = min(max(selectedIndex, 0), count - 1)
        var result = [selected]
        for distance in 1..<count {
            let forward = (selected + distance) % count
            if !result.contains(forward) { result.append(forward) }
            let backward = (selected - distance + count) % count
            if !result.contains(backward) { result.append(backward) }
        }
        return result
    }
}

final class WindowSwitcherItem: ObservableObject, Identifiable, @unchecked Sendable {
    let id: String
    let windowID: CGWindowID?
    let processID: pid_t
    let appName: String
    let bundleIdentifier: String?
    let title: String
    let icon: NSImage
    @Published private(set) var preview: NSImage?
    let axWindow: AXUIElement?
    let isMinimized: Bool
    let isHidden: Bool
    let canCapturePreview: Bool

    init(
        id: String,
        windowID: CGWindowID?,
        processID: pid_t,
        appName: String,
        bundleIdentifier: String?,
        title: String,
        icon: NSImage,
        preview: NSImage?,
        axWindow: AXUIElement?,
        isMinimized: Bool,
        isHidden: Bool,
        canCapturePreview: Bool
    ) {
        self.id = id
        self.windowID = windowID
        self.processID = processID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.icon = icon
        self.preview = preview
        self.axWindow = axWindow
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.canCapturePreview = canCapturePreview
    }

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    func updatePreview(_ preview: NSImage?) {
        self.preview = preview
    }
}

private struct WindowSwitcherServerRecord {
    let windowID: CGWindowID
    let processID: pid_t
    let title: String
    let frame: CGRect
    let order: Int
    let isOnScreen: Bool
}

private struct WindowSwitcherAXAttributes {
    let role: String?
    let title: String
    let isMinimized: Bool
    let frame: CGRect?
}

private enum WindowSwitcherInventory {
    static func snapshot(
        settings: WindowSwitcherSettings,
        frontmostProcessID: pid_t?,
        recentProcessIDs: [pid_t]
    ) -> [WindowSwitcherItem] {
        let serverRecords = windowServerRecords()
        let recordsByProcess = Dictionary(grouping: serverRecords, by: \.processID)
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            guard application.processIdentifier != getpid(), !application.isTerminated else { return false }
            guard application.activationPolicy == .regular || application.activationPolicy == .accessory else { return false }
            if application.isHidden && !settings.includeHiddenApplications { return false }
            return true
        }

        let recentOrder = Dictionary(uniqueKeysWithValues: recentProcessIDs.enumerated().map { ($1, $0) })
        let orderedApplications = applications.sorted { lhs, rhs in
            let lhsPID = lhs.processIdentifier
            let rhsPID = rhs.processIdentifier
            if lhsPID == frontmostProcessID { return true }
            if rhsPID == frontmostProcessID { return false }
            let lhsOrder = recentOrder[lhsPID] ?? Int.max
            let rhsOrder = recentOrder[rhsPID] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? "") == .orderedAscending
        }

        var result: [WindowSwitcherItem] = []
        for application in orderedApplications {
            let processID = application.processIdentifier
            let records = recordsByProcess[processID] ?? []
            let icon = applicationIcon(for: application)
            let appElement = AXUIElementCreateApplication(processID)
            // Keep one unresponsive application from delaying the whole cache.
            // WindowServer records still provide a useful fallback tile.
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            var windowsValue: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            )
            let axWindows = axResult == .success ? (windowsValue as? [AXUIElement] ?? []) : []
            var usedWindowIDs = Set<CGWindowID>()
            var appItems: [WindowSwitcherItem] = []

            for (index, axWindow) in axWindows.enumerated() {
                let attributes = windowAttributes(of: axWindow)
                guard attributes.role == kAXWindowRole as String else { continue }
                let title = attributes.title
                let minimized = attributes.isMinimized
                if minimized && !settings.includeMinimizedWindows { continue }

                let frame = attributes.frame
                let record = matchingRecord(
                    title: title,
                    frame: frame,
                    records: records,
                    usedWindowIDs: usedWindowIDs
                )
                if let record { usedWindowIDs.insert(record.windowID) }

                let resolvedTitle = title.isEmpty ? (record?.title ?? "") : title
                guard frame.map({ $0.width >= 2 && $0.height >= 2 }) ?? true else { continue }
                appItems.append(makeItem(
                    application: application,
                    axWindow: axWindow,
                    serverRecord: record,
                    fallbackTitle: resolvedTitle,
                    index: index,
                    icon: icon,
                    minimized: minimized
                ))
            }

            // A few applications expose WindowServer windows but fail their AX
            // window query. Keeping those visible still lets the user activate
            // the owning application, which is better than silently dropping it.
            if appItems.isEmpty {
                for (index, record) in records.enumerated() where record.isOnScreen {
                    appItems.append(makeItem(
                        application: application,
                        axWindow: nil,
                        serverRecord: record,
                        fallbackTitle: record.title,
                        index: index,
                        icon: icon,
                        minimized: false
                    ))
                }
            }

            let recordOrder = Dictionary(uniqueKeysWithValues: records.map { ($0.windowID, $0.order) })
            result.append(contentsOf: appItems.sorted { lhs, rhs in
                let lhsOrder = lhs.windowID.flatMap { recordOrder[$0] } ?? Int.max
                let rhsOrder = rhs.windowID.flatMap { recordOrder[$0] } ?? Int.max
                return lhsOrder == rhsOrder ? lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending : lhsOrder < rhsOrder
            })
        }

        return result
    }

    static func windowServerSignature() -> Int {
        var hasher = Hasher()
        for record in windowServerRecords() {
            hasher.combine(record.windowID)
            hasher.combine(record.processID)
            hasher.combine(record.title)
            hasher.combine(record.isOnScreen)
            hasher.combine(Int(record.frame.origin.x.rounded()))
            hasher.combine(Int(record.frame.origin.y.rounded()))
            hasher.combine(Int(record.frame.width.rounded()))
            hasher.combine(Int(record.frame.height.rounded()))
        }
        return hasher.finalize()
    }

    private static func makeItem(
        application: NSRunningApplication,
        axWindow: AXUIElement?,
        serverRecord: WindowSwitcherServerRecord?,
        fallbackTitle: String,
        index: Int,
        icon: NSImage,
        minimized: Bool
    ) -> WindowSwitcherItem {
        let processID = application.processIdentifier
        let appName = application.localizedName ?? application.bundleIdentifier ?? "Application"
        let bundleIdentifier = application.bundleIdentifier
        let windowID = serverRecord?.windowID
        let stableID: String
        if let windowID {
            stableID = "window-\(windowID)"
        } else {
            stableID = "ax-\(processID)-\(index)-\(fallbackTitle)"
        }
        return WindowSwitcherItem(
            id: stableID,
            windowID: windowID,
            processID: processID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: fallbackTitle,
            icon: icon,
            preview: nil,
            axWindow: axWindow,
            isMinimized: minimized,
            isHidden: application.isHidden,
            canCapturePreview: serverRecord?.isOnScreen == true
        )
    }

    private static func applicationIcon(for application: NSRunningApplication) -> NSImage {
        application.icon
            ?? (application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) })
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
    }

    private static func windowServerRecords() -> [WindowSwitcherServerRecord] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return infos.enumerated().compactMap { order, info in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let processID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processID > 0,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 2,
                  frame.height >= 2 else { return nil }
            let title = info[kCGWindowName as String] as? String ?? ""
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return WindowSwitcherServerRecord(
                windowID: CGWindowID(number),
                processID: processID,
                title: title,
                frame: frame,
                order: order,
                isOnScreen: isOnScreen
            )
        }
    }

    private static func matchingRecord(
        title: String,
        frame: CGRect?,
        records: [WindowSwitcherServerRecord],
        usedWindowIDs: Set<CGWindowID>
    ) -> WindowSwitcherServerRecord? {
        let available = records.filter { !usedWindowIDs.contains($0.windowID) }
        if !title.isEmpty, let exact = available.first(where: { $0.title == title }) { return exact }
        guard let frame else { return available.first }
        return available.min { lhs, rhs in
            frameDistance(frame, lhs.frame) < frameDistance(frame, rhs.frame)
        }
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private static func windowAttributes(of element: AXUIElement) -> WindowSwitcherAXAttributes {
        let keys = [
            kAXRoleAttribute,
            kAXTitleAttribute,
            kAXMinimizedAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute
        ]
        var values: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values) == .success,
           let values = values as? [CFTypeRef], values.count == keys.count {
            let position = pointValue(values[3])
            let size = sizeValue(values[4])
            return WindowSwitcherAXAttributes(
                role: values[0] as? String,
                title: values[1] as? String ?? "",
                isMinimized: (values[2] as? NSNumber)?.boolValue ?? false,
                frame: position.flatMap { position in size.map { CGRect(origin: position, size: $0) } }
            )
        }
        return WindowSwitcherAXAttributes(
            role: stringAttribute(kAXRoleAttribute, from: element),
            title: stringAttribute(kAXTitleAttribute, from: element) ?? "",
            isMinimized: boolAttribute(kAXMinimizedAttribute, from: element),
            frame: frame(of: element)
        )
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func pointValue(_ value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

}

private struct WindowSwitcherCapturedPreview: @unchecked Sendable {
    let image: CGImage
}

private enum WindowSwitcherPreviewCapture {
    private typealias CaptureFunction = @convention(c) (
        CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
    ) -> CGImage?

    // Keep the framework handle and symbol for the process lifetime. Resolving
    // both for every tile was measurable work on the shortcut's hot path.
    private static let captureFunction: CaptureFunction? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CaptureFunction.self)
    }()

    static func capture(windowID: CGWindowID, maximumPixelSize: CGSize) -> WindowSwitcherCapturedPreview? {
        guard let captureFunction,
              let source = captureFunction(
                .null,
                .optionIncludingWindow,
                windowID,
                [.nominalResolution, .boundsIgnoreFraming]
              ) else { return nil }
        return WindowSwitcherCapturedPreview(image: downscaled(source, maximumPixelSize: maximumPixelSize))
    }

    private static func downscaled(_ source: CGImage, maximumPixelSize: CGSize) -> CGImage {
        let sourceSize = CGSize(width: source.width, height: source.height)
        let scale = min(
            1,
            maximumPixelSize.width / max(sourceSize.width, 1),
            maximumPixelSize.height / max(sourceSize.height, 1)
        )
        guard scale < 1 else { return source }
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? source
    }
}

// MARK: - Global shortcut event tap

final class WindowSwitcherEventTapContext: @unchecked Sendable {
    let owner: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var eventTap: CFMachPort?

    init(owner: UnsafeMutableRawPointer) {
        self.owner = owner
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

private func windowSwitcherEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent?,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return event.map(Unmanaged.passUnretained) }
    let context = Unmanaged<WindowSwitcherEventTapContext>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        context.reenableEventTap()
        return event.map(Unmanaged.passUnretained)
    }
    guard let event else { return nil }

    let typeRawValue = type.rawValue
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flagsRawValue = event.flags.rawValue
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let owner = Unmanaged<WindowSwitcherModel>.fromOpaque(context.owner).takeUnretainedValue()
    guard Thread.isMainThread else {
        Task { @MainActor in
            _ = owner.handleEventTapEvent(
                typeRawValue: typeRawValue,
                keyCode: keyCode,
                flagsRawValue: flagsRawValue,
                isAutorepeat: isAutorepeat
            )
        }
        return Unmanaged.passUnretained(event)
    }
    let handled = MainActor.assumeIsolated {
        owner.handleEventTapEvent(
            typeRawValue: typeRawValue,
            keyCode: keyCode,
            flagsRawValue: flagsRawValue,
            isAutorepeat: isAutorepeat
        )
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Runtime model

private struct WindowSwitcherPendingSession {
    var reverse: Bool
    var manual: Bool
    var additionalSelectionOffset = 0
    var commitWhenReady = false
    var startedAt = CFAbsoluteTimeGetCurrent()
}

private struct WindowSwitcherInventoryRefresh: Sendable {
    let snapshot: [WindowSwitcherItem]?
    let signature: Int
}

@MainActor
final class WindowSwitcherModel: ObservableObject {
    private static let performanceLogger = Logger(
        subsystem: "com.misswell.macpilot",
        category: "WindowSwitcherPerformance"
    )

    @Published private(set) var settings = WindowSwitcherSettings()
    private(set) var windows: [WindowSwitcherItem] = []
    private(set) var selectedIndex = 0
    private(set) var isShowing = false
    @Published private(set) var hasAccessibilityPermission = false

    var language: AppLanguage = .system
    var persist: (() -> Void)?

    private var isActive = false
    private var isManualSession = false
    private var tabIsDown = false
    private var consumeTabKeyUp = false
    private var consumeEscapeKeyUp = false
    private var recentProcessIDs: [pid_t] = []
    private var cachedWindows: [WindowSwitcherItem] = []
    private var inventoryTask: Task<Void, Never>?
    private var inventoryRevision = 0
    private var inventorySignature: Int?
    private var pendingSession: WindowSwitcherPendingSession?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailCache: [CGWindowID: NSImage] = [:]
    private var thumbnailCacheOrder: [CGWindowID] = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapContext: WindowSwitcherEventTapContext?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var manualDismissTask: Task<Void, Never>?
    private var panelController: WindowSwitcherPanelController?

    init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        noteApplicationActivation(NSWorkspace.shared.frontmostApplication)
    }

    func applyLoadedSettings(_ settings: WindowSwitcherSettings) {
        self.settings = settings
        cachedWindows = []
        if isActive {
            refreshEventTap()
            requestInventoryRefresh(priority: .utility)
        }
    }

    func activateFromConfiguration() {
        guard !isActive else { return }
        isActive = true
        panelController = WindowSwitcherPanelController(model: self)
        panelController?.prepare()
        installWorkspaceObserver()
        refreshEventTap()
        requestInventoryRefresh(priority: .utility)
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            refreshEventTap()
            requestInventoryRefresh(priority: .userInitiated)
        } else {
            cancelSession()
            cancelPendingSession()
            removeEventTap()
        }
        persist?()
    }

    func setIncludeMinimizedWindows(_ enabled: Bool) {
        settings.includeMinimizedWindows = enabled
        cachedWindows = []
        requestInventoryRefresh(priority: .utility)
        persist?()
    }

    func setIncludeHiddenApplications(_ enabled: Bool) {
        settings.includeHiddenApplications = enabled
        cachedWindows = []
        requestInventoryRefresh(priority: .utility)
        persist?()
    }

    func setShowThumbnails(_ enabled: Bool) {
        settings.showThumbnails = enabled
        if enabled {
            applyCachedPreviews(to: cachedWindows)
            prewarmThumbnails()
        } else {
            thumbnailTask?.cancel()
            cachedWindows.forEach { $0.updatePreview(nil) }
            windows.forEach { $0.updatePreview(nil) }
        }
        persist?()
    }

    func setShowWindowTitles(_ enabled: Bool) {
        settings.showWindowTitles = enabled
        persist?()
    }

    func requestAccessibility() {
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        refreshEventTap()
        if hasAccessibilityPermission { requestInventoryRefresh(priority: .userInitiated) }
    }

    func refreshPermissionStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        refreshEventTap()
        if hasAccessibilityPermission { requestInventoryRefresh(priority: .utility) }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func showSwitcherNow() {
        guard settings.isEnabled else { return }
        _ = beginSession(reverse: false, manual: true)
    }

    func select(index: Int) {
        guard windows.indices.contains(index) else { return }
        guard selectedIndex != index else { return }
        objectWillChange.send()
        selectedIndex = index
    }

    func commitSelection(at index: Int? = nil) {
        guard isShowing else { return }
        if let index, windows.indices.contains(index), selectedIndex != index {
            selectedIndex = index
        }
        finishSession(commit: true)
    }

    func cancelSelection() {
        guard isShowing else { return }
        finishSession(commit: false)
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    fileprivate func handleEventTapEvent(
        typeRawValue: CGEventType.RawValue,
        keyCode: Int64,
        flagsRawValue: CGEventFlags.RawValue,
        isAutorepeat: Bool
    ) -> Bool {
        guard let type = CGEventType(rawValue: typeRawValue) else { return false }
        let flags = CGEventFlags(rawValue: flagsRawValue)
        switch type {
        case .keyDown:
            if keyCode == 53 { // Escape
                guard isShowing || pendingSession != nil else { return false }
                consumeEscapeKeyUp = true
                if isShowing { cancelSelection() } else { cancelPendingSession() }
                return true
            }
            guard keyCode == 48 else { return false } // Tab
            let optionPressed = flags.contains(.maskAlternate)
            let reverse = flags.contains(.maskShift)
            if isShowing {
                cycleSelection(reverse: reverse)
                tabIsDown = true
                return true
            }
            if pendingSession != nil {
                pendingSession?.additionalSelectionOffset += reverse ? -1 : 1
                tabIsDown = true
                return true
            }
            guard settings.isEnabled,
                  optionPressed,
                  !flags.contains(.maskCommand),
                  !flags.contains(.maskControl) else { return false }
            guard beginSession(reverse: reverse, manual: false) else { return false }
            tabIsDown = true
            return true

        case .keyUp:
            if keyCode == 48, isShowing || pendingSession != nil || consumeTabKeyUp {
                tabIsDown = false
                consumeTabKeyUp = false
                return true
            }
            if keyCode == 53, consumeEscapeKeyUp {
                consumeEscapeKeyUp = false
                return true
            }
            return false

        case .flagsChanged:
            if pendingSession != nil,
               pendingSession?.manual == false,
               !flags.contains(.maskAlternate) {
                consumeTabKeyUp = tabIsDown
                tabIsDown = false
                pendingSession?.commitWhenReady = true
                return true
            }
            guard isShowing, !isManualSession, !flags.contains(.maskAlternate) else { return false }
            consumeTabKeyUp = tabIsDown
            tabIsDown = false
            finishSession(commit: true)
            return true

        default:
            return false
        }
    }

    private func beginSession(reverse: Bool, manual: Bool) -> Bool {
        guard !isShowing else { return true }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = orderedForSession(cachedWindows, frontmostProcessID: frontmost)
        guard !snapshot.isEmpty else {
            pendingSession = WindowSwitcherPendingSession(
                reverse: reverse,
                manual: manual,
                startedAt: startedAt
            )
            requestInventoryRefresh(priority: .userInitiated)
            return true
        }
        showSession(
            snapshot,
            reverse: reverse,
            manual: manual,
            additionalSelectionOffset: 0,
            startedAt: startedAt,
            cacheHit: true
        )
        requestInventoryRefresh(priority: .utility)
        return true
    }

    private func showSession(
        _ snapshot: [WindowSwitcherItem],
        reverse: Bool,
        manual: Bool,
        additionalSelectionOffset: Int,
        startedAt: CFAbsoluteTime,
        cacheHit: Bool
    ) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentIndex = snapshot.firstIndex { $0.processID == frontmost }
        let initialIndex = WindowSwitcherSelection.initialIndex(
            count: snapshot.count,
            currentIndex: currentIndex,
            reverse: reverse
        ) ?? 0
        let resolvedIndex = WindowSwitcherSelection.cycledIndex(
            current: initialIndex,
            count: snapshot.count,
            offset: additionalSelectionOffset
        ) ?? initialIndex
        objectWillChange.send()
        windows = snapshot
        selectedIndex = resolvedIndex
        isManualSession = manual
        isShowing = true
        panelController = panelController ?? WindowSwitcherPanelController(model: self)
        panelController?.show()
        reportPresentationLatency(startedAt: startedAt, cacheHit: cacheHit)
        refreshThumbnails(for: snapshot, selectedIndex: selectedIndex, maximumCount: nil, requireShowing: true)
        if manual {
            manualDismissTask?.cancel()
            manualDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.isShowing, self.isManualSession else { return }
                self.finishSession(commit: false)
            }
        }
    }

    private func cycleSelection(reverse: Bool) {
        guard let next = WindowSwitcherSelection.cycledIndex(
            current: selectedIndex,
            count: windows.count,
            offset: reverse ? -1 : 1
        ) else { return }
        objectWillChange.send()
        selectedIndex = next
    }

    private func finishSession(commit: Bool) {
        manualDismissTask?.cancel()
        manualDismissTask = nil
        let selected = windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
        isShowing = false
        isManualSession = false
        panelController?.hide()
        thumbnailTask?.cancel()
        if commit, let selected {
            focus(selected)
        }
        requestInventoryRefresh(priority: .utility)
    }

    private func cancelSession() {
        guard isShowing else { return }
        finishSession(commit: false)
    }

    private func cancelPendingSession() {
        pendingSession = nil
        tabIsDown = false
    }

    private func focus(_ item: WindowSwitcherItem) {
        guard let application = NSRunningApplication(processIdentifier: item.processID) else { return }
        if application.isHidden { _ = application.unhide() }
        if let axWindow = item.axWindow, item.isMinimized {
            _ = AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        _ = application.activate(options: [.activateAllWindows])
        if let axWindow = item.axWindow {
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
            _ = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, true as CFTypeRef)
        }
        noteApplicationActivation(application)
    }

    private func installWorkspaceObserver() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSWorkspace.didActivateApplicationNotification {
                        self.noteApplicationActivation(application)
                    }
                    self.requestInventoryRefresh(priority: .utility)
                }
            }
        }
    }

    private func noteApplicationActivation(_ application: NSRunningApplication?) {
        guard let processID = application?.processIdentifier, processID != getpid() else { return }
        recentProcessIDs.removeAll { $0 == processID }
        recentProcessIDs.insert(processID, at: 0)
        if recentProcessIDs.count > 128 { recentProcessIDs.removeLast(recentProcessIDs.count - 128) }
    }

    private func orderedForSession(
        _ items: [WindowSwitcherItem],
        frontmostProcessID: pid_t?
    ) -> [WindowSwitcherItem] {
        WindowSwitcherOrdering.orderedIndices(
            processIDs: items.map(\.processID),
            frontmostProcessID: frontmostProcessID,
            recentProcessIDs: recentProcessIDs
        ).map { items[$0] }
    }

    private func requestInventoryRefresh(priority: TaskPriority) {
        guard isActive, settings.isEnabled, hasAccessibilityPermission else { return }
        inventoryRevision += 1
        guard inventoryTask == nil else { return }
        startInventoryRefresh(priority: priority)
    }

    private func startInventoryRefresh(priority: TaskPriority) {
        let revision = inventoryRevision
        let settings = settings
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentProcessIDs = recentProcessIDs
        let previousSignature = inventorySignature
        let hasCachedWindows = !cachedWindows.isEmpty
        let startedAt = CFAbsoluteTimeGetCurrent()
        inventoryTask = Task { @MainActor [weak self] in
            let refresh = await Task.detached(priority: priority) {
                let signature = WindowSwitcherInventory.windowServerSignature()
                if hasCachedWindows, signature == previousSignature {
                    return WindowSwitcherInventoryRefresh(snapshot: nil, signature: signature)
                }
                let snapshot = WindowSwitcherInventory.snapshot(
                    settings: settings,
                    frontmostProcessID: frontmostProcessID,
                    recentProcessIDs: recentProcessIDs
                )
                return WindowSwitcherInventoryRefresh(snapshot: snapshot, signature: signature)
            }.value
            guard let self else { return }
            self.reportInventoryLatency(
                startedAt: startedAt,
                windowCount: refresh.snapshot?.count ?? self.cachedWindows.count,
                performedAccessibilityEnumeration: refresh.snapshot != nil
            )
            self.inventoryTask = nil
            self.inventorySignature = refresh.signature
            let settingsStillMatch = settings == self.settings
            if settingsStillMatch {
                if let snapshot = refresh.snapshot {
                    self.cachedWindows = snapshot
                    self.applyCachedPreviews(to: snapshot)
                }
                if let pending = self.pendingSession {
                    self.pendingSession = nil
                    self.completePendingSession(pending, snapshot: self.cachedWindows)
                }
            }
            if revision != self.inventoryRevision || !settingsStillMatch {
                self.startInventoryRefresh(priority: self.pendingSession == nil ? .utility : .userInitiated)
                return
            }
            self.prepareHiddenPanelContents()
            self.prewarmThumbnails()
        }
    }

    private func completePendingSession(
        _ pending: WindowSwitcherPendingSession,
        snapshot: [WindowSwitcherItem]
    ) {
        guard !snapshot.isEmpty else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ordered = orderedForSession(snapshot, frontmostProcessID: frontmost)
        let currentIndex = ordered.firstIndex { $0.processID == frontmost }
        let initialIndex = WindowSwitcherSelection.initialIndex(
            count: ordered.count,
            currentIndex: currentIndex,
            reverse: pending.reverse
        ) ?? 0
        let resolvedIndex = WindowSwitcherSelection.cycledIndex(
            current: initialIndex,
            count: ordered.count,
            offset: pending.additionalSelectionOffset
        ) ?? initialIndex
        if pending.commitWhenReady {
            focus(ordered[resolvedIndex])
        } else {
            showSession(
                ordered,
                reverse: pending.reverse,
                manual: pending.manual,
                additionalSelectionOffset: pending.additionalSelectionOffset,
                startedAt: pending.startedAt,
                cacheHit: false
            )
        }
    }

    private func reportPresentationLatency(startedAt: CFAbsoluteTime, cacheHit: Bool) {
        let milliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        guard milliseconds >= 16 else { return }
        Self.performanceLogger.notice(
            "presentation latency: \(milliseconds, privacy: .public) ms; cache hit: \(cacheHit, privacy: .public)"
        )
    }

    private func reportInventoryLatency(
        startedAt: CFAbsoluteTime,
        windowCount: Int,
        performedAccessibilityEnumeration: Bool
    ) {
        let milliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        guard milliseconds >= 100 else { return }
        Self.performanceLogger.notice(
            "inventory latency: \(milliseconds, privacy: .public) ms; windows: \(windowCount, privacy: .public); AX: \(performedAccessibilityEnumeration, privacy: .public)"
        )
    }

    private func applyCachedPreviews(to items: [WindowSwitcherItem]) {
        guard settings.showThumbnails else {
            items.forEach { $0.updatePreview(nil) }
            return
        }
        for item in items {
            guard let windowID = item.windowID else { continue }
            item.updatePreview(thumbnailCache[windowID])
        }
    }

    private func prepareHiddenPanelContents() {
        guard !isShowing, pendingSession == nil, !cachedWindows.isEmpty else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ordered = orderedForSession(cachedWindows, frontmostProcessID: frontmost)
        let currentIndex = ordered.firstIndex { $0.processID == frontmost }
        let preparedSelection = WindowSwitcherSelection.initialIndex(
            count: ordered.count,
            currentIndex: currentIndex,
            reverse: false
        ) ?? 0
        objectWillChange.send()
        windows = ordered
        selectedIndex = preparedSelection
    }

    private func prewarmThumbnails() {
        guard !isShowing else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ordered = orderedForSession(cachedWindows, frontmostProcessID: frontmost)
        let selected = WindowSwitcherSelection.initialIndex(
            count: ordered.count,
            currentIndex: ordered.firstIndex { $0.processID == frontmost },
            reverse: false
        ) ?? 0
        refreshThumbnails(for: ordered, selectedIndex: selected, maximumCount: 3, requireShowing: false)
    }

    private func refreshThumbnails(
        for items: [WindowSwitcherItem],
        selectedIndex: Int,
        maximumCount: Int?,
        requireShowing: Bool
    ) {
        thumbnailTask?.cancel()
        guard settings.showThumbnails else { return }
        let prioritized = WindowSwitcherThumbnailPriority.orderedIndices(
            count: items.count,
            selectedIndex: selectedIndex
        )
        let indices = maximumCount.map { Array(prioritized.prefix($0)) } ?? prioritized
        thumbnailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for index in indices {
                guard !Task.isCancelled, self.settings.showThumbnails else { return }
                if requireShowing && !self.isShowing { return }
                let item = items[index]
                guard let windowID = item.windowID, item.canCapturePreview else { continue }
                if let cached = self.thumbnailCache[windowID] {
                    item.updatePreview(cached)
                    continue
                }
                let captured = await Task.detached(priority: .utility) {
                    WindowSwitcherPreviewCapture.capture(
                        windowID: windowID,
                        maximumPixelSize: CGSize(width: 320, height: 200)
                    )
                }.value
                guard !Task.isCancelled, let captured else { continue }
                let image = NSImage(
                    cgImage: captured.image,
                    size: NSSize(width: captured.image.width, height: captured.image.height)
                )
                self.storeThumbnail(image, for: windowID)
                item.updatePreview(image)
            }
        }
    }

    private func storeThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        thumbnailCache[windowID] = image
        thumbnailCacheOrder.removeAll { $0 == windowID }
        thumbnailCacheOrder.append(windowID)
        while thumbnailCacheOrder.count > 64 {
            let removed = thumbnailCacheOrder.removeFirst()
            thumbnailCache.removeValue(forKey: removed)
        }
    }

    private func refreshEventTap() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        removeEventTap()
        guard isActive, settings.isEnabled, hasAccessibilityPermission else { return }

        let context = WindowSwitcherEventTapContext(owner: Unmanaged.passUnretained(self).toOpaque())
        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: windowSwitcherEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else { return }

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

// MARK: - Overlay panel

@MainActor
private final class WindowSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class WindowSwitcherPanelController {
    private weak var model: WindowSwitcherModel?
    private var panel: WindowSwitcherPanel?

    init(model: WindowSwitcherModel) {
        self.model = model
    }

    func prepare() {
        guard panel == nil, let model else { return }
        panel = makePanel(model: model)
    }

    func show() {
        guard let model else { return }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: min(940, max(620, visibleFrame.width - 80)), height: 220)
        let targetFrame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: false)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: WindowSwitcherModel) -> WindowSwitcherPanel {
        let panel = WindowSwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: WindowSwitcherOverlay(model: model))
        return panel
    }
}

private struct WindowSwitcherOverlay: View {
    @ObservedObject var model: WindowSwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                Text(model.t("windowSwitcherTitle"))
                    .font(.headline)
                Spacer()
                Text(model.t("windowSwitcherShortcut"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if model.windows.isEmpty {
                Text(model.t("windowSwitcherNoWindows"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 118)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(model.windows.indices, id: \.self) { index in
                                let item = model.windows[index]
                                WindowSwitcherTile(
                                    item: item,
                                    isSelected: index == model.selectedIndex,
                                    showTitle: model.settings.showWindowTitles
                                ) {
                                    model.commitSelection(at: index)
                                }
                                .id(item.id)
                                .onHover { isHovered in
                                    if isHovered { model.select(index: index) }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .onChange(of: model.selectedIndex) { _, index in
                        guard model.windows.indices.contains(index) else { return }
                        proxy.scrollTo(model.windows[index].id, anchor: .center)
                    }
                    .onAppear {
                        guard model.windows.indices.contains(model.selectedIndex) else { return }
                        proxy.scrollTo(model.windows[model.selectedIndex].id, anchor: .center)
                    }
                }
                .frame(height: 142)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 188)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18)))
    }
}

private struct WindowSwitcherTile: View {
    @ObservedObject var item: WindowSwitcherItem
    let isSelected: Bool
    let showTitle: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let preview = item.preview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(nsImage: item.icon)
                                .resizable()
                                .scaledToFit()
                                .padding(26)
                        }
                    }
                    .frame(width: 126, height: 78)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    Image(nsImage: item.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .offset(x: 6, y: 12)
                }
                Text(item.appName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if showTitle {
                    Text(item.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(width: 144, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var windowSwitcher: WindowSwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.t("windowSwitcher"))
                    .font(.headline)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { windowSwitcher.settings.isEnabled },
                        set: { windowSwitcher.setEnabled($0) }
                    )
                )
                .labelsHidden()
            }
            Text(model.t("windowSwitcherSubtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(model.t("windowSwitcherShortcutHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                model.t("windowSwitcherIncludeMinimized"),
                isOn: Binding(
                    get: { windowSwitcher.settings.includeMinimizedWindows },
                    set: { windowSwitcher.setIncludeMinimizedWindows($0) }
                )
            )
            Toggle(
                model.t("windowSwitcherIncludeHidden"),
                isOn: Binding(
                    get: { windowSwitcher.settings.includeHiddenApplications },
                    set: { windowSwitcher.setIncludeHiddenApplications($0) }
                )
            )
            Toggle(
                model.t("windowSwitcherShowThumbnails"),
                isOn: Binding(
                    get: { windowSwitcher.settings.showThumbnails },
                    set: { windowSwitcher.setShowThumbnails($0) }
                )
            )
            Toggle(
                model.t("windowSwitcherShowTitles"),
                isOn: Binding(
                    get: { windowSwitcher.settings.showWindowTitles },
                    set: { windowSwitcher.setShowWindowTitles($0) }
                )
            )

            if !windowSwitcher.hasAccessibilityPermission {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.t("windowSwitcherAccessibilityRequired"), systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                    HStack {
                        Button(model.t("windowSwitcherGrantAccessibility")) {
                            windowSwitcher.requestAccessibility()
                        }
                        Button(model.t("openAccessibilitySettings")) {
                            windowSwitcher.openAccessibilitySettings()
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label(model.t("windowSwitcherAccessibilityReady"), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }

            Button(model.t("windowSwitcherTestNow")) {
                windowSwitcher.showSwitcherNow()
            }
            .disabled(!windowSwitcher.settings.isEnabled || !windowSwitcher.hasAccessibilityPermission)
        }
        .onAppear { windowSwitcher.refreshPermissionStatus() }
    }
}
