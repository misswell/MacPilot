import Foundation

/// Menu-bar badge preferences that do not belong to a feature's configuration.
///
/// These describe how the status item is drawn, not how a feature behaves, so
/// they stay in `UserDefaults` next to the other interface-only preferences
/// (Quick Access placement, the last capture area). Keeping them out of
/// `config.json` also means enabling the badge can never be stranded by a
/// configuration downgrade.
enum MenuBarBadgePreference {
    static let cpuPercentKey = "menuBar.showsCPUPercent"

    /// The CPU percentage stays hidden until the user asks for it. The badge is
    /// noise for most people, and a menu-bar item must not grow a number just
    /// because the CPU monitor happens to be enabled.
    static func showsCPUPercent(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: cpuPercentKey) as? Bool ?? false
    }

    static func setShowsCPUPercent(_ shows: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(shows, forKey: cpuPercentKey)
    }
}
