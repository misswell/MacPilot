import Foundation

/// Decides when the Mac should hang up on a client that has gone quiet.
///
/// A socket's state says nothing about whether the app behind it is still
/// alive. iOS keeps a suspended app's TCP connection `ESTABLISHED` for as long
/// as it likes, and TCP keepalive is answered by the peer's kernel rather than
/// by its app, so neither can detect a frozen client. Only the application
/// heartbeat can, which is why the Mac reaps connections itself instead of
/// trusting the socket.
enum RemoteConnectionIdlePolicy {
    /// The iPhone sends a `ping` every 15s, so this is six missed heartbeats.
    static let authenticatedTimeout: TimeInterval = 90

    /// A pairing client is legitimately silent while the user reads the code off
    /// the Mac's screen and types it, so this covers the whole 120s pairing
    /// window with room to spare.
    static let pairingTimeout: TimeInterval = 180

    static func timeout(isAuthenticated: Bool) -> TimeInterval {
        isAuthenticated ? authenticatedTimeout : pairingTimeout
    }

    /// True when the client has been silent for longer than `timeout` allows.
    static func shouldReap(
        lastActivityAt: Date,
        timeout: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(lastActivityAt) > timeout
    }

    /// True when the client has been silent for longer than its phase allows.
    static func shouldReap(
        lastActivityAt: Date,
        isAuthenticated: Bool,
        now: Date = Date()
    ) -> Bool {
        shouldReap(
            lastActivityAt: lastActivityAt,
            timeout: timeout(isAuthenticated: isAuthenticated),
            now: now
        )
    }
}
