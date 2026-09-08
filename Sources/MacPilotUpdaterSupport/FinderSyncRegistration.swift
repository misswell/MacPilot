import Foundation

public enum FinderSyncRegistration {
    public static let extensionBundleIdentifier = "com.misswell.macpilot.finder-sync"

    public static func registeredExtensionPaths(in plugInKitOutput: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        for rawLine in plugInKitOutput.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.contains(extensionBundleIdentifier) else { continue }

            let path: String
            if let separator = line.lastIndex(of: "\t") {
                path = String(line[line.index(after: separator)...])
            } else if let slash = line.firstIndex(of: "/") {
                path = String(line[slash...])
            } else {
                continue
            }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.hasSuffix(".appex"), seen.insert(trimmedPath).inserted else { continue }
            paths.append(trimmedPath)
        }

        return paths
    }

    public static func isElectedForUse(in plugInKitOutput: String) -> Bool {
        plugInKitOutput.split(whereSeparator: \.isNewline).contains { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("+") && line.contains(extensionBundleIdentifier)
        }
    }

    public static func registrationArguments(
        for applicationURL: URL,
        registeredExtensionPaths: [String] = [],
        restoreEnabledElection: Bool
    ) -> [[String]] {
        let extensionPath = applicationURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path

        var pathsToRemove: [String] = []
        var seen = Set<String>()
        for path in registeredExtensionPaths + [extensionPath] {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            pathsToRemove.append(path)
        }

        var arguments = pathsToRemove.map { ["-r", $0] }
        arguments.append(["-a", extensionPath])
        if restoreEnabledElection {
            arguments.append([
                "-e", "use", "-i", extensionBundleIdentifier
            ])
        }
        return arguments
    }
}
