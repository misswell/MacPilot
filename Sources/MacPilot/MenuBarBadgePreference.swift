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

    /// The CPU percentage is shown whenever the CPU monitor is enabled, unless
    /// the user turned the badge off. Defaults to on so an existing install
    /// keeps the number it had before this switch existed.
    static func showsCPUPercent(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: cpuPercentKey) as? Bool ?? true
    }

    static func setShowsCPUPercent(_ shows: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(shows, forKey: cpuPercentKey)
    }
}
