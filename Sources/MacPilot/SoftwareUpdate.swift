import AppKit
import CryptoKit
import Foundation

struct SoftwareVersion: Comparable, Hashable, CustomStringConvertible {
    private let components: [Int]

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.compactMap({ Int($0) }).count == pieces.count else { return nil }
        components = pieces.compactMap { Int($0) }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func == (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        normalized(lhs.components) == normalized(rhs.components)
    }

    static func < (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Self.normalized(components))
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1 && result.last == 0 { result.removeLast() }
        return result
    }
}

struct SoftwareRelease: Equatable {
    let version: SoftwareVersion
    let releaseNotes: String
    let archiveURL: URL
    let sha256: String

    func isNewer(than currentVersion: String) -> Bool {
        guard let current = SoftwareVersion(currentVersion) else { return false }
        return current < version
    }

    static func decodeGitHubResponse(
        _ data: Data,
        architecture: AppArchitecture = .current
    ) throws -> SoftwareRelease {
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard !response.draft, !response.prerelease,
              let version = SoftwareVersion(response.tagName) else {
            throw SoftwareUpdateError.invalidRelease
        }
        let expectedNames = AppIdentity.archiveNames(
            for: version.description,
            architecture: architecture
        )
        guard let asset = expectedNames.lazy
            .compactMap({ expectedName in response.assets.first { $0.name == expectedName } })
            .first(where: { asset in
                guard asset.url.scheme == "https",
                      let digest = asset.digest,
                      digest.hasPrefix("sha256:") else {
                    return false
                }
                let value = String(digest.dropFirst("sha256:".count)).lowercased()
                return value.count == 64 && value.allSatisfy(\.isHexDigit)
            }),
              let digest = asset.digest else {
            throw SoftwareUpdateError.missingVerifiedArchive
        }
        let sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw SoftwareUpdateError.missingVerifiedArchive
        }
        return SoftwareRelease(
            version: version,
            releaseNotes: response.body,
            archiveURL: asset.url,
            sha256: sha256
        )
    }
}

enum SoftwareUpdateError: Error, Equatable {
    case invalidRelease
    case missingVerifiedArchive
    case invalidResponse
    case digestMismatch
    case invalidApplication
    case versionMismatch
    case invalidSignature
    case wrongDeveloperTeam
    case gatekeeperRejected
    case installationUnavailable
    case updaterHelperMissing
    case commandFailed(String)
}

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let url: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
    }
}

struct SoftwareUpdateFailure: Equatable {
    enum Message: String {
        case release = "updateErrorRelease"
        case integrity = "updateErrorIntegrity"
        case verification = "updateErrorVerification"
        case location = "updateErrorLocation"
        case helper = "updateErrorHelper"
        case network = "updateErrorNetwork"
        case command = "updateErrorCommand"
    }

    let message: Message
    let detail: String?

    init(_ error: Error) {
        guard let error = error as? SoftwareUpdateError else {
            message = .network
            detail = error.localizedDescription
            return
        }
        switch error {
        case .invalidRelease, .missingVerifiedArchive, .invalidResponse:
            message = .release
            detail = nil
        case .digestMismatch:
            message = .integrity
            detail = nil
        case .invalidApplication, .versionMismatch, .invalidSignature, .wrongDeveloperTeam, .gatekeeperRejected:
            message = .verification
            detail = nil
        case .installationUnavailable:
            message = .location
            detail = nil
        case .updaterHelperMissing:
            message = .helper
            detail = nil
        case .commandFailed(let message):
            self.message = .command
            detail = message
        }
    }
}

enum SoftwareUpdateState: Equatable {
    enum Activity: String {
        case checking = "checkingForUpdates"
        case downloading = "downloadingUpdate"
        case installing = "preparingUpdate"
    }

    case idle
    case checking
    case upToDate
    case available(SoftwareRelease)
    case downloading(SoftwareRelease)
    case installing(SoftwareRelease)
    case failed(SoftwareUpdateFailure)

    var activity: Activity? {
        switch self {
        case .checking: .checking
        case .downloading: .downloading
        case .installing: .installing
        default: nil
        }
    }

    var isBusy: Bool { activity != nil }

    var availableRelease: SoftwareRelease? {
        switch self {
        case .available(let release), .downloading(let release), .installing(let release): release
        default: nil
        }
    }
}

@MainActor
final class SoftwareUpdater: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(AppIdentity.githubRepository)/releases/latest")!

    @Published private(set) var state: SoftwareUpdateState = .idle
    let currentVersion: String

    private let session: URLSession
    private let applicationURL: URL

    init(
        currentVersion: String = AppVersionInfo.current().version,
        session: URLSession = .shared,
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        self.currentVersion = currentVersion
        self.session = session
        self.applicationURL = applicationURL
    }

    func checkForUpdates() async {
        guard !state.isBusy else { return }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            state = release.isNewer(than: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed(SoftwareUpdateFailure(error))
        }
    }

    func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        state = .downloading(release)
        do {
            let (downloadURL, response) = try await session.download(from: release.archiveURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SoftwareUpdateError.invalidResponse
            }
            state = .installing(release)
            let package = try await Task.detached(priority: .userInitiated) {
                try UpdatePackageValidator.prepare(downloadURL: downloadURL, release: release)
            }.value
            try launchInstaller(for: package)
            NSApp.terminate(nil)
        } catch {
            state = .failed(SoftwareUpdateFailure(error))
        }
    }

    private func fetchLatestRelease() async throws -> SoftwareRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SoftwareUpdateError.invalidResponse
        }
        return try SoftwareRelease.decodeGitHubResponse(data)
    }

    private func launchInstaller(for package: VerifiedUpdatePackage) throws {
        guard applicationURL.pathExtension == "app",
              AppIdentity.isKnownBundleIdentifier(Bundle(url: applicationURL)?.bundleIdentifier),
              FileManager.default.isWritableFile(atPath: applicationURL.deletingLastPathComponent().path) else {
            throw SoftwareUpdateError.installationUnavailable
        }
        guard let bundledHelper = AppIdentity.updaterURLs(in: applicationURL)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SoftwareUpdateError.updaterHelperMissing
        }

        let helperDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotUpdater-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helperURL = helperDirectory.appendingPathComponent("MacPilotUpdater")
        try FileManager.default.copyItem(at: bundledHelper, to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacPilot/update.log")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            package.applicationURL.path,
            applicationURL.path,
            package.workingDirectory.path,
            helperDirectory.path,
            logURL.path
        ]
        try process.run()
    }
}

struct VerifiedUpdatePackage: Sendable {
    let applicationURL: URL
    let workingDirectory: URL
}

enum UpdatePackageValidator {
    private static let developerTeamIdentifier = "U8U443D7ZL"

    static func prepare(downloadURL: URL, release: SoftwareRelease) throws -> VerifiedUpdatePackage {
        let digest = try sha256(of: downloadURL)
        guard digest == release.sha256 else { throw SoftwareUpdateError.digestMismatch }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        do {
            let archiveURL = workingDirectory.appendingPathComponent("update.zip")
            try FileManager.default.copyItem(at: downloadURL, to: archiveURL)
            try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, workingDirectory.path])

            guard let applicationURL = AppIdentity.applicationURLs(in: workingDirectory).first(where: {
                guard let bundle = Bundle(url: $0) else { return false }
                return AppIdentity.isKnownBundleIdentifier(bundle.bundleIdentifier)
            }),
            let bundle = Bundle(url: applicationURL) else {
                throw SoftwareUpdateError.invalidApplication
            }
            guard let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                  AppIdentity.knownExecutableNames.contains(executableName),
                  FileManager.default.isExecutableFile(
                      atPath: applicationURL.appendingPathComponent("Contents/MacOS/\(executableName)").path
                  ),
                  AppIdentity.updaterURLs(in: applicationURL)
                      .contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw SoftwareUpdateError.invalidApplication
            }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard version.flatMap(SoftwareVersion.init) == release.version else {
                throw SoftwareUpdateError.versionMismatch
            }

            try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", applicationURL.path])
            let signatureDetails = try run(
                "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", applicationURL.path]
            )
            guard signatureDetails.contains("TeamIdentifier=\(developerTeamIdentifier)") else {
                throw SoftwareUpdateError.wrongDeveloperTeam
            }
            do {
                try run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", applicationURL.path])
            } catch {
                throw SoftwareUpdateError.gatekeeperRejected
            }
            return VerifiedUpdatePackage(applicationURL: applicationURL, workingDirectory: workingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if executable == "/usr/bin/codesign" { throw SoftwareUpdateError.invalidSignature }
            throw SoftwareUpdateError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
