import Foundation

/// Commands an authenticated client may ask the Mac to perform.
///
/// `wakeDisplay` stays internal for now: the iPhone home screen only exposes
/// lock, display off, unlock and wake-and-unlock, but the primitive is part of
/// the wire protocol so a later release can surface it without a version bump.
public enum RemoteCommand: String, Codable, Sendable, CaseIterable, Equatable {
    case getState
    case lockScreen
    case displayOff
    case wakeDisplay
    case unlock
    case wakeAndUnlock
    case ping
    /// Drive the panel backlight. Carries a `RemoteLevelRequest` payload.
    case setBrightness
    /// Drive the default output device's volume (and optionally its mute).
    /// Carries a `RemoteLevelRequest` payload.
    case setVolume

    /// Commands that change the machine and therefore always require an
    /// authenticated, encrypted session.
    public var requiresAuthentication: Bool {
        switch self {
        case .getState, .ping:
            return false
        case .lockScreen, .displayOff, .wakeDisplay, .unlock, .wakeAndUnlock,
             .setBrightness, .setVolume:
            return true
        }
    }
}

/// Capabilities advertised in the Bonjour TXT record.
public enum RemoteCapability: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case lock
    case displayOff
    case wake
    case unlock
}
