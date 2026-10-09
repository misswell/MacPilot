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

/// Visibility and ordering are independent phone UI preferences, shared by all
/// Macs. Unknown keys are retained so newer controls survive a downgrade.
@MainActor
final class RemoteControlPreferences: ObservableObject {
    private static let storageKey = "remoteControl.hiddenFeatures"
    private static let orderStorageKey = "remoteControl.featureOrder"
    private static let groupOrderStorageKey = "remoteControl.groupOrder"
    private let defaults: UserDefaults
    @Published private var hidden: Set<String>
    @Published private var storedOrder: [String]
    @Published private var storedGroupOrder: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hidden = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
        self.storedOrder = defaults.stringArray(forKey: Self.orderStorageKey) ?? []
        self.storedGroupOrder = defaults.stringArray(forKey: Self.groupOrderStorageKey)
            ?? (defaults.stringArray(forKey: Self.orderStorageKey) ?? [])
                .compactMap(RemoteControlFeature.init(rawValue:)).map { $0.group.rawValue }
        if defaults.object(forKey: Self.groupOrderStorageKey) == nil,
           defaults.object(forKey: Self.orderStorageKey) != nil {
            defaults.set(storedGroupOrder, forKey: Self.groupOrderStorageKey)
        }
    }

    var orderedFeatures: [RemoteControlFeature] {
        var seen = Set<RemoteControlFeature>()
        return (storedOrder.compactMap(RemoteControlFeature.init(rawValue:))
                + RemoteControlFeature.allCases).filter { seen.insert($0).inserted }
    }

    var orderedGroups: [RemoteControlFeature.Group] {
        var seen = Set<RemoteControlFeature.Group>()
        return (storedGroupOrder.compactMap(RemoteControlFeature.Group.init(rawValue:))
                + RemoteControlFeature.Group.allCases).filter { seen.insert($0).inserted }
    }

    func features(in group: RemoteControlFeature.Group) -> [RemoteControlFeature] {
        let features = orderedFeatures.filter { $0.group == group }
        // Mute is attached to the volume slider, not a standalone home row.
        return group == .levels ? features.filter { $0 != .mute } + [.mute] : features
    }

    var homeSections: [[RemoteControlFeature]] {
        orderedGroups.map { group in
            features(in: group).filter { $0 != .keyboard && isEnabled($0) }
        }.filter { !$0.isEmpty }
    }

    func moveFeatures(in group: RemoteControlFeature.Group, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var features = features(in: group)
        guard !offsets.isEmpty, destination >= 0, destination <= features.count,
              offsets.allSatisfy({ features.indices.contains($0) }) else { return }
        guard !offsets.contains(where: { features[$0] == .mute }) else { return }
        let moving = offsets.map { features[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        for index in offsets.reversed() { features.remove(at: index) }
        features.insert(contentsOf: moving, at: insertion)
        if group == .levels { features = features.filter { $0 != .mute } + [.mute] }
        let unknown = storedOrder.filter { RemoteControlFeature(rawValue: $0) == nil }
        storedOrder = RemoteControlFeature.Group.allCases.flatMap {
            $0 == group ? features : self.features(in: $0)
        }.map(\.rawValue) + unknown
        defaults.set(storedOrder, forKey: Self.orderStorageKey)
    }

    func moveGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var groups = orderedGroups
        guard !offsets.isEmpty, destination >= 0, destination <= groups.count,
              offsets.allSatisfy({ groups.indices.contains($0) }) else { return }
        let moving = offsets.map { groups[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        for index in offsets.reversed() { groups.remove(at: index) }
        groups.insert(contentsOf: moving, at: insertion)
        let unknown = storedGroupOrder.filter { RemoteControlFeature.Group(rawValue: $0) == nil }
        storedGroupOrder = groups.map(\.rawValue) + unknown
        defaults.set(storedGroupOrder, forKey: Self.groupOrderStorageKey)
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
