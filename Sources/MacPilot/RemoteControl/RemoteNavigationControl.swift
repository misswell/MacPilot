import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import MacPilotRemoteProtocol

/// Emits the small, explicit navigation-key vocabulary exposed by PilotNest.
/// This intentionally has no generic key-code input path.
@MainActor
enum RemoteNavigationControl {
    static func keyCode(for key: RemoteNavigationKey) -> CGKeyCode {
        switch key {
        case .pageUp: CGKeyCode(kVK_PageUp)
        case .pageDown: CGKeyCode(kVK_PageDown)
        case .home: CGKeyCode(kVK_Home)
        case .end: CGKeyCode(kVK_End)
        }
    }

    /// Creates events without dispatching them, so the event shape can be
    /// validated without injecting keyboard input into the user's session.
    static func events(for key: RemoteNavigationKey) -> [CGEvent]? {
        let code = keyCode(for: key)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            return nil
        }
        down.flags = CGEventFlags(rawValue: 0)
        up.flags = CGEventFlags(rawValue: 0)
        return [down, up]
    }

    /// The sink is injectable for safe tests. Production uses the system event
    /// tap only after Accessibility permission has been confirmed.
    static func send(
        _ key: RemoteNavigationKey,
        isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) -> RemoteErrorCode? {
        guard isAccessibilityTrusted() else { return .accessibilityPermissionRequired }
        guard let events = events(for: key) else { return .internalError }
        events.forEach(postEvent)
        return nil
    }
}
