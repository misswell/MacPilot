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
    var previewSize = WindowSwitcherPreviewSize.medium
    var showIconsOnly = false
    /// Bundle identifiers of apps whose windows should appear as one switcher item.
    var mergeApplicationBundleIdentifiers: [String] = []
    /// Legacy configuration field retained so older config files decode safely.
    /// Listed apps are now always collapsed in the switcher without changing
    /// their actual windows.
    var autoMergeApplicationWindows = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        includeMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .includeMinimizedWindows) ?? true
        includeHiddenApplications = try container.decodeIfPresent(Bool.self, forKey: .includeHiddenApplications) ?? false
        showThumbnails = try container.decodeIfPresent(Bool.self, forKey: .showThumbnails) ?? true
        showWindowTitles = try container.decodeIfPresent(Bool.self, forKey: .showWindowTitles) ?? true
        previewSize = try container.decodeIfPresent(WindowSwitcherPreviewSize.self, forKey: .previewSize) ?? .medium
        showIconsOnly = try container.decodeIfPresent(Bool.self, forKey: .showIconsOnly) ?? false
        mergeApplicationBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .mergeApplicationBundleIdentifiers) ?? []
        autoMergeApplicationWindows = try container.decodeIfPresent(Bool.self, forKey: .autoMergeApplicationWindows) ?? true
    }
}

/// Presentation-only grouping for configured applications. It never changes
/// the owning application's windows; it only chooses which item the switcher
/// should display.
enum WindowSwitcherApplicationGrouping {
    static func displayedIndices(
        isMinimized: [Bool],
        applicationBundleIdentifier: String?,
        settings: WindowSwitcherSettings
    ) -> [Int] {
        let allIndices = isMinimized.indices.filter {
            settings.includeMinimizedWindows || !isMinimized[$0]
        }
        guard let applicationBundleIdentifier,
              settings.mergeApplicationBundleIdentifiers.contains(applicationBundleIdentifier),
              !allIndices.isEmpty else {
            return allIndices
        }
        return [allIndices.first(where: { !isMinimized[$0] }) ?? allIndices[0]]
    }
}

enum WindowSwitcherPreviewSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
}

enum WindowSwitcherSelection {
    static func initialIndex(count: Int, currentIndex: Int?, reverse: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        guard let currentIndex else { return nil }
        let offset = reverse ? -1 : 1
        return wrappedIndex(currentIndex + offset, count: count)
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
        ids: [String],
        recentIDs: [String]
    ) -> [Int] {
        let recentOrder = Dictionary(uniqueKeysWithValues: recentIDs.enumerated().map { ($1, $0) })
        return ids.indices.sorted { lhs, rhs in
            let lhsOrder = recentOrder[ids[lhs]] ?? Int.max
            let rhsOrder = recentOrder[ids[rhs]] ?? Int.max
            return lhsOrder == rhsOrder ? lhs < rhs : lhsOrder < rhsOrder
        }
    }
}

enum WindowSwitcherActivationRouting {
    static func promotedWindowID(
        applicationProcessID: pid_t,
        candidateWindowIDs: [String],
        focusedWindowID: String?
    ) -> String? {
        // MacPilot's own windows are part of the inventory, so the app itself
        // must follow the same activation path as every other application.
        guard applicationProcessID > 0,
              let fallbackID = candidateWindowIDs.first else { return nil }
        guard candidateWindowIDs.count > 1 else { return fallbackID }
        return focusedWindowID ?? fallbackID
    }
}

enum WindowSwitcherRecentWindowIDs {
    /// Cycling only previews a candidate; recency changes when selection commits.
    static func afterPreviewSelection(
        recentIDs: [String],
        windowID _: String
    ) -> [String] {
        recentIDs
    }

    /// A committed focus change moves exactly one window to the front.
    static func afterCommittedSelection(
        recentIDs: [String],
        windowID: String,
        limit: Int = 128
    ) -> [String] {
        moveToFront(windowID, in: recentIDs, limit: limit)
    }

    static func afterInventorySnapshot(
        recentIDs: [String],
        previousIDs: Set<String>,
        snapshotIDs: [String],
        limit: Int = 128
    ) -> [String] {
        var updated = recentIDs
        var knownIDs = Set(updated)
        for id in snapshotIDs where !previousIDs.contains(id) && knownIDs.insert(id).inserted {
            updated.append(id)
        }
        if updated.count > limit { updated.removeLast(updated.count - limit) }
        return updated
    }

    private static func moveToFront(_ windowID: String, in recentIDs: [String], limit: Int) -> [String] {
        var updated = recentIDs.filter { $0 != windowID }
        updated.insert(windowID, at: 0)
        if updated.count > limit { updated.removeLast(updated.count - limit) }
        return updated
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
    let frame: CGRect?
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
        frame: CGRect?,
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
        self.frame = frame
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

private struct WindowSwitcherServerScan {
    let records: [WindowSwitcherServerRecord]
    let signature: Int
}

private struct WindowSwitcherAXAttributes {
    let role: String?
    let title: String
    let isMinimized: Bool
    let frame: CGRect?
    /// Stable window number (kAXWindowNumberAttribute); nil when unavailable.
    let windowNumber: CGWindowID?
}

enum WindowSwitcherWindowMatching {
    private static let maximumFrameDistance: CGFloat = 64

    static func shouldIncludeAXWindow(
        hasMatchingServerRecord: Bool,
        isOnScreen: Bool,
        isMinimized: Bool
    ) -> Bool {
        // The switcher inventory intentionally follows the same set of
        // windows that Mission Control can show. AX also reports minimized
        // windows and windows from other Spaces, but neither belongs in that
        // set when there is no current on-screen WindowServer record.
        !isMinimized && hasMatchingServerRecord && isOnScreen
    }

    static func matchingFrameIndex(
        windowFrame: CGRect,
        candidateFrames: [CGRect]
    ) -> Int? {
        guard !candidateFrames.isEmpty else { return nil }
        guard let index = candidateFrames.indices.min(by: { lhs, rhs in
            frameDistance(windowFrame, candidateFrames[lhs])
                < frameDistance(windowFrame, candidateFrames[rhs])
        }), frameDistance(windowFrame, candidateFrames[index]) <= maximumFrameDistance else {
            return nil
        }
        return index
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }
}

private enum WindowSwitcherInventory {
    static func snapshot(
        settings: WindowSwitcherSettings,
        serverRecords: [WindowSwitcherServerRecord],
        excludedWindowIDs: Set<CGWindowID> = []
    ) -> [WindowSwitcherItem] {
        let recordsByProcess = Dictionary(grouping: serverRecords, by: \.processID)
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated else { return false }
            guard application.activationPolicy == .regular || application.activationPolicy == .accessory else { return false }
            if application.isHidden && !settings.includeHiddenApplications { return false }
            let processRecords = recordsByProcess[application.processIdentifier] ?? []
            guard processRecords.contains(where: { $0.isOnScreen }) else { return false }
            return true
        }

        let orderedApplications = applications.sorted { lhs, rhs in
            (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? "") == .orderedAscending
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
                // 跳过排除窗口（如切换器自身的面板），避免把自身显示出来。
                if let windowNumber = attributes.windowNumber, excludedWindowIDs.contains(windowNumber) { continue }
                let title = attributes.title
                let minimized = attributes.isMinimized

                let frame = attributes.frame
                let record = matchingRecord(
                    title: title,
                    frame: frame,
                    records: records,
                    usedWindowIDs: usedWindowIDs
                )
                if let record { usedWindowIDs.insert(record.windowID) }

                // AX also exposes floating overlays and other non-window-layer
                // surfaces. If WindowServer cannot match one to a regular
                // layer-0 window, do not let it masquerade as an app window.
                // A minimized AX window is not part of Mission Control's
                // visible window set, so it is not a fallback candidate here.
                guard WindowSwitcherWindowMatching.shouldIncludeAXWindow(
                    hasMatchingServerRecord: record != nil,
                    isOnScreen: record?.isOnScreen == true,
                    isMinimized: minimized
                ) else { continue }

                let resolvedTitle = title.isEmpty ? (record?.title ?? "") : title
                guard frame.map({ $0.width >= 2 && $0.height >= 2 }) ?? true else { continue }
                appItems.append(makeItem(
                    application: application,
                    axWindow: axWindow,
                    serverRecord: record,
                    frame: frame,
                    fallbackTitle: resolvedTitle,
                    windowNumber: attributes.windowNumber,
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
                        frame: record.frame,
                        fallbackTitle: record.title,
                        windowNumber: record.windowID,
                        index: index,
                        icon: icon,
                        minimized: false
                    ))
                }
            }

            let recordOrder: [CGWindowID: Int] = Dictionary(uniqueKeysWithValues: records.map { ($0.windowID, $0.order) })
            let orderedItems = appItems.sorted { lhs, rhs in
                let lhsOrder = lhs.windowID.flatMap { recordOrder[$0] } ?? Int.max
                let rhsOrder = rhs.windowID.flatMap { recordOrder[$0] } ?? Int.max
                return lhsOrder == rhsOrder ? lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending : lhsOrder < rhsOrder
            }
            let displayedIndices = WindowSwitcherApplicationGrouping.displayedIndices(
                isMinimized: orderedItems.map(\.isMinimized),
                applicationBundleIdentifier: application.bundleIdentifier,
                settings: settings
            )
            result.append(contentsOf: displayedIndices.map { orderedItems[$0] })
        }

        return result
    }

    static func scanWindowServer() -> WindowSwitcherServerScan {
        let records = windowServerRecords()
        var hasher = Hasher()
        for record in records {
            hasher.combine(record.windowID)
            hasher.combine(record.processID)
            hasher.combine(record.title)
            hasher.combine(record.isOnScreen)
            hasher.combine(Int(record.frame.origin.x.rounded()))
            hasher.combine(Int(record.frame.origin.y.rounded()))
            hasher.combine(Int(record.frame.width.rounded()))
            hasher.combine(Int(record.frame.height.rounded()))
        }
        return WindowSwitcherServerScan(records: records, signature: hasher.finalize())
    }

    private static func makeItem(
        application: NSRunningApplication,
        axWindow: AXUIElement?,
        serverRecord: WindowSwitcherServerRecord?,
        frame: CGRect?,
        fallbackTitle: String,
        windowNumber: CGWindowID?,
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
        } else if let windowNumber {
            // AX window number is stable across refreshes even when the
            // WindowServer record does not match, so the switcher does not
            // mistake a long-lived window for a brand-new one on every scan.
            stableID = "window-\(windowNumber)"
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
            frame: frame,
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
        // Only records visible on the current Space are represented in
        // Mission Control's window overview. Do this before title/frame
        // matching so an AX window cannot borrow an off-screen window from
        // another Space and enter the inventory.
        let available = records.filter { $0.isOnScreen && !usedWindowIDs.contains($0.windowID) }
        if !title.isEmpty, let exact = available.first(where: { $0.title == title }) { return exact }
        guard let frame else { return nil }
        guard let index = WindowSwitcherWindowMatching.matchingFrameIndex(
            windowFrame: frame,
            candidateFrames: available.map(\.frame)
        ) else { return nil }
        return available[index]
    }

    private static func windowAttributes(of element: AXUIElement) -> WindowSwitcherAXAttributes {
        let keys: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXMinimizedAttribute as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            "AXWindowNumber" as CFString
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
                frame: position.flatMap { position in size.map { CGRect(origin: position, size: $0) } },
                windowNumber: (values[5] as? NSNumber).map { CGWindowID($0.intValue) }
            )
        }
        return WindowSwitcherAXAttributes(
            role: stringAttribute(kAXRoleAttribute, from: element),
            title: stringAttribute(kAXTitleAttribute, from: element) ?? "",
            isMinimized: boolAttribute(kAXMinimizedAttribute, from: element),
            frame: frame(of: element),
            windowNumber: intAttribute("AXWindowNumber", from: element).map { CGWindowID($0) }
        )
    }

    private static func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
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

private enum WindowSwitcherFocusedWindowResolver {
    static func resolve(processID: pid_t, candidates: [WindowSwitcherItem]) -> String? {
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success else { return candidates.first?.id }
        guard let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return candidates.first?.id
        }
        let focusedWindow = focusedWindowValue as! AXUIElement

        if let identityMatch = candidates.first(where: { item in
            guard let itemWindow = item.axWindow else { return false }
            return CFEqual(focusedWindow, itemWindow)
        }) {
            return identityMatch.id
        }

        var titleValue: CFTypeRef?
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleValue)
        AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue)
        let title = titleValue as? String ?? ""
        if !title.isEmpty, let exact = candidates.first(where: { $0.title == title }) {
            return exact.id
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        let hasPosition = positionValue.map {
            CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue, .cgPoint, &position)
        } ?? false
        let hasSize = sizeValue.map {
            CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue, .cgSize, &size)
        } ?? false
        guard hasPosition, hasSize else { return candidates.first?.id }
        let frame = CGRect(origin: position, size: size)
        return candidates
            .compactMap { item -> (WindowSwitcherItem, CGFloat)? in
                guard let itemFrame = item.frame, !itemFrame.isNull else { return nil }
                return (item, frameDistance(frame, itemFrame))
            }
            .min { $0.1 < $1.1 }?
            .0.id ?? candidates.first?.id
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }
}

@MainActor
final class WindowSwitcherModel: ObservableObject {
    private static let inventoryRefreshDebounce = Duration.milliseconds(200)
    private static let thumbnailCacheLimit = 24
    private static let thumbnailMaximumPixelSize = CGSize(width: 256, height: 160)
    private static let mouseSelectionDistanceThreshold: CGFloat = 24
    private static let performanceLogger = Logger(
        subsystem: "com.misswell.macpilot",
        category: "WindowSwitcherPerformance"
    )
    private static let windowSwitcherLogger = Logger(
        subsystem: "com.misswell.macpilot",
        category: "WindowSwitcher"
    )
    private static let activationLogger = Logger(
        subsystem: "com.misswell.macpilot",
        category: "WindowSwitcherActivation"
    )

    @Published private(set) var settings = WindowSwitcherSettings()
    private(set) var windows: [WindowSwitcherItem] = []
    private(set) var selectedIndex: Int?
    private(set) var selectedItemID: String?
    private(set) var isShowing = false
    @Published private(set) var hasAccessibilityPermission = false

    var language: AppLanguage = .system
    var persist: (() -> Void)?

    private var isActive = false
    private var isRuntimeActive = false
    private var isManualSession = false
    private var tabIsDown = false
    private var consumeTabKeyUp = false
    private var consumeEscapeKeyUp = false
    private var recentWindowIDs: [String] = []
    private var cachedWindows: [WindowSwitcherItem] = []
    private var inventoryTask: Task<Void, Never>?
    private var inventoryRefreshDebounceTask: Task<Void, Never>?
    private var inventoryRevision = 0
    private var inventorySignature: Int?
    private var pendingSession: WindowSwitcherPendingSession?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailRevision = 0
    private var thumbnailCache: [CGWindowID: NSImage] = [:]
    private var thumbnailCacheOrder: [CGWindowID] = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapContext: WindowSwitcherEventTapContext?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var manualDismissTask: Task<Void, Never>?
    private var panelController: WindowSwitcherPanelController?
    private var mouseSelectionEnabled = true
    private var mouseSelectionAnchor: CGPoint?
    private var previousSnapshotWindowIDs: Set<String> = []
    private var activationCandidate: NSRunningApplication?
    private var activationConfirmTask: Task<Void, Never>?

    var gridColumnCount: Int {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let preferredWidth = min(1080, max(680, visibleFrame.width - 80))
        let tileWidth = settings.showIconsOnly ? 180 : settings.previewSize.tileWidth
        let usableWidth = preferredWidth - 32 - 4
        return max(1, Int((usableWidth + 10) / (tileWidth + 10)))
    }

    init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        noteApplicationActivation(NSWorkspace.shared.frontmostApplication)
    }

    func applyLoadedSettings(_ settings: WindowSwitcherSettings) {
        self.settings = settings
        cachedWindows = []
        if isActive {
            if settings.isEnabled {
                if isRuntimeActive {
                    refreshEventTap()
                    requestInventoryRefresh(priority: .utility)
                } else {
                    startRuntime(inventoryPriority: .utility)
                }
            } else {
                stopRuntime()
            }
        }
    }

    func activateFromConfiguration() {
        guard !isActive else { return }
        isActive = true
        guard settings.isEnabled else { return }
        startRuntime(inventoryPriority: .utility)
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            startRuntime(inventoryPriority: .userInitiated)
        } else {
            stopRuntime()
        }
        persist?()
    }

    /// Adds or removes an app from the merge-windows list.
    func setMergeApplication(_ bundleIdentifier: String, enabled: Bool) {
        var identifiers = settings.mergeApplicationBundleIdentifiers
        if enabled {
            guard !identifiers.contains(bundleIdentifier) else { return }
            identifiers.append(bundleIdentifier)
        } else {
            identifiers.removeAll { $0 == bundleIdentifier }
        }
        settings.mergeApplicationBundleIdentifiers = identifiers
        persist?()
    }

    private func startRuntime(inventoryPriority: TaskPriority) {
        guard isActive, settings.isEnabled, !isRuntimeActive else { return }
        isRuntimeActive = true
        panelController = WindowSwitcherPanelController(model: self)
        panelController?.prepare()
        installWorkspaceObserver()
        refreshEventTap()
        requestInventoryRefresh(priority: inventoryPriority)
    }

    private func stopRuntime() {
        guard isRuntimeActive else { return }
        isRuntimeActive = false
        cancelSession()
        cancelPendingSession()
        manualDismissTask?.cancel()
        manualDismissTask = nil
        inventoryRevision += 1
        inventoryTask?.cancel()
        inventoryTask = nil
        inventoryRefreshDebounceTask?.cancel()
        inventoryRefreshDebounceTask = nil
        cancelThumbnailRefresh()
        removeEventTap()
        removeWorkspaceObservers()
        clearThumbnailCache()
        cachedWindows.removeAll(keepingCapacity: false)
        recentWindowIDs.removeAll(keepingCapacity: false)
        inventorySignature = nil
        _ = updatePanelContents([], selectedIndex: nil)
        panelController?.releaseResources()
        panelController = nil
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
            cancelThumbnailRefresh()
            clearThumbnailCache()
        }
        persist?()
    }

    func setShowWindowTitles(_ enabled: Bool) {
        settings.showWindowTitles = enabled
        persist?()
    }

    func setPreviewSize(_ size: WindowSwitcherPreviewSize) {
        settings.previewSize = size
        persist?()
    }

    func setShowIconsOnly(_ enabled: Bool) {
        settings.showIconsOnly = enabled
        if enabled {
            cancelThumbnailRefresh()
            clearThumbnailCache()
            applyCachedPreviews(to: cachedWindows)
        }
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
        select(itemID: windows[index].id)
    }

    func select(itemID: String) {
        guard let index = windows.firstIndex(where: { $0.id == itemID }) else { return }
        guard selectedItemID != itemID else { return }
        objectWillChange.send()
        selectedIndex = index
        selectedItemID = itemID
    }

    func handleHover(itemID: String) {
        unlockMouseSelectionIfMoved()
        guard mouseSelectionEnabled else { return }
        select(itemID: itemID)
    }

    func commitSelection(at index: Int? = nil) {
        guard isShowing else { return }
        if let index, windows.indices.contains(index) {
            select(itemID: windows[index].id)
        }
        finishSession(commit: true)
    }

    func commitSelection(itemID: String) {
        guard isShowing else { return }
        select(itemID: itemID)
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
        guard isRuntimeActive else { return false }
        guard !isShowing else { return true }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let snapshot = orderedForSession(cachedWindows)
        DiagnosticLog.write(
            "WindowSwitcher",
            "Session began: \(snapshot.map { "\($0.appName):\($0.id)" }.joined(separator: ", "))"
        )
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
        )
        let resolvedIndex: Int?
        if let initialIndex {
            resolvedIndex = WindowSwitcherSelection.cycledIndex(
                current: initialIndex,
                count: snapshot.count,
                offset: additionalSelectionOffset
            ) ?? initialIndex
        } else if additionalSelectionOffset != 0 {
            let start = reverse ? snapshot.count - 1 : 0
            resolvedIndex = WindowSwitcherSelection.cycledIndex(
                current: start,
                count: snapshot.count,
                offset: max(0, additionalSelectionOffset - 1)
            )
        } else {
            resolvedIndex = nil
        }
        updatePanelContents(snapshot, selectedIndex: resolvedIndex)
        isManualSession = manual
        isShowing = true
        resetMouseSelectionLock()
        panelController = panelController ?? WindowSwitcherPanelController(model: self)
        panelController?.show()
        reportPresentationLatency(startedAt: startedAt, cacheHit: cacheHit)
        refreshThumbnails(
            for: snapshot,
            selectedIndex: selectedIndex,
            maximumCount: Self.thumbnailCacheLimit,
            requireShowing: true
        )
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
        guard !windows.isEmpty else { return }
        let next: Int
        if let current = selectedIndex {
            guard let cycled = WindowSwitcherSelection.cycledIndex(
                current: current,
                count: windows.count,
                offset: reverse ? -1 : 1
            ) else { return }
            next = cycled
        } else {
            next = reverse ? windows.count - 1 : 0
        }
        recentWindowIDs = WindowSwitcherRecentWindowIDs.afterPreviewSelection(
            recentIDs: recentWindowIDs,
            windowID: windows[next].id
        )
        objectWillChange.send()
        selectedIndex = next
        selectedItemID = windows[next].id
    }

    @discardableResult
    private func updatePanelContents(
        _ items: [WindowSwitcherItem],
        selectedIndex: Int?
    ) -> Bool {
        let itemsChanged = !windows.elementsEqual(items, by: { $0 === $1 })
        let newSelectedID = selectedIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }
        guard self.selectedIndex != selectedIndex || self.selectedItemID != newSelectedID || itemsChanged else { return false }
        objectWillChange.send()
        windows = items
        self.selectedIndex = selectedIndex
        self.selectedItemID = newSelectedID
        return true
    }

    private func finishSession(commit: Bool) {
        manualDismissTask?.cancel()
        manualDismissTask = nil
        let selected = selectedIndex.flatMap { windows.indices.contains($0) ? windows[$0] : nil }
        isShowing = false
        isManualSession = false
        mouseSelectionEnabled = true
        mouseSelectionAnchor = nil
        panelController?.hide()
        cancelThumbnailRefresh()
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

    private func resetMouseSelectionLock() {
        mouseSelectionEnabled = false
        mouseSelectionAnchor = NSEvent.mouseLocation
    }

    private func unlockMouseSelectionIfMoved() {
        guard !mouseSelectionEnabled else { return }
        guard let anchor = mouseSelectionAnchor else {
            mouseSelectionEnabled = true
            mouseSelectionAnchor = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        let deltaX = mouse.x - anchor.x
        let deltaY = mouse.y - anchor.y
        let threshold = Self.mouseSelectionDistanceThreshold
        if (deltaX * deltaX + deltaY * deltaY) >= threshold * threshold {
            mouseSelectionEnabled = true
            mouseSelectionAnchor = nil
        }
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
        noteWindowActivation(item.id)
    }

    private func installWorkspaceObserver() {
        guard workspaceObservers.isEmpty else { return }
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
                        DiagnosticLog.write("WindowSwitcher", "App activated: \(application?.localizedName ?? "?")")
                        Self.activationLogger.info(
                            "App activated: \(application?.localizedName ?? "?", privacy: .public)"
                        )
                        // Background apps frequently grab activation briefly (notifications,
                        // update checkers, menu-bar helpers). Only record an app as "recent"
                        // once it has actually stayed in the foreground, so they don't get
                        // inserted into the middle of an Alt+Tab cycle.
                        self.scheduleActivationConfirmation(application)
                    }
                    self.requestInventoryRefresh(priority: .utility)
                }
            }
        }
    }

    /// Defer recording an activation until the app keeps foreground focus for a
    /// short while, filtering out transient background activations.
    private func scheduleActivationConfirmation(_ application: NSRunningApplication?) {
        activationConfirmTask?.cancel()
        activationCandidate = application
        activationConfirmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            guard let candidate = self.activationCandidate,
                  let frontmost = NSWorkspace.shared.frontmostApplication,
                  candidate.processIdentifier == frontmost.processIdentifier else { return }
            DiagnosticLog.write("WindowSwitcher", "Confirmed foreground: \(candidate.localizedName ?? "?")")
            self.noteApplicationActivation(candidate)
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll(keepingCapacity: false)
    }

    private func noteApplicationActivation(_ application: NSRunningApplication?) {
        guard let processID = application?.processIdentifier else { return }
        let candidates = cachedWindows.filter { $0.processID == processID }
        let focusedWindowID = candidates.count > 1
            ? WindowSwitcherFocusedWindowResolver.resolve(processID: processID, candidates: candidates)
            : nil
        guard let promotedWindowID = WindowSwitcherActivationRouting.promotedWindowID(
            applicationProcessID: processID,
            candidateWindowIDs: candidates.map(\.id),
            focusedWindowID: focusedWindowID
        ) else { return }
        if candidates.count > 1 {
            DiagnosticLog.write(
                "WindowSwitcher",
                "Promoting window \(promotedWindowID) for \(application?.localizedName ?? "?")"
            )
            Self.activationLogger.info(
                "Promoting \(application?.localizedName ?? "?") window \(promotedWindowID, privacy: .public)"
            )
        }
        noteWindowActivation(promotedWindowID)
    }

    private func noteWindowActivation(_ windowID: String) {
        recentWindowIDs = WindowSwitcherRecentWindowIDs.afterCommittedSelection(
            recentIDs: recentWindowIDs,
            windowID: windowID
        )
    }

    /// Newly appearing windows (just launched apps, or windows that reappeared
    /// in a refreshed snapshot) are recorded after already-known recency. A
    /// refresh must never outrank a window the user just activated.
    private func recordNewWindows(_ snapshot: [WindowSwitcherItem]) {
        let currentIDs = Set(snapshot.map(\.id))
        let newIDs = currentIDs.subtracting(previousSnapshotWindowIDs)
        if !newIDs.isEmpty {
            if newIDs.count <= 8 {
                let names = snapshot.filter { newIDs.contains($0.id) }.map(\.appName)
                DiagnosticLog.write("WindowSwitcher", "Recording newly observed windows after existing recency: \(names.joined(separator: ", "))")
                Self.windowSwitcherLogger.info("Recording newly observed windows after existing recency: \(names.joined(separator: ", "))")
            } else {
                DiagnosticLog.write("WindowSwitcher", "Recording \(newIDs.count) newly observed windows after existing recency")
                Self.windowSwitcherLogger.info("Recording \(newIDs.count) newly observed windows after existing recency")
            }
            recentWindowIDs = WindowSwitcherRecentWindowIDs.afterInventorySnapshot(
                recentIDs: recentWindowIDs,
                previousIDs: previousSnapshotWindowIDs,
                snapshotIDs: snapshot.map(\.id)
            )
        }
        previousSnapshotWindowIDs = currentIDs
    }

    private func orderedForSession(_ items: [WindowSwitcherItem]) -> [WindowSwitcherItem] {
        WindowSwitcherOrdering.orderedIndices(
            ids: items.map(\.id),
            recentIDs: recentWindowIDs
        ).map { items[$0] }
    }

    private func requestInventoryRefresh(priority: TaskPriority) {
        guard isRuntimeActive, settings.isEnabled, hasAccessibilityPermission else { return }
        inventoryRevision += 1
        scheduleInventoryRefresh(priority: priority)
    }

    private func scheduleInventoryRefresh(priority: TaskPriority) {
        guard inventoryTask == nil else { return }
        inventoryRefreshDebounceTask?.cancel()
        inventoryRefreshDebounceTask = nil
        if priority == .userInitiated {
            startInventoryRefresh(priority: priority)
            return
        }
        inventoryRefreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.inventoryRefreshDebounce)
            guard !Task.isCancelled, let self else { return }
            self.inventoryRefreshDebounceTask = nil
            guard self.inventoryTask == nil else { return }
            self.startInventoryRefresh(priority: priority)
        }
    }

    private func startInventoryRefresh(priority: TaskPriority) {
        inventoryRefreshDebounceTask?.cancel()
        inventoryRefreshDebounceTask = nil
        let revision = inventoryRevision
        let settings = settings
        let previousSignature = inventorySignature
        let hasCachedWindows = !cachedWindows.isEmpty
        let startedAt = CFAbsoluteTimeGetCurrent()
        // 排除切换器自身面板的窗口号，避免把面板显示在清单里。
        let excludedWindowIDs: Set<CGWindowID> = {
            guard let panelID = panelController?.panelWindowID else { return [] }
            return [panelID]
        }()
        inventoryTask = Task { @MainActor [weak self] in
            let refresh = await Task.detached(priority: priority) {
                let serverScan = WindowSwitcherInventory.scanWindowServer()
                let signature = serverScan.signature
                if hasCachedWindows, signature == previousSignature {
                    return WindowSwitcherInventoryRefresh(snapshot: nil, signature: signature)
                }
                let snapshot = WindowSwitcherInventory.snapshot(
                    settings: settings,
                    serverRecords: serverScan.records,
                    excludedWindowIDs: excludedWindowIDs
                )
                return WindowSwitcherInventoryRefresh(snapshot: snapshot, signature: signature)
            }.value
            guard !Task.isCancelled, let self, self.isRuntimeActive else { return }
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
                    self.recordNewWindows(snapshot)
                }
                if let pending = self.pendingSession {
                    self.pendingSession = nil
                    self.completePendingSession(pending, snapshot: self.cachedWindows)
                }
            }
            if revision != self.inventoryRevision || !settingsStillMatch {
                self.scheduleInventoryRefresh(priority: self.pendingSession == nil ? .utility : .userInitiated)
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
        let ordered = orderedForSession(snapshot)
        let currentIndex = ordered.firstIndex { $0.processID == frontmost }
        let initialIndex = WindowSwitcherSelection.initialIndex(
            count: ordered.count,
            currentIndex: currentIndex,
            reverse: pending.reverse
        )
        let resolvedIndex: Int?
        if let initialIndex {
            resolvedIndex = WindowSwitcherSelection.cycledIndex(
                current: initialIndex,
                count: ordered.count,
                offset: pending.additionalSelectionOffset
            ) ?? initialIndex
        } else if pending.additionalSelectionOffset != 0 {
            let start = pending.reverse ? ordered.count - 1 : 0
            resolvedIndex = WindowSwitcherSelection.cycledIndex(
                current: start,
                count: ordered.count,
                offset: max(0, pending.additionalSelectionOffset - 1)
            )
        } else {
            resolvedIndex = nil
        }
        if pending.commitWhenReady {
            if let resolvedIndex, ordered.indices.contains(resolvedIndex) {
                focus(ordered[resolvedIndex])
            }
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
        let ordered = orderedForSession(cachedWindows)
        updatePanelContents(ordered, selectedIndex: nil)
    }

    private func prewarmThumbnails() {
        guard !isShowing else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ordered = orderedForSession(cachedWindows)
        let selected = WindowSwitcherSelection.initialIndex(
            count: ordered.count,
            currentIndex: ordered.firstIndex { $0.processID == frontmost },
            reverse: false
        )
        if let selected {
            refreshThumbnails(for: ordered, selectedIndex: selected, maximumCount: 3, requireShowing: false)
        }
    }

    private func refreshThumbnails(
        for items: [WindowSwitcherItem],
        selectedIndex: Int?,
        maximumCount: Int?,
        requireShowing: Bool
    ) {
        cancelThumbnailRefresh()
        guard settings.showThumbnails, let selectedIndex else { return }
        let revision = thumbnailRevision
        let maximumPixelSize = Self.thumbnailMaximumPixelSize
        let prioritized = WindowSwitcherThumbnailPriority.orderedIndices(
            count: items.count,
            selectedIndex: selectedIndex
        )
        let indices = maximumCount.map { Array(prioritized.prefix($0)) } ?? prioritized
        thumbnailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.thumbnailRevision == revision {
                    self.thumbnailTask = nil
                }
            }
            for index in indices {
                guard !Task.isCancelled, self.settings.showThumbnails else { return }
                if requireShowing && !self.isShowing { return }
                let item = items[index]
                guard let windowID = item.windowID, item.canCapturePreview else { continue }
                if let cached = self.cachedThumbnail(for: windowID) {
                    item.updatePreview(cached)
                    continue
                }
                let captured = await Task.detached(priority: .utility) {
                    WindowSwitcherPreviewCapture.capture(
                        windowID: windowID,
                        maximumPixelSize: maximumPixelSize
                    )
                }.value
                guard let captured else { continue }
                let image = NSImage(
                    cgImage: captured.image,
                    size: NSSize(width: captured.image.width, height: captured.image.height)
                )
                self.storeThumbnail(image, for: windowID)
                guard !Task.isCancelled else { return }
                item.updatePreview(image)
            }
        }
    }

    private func cancelThumbnailRefresh() {
        thumbnailRevision += 1
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    private func cachedThumbnail(for windowID: CGWindowID) -> NSImage? {
        guard let image = thumbnailCache[windowID] else { return nil }
        thumbnailCacheOrder.removeAll { $0 == windowID }
        thumbnailCacheOrder.append(windowID)
        return image
    }

    private func storeThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        thumbnailCache[windowID] = image
        thumbnailCacheOrder.removeAll { $0 == windowID }
        thumbnailCacheOrder.append(windowID)
        while thumbnailCacheOrder.count > Self.thumbnailCacheLimit {
            let removed = thumbnailCacheOrder.removeFirst()
            thumbnailCache.removeValue(forKey: removed)
            clearPreview(for: removed)
        }
    }

    private func clearThumbnailCache() {
        thumbnailCache.removeAll(keepingCapacity: false)
        thumbnailCacheOrder.removeAll(keepingCapacity: false)
        clearPreview(for: nil)
    }

    private func clearPreview(for windowID: CGWindowID?) {
        var visited = Set<ObjectIdentifier>()
        for item in cachedWindows + windows {
            guard windowID == nil || item.windowID == windowID else { continue }
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            item.updatePreview(nil)
        }
    }

    private func refreshEventTap() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        removeEventTap()
        guard isRuntimeActive, settings.isEnabled, hasAccessibilityPermission else { return }

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

    /// 切换器面板自身的窗口号，用于从窗口清单里排除，避免显示自己。
    var panelWindowID: CGWindowID? {
        guard let panel else { return nil }
        return CGWindowID(panel.windowNumber)
    }

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
        updateFrame(of: panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func releaseResources() {
        let currentPanel = panel
        panel = nil
        currentPanel?.orderOut(nil)
        currentPanel?.contentView = nil
        currentPanel?.close()
    }

    private func updateFrame(of panel: WindowSwitcherPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let preferredWidth = min(1080, max(680, visibleFrame.width - 80))
        let columns = model?.gridColumnCount ?? 6
        let windowCount = model?.windows.count ?? 0
        let rows = max(1, (windowCount + columns - 1) / columns)
        let tileHeight = model?.settings.layoutTileHeight ?? 132
        // Include the grid padding, title row, stack spacing, and outer padding.
        // Keeping this in sync with WindowSwitcherOverlay prevents a one-row
        // grid from being a few points taller than the panel's content area.
        let contentHeight = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * 12 + 72
        let size = NSSize(
            width: preferredWidth,
            height: min(visibleFrame.height - 80, max(188, contentHeight))
        )
        let targetFrame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: false)
        }
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
                if model.windows.count > model.gridColumnCount {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            windowGrid
                        }
                        .onChange(of: model.selectedItemID) { _, itemID in
                            guard let itemID else { return }
                            proxy.scrollTo(itemID, anchor: .center)
                        }
                        .onAppear {
                            guard let itemID = model.selectedItemID else { return }
                            proxy.scrollTo(itemID, anchor: .center)
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    windowGrid
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 188)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18)))
    }

    private var windowGrid: some View {
        let columns = (0..<model.gridColumnCount).map { _ in
            GridItem(.flexible(minimum: model.settings.tileMinimumWidth), spacing: 10)
        }
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(model.windows) { item in
                WindowSwitcherTile(
                    item: item,
                    isSelected: model.selectedItemID == item.id,
                    showTitle: model.settings.showWindowTitles,
                    showIconsOnly: model.settings.showIconsOnly,
                    previewSize: model.settings.previewSize
                ) {
                    model.commitSelection(itemID: item.id)
                }
                .onContinuousHover { phase in
                    if case .active = phase {
                        model.handleHover(itemID: item.id)
                    }
                }
            }
        }
        .padding(2)
    }
}

private struct WindowSwitcherTile: View {
    @ObservedObject var item: WindowSwitcherItem
    let isSelected: Bool
    let showTitle: Bool
    let showIconsOnly: Bool
    let previewSize: WindowSwitcherPreviewSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                if showIconsOnly {
                    HStack(spacing: 10) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                        Text(item.appName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(width: previewSize.tileWidth - 16, alignment: .leading)
                } else {
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
                        .frame(width: previewSize.previewWidth, height: previewSize.previewHeight)
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
            }
            .padding(8)
            .frame(width: previewSize.tileWidth, alignment: .leading)
            .frame(minHeight: showIconsOnly ? 72 : previewSize.layoutTileHeight(showTitle: showTitle))
            .background(isSelected ? Color(nsColor: .systemBlue).opacity(0.24) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 5)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .systemBlue), lineWidth: 3)
                        .padding(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private extension WindowSwitcherPreviewSize {
    var previewWidth: CGFloat {
        switch self {
        case .small: return 88
        case .medium: return 126
        case .large: return 164
        }
    }

    var previewHeight: CGFloat {
        switch self {
        case .small: return 56
        case .medium: return 78
        case .large: return 102
        }
    }

    var tileWidth: CGFloat {
        switch self {
        case .small: return 110
        case .medium: return 144
        case .large: return 182
        }
    }

    var tileHeight: CGFloat {
        switch self {
        case .small: return 96
        case .medium: return 122
        case .large: return 150
        }
    }

    func layoutTileHeight(showTitle: Bool) -> CGFloat {
        let contentHeight = previewHeight + 6 + 16 + (showTitle ? 6 + 13 : 0) + 16
        return max(tileHeight, contentHeight)
    }
}

private extension WindowSwitcherSettings {
    var tileMinimumWidth: CGFloat {
        if showIconsOnly { return 180 }
        return previewSize.tileWidth
    }

    var layoutTileHeight: CGFloat {
        if showIconsOnly { return 72 }
        return previewSize.layoutTileHeight(showTitle: showWindowTitles)
    }
}

struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var windowSwitcher: WindowSwitcherModel

    private struct MergeAppRow: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let isRunning: Bool
    }

    private var mergeApps: [MergeAppRow] {
        windowSwitcher.settings.mergeApplicationBundleIdentifiers.map { identifier in
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
            return MergeAppRow(
                id: identifier,
                name: app?.localizedName ?? identifier,
                icon: app?.icon ?? NSImage(),
                isRunning: app != nil
            )
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("windowSwitcher")).font(.system(size: 30, weight: .bold))
                    Text(model.t("windowSwitcherSubtitle")).foregroundStyle(.secondary)
                }

                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.t("windowSwitcherTitle")).font(.headline)
                            Text(model.t("windowSwitcherShortcutHint"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { windowSwitcher.settings.isEnabled },
                                set: { windowSwitcher.setEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.large)
                    }
                }

                SettingsCard {
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
                    Toggle(
                        model.t("windowSwitcherShowIconsOnly"),
                        isOn: Binding(
                            get: { windowSwitcher.settings.showIconsOnly },
                            set: { windowSwitcher.setShowIconsOnly($0) }
                        )
                    )
                    Divider()
                    Picker(model.t("windowSwitcherPreviewSize"), selection: Binding(
                        get: { windowSwitcher.settings.previewSize },
                        set: { windowSwitcher.setPreviewSize($0) }
                    )) {
                        Text(model.t("windowSwitcherPreviewSmall")).tag(WindowSwitcherPreviewSize.small)
                        Text(model.t("windowSwitcherPreviewMedium")).tag(WindowSwitcherPreviewSize.medium)
                        Text(model.t("windowSwitcherPreviewLarge")).tag(WindowSwitcherPreviewSize.large)
                    }
                }

                SettingsCard {
                    Text(model.t("windowSwitcherMerge")).font(.headline)
                    Text(model.t("windowSwitcherMergeHint")).font(.subheadline).foregroundStyle(.secondary)

                    Divider()

                    if mergeApps.isEmpty {
                        Text(model.t("windowSwitcherNoMergeApps"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mergeApps) { app in
                            HStack(spacing: 10) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                if !app.isRunning {
                                    Text(model.t("windowSwitcherNotRunning"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    windowSwitcher.setMergeApplication(app.id, enabled: false)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help(model.t("windowSwitcherRemove"))
                            }
                        }
                    }

                    Divider()

                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            if let identifier = app.bundleIdentifier {
                                Button(app.localizedName ?? identifier) {
                                    windowSwitcher.setMergeApplication(identifier, enabled: true)
                                }
                            }
                        }
                    } label: {
                        Label(model.t("windowSwitcherAddMergeApp"), systemImage: "plus")
                    }
                    .disabled(runningApps.isEmpty)
                }

                SettingsCard {
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
                    } else {
                        Label(model.t("windowSwitcherAccessibilityReady"), systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }

                    Divider()

                    Button(model.t("windowSwitcherTestNow")) {
                        windowSwitcher.showSwitcherNow()
                    }
                    .disabled(!windowSwitcher.settings.isEnabled || !windowSwitcher.hasAccessibilityPermission)
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .onAppear { windowSwitcher.refreshPermissionStatus() }
    }
}
