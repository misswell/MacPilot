import AppKit
import ApplicationServices
import CoreGraphics

/// What the Accessibility API says about the frontmost application's focused
/// window. `accessibilityTrusted == false` is a real answer, not an error: the
/// resolver then uses its declared window-server fallback.
struct FocusedWindowProbe: Equatable, Sendable {
    let accessibilityTrusted: Bool
    let windowID: CGWindowID?
    let title: String?
    let frame: CGRect?

    init(
        accessibilityTrusted: Bool,
        windowID: CGWindowID? = nil,
        title: String? = nil,
        frame: CGRect? = nil
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.windowID = windowID
        self.title = title
        self.frame = frame
    }
}

struct CaptureWindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let title: String?
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
    /// 0 is the front-most window in WindowServer's list.
    let zIndex: Int
}

enum CaptureWindowSelectionSource: String, Equatable, Sendable {
    case accessibilityFocusedWindow
    case accessibilityTitleAndFrame
    case frontmostWindow
    case largestWindowFallback
    case none
}

struct CaptureWindowSelection: Equatable, Sendable {
    let windowID: CGWindowID?
    let source: CaptureWindowSelectionSource
    let detail: String
}

/// Picks the window 「当前窗口截图」 must capture.
///
/// The primary answer is `AXFocusedWindow` mapped by window ID. When AX is
/// unavailable the fallback is the front-most layer-0 window in WindowServer's
/// z-order (a defined answer), and only an explicitly allowed last resort may
/// use the largest window. A silent "pick the biggest titled window" is what
/// made inactive windows win over the focused one.
enum CaptureWindowFocusResolver {
    static func select(
        probe: FocusedWindowProbe,
        candidates: [CaptureWindowCandidate],
        allowLargestFallback: Bool
    ) -> CaptureWindowSelection {
        let ordinary = candidates
            .filter(\.isOnScreen)
            .filter { $0.layer == 0 && $0.windowID != 0 }
            .sorted { $0.zIndex < $1.zIndex }
        guard !ordinary.isEmpty else {
            return CaptureWindowSelection(windowID: nil, source: .none, detail: "no ordinary windows")
        }

        if let focusedID = probe.windowID,
           ordinary.contains(where: { $0.windowID == focusedID }) {
            return CaptureWindowSelection(
                windowID: focusedID,
                source: .accessibilityFocusedWindow,
                detail: "AXFocusedWindow id=\(focusedID)"
            )
        }

        if probe.accessibilityTrusted,
           let title = normalizedTitle(probe.title),
           let frame = probe.frame {
            let matches = ordinary.filter { candidate in
                normalizedTitle(candidate.title) == title
                    && abs(candidate.frame.width - frame.width) <= 2
                    && abs(candidate.frame.height - frame.height) <= 2
            }
            if matches.count == 1, let match = matches.first {
                return CaptureWindowSelection(
                    windowID: match.windowID,
                    source: .accessibilityTitleAndFrame,
                    detail: "AX title+size match id=\(match.windowID)"
                )
            }
        }

        if let frontmost = ordinary.first {
            let detail = probe.accessibilityTrusted
                ? "AX focused window not in window list; using front-most id=\(frontmost.windowID)"
                : "Accessibility unavailable; using front-most id=\(frontmost.windowID)"
            return CaptureWindowSelection(
                windowID: frontmost.windowID,
                source: .frontmostWindow,
                detail: detail
            )
        }

        let largest = ordinary.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
        if allowLargestFallback, let largest {
            return CaptureWindowSelection(
                windowID: largest.windowID,
                source: .largestWindowFallback,
                detail: "explicit largest-window fallback id=\(largest.windowID)"
            )
        }
        return CaptureWindowSelection(windowID: nil, source: .none, detail: "no eligible window")
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads the frontmost application's focused window. Runs synchronously on
    /// the caller (main thread for window state); AX calls are cheap relative
    /// to a screen capture.
    @MainActor
    static func probe(processID: pid_t, mainScreenHeight: CGFloat) -> FocusedWindowProbe {
        guard AXIsProcessTrusted() else {
            return FocusedWindowProbe(accessibilityTrusted: false)
        }
        let application = AXUIElementCreateApplication(processID)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return FocusedWindowProbe(accessibilityTrusted: true)
        }
        let window = windowValue as! AXUIElement

        var windowNumberValue: CFTypeRef?
        let windowID: CGWindowID? = {
            guard AXUIElementCopyAttributeValue(
                window,
                "AXWindowNumber" as CFString,
                &windowNumberValue
            ) == .success, let number = windowNumberValue as? NSNumber else { return nil }
            return CGWindowID(number.uint32Value)
        }()

        var titleValue: CFTypeRef?
        let title: String? = {
            guard AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success else { return nil }
            return titleValue as? String
        }()

        let frame: CGRect? = {
            guard let position = axPoint(window, attribute: kAXPositionAttribute as CFString),
                  let size = axSize(window, attribute: kAXSizeAttribute as CFString) else {
                return nil
            }
            // AX frames are top-left origin; AppKit screen coordinates are
            // bottom-left. Convert exactly once at this boundary.
            return CGRect(
                x: position.x,
                y: mainScreenHeight - position.y - size.height,
                width: size.width,
                height: size.height
            )
        }()

        return FocusedWindowProbe(
            accessibilityTrusted: true,
            windowID: windowID,
            title: title,
            frame: frame
        )
    }

    private static func axPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
