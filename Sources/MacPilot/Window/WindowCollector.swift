import AppKit
import ApplicationServices
import CoreGraphics

struct WindowSwitcherServerRecord {
    let windowID: CGWindowID
    let processID: pid_t
    let title: String
    let frame: CGRect
    let order: Int
    let isOnScreen: Bool
}

struct WindowSwitcherServerScan {
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

enum WindowSwitcherInventory {
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
            windowNumber: windowNumber,
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

