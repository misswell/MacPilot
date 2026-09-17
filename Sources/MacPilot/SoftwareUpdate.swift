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

    /// GitHub's public API is rate-limited by the caller's shared IP. When
    /// that limit is exhausted, the public release page still exposes the
    /// verified asset links and digests without requiring authentication.
    static func decodeGitHubAssetsHTML(
        _ data: Data,
        tagName: String,
        architecture: AppArchitecture = .current
    ) throws -> SoftwareRelease {
        guard let version = SoftwareVersion(tagName) else {
            throw SoftwareUpdateError.invalidRelease
        }
        let expectedNames = AppIdentity.archiveNames(
            for: version.description,
            architecture: architecture
        )
        let html = String(decoding: data, as: UTF8.self)
        let pattern = #"href="(/[^"]+/releases/download/[^/]+/([^"/]+\.zip))"[\s\S]*?sha256:([0-9a-fA-F]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw SoftwareUpdateError.invalidRelease
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let assets = regex.matches(in: html, range: range).compactMap { match -> (String, URL, String)? in
            guard let pathRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let digestRange = Range(match.range(at: 3), in: html),
                  let url = URL(string: "https://github.com\(html[pathRange])") else {
                return nil
            }
            return (String(html[nameRange]), url, String(html[digestRange]).lowercased())
        }
        guard let asset = expectedNames.lazy
            .compactMap({ expectedName in assets.first { $0.0 == expectedName } })
            .first else {
            throw SoftwareUpdateError.missingVerifiedArchive
        }
        return SoftwareRelease(
            version: version,
            releaseNotes: "",
            archiveURL: asset.1,
            sha256: asset.2
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
    case identityMismatch
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
        case .invalidApplication, .versionMismatch, .invalidSignature, .wrongDeveloperTeam, .identityMismatch, .gatekeeperRejected:
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
    static let latestReleasePageURL = URL(string: "https://github.com/\(AppIdentity.githubRepository)/releases/latest")!

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
            let downloadURL = try await UpdateArchiveDownloader.download(
                release: release,
                preferredHost: UserDefaults.standard.string(forKey: "updateDownloadMirrorHost"),
                didVerifySource: { source in
                    if source.host != release.archiveURL.host {
                        UserDefaults.standard.set(source.host, forKey: "updateDownloadMirrorHost")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "updateDownloadMirrorHost")
                    }
                }
            ) { request in
                try await self.session.download(for: request)
            }
            defer { try? FileManager.default.removeItem(at: downloadURL) }
            state = .installing(release)
            let package = try await Task.detached(priority: .userInitiated) {
                try UpdatePackageValidator.prepare(downloadURL: downloadURL, release: release)
            }.value
            try launchInstaller(for: package)
            NSApp.terminate(nil)
        } catch {
            // The user-facing message groups several distinct checks; keep the
            // exact reason in the diagnostic log so a failed update stays
            // diagnosable without reading the validator source.
            DiagnosticLog.write("SoftwareUpdate", "Update failed: \(String(describing: error))")
            state = .failed(SoftwareUpdateFailure(error))
        }
    }

    private func fetchLatestRelease() async throws -> SoftwareRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw SoftwareUpdateError.invalidResponse
        }
        if statusCode == 403 {
            return try await fetchLatestReleaseFromWeb()
        }
        guard statusCode == 200 else {
            throw SoftwareUpdateError.invalidResponse
        }
        return try SoftwareRelease.decodeGitHubResponse(data)
    }

    private func fetchLatestReleaseFromWeb() async throws -> SoftwareRelease {
        var latestRequest = URLRequest(url: Self.latestReleasePageURL)
        latestRequest.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        latestRequest.timeoutInterval = 20
        let (_, latestResponse) = try await session.data(for: latestRequest)
        guard (latestResponse as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = latestResponse.url,
              let tagName = finalURL.pathComponents.last,
              !tagName.isEmpty,
              tagName != "latest" else {
            throw SoftwareUpdateError.invalidResponse
        }

        guard let assetsURL = URL(string: "https://github.com/\(AppIdentity.githubRepository)/releases/expanded_assets/\(tagName)") else {
            throw SoftwareUpdateError.invalidResponse
        }
        var assetsRequest = URLRequest(url: assetsURL)
        assetsRequest.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        assetsRequest.timeoutInterval = 20
        let (assetsData, assetsResponse) = try await session.data(for: assetsRequest)
        guard (assetsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw SoftwareUpdateError.invalidResponse
        }
        return try SoftwareRelease.decodeGitHubAssetsHTML(assetsData, tagName: tagName)
    }

    private func launchInstaller(for package: VerifiedUpdatePackage) throws {
        guard !Bundle.main.bundleURL.path.contains("/AppTranslocation/") else {
            throw SoftwareUpdateError.installationUnavailable
        }
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

enum UpdateArchiveDownloader {
    /// Only rewrite this application's public GitHub release assets. Metadata
    /// and its expected digest continue to come directly from GitHub.
    static func sources(for original: URL, preferredHost: String? = nil) -> [URL] {
        guard original.scheme == "https", original.host == "github.com",
              original.user == nil, original.password == nil, original.port == nil,
              original.path.hasPrefix("/\(AppIdentity.githubRepository)/releases/download/"),
              var mirror = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            return [original]
        }
        mirror.host = "xget.xi-xu.me"
        mirror.percentEncodedPath = "/gh" + mirror.percentEncodedPath
        guard let mirrorURL = mirror.url else { return [original] }
        var mirrors = [mirrorURL] + ["ghfast.top", "gh-proxy.org"].compactMap {
            URL(string: "https://\($0)/\(original.absoluteString)")
        }
        if let index = mirrors.firstIndex(where: { $0.host == preferredHost }) {
            mirrors.insert(mirrors.remove(at: index), at: 0)
        }
        return mirrors + [original]
    }

    static func download(
        release: SoftwareRelease,
        preferredHost: String? = nil,
        isolation: isolated (any Actor)? = #isolation,
        didVerifySource: (URL) -> Void = { _ in },
        fetch: (URLRequest) async throws -> (URL, URLResponse)
    ) async throws -> URL {
        var lastError: any Error = SoftwareUpdateError.invalidResponse
        for source in sources(for: release.archiveURL, preferredHost: preferredHost) {
            try Task.checkCancellation()
            var request = URLRequest(url: source)
            // Bound a stalled source so an unreachable mirror cannot prevent
            // the final direct attempt. Active transfers can keep receiving.
            request.timeoutInterval = 15
            request.setValue("MacPilot", forHTTPHeaderField: "User-Agent")
            do {
                let (file, response) = try await fetch(request)
                do {
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw SoftwareUpdateError.invalidResponse
                    }
                    let digest = try await Task.detached(priority: .utility) {
                        try UpdatePackageValidator.sha256(of: file)
                    }.value
                    guard digest == release.sha256 else { throw SoftwareUpdateError.digestMismatch }
                    try Task.checkCancellation()
                    didVerifySource(source)
                    return file
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                try Task.checkCancellation()
                lastError = error
                DiagnosticLog.write("SoftwareUpdate", "Download source \(source.host ?? "unknown") failed: \(error)")
            }
        }
        throw lastError
    }
}

struct VerifiedUpdatePackage: Sendable {
    let applicationURL: URL
    let workingDirectory: URL
}

enum UpdatePackageValidator {
    /// The team every MacPilot build must be signed by. This is the same value
    /// the build script pins into the designated requirement
    /// (`Scripts/signing-requirement.sh`); `SigningRequirementTests` asserts the
    /// two never drift apart, because an update signed by another team must be
    /// rejected while our own development and release builds must stay
    /// interchangeable.
    static let developerTeamIdentifier = "U8U443D7ZL"

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
            // Privacy grants (Accessibility, Screen Recording, Apple Events)
            // are recorded together with a requirement derived from the
            // designated requirement of the app that was granted, and macOS
            // validates that recorded requirement against the candidate's
            // certificate chain. An incoming app therefore keeps every grant
            // whenever it satisfies the running app's requirement, even when
            // the two requirements are not textually identical -- and they are
            // not always: a signing host that cannot see Apple's Developer ID
            // intermediate writes a weaker requirement than the canonical
            // Developer ID one. Compare semantics rather than text, or a
            // legitimate update gets rejected as an identity change.
            let runningRequirement = try designatedRequirement(of: Bundle.main.bundleURL)
            guard !runningRequirement.isEmpty,
                  satisfies(runningRequirement, at: applicationURL) else {
                throw SoftwareUpdateError.identityMismatch
            }
            do {
                try run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", applicationURL.path])
            } catch {
                throw SoftwareUpdateError.gatekeeperRejected
            }
            // Drop the Gatekeeper quarantine attribute from the verified
            // update so the relaunched app is not translocated to a
            // randomized path, which would re-prompt privacy grants.
            stripQuarantine(from: applicationURL)
            return VerifiedUpdatePackage(applicationURL: applicationURL, workingDirectory: workingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    /// The designated requirement of the signed bundle at `bundleURL`
    /// (everything after "designated =>" in `codesign -d -r-` output), or
    /// an empty string when it cannot be determined.
    static func designatedRequirement(of bundleURL: URL) throws -> String {
        let output = try run(
            "/usr/bin/codesign",
            arguments: ["--display", "-r-", bundleURL.path]
        )
        return Self.parseDesignatedRequirement(from: output)
    }

    static func parseDesignatedRequirement(from codesignOutput: String) -> String {
        for line in codesignOutput.split(separator: "\n") {
            if line.contains("designated"), let range = line.range(of: "=> ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// Whether the code at `bundleURL` satisfies `requirement`. This is the
    /// check macOS performs against the requirement recorded when a privacy
    /// grant was made, so it is also the right test for "does this update keep
    /// the grants the running app already has".
    static func satisfies(_ requirement: String, at bundleURL: URL) -> Bool {
        guard !requirement.isEmpty else { return false }
        do {
            try run(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "-R", "=\(requirement)", bundleURL.path]
            )
            return true
        } catch {
            return false
        }
    }

    /// Removes the Gatekeeper quarantine attribute; a no-op when the
    /// attribute is absent.
    private static func stripQuarantine(from applicationURL: URL) {
        _ = try? run("/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", applicationURL.path])
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
