import AppKit
import CryptoKit
import Foundation

/// Why a release was selected for installation. The distinction is semantic,
/// not cosmetic: automatic updates only ever move forward, while every manual
/// intent may target any verified release, including historical ones.
enum InstallationIntent: String, Codable, Equatable, Sendable {
    case automatic
    case manualUpgrade
    case manualDowngrade
    case channelSwitch
    /// 保护快照：不是版本切换，而是恢复配置前为当前状态留下的还原点。
    case configurationRestore
}

struct SoftwareRelease: Equatable, Sendable {
    let version: SoftwareVersion
    let releaseNotes: String
    let archiveURL: URL
    let sha256: String
    var isPrerelease: Bool = false
    var publishedAt: Date? = nil

    func isNewer(than currentVersion: String) -> Bool {
        guard let current = SoftwareVersion(currentVersion) else { return false }
        return current < version
    }

    static func decodeGitHubResponse(
        _ data: Data,
        architecture: AppArchitecture = .current,
        channel: AppChannel = .stable
    ) throws -> SoftwareRelease {
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        return try decode(response, architecture: architecture, channel: channel)
    }

    static func decode(_ response: GitHubReleaseResponse, architecture: AppArchitecture, channel: AppChannel) throws -> SoftwareRelease {
        guard !response.draft, response.prerelease == (channel == .beta),
              let version = SoftwareVersion(response.tagName),
              version.isPrerelease == response.prerelease,
              channel != .beta || version.prerelease.first == "beta" else {
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
            releaseNotes: response.body ?? "",
            archiveURL: asset.url,
            sha256: sha256,
            isPrerelease: response.prerelease,
            publishedAt: response.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
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
        guard let version = SoftwareVersion(tagName), !version.isPrerelease else {
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
    case systemTooOld
    case invalidSignature
    case wrongDeveloperTeam
    case identityMismatch
    case gatekeeperRejected
    case installationUnavailable
    case updaterHelperMissing
    case commandFailed(String)
}

struct GitHubReleaseResponse: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
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
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
        case publishedAt = "published_at"
    }
}

struct SoftwareUpdateFailure: Equatable {
    enum Message: String {
        case release = "updateErrorRelease"
        case integrity = "updateErrorIntegrity"
        case verification = "updateErrorVerification"
        case system = "updateErrorSystem"
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
        case .systemTooOld:
            message = .system
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
    private(set) var channel: AppChannel = .stable
    private var channelRevision = 0

    private let session: URLSession
    private let applicationURL: URL
    /// Set by the Version Switch integration so update checks and installs
    /// stand down while a version switch transaction owns the app.
    var isVersionSwitchInProgress: () -> Bool = { false }
    /// Pre-install transaction for manual version switches (freeze, snapshot,
    /// channel change). Installed by the model; automatic updates run without.
    var manualTransaction: ((SoftwareRelease, InstallationIntent, VerifiedUpdatePackage) async throws -> Void)?

    init(
        currentVersion: String = AppVersionInfo.current().version,
        session: URLSession = .shared,
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        self.currentVersion = currentVersion
        self.session = session
        self.applicationURL = applicationURL
    }

    func setChannel(_ channel: AppChannel) {
        guard self.channel != channel else { return }
        self.channel = channel
        channelRevision += 1
        if state.activity != .downloading && state.activity != .installing { state = .idle }
    }

    func checkForUpdates() async {
        guard !state.isBusy, !isVersionSwitchInProgress() else { return }
        state = .checking
        let revision = channelRevision
        let requestedChannel = channel
        do {
            let release = try await fetchLatestRelease(channel: requestedChannel)
            guard revision == channelRevision else { return }
            state = release.map { $0.isNewer(than: currentVersion) ? .available($0) : .upToDate } ?? .upToDate
        } catch {
            guard revision == channelRevision else { return }
            state = .failed(SoftwareUpdateFailure(error))
        }
    }

    /// The single install entry point. Automatic updates keep the strict
    /// newer-only rule; manual intents accept any verified release other than
    /// the running one and route the pre-install transaction (configuration
    /// freeze, protection snapshot, channel switch) through `manualTransaction`.
    func install(release: SoftwareRelease, intent: InstallationIntent) async {
        guard !state.isBusy, !isVersionSwitchInProgress() else { return }
        switch intent {
        case .automatic:
            // 自动更新永远只向前。Downgrades exist exclusively in the Version
            // Manager, where the user explicitly picked a target release.
            guard release.isNewer(than: currentVersion) else {
                state = .upToDate
                return
            }
        case .manualUpgrade, .manualDowngrade, .channelSwitch:
            guard release.version != SoftwareVersion(currentVersion) else { return }
        case .configurationRestore:
            // 配置恢复不安装任何版本，不会走到这里；按手动安装的规则兜底。
            guard release.version != SoftwareVersion(currentVersion) else { return }
        }
        do {
            let package = try await downloadAndValidate(release)
            guard let manualTransaction else {
                try launchInstaller(for: package)
                requestTerminateAfterInstall()
                return
            }
            // Manual switches run the full transaction; on success the
            // coordinator terminates the app after the updater takes over.
            try await manualTransaction(release, intent, package)
        } catch {
            // The user-facing message groups several distinct checks; keep the
            // exact reason in the diagnostic log so a failed update stays
            // diagnosable without reading the validator source.
            DiagnosticLog.write("SoftwareUpdate", "Update failed: \(String(describing: error))")
            state = .failed(SoftwareUpdateFailure(error))
        }
    }

    func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        await install(release: release, intent: .automatic)
    }

    /// Downloads the release archive through the shared mirror chain and runs
    /// the full package validation. Automatic updates and version switches
    /// converge here: exactly one downloader, exactly one validator.
    func downloadAndValidate(
        _ release: SoftwareRelease,
        isCancelled: @escaping () -> Bool = { false },
        fetch: ((URLRequest) async throws -> (URL, URLResponse))? = nil
    ) async throws -> VerifiedUpdatePackage {
        state = .downloading(release)
        // `isCancelled` 是"已取消"语义，下载链要的是"继续"语义，这里取反。
        // 传反了会让每次下载在第一个镜像前就抛 CancellationError。
        let fetchArchive = fetch ?? { request in try await self.session.download(for: request) }
        let downloadURL = try await UpdateArchiveDownloader.download(
            release: release,
            preferredHost: UserDefaults.standard.string(forKey: "updateDownloadMirrorHost"),
            shouldContinue: { !isCancelled() },
            didVerifySource: { source in
                if source.host != release.archiveURL.host {
                    UserDefaults.standard.set(source.host, forKey: "updateDownloadMirrorHost")
                } else {
                    UserDefaults.standard.removeObject(forKey: "updateDownloadMirrorHost")
                }
            },
            fetch: fetchArchive
        )
        defer { try? FileManager.default.removeItem(at: downloadURL) }
        state = .installing(release)
        return try await Task.detached(priority: .userInitiated) {
            try UpdatePackageValidator.prepare(downloadURL: downloadURL, release: release)
        }.value
    }

    private func fetchLatestRelease(channel: AppChannel) async throws -> SoftwareRelease? {
        try await ReleaseFetcher.fetchLatest(
            channel: channel,
            session: session,
            currentVersion: currentVersion
        )
    }

    /// Launches MacPilotUpdater for an already validated package. When
    /// `successTokenID` is set, the updater keeps the previous bundle as a
    /// rollback copy until the relaunched app confirms it runs stably.
    func launchInstaller(for package: VerifiedUpdatePackage, successTokenID: UUID? = nil) throws {
        guard !Bundle.main.bundleURL.path.contains("/AppTranslocation/") else {
            throw SoftwareUpdateError.installationUnavailable
        }
        guard applicationURL.pathExtension == "app",
              AppIdentity.isKnownBundleIdentifier(Bundle(url: applicationURL)?.bundleIdentifier),
              FileManager.default.isWritableFile(atPath: applicationURL.deletingLastPathComponent().path) else {
            throw SoftwareUpdateError.installationUnavailable
        }
        let bundledHelper = try installerHelperURL(for: package)

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
        if let successTokenID {
            process.arguments!.append(VersionManagerPaths.successTokenURL(id: successTokenID).path)
        }
        do {
            try process.run()
        } catch {
            // Nothing else owns these directories until the helper starts: the
            // extracted app is a hundred-odd megabytes, and a failed launch
            // would otherwise leave it in the temp folder forever.
            try? FileManager.default.removeItem(at: helperDirectory)
            try? FileManager.default.removeItem(at: package.workingDirectory)
            throw error
        }
    }

    func installerHelperURL(for package: VerifiedUpdatePackage) throws -> URL {
        guard let targetBundle = Bundle(url: package.applicationURL),
              let targetVersion = SoftwareVersion(AppVersionInfo.current(bundle: targetBundle).version) else {
            throw SoftwareUpdateError.invalidApplication
        }
        // The verified target carries installer fixes needed for this upgrade.
        // Using the running app's helper would strand an installation whenever
        // that older helper is the component preventing updates. On downgrades,
        // keep the newer installed helper instead of reintroducing its bugs.
        let installedVersion = Bundle(url: applicationURL)
            .flatMap { SoftwareVersion(AppVersionInfo.current(bundle: $0).version) }
        let helperApplication = installedVersion.map { $0 > targetVersion } == true
            ? applicationURL : package.applicationURL
        guard let helper = AppIdentity.updaterURLs(in: helperApplication)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SoftwareUpdateError.updaterHelperMissing
        }
        return helper
    }

    /// The updater helper polls for this process to exit and gives up after
    /// 60 seconds (UpdaterMain.waitForParent). NSApp.terminate is a silent
    /// no-op while any window still has a sheet attached — the Version
    /// Manager sheet is necessarily open for every manual switch — so after
    /// requesting the graceful quit we fall back to a hard exit well inside
    /// the helper's window. Everything the switch needed to persist is
    /// already on disk by the time awaitingRelaunch is reached.
    func requestTerminateAfterInstall() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // A display recovery transaction owns its virtual output. Forced
            // exit must not bypass the asynchronous restoration barrier.
            guard DisplayControlTermination.mayForceExit else { return }
            exit(0)
        }
    }
}

enum UpdateArchiveDownloader {
    /// Only rewrite this application's public GitHub release assets. Metadata
    /// and its expected digest continue to come directly from GitHub.
    static func sources(for original: URL, preferredHost: String? = nil) -> [URL] {
        guard original.scheme == "https", original.host == "github.com",
              original.user == nil, original.password == nil, original.port == nil,
              AppIdentity.updateRepositories.contains(where: {
                  original.path.hasPrefix("/\($0)/releases/download/")
              }),
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
        shouldContinue: () -> Bool = { true },
        isolation: isolated (any Actor)? = #isolation,
        didVerifySource: (URL) -> Void = { _ in },
        fetch: (URLRequest) async throws -> (URL, URLResponse)
    ) async throws -> URL {
        var lastError: any Error = SoftwareUpdateError.invalidResponse
        for source in sources(for: release.archiveURL, preferredHost: preferredHost) {
            guard shouldContinue() else { throw CancellationError() }
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
                    guard shouldContinue() else {
                        try? FileManager.default.removeItem(at: file)
                        throw CancellationError()
                    }
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
            // Unzip straight from the downloaded archive. Copying it into the
            // staging directory first doubled the footprint of a hundred-odd
            // megabyte download, and had ditto read from a file sitting inside
            // the directory it was writing.
            try run("/usr/bin/ditto", arguments: ["-x", "-k", downloadURL.path, workingDirectory.path])

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
            let version = AppVersionInfo.current(bundle: bundle).version
            guard SoftwareVersion(version) == release.version else {
                throw SoftwareUpdateError.versionMismatch
            }
            // A downgrade target may predate this Mac's system version; reject
            // it before anything replaces the installed app.
            if let minimumSystemVersion = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
               !Self.currentSystemSatisfies(minimumSystemVersion) {
                throw SoftwareUpdateError.systemTooOld
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

    /// Whether this Mac satisfies an `LSMinimumSystemVersion` string such as
    /// "14.0" or "15.4.1".
    static func currentSystemSatisfies(_ minimumSystemVersion: String) -> Bool {
        let parts = minimumSystemVersion
            .split(separator: ".")
            .compactMap { Int($0) }
        guard !parts.isEmpty else { return true }
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let required = (parts + [0, 0]).prefix(3).map { $0 }
        let running = [current.majorVersion, current.minorVersion, current.patchVersion]
        for (need, have) in zip(required, running) where need != have {
            return have > need
        }
        return true
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.hashChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 1 MB — the archive is hundreds of megabytes and is hashed twice per
    /// install, so the read has to stream. See `sha256(of:)`.
    private static let hashChunkSize = 1_048_576

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a pipe holds 64 KB, so a chatty `ditto`/`codesign`
        // fills it and blocks on write while the parent blocks on exit.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if executable == "/usr/bin/codesign" { throw SoftwareUpdateError.invalidSignature }
            throw SoftwareUpdateError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
