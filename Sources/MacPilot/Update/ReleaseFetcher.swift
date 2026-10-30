import Foundation

enum ReleaseFetcher {
    /// Query independently so an unavailable repository cannot prevent the
    /// other one from returning verified releases. Cancellation stops all work.
    static func queryRepositories<Value: Sendable>(
        _ repositories: [String],
        fetch: @escaping @Sendable (String) async throws -> Value
    ) async throws -> [Value] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Result<Value, Error>).self) { group in
            for (index, repository) in repositories.enumerated() {
                group.addTask {
                    do { return (index, .success(try await fetch(repository))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var values: [(Int, Value)] = []
            var firstError: Error?
            for try await (index, result) in group {
                try Task.checkCancellation()
                switch result {
                case .success(let value): values.append((index, value))
                case .failure(let error):
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        group.cancelAll()
                        throw error
                    }
                    firstError = firstError ?? error
                    DiagnosticLog.write("SoftwareUpdate", "Release source \(repositories[index]) failed: \(error.localizedDescription)")
                }
            }
            guard !values.isEmpty else { throw firstError ?? SoftwareUpdateError.invalidResponse }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func fetchLatest(
        channel: AppChannel,
        session: URLSession,
        currentVersion: String,
        repositories: [String] = AppIdentity.updateRepositories
    ) async throws -> SoftwareRelease? {
        let releases = try await queryRepositories(repositories) { repository in
            if channel == .beta {
                return try await fetchBeta(repository: repository, session: session, currentVersion: currentVersion)
            }
            return try await fetchStable(repository: repository, session: session, currentVersion: currentVersion)
        }
        return releases.compactMap { $0 }.max { $0.version < $1.version }
    }

    static func selectBeta(_ data: Data, architecture: AppArchitecture = .current) throws -> SoftwareRelease? {
        try JSONDecoder().decode([GitHubReleaseResponse].self, from: data)
            .compactMap { try? SoftwareRelease.decode($0, architecture: architecture, channel: .beta) }
            .max { $0.version < $1.version }
    }

    /// Scan every page: GitHub orders releases by date, not SemVer precedence.
    static func fetchBeta(session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        try await fetchLatest(channel: .beta, session: session, currentVersion: currentVersion)
    }

    private static func fetchBeta(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        do {
            return try await fetchBetaFromAPI(repository: repository, session: session, currentVersion: currentVersion)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // The public API is rate limited per IP, and beta releases only
            // exist in the API — the release page carries the same tags and
            // asset digests, so a limited caller can still update.
            DiagnosticLog.write("SoftwareUpdate", "Release API \(repository) beta list failed: \(error.localizedDescription); using the release page")
        }
        return try await fetchBetaFromWeb(repository: repository, session: session, currentVersion: currentVersion)
    }

    private static func fetchBetaFromAPI(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        var page = 1
        var best: SoftwareRelease?
        while true {
            try Task.checkCancellation()
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw SoftwareUpdateError.sourceUnavailable
            }
            if let candidate = try selectBeta(data), best.map({ $0.version < candidate.version }) ?? true {
                best = candidate
            }
            guard response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true else { return best }
            page += 1
        }
    }

    /// Newest beta tag on the public release page, which lists prereleases the
    /// API's `/releases/latest` endpoint never returns.
    static func selectBetaTag(fromListPage data: Data, repository: String) -> String? {
        let html = String(decoding: data, as: UTF8.self)
        let escaped = NSRegularExpression.escapedPattern(for: repository)
        let pattern = #"href="/\#(escaped)/releases/tag/([^"?]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let tags = regex.matches(in: html, range: range).compactMap { match -> (SoftwareVersion, String)? in
            guard let tagRange = Range(match.range(at: 1), in: html) else { return nil }
            let tag = String(html[tagRange])
            guard let version = SoftwareVersion(tag),
                  version.isPrerelease,
                  version.prerelease.first == "beta" else { return nil }
            return (version, tag)
        }
        return tags.max { $0.0 < $1.0 }?.1
    }

    private static func fetchBetaFromWeb(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        let listURL = URL(string: "https://github.com/\(repository)/releases")!
        let (listData, listResponse) = try await session.data(for: request(listURL, currentVersion: currentVersion))
        guard (listResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw SoftwareUpdateError.sourceUnavailable
        }
        guard let tagName = selectBetaTag(fromListPage: listData, repository: repository) else { return nil }
        let assetsURL = URL(string: "https://github.com/\(repository)/releases/expanded_assets/\(tagName)")!
        let (data, assetsResponse) = try await session.data(for: request(assetsURL, currentVersion: currentVersion))
        guard (assetsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw SoftwareUpdateError.sourceUnavailable
        }
        var release = try SoftwareRelease.decodeGitHubAssetsHTML(
            data,
            tagName: tagName,
            channel: .beta
        )
        release.isPrerelease = true
        return release
    }

    private static func request(_ url: URL, currentVersion: String, isAPI: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if isAPI { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return request
    }

    private static func fetchStable(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let (data, response) = try await session.data(for: request(url, currentVersion: currentVersion, isAPI: true))
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw SoftwareUpdateError.invalidResponse }
        if status == 403 || status == 429 {
            return try await fetchStableFromWeb(repository: repository, session: session, currentVersion: currentVersion)
        }
        guard status == 200 else { throw SoftwareUpdateError.sourceUnavailable }
        return try SoftwareRelease.decodeGitHubResponse(data)
    }

    private static func fetchStableFromWeb(repository: String, session: URLSession, currentVersion: String) async throws -> SoftwareRelease {
        let url = URL(string: "https://github.com/\(repository)/releases/latest")!
        let (_, response) = try await session.data(for: request(url, currentVersion: currentVersion))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = response.url,
              let tagName = finalURL.pathComponents.last,
              !tagName.isEmpty, tagName != "latest" else { throw SoftwareUpdateError.sourceUnavailable }
        let assetsURL = URL(string: "https://github.com/\(repository)/releases/expanded_assets/\(tagName)")!
        let (data, assetsResponse) = try await session.data(for: request(assetsURL, currentVersion: currentVersion))
        guard (assetsResponse as? HTTPURLResponse)?.statusCode == 200 else { throw SoftwareUpdateError.sourceUnavailable }
        return try SoftwareRelease.decodeGitHubAssetsHTML(data, tagName: tagName)
    }
}
