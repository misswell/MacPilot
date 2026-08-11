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

final class WindowSwitcherItem: Identifiable {
    let id: String
    let windowID: CGWindowID?
    let processID: pid_t
    let appName: String
    let bundleIdentifier: String?
    let title: String
    let icon: NSImage
    let preview: NSImage?
    let axWindow: AXUIElement?
    let isMinimized: Bool
    let isHidden: Bool

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
        isHidden: Bool
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
    }

    var displayTitle: String {
        title.isEmpty ? appName : title
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
            let appElement = AXUIElementCreateApplication(processID)
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
                guard role(of: axWindow) == kAXWindowRole as String else { continue }
                let title = stringAttribute(kAXTitleAttribute, from: axWindow) ?? ""
                let minimized = boolAttribute(kAXMinimizedAttribute, from: axWindow)
                if minimized && !settings.includeMinimizedWindows { continue }

                let frame = frame(of: axWindow)
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
                    settings: settings,
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
                        settings: settings,
                        minimized: false
                    ))
                }
            }

            result.append(contentsOf: appItems.sorted { lhs, rhs in
                let lhsOrder = records.first(where: { $0.windowID == lhs.windowID })?.order ?? Int.max
                let rhsOrder = records.first(where: { $0.windowID == rhs.windowID })?.order ?? Int.max
                return lhsOrder == rhsOrder ? lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending : lhsOrder < rhsOrder
            })
        }

        return result
    }

    private static func makeItem(
        application: NSRunningApplication,
        axWindow: AXUIElement?,
        serverRecord: WindowSwitcherServerRecord?,
        fallbackTitle: String,
        index: Int,
        settings: WindowSwitcherSettings,
        minimized: Bool
    ) -> WindowSwitcherItem {
        let processID = application.processIdentifier
        let appName = application.localizedName ?? application.bundleIdentifier ?? "Application"
        let bundleIdentifier = application.bundleIdentifier
        let windowID = serverRecord?.windowID
        let icon = application.icon
            ?? (application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) })
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        let thumbnail = settings.showThumbnails && serverRecord?.isOnScreen == true
            ? serverRecord.flatMap { Self.preview(for: $0.windowID) }
            : nil
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
            preview: thumbnail,
            axWindow: axWindow,
            isMinimized: minimized,
            isHidden: application.isHidden
        )
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

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, from: element)
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

    private static func preview(for windowID: CGWindowID) -> NSImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
        ) -> CGImage?
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        guard let image = capture(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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

@MainActor
final class WindowSwitcherModel: ObservableObject {
    @Published private(set) var settings = WindowSwitcherSettings()
    @Published private(set) var windows: [WindowSwitcherItem] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isShowing = false
    @Published private(set) var hasAccessibilityPermission = false

    var language: AppLanguage = .system
    var persist: (() -> Void)?

    private var isActive = false
    private var isManualSession = false
    private var tabIsDown = false
    private var consumeTabKeyUp = false
    private var consumeEscapeKeyUp = false
    private var recentProcessIDs: [pid_t] = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapContext: WindowSwitcherEventTapContext?
    private var workspaceObserver: NSObjectProtocol?
    private var manualDismissTask: Task<Void, Never>?
    private var panelController: WindowSwitcherPanelController?

    init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        noteApplicationActivation(NSWorkspace.shared.frontmostApplication)
    }

    func applyLoadedSettings(_ settings: WindowSwitcherSettings) {
        self.settings = settings
        if isActive { refreshEventTap() }
    }

    func activateFromConfiguration() {
        guard !isActive else { return }
        isActive = true
        installWorkspaceObserver()
        refreshEventTap()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            refreshEventTap()
        } else {
            cancelSession()
            removeEventTap()
        }
        persist?()
    }

    func setIncludeMinimizedWindows(_ enabled: Bool) {
        settings.includeMinimizedWindows = enabled
        persist?()
    }

    func setIncludeHiddenApplications(_ enabled: Bool) {
        settings.includeHiddenApplications = enabled
        persist?()
    }

    func setShowThumbnails(_ enabled: Bool) {
        settings.showThumbnails = enabled
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
    }

    func refreshPermissionStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        refreshEventTap()
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
        selectedIndex = index
    }

    func commitSelection(at index: Int? = nil) {
        guard isShowing else { return }
        if let index, windows.indices.contains(index) { selectedIndex = index }
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
                guard isShowing else { return false }
                consumeEscapeKeyUp = true
                cancelSelection()
                return true
            }
            guard keyCode == 48 else { return false } // Tab
            let optionPressed = flags.contains(.maskAlternate)
            let reverse = flags.contains(.maskShift)
            if isShowing {
                if !tabIsDown || isAutorepeat {
                    if tabIsDown {
                        cycleSelection(reverse: reverse)
                    }
                }
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
            if keyCode == 48, isShowing || consumeTabKeyUp {
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
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = WindowSwitcherInventory.snapshot(
            settings: settings,
            frontmostProcessID: frontmost,
            recentProcessIDs: recentProcessIDs
        )
        guard !snapshot.isEmpty else { return false }
        windows = snapshot
        let currentIndex = snapshot.firstIndex { $0.processID == frontmost }
        selectedIndex = WindowSwitcherSelection.initialIndex(
            count: snapshot.count,
            currentIndex: currentIndex,
            reverse: reverse
        ) ?? 0
        isManualSession = manual
        isShowing = true
        panelController = panelController ?? WindowSwitcherPanelController(model: self)
        panelController?.show()
        if manual {
            manualDismissTask?.cancel()
            manualDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.isShowing, self.isManualSession else { return }
                self.finishSession(commit: false)
            }
        }
        return true
    }

    private func cycleSelection(reverse: Bool) {
        guard let next = WindowSwitcherSelection.cycledIndex(
            current: selectedIndex,
            count: windows.count,
            offset: reverse ? -1 : 1
        ) else { return }
        selectedIndex = next
    }

    private func finishSession(commit: Bool) {
        manualDismissTask?.cancel()
        manualDismissTask = nil
        let selected = windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
        isShowing = false
        isManualSession = false
        windows = []
        panelController?.hide()
        if commit, let selected {
            focus(selected)
        }
    }

    private func cancelSession() {
        guard isShowing else { return }
        finishSession(commit: false)
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
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.noteApplicationActivation(application) }
        }
    }

    private func noteApplicationActivation(_ application: NSRunningApplication?) {
        guard let processID = application?.processIdentifier, processID != getpid() else { return }
        recentProcessIDs.removeAll { $0 == processID }
        recentProcessIDs.insert(processID, at: 0)
        if recentProcessIDs.count > 128 { recentProcessIDs.removeLast(recentProcessIDs.count - 128) }
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

    func show() {
        guard let model else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: WindowSwitcherOverlay(model: model))
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: min(940, max(620, visibleFrame.width - 80)), height: 220)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ))
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> WindowSwitcherPanel {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, item in
                            WindowSwitcherTile(
                                item: item,
                                isSelected: index == model.selectedIndex,
                                showTitle: model.settings.showWindowTitles
                            ) {
                                model.commitSelection(at: index)
                            }
                            .onHover { isHovered in
                                if isHovered { model.select(index: index) }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
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
    let item: WindowSwitcherItem
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
