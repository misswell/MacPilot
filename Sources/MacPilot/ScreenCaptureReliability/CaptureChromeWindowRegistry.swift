import AppKit

/// Window-ID based registry for every window that exists only to serve the
/// screenshot UI (Quick Access panel, selection overlays, HUDs).
///
/// ScreenCaptureKit filters exclude these IDs instead of excluding the whole
/// MacPilot process, so the user can still capture MacPilot's ordinary windows.
/// Visibility is token based: an older session can only release the tokens it
/// owns, never re-show a window a newer session is hiding.
@MainActor
final class CaptureChromeWindowRegistry {
    static let shared = CaptureChromeWindowRegistry()

    struct HideToken: Hashable, Sendable {
        let id: UUID
        let sessionID: UUID
    }

    private struct Entry {
        weak var window: NSWindow?
        let sessionID: UUID?
        let reason: String
    }

    private final class HideState {
        weak var window: NSWindow?
        /// token id -> owning session.
        var tokens: [UUID: UUID] = [:]
        var wasVisible = false
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var hides: [ObjectIdentifier: HideState] = [:]
    private var keysBySession: [UUID: Set<ObjectIdentifier>] = [:]
    private let windowNumber: (NSWindow) -> Int

    /// The provider exists so tests can assign window numbers without ordering
    /// windows on screen; production always reads the live `NSWindow`.
    init(windowNumber: @escaping (NSWindow) -> Int = { $0.windowNumber }) {
        self.windowNumber = windowNumber
    }

    func register(_ window: NSWindow, sessionID: UUID? = nil, reason: String) {
        let key = ObjectIdentifier(window)
        entries[key] = Entry(window: window, sessionID: sessionID, reason: reason)
        if let sessionID {
            keysBySession[sessionID, default: []].insert(key)
        }
    }

    func unregister(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let sessionID = entries[key]?.sessionID {
            keysBySession[sessionID]?.remove(key)
        }
        entries[key] = nil
    }

    /// Window IDs to exclude from a capture filter. Zero-numbered windows are
    /// skipped: they are not on screen and cannot appear in a capture.
    func excludedWindowIDs(for sessionID: UUID? = nil) -> Set<CGWindowID> {
        var result: Set<CGWindowID> = []
        var staleKeys: [ObjectIdentifier] = []
        for (key, entry) in entries {
            if let sessionID, entry.sessionID != sessionID { continue }
            guard let window = entry.window else {
                staleKeys.append(key)
                continue
            }
            let number = windowNumber(window)
            if number > 0 {
                result.insert(CGWindowID(number))
            }
        }
        for key in staleKeys {
            entries[key] = nil
        }
        return result
    }

    /// Hides a window for the duration of one capture session. Returns nil when
    /// the window is already off screen, so callers never hold a token that
    /// restores nothing.
    @discardableResult
    func hide(_ window: NSWindow, sessionID: UUID, reason: String) -> HideToken? {
        guard window.isVisible else { return nil }
        let key = ObjectIdentifier(window)
        let token = HideToken(id: UUID(), sessionID: sessionID)
        let state = hides[key] ?? HideState()
        if state.tokens.isEmpty {
            state.window = window
            state.wasVisible = window.isVisible
        }
        state.tokens[token.id] = sessionID
        hides[key] = state
        register(window, sessionID: sessionID, reason: reason)
        window.orderOut(nil)
        return token
    }

    /// Releases one session's hold. The window stays hidden while any other
    /// token (typically from a newer session) still owns it.
    func restore(_ token: HideToken) {
        for (key, state) in hides {
            guard state.tokens.removeValue(forKey: token.id) != nil else { continue }
            finishRestoreIfUnowned(key: key, state: state)
            return
        }
    }

    /// Drops every hide hold owned by a session. Tokens from other sessions are
    /// left untouched, so a late completion cannot reveal a newer capture's
    /// still-hidden chrome.
    func restoreAll(sessionID: UUID) {
        for (key, state) in hides {
            let owned = state.tokens.filter { $0.value == sessionID }.map(\.key)
            for tokenID in owned {
                state.tokens.removeValue(forKey: tokenID)
            }
            finishRestoreIfUnowned(key: key, state: state)
        }
    }

    /// Drops every registration and hide hold owned by a session. Any window
    /// that was hidden only by this session is restored exactly once.
    func endSession(_ sessionID: UUID) {
        restoreAll(sessionID: sessionID)
        let keys = keysBySession.removeValue(forKey: sessionID) ?? []
        for key in keys where entries[key]?.sessionID == sessionID {
            entries[key] = nil
        }
    }

    func unregisterAll() {
        entries.removeAll()
        for (key, state) in hides {
            if let window = state.window, !window.isVisible, state.wasVisible {
                window.orderFront(nil)
            }
            hides[key] = nil
        }
        keysBySession.removeAll()
    }

    private func finishRestoreIfUnowned(key: ObjectIdentifier, state: HideState) {
        guard state.tokens.isEmpty else { return }
        let window = state.window
        hides[key] = nil
        if let window, !window.isVisible, state.wasVisible {
            window.orderFront(nil)
        }
    }
}
