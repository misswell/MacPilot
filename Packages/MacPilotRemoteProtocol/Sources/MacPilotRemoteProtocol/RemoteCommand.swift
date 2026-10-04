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
    case mediaPrevious
    case mediaPlayPause
    case mediaNext
    /// Arms the realtime input channel (the trackpad) for this connection.
    /// The actual pointer events travel as binary batches on frame tag `0x03`,
    /// never as commands.
    case beginRealtimeInput
    /// Disarms the realtime input channel.
    case endRealtimeInput
    /// Opens the phone keyboard only when the pointer is over editable text.
    case beginTextInput
    case textInput
    case endTextInput
    /// Lists the Mac's Dock groups with per-app running state. Replies with a
    /// `RemoteDockGroupsSnapshot` payload.
    case getDockGroups
    /// Launches every member of one Dock group (running members are activated).
    /// Carries a `RemoteDockGroupLaunchRequest` payload and replies with the
    /// refreshed `RemoteDockGroupsSnapshot`.
    case launchDockGroup
    /// Launches or activates a single member of one Dock group. Carries a
    /// `RemoteDockGroupLaunchRequest` payload with `appID` set.
    case launchDockGroupApp
    case beginRemoteVideo
    case endRemoteVideo
    case remotePointer
    case remoteKey

    /// Commands that change the machine and therefore always require an
    /// authenticated, encrypted session.
    public var requiresAuthentication: Bool {
        switch self {
        case .getState, .ping:
            return false
        case .lockScreen, .displayOff, .wakeDisplay, .unlock, .wakeAndUnlock,
             .setBrightness, .setVolume, .mediaPrevious, .mediaPlayPause, .mediaNext,
             .beginRealtimeInput, .endRealtimeInput,
             .beginTextInput, .textInput, .endTextInput,
             .getDockGroups, .launchDockGroup, .launchDockGroupApp,
             .beginRemoteVideo, .endRemoteVideo, .remotePointer, .remoteKey:
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
    /// The Mac accepts binary realtime input batches (the trackpad channel).
    case realtimeInput
    /// The Mac reads graded pressure from kind-4 press events and applies it
    /// to the injected CGEvents. Senders without this advertisement fall back
    /// to plain clicks, which keeps old Macs working untouched.
    case inputPressure
    /// The Mac understands the continuous press stream (pressBegin /
    /// pressUpdate / pressEnd), so the phone can actuate the button while the
    /// finger is still down and grade it as the contact deepens. Macs that
    /// only advertise `.inputPressure` get the one-shot kind-4 press instead.
    case inputPressureStream
    /// The Mac answers the Dock group commands and launching a group or one of
    /// its members from the phone is safe to attempt. Macs without this
    /// advertisement would drop the connection on an unknown command rawValue,
    /// so the phone hides the whole section instead of sending it.
    case dockGroups
    case remoteDesktop
    /// System media keys. Senders must see this before sending media commands.
    case mediaControl

    /// App Store 1.0/1.1 peers know only the four screen-control cases.
    /// Their synthesized Codable decoder rejects the entire hello on any new
    /// enum case. Missing features must therefore use that original vocabulary.
    public static func negotiated(_ advertised: [Self], features: [String]?) -> [Self] {
        let known = Set(features ?? [])
        return advertised.filter { capability in
            switch capability {
            case .lock, .displayOff, .wake, .unlock:
                true
            case .realtimeInput, .inputPressure, .inputPressureStream:
                // The first feature-aware 1.2 clients declared only desktop,
                // but already understood all three input capability cases.
                known.contains(capability.rawValue) || known.contains(Self.remoteDesktop.rawValue)
            case .remoteDesktop, .dockGroups, .mediaControl:
                known.contains(capability.rawValue)
            }
        }
    }
}
