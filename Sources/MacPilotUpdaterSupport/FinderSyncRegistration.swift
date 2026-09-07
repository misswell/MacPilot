import Foundation

public enum FinderSyncRegistration {
    public static let extensionBundleIdentifier = "com.misswell.macpilot.finder-sync"

    public static func isElectedForUse(in plugInKitOutput: String) -> Bool {
        plugInKitOutput.split(whereSeparator: \.isNewline).contains { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("+") && line.contains(extensionBundleIdentifier)
        }
    }

    public static func registrationArguments(
        for applicationURL: URL,
        restoreEnabledElection: Bool
    ) -> [[String]] {
        let extensionPath = applicationURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path

        var arguments = [["-a", extensionPath]]
        if restoreEnabledElection {
            arguments.append([
                "-e", "use", "-i", extensionBundleIdentifier
            ])
        }
        return arguments
    }
}
