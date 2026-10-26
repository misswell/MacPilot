import AppKit
import Foundation

/// Which of the two system entry points MacPilot keeps.
///
/// Both are on after a fresh install. Neither may be turned off while the
/// other is already off: a running app with no Dock icon and no menu-bar icon
/// has no way back into it.
struct AppPresenceSettings: Codable, Equatable {
    var showsDockIcon: Bool
    var showsMenuBarIcon: Bool

    static let standard = AppPresenceSettings()

    init(showsDockIcon: Bool = true, showsMenuBarIcon: Bool = true) {
        self.showsDockIcon = showsDockIcon
        self.showsMenuBarIcon = showsMenuBarIcon
    }

    private enum CodingKeys: String, CodingKey {
        case showsDockIcon, showsMenuBarIcon
    }

    /// Both keys decode tolerantly: a configuration written before they
    /// existed has neither, and one hand-edited to hide both must still leave
    /// a way into the app.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            showsDockIcon: try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? true,
            showsMenuBarIcon: try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarIcon) ?? true
        )
        self = normalized()
    }

    /// The menu-bar icon wins a conflict: it is the entry point that exists
    /// whether or not a window is open.
    func normalized() -> AppPresenceSettings {
        guard !showsDockIcon, !showsMenuBarIcon else { return self }
        return AppPresenceSettings(showsDockIcon: false, showsMenuBarIcon: true)
    }

    /// The settings with the Dock icon switched, or nil when that would leave
    /// no entry point at all.
    func allowingDockIconChange(to shows: Bool) -> AppPresenceSettings? {
        guard shows || showsMenuBarIcon else { return nil }
        var updated = self
        updated.showsDockIcon = shows
        return updated
    }

    /// The settings with the menu-bar icon switched, or nil when that would
    /// leave no entry point at all.
    func allowingMenuBarIconChange(to shows: Bool) -> AppPresenceSettings? {
        guard shows || showsDockIcon else { return nil }
        var updated = self
        updated.showsMenuBarIcon = shows
        return updated
    }
}

/// The one rule that is not a plain on/off switch: when the Dock icon is in
/// use and the menu bar still offers a way in, the Dock icon lives exactly as
/// long as the main window does.
///
/// The exception is the Dock-only configuration: there the icon is the single
/// way back into the app, so it has to outlive the window.
enum AppPresencePolicy {
    static func showsDockIcon(_ settings: AppPresenceSettings, isMainWindowOpen: Bool) -> Bool {
        guard settings.showsDockIcon else { return false }
        return settings.showsMenuBarIcon ? isMainWindowOpen : true
    }
}

/// Applies the two switches to the running process: the activation policy owns
/// the Dock icon, the menu-bar controller owns its status item.
///
/// Both effects are injected so tests can assert the decisions without a
/// status item or a real activation-policy change.
@MainActor
final class AppPresenceController: ObservableObject {
    @Published private(set) var settings: AppPresenceSettings
    @Published private(set) var isMainWindowOpen: Bool
    /// The last values handed to AppKit, kept so repeated decisions do not
    /// re-apply them.
    private(set) var appliedActivationPolicy: NSApplication.ActivationPolicy?

    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private var applyMenuBarIcon: (@MainActor (Bool) -> Void)?
    private var appliedMenuBarIcon: Bool?
    private var hasFinishedLaunching: Bool
    private var launchSubscription: AppPresenceLaunchSubscription?

    init(
        settings: AppPresenceSettings = .standard,
        isMainWindowOpen: Bool = false,
        isLaunched: Bool? = nil,
        notificationCenter: NotificationCenter = .default,
        applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }
    ) {
        self.settings = settings.normalized()
        self.isMainWindowOpen = isMainWindowOpen
        self.applyPolicy = applyPolicy
        hasFinishedLaunching = isLaunched ?? (NSApp?.isRunning == true)
        launchSubscription = AppPresenceLaunchSubscription(center: notificationCenter) { [weak self] in
            self?.didFinishLaunching()
        }
        // During `App.init` the process has not finished launching, and the
        // menu-bar controller does not exist yet; the launch notification is
        // what applies the stored state. A process that is already running
        // (tests, or a controller created late) has none to wait for.
        if hasFinishedLaunching { apply() }
    }
    /// Wires the menu-bar side once the status item controller exists, and
    /// applies the current value straight away.
    func attachMenuBarIcon(_ applier: @escaping @MainActor (Bool) -> Void) {
        applyMenuBarIcon = applier
        appliedMenuBarIcon = nil
        apply()
    }

    func update(settings newSettings: AppPresenceSettings) {
        let normalized = newSettings.normalized()
        guard normalized != settings else { return }
        settings = normalized
        apply()
    }

    func mainWindowVisibilityChanged(_ isOpen: Bool) {
        guard isOpen != isMainWindowOpen else { return }
        isMainWindowOpen = isOpen
        apply()
    }

    private func didFinishLaunching() {
        hasFinishedLaunching = true
        // One-shot: a second notification must not resurrect a controller
        // that has been released.
        launchSubscription = nil
        apply()
    }

    private func apply() {
        guard hasFinishedLaunching else { return }
        if appliedMenuBarIcon != settings.showsMenuBarIcon {
            appliedMenuBarIcon = settings.showsMenuBarIcon
            applyMenuBarIcon?(settings.showsMenuBarIcon)
        }
        let policy: NSApplication.ActivationPolicy = AppPresencePolicy.showsDockIcon(
            settings,
            isMainWindowOpen: isMainWindowOpen
        ) ? .regular : .accessory
        guard appliedActivationPolicy != policy else { return }
        appliedActivationPolicy = policy
        applyPolicy(policy)
    }
}

private final class AppPresenceLaunchSubscription: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, action: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    deinit { center.removeObserver(token) }
}
