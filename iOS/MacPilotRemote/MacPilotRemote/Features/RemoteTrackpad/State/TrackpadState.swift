import Foundation

/// The trackpad page's own state machine.
///
/// `RemoteConnectionState` describes the link; this describes the page. The
/// two stay separate on purpose: the page keeps its surface and its pending
/// input alive across a reconnect instead of tearing everything down because
/// the link blipped.
enum TrackpadPhase: Equatable {
    case idle
    /// Flip animation and the `beginRealtimeInput` round trip are in flight.
    case entering
    case active
    /// The link dropped while the page was open; holding position until the
    /// connect supervisor brings it back.
    case reconnecting
    /// The link is gone for good (or the app went to the background); the page
    /// explains itself instead of closing on the user.
    case disconnected
    /// Close animation running; the `endRealtimeInput` is in flight.
    case exiting

    var isActiveLike: Bool { self == .active || self == .reconnecting }
}

/// Which way the user holds the phone. Deliberately not the system rotation:
/// someone lying on a couch with the phone flat must not have the surface
/// flip under their fingers when the gyroscope wakes up.
enum TrackpadOrientation: String, CaseIterable {
    /// Phone upright: screen right is cursor right.
    case portrait
    /// Phone sideways with its top to the user's left.
    case landscape

    var iconSystemName: String {
        switch self {
        case .portrait: return "iphone"
        case .landscape: return "iphone.landscape"
        }
    }
}

struct TrackpadSettings: Equatable {
    /// 0.5...2; shifts where the acceleration ramp starts.
    var trackingSpeed: Double = 1
    /// Content follows the fingers, the way macOS ships.
    var naturalScrolling: Bool = true
    var tapToClick: Bool = true
    var scrollInertia: Bool = true
}

/// Persists trackpad preferences in `UserDefaults`. The key strings live here
/// so nothing else writes half of a setting.
struct TrackpadSettingsStore {
    private enum Key {
        static let orientation = "trackpad.orientation"
        static let trackingSpeed = "trackpad.trackingSpeed"
        static let naturalScrolling = "trackpad.naturalScrolling"
        static let tapToClick = "trackpad.tapToClick"
        static let scrollInertia = "trackpad.scrollInertia"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var orientation: TrackpadOrientation {
        get {
            defaults.string(forKey: Key.orientation).flatMap(TrackpadOrientation.init(rawValue:)) ?? .portrait
        }
        set { defaults.set(newValue.rawValue, forKey: Key.orientation) }
    }

    var settings: TrackpadSettings {
        get {
            var settings = TrackpadSettings()
            let speed = defaults.double(forKey: Key.trackingSpeed)
            if speed > 0 { settings.trackingSpeed = min(max(speed, 0.5), 2) }
            if defaults.object(forKey: Key.naturalScrolling) != nil {
                settings.naturalScrolling = defaults.bool(forKey: Key.naturalScrolling)
            }
            if defaults.object(forKey: Key.tapToClick) != nil {
                settings.tapToClick = defaults.bool(forKey: Key.tapToClick)
            }
            if defaults.object(forKey: Key.scrollInertia) != nil {
                settings.scrollInertia = defaults.bool(forKey: Key.scrollInertia)
            }
            return settings
        }
        set {
            defaults.set(newValue.trackingSpeed, forKey: Key.trackingSpeed)
            defaults.set(newValue.naturalScrolling, forKey: Key.naturalScrolling)
            defaults.set(newValue.tapToClick, forKey: Key.tapToClick)
            defaults.set(newValue.scrollInertia, forKey: Key.scrollInertia)
        }
    }
}
