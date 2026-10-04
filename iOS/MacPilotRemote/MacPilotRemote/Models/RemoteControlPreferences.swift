import Combine
import Foundation
import MacPilotRemoteProtocol

enum RemoteControlFeature: String, CaseIterable, Identifiable {
    case desktop, trackpad, keyboard
    case displayOff, wakeDisplay, lockScreen, wakeAndUnlock
    case mediaPrevious, mediaPlayPause, mediaNext
    case brightness, volume, mute

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case input, screen, media, levels
        var id: String { rawValue }
        var titleKey: String { "controlsGroup\(rawValue.capitalized)" }
        var features: [RemoteControlFeature] {
            RemoteControlFeature.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .desktop, .trackpad, .keyboard: .input
        case .displayOff, .wakeDisplay, .lockScreen, .wakeAndUnlock: .screen
        case .mediaPrevious, .mediaPlayPause, .mediaNext: .media
        case .brightness, .volume, .mute: .levels
        }
    }

    var titleKey: String {
        switch self {
        case .desktop: "desktopTitle"
        case .trackpad: "trackpadEntry"
        case .keyboard: "desktopKeyboard"
        case .displayOff: "actionDisplayOff"
        case .wakeDisplay: "actionWakeDisplay"
        case .lockScreen: "actionLock"
        case .wakeAndUnlock: "actionWakeAndUnlock"
        case .mediaPrevious: "mediaPrevious"
        case .mediaPlayPause: "mediaPlayPause"
        case .mediaNext: "mediaNext"
        case .brightness: "brightnessLabel"
        case .volume: "volumeLabel"
        case .mute: "mute"
        }
    }

    var icon: String {
        switch self {
        case .desktop: "display"
        case .trackpad: "computermouse"
        case .keyboard: "keyboard"
        case .displayOff: "moon.fill"
        case .wakeDisplay: "sun.max.fill"
        case .lockScreen: "lock.fill"
        case .wakeAndUnlock: "sunrise.fill"
        case .mediaPrevious: "backward.end.fill"
        case .mediaPlayPause: "playpause.fill"
        case .mediaNext: "forward.end.fill"
        case .brightness: "sun.max"
        case .volume: "speaker.wave.2"
        case .mute: "speaker.slash"
        }
    }

    var command: RemoteCommand? {
        switch self {
        case .displayOff: .displayOff
        case .wakeDisplay: .wakeDisplay
        case .lockScreen: .lockScreen
        case .wakeAndUnlock: .wakeAndUnlock
        case .mediaPrevious: .mediaPrevious
        case .mediaPlayPause: .mediaPlayPause
        case .mediaNext: .mediaNext
        default: nil
        }
    }
}

/// Only hidden controls are saved. New controls default to visible, and unknown
/// keys survive a downgrade. This is a phone UI preference, shared by all Macs.
@MainActor
final class RemoteControlPreferences: ObservableObject {
    private static let storageKey = "remoteControl.hiddenFeatures"
    private let defaults: UserDefaults
    @Published private var hidden: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hidden = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isEnabled(_ feature: RemoteControlFeature) -> Bool {
        !hidden.contains(feature.rawValue)
    }

    func setEnabled(_ enabled: Bool, for feature: RemoteControlFeature) {
        if enabled { hidden.remove(feature.rawValue) }
        else { hidden.insert(feature.rawValue) }
        defaults.set(hidden.sorted(), forKey: Self.storageKey)
    }

    var hasHomeControls: Bool {
        RemoteControlFeature.allCases.contains { $0 != .keyboard && isEnabled($0) }
    }
}
