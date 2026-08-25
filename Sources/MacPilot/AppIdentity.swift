import Foundation

enum AppArchitecture: String, CaseIterable {
    case arm64
    case x86_64

    static let current: Self = {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .arm64
        #endif
    }()
}

enum AppIdentity {
    static let name = "MacPilot"
    static let bundleIdentifier = "com.misswell.macpilot"
    static let legacyBundleIdentifier = "com.misswell.octopilot"
    static let githubRepository = "misswell/MacPilot"

    static let appBundleName = "MacPilot.app"
    static let legacyAppBundleName = "OctoPilot.app"
    static let executableName = "MacPilot"
    static let legacyExecutableName = "OctoPilot"
    static let updaterExecutableName = "MacPilotUpdater"
    static let legacyUpdaterExecutableName = "OctoPilotUpdater"
    static let configurationDirectoryName = "MacPilot"
    static let legacyConfigurationDirectoryNames = ["OctoPilot", "OctoQuit"]

    static var knownBundleIdentifiers: [String] {
        [bundleIdentifier, legacyBundleIdentifier]
    }

    static var knownAppBundleNames: [String] {
        [appBundleName, legacyAppBundleName]
    }

    static var knownUpdaterExecutableNames: [String] {
        [updaterExecutableName, legacyUpdaterExecutableName]
    }

    static var knownExecutableNames: [String] {
        [executableName, legacyExecutableName]
    }

    static func isKnownBundleIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return knownBundleIdentifiers.contains(identifier)
    }

    static func archiveNames(
        for version: String,
        architecture: AppArchitecture = .current
    ) -> [String] {
        [
            "MacPilot-\(version)-\(architecture.rawValue)-macos.zip",
            "MacPilot-\(version)-macos.zip",
            "OctoPilot-\(version)-\(architecture.rawValue)-macos.zip",
            "OctoPilot-\(version)-macos.zip"
        ]
    }

    static func applicationURLs(in directory: URL) -> [URL] {
        knownAppBundleNames.map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    static func updaterURLs(in applicationURL: URL) -> [URL] {
        knownUpdaterExecutableNames.map {
            applicationURL.appendingPathComponent("Contents/MacOS/\($0)")
        }
    }
}
