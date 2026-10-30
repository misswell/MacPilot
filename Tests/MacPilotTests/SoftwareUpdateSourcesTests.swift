import Foundation
import Testing
@testable import MacPilot

extension SoftwareUpdateTests {
    @MainActor @Test(arguments: [AppChannel.stable, .beta], ["oldUnavailable", "newUnavailable", "oldNewest", "newNewest"])
    func bothReleaseRepositoriesAreCheckedAndTheNewestUsableVersionWins(channel: AppChannel, scenario: String) async throws {
        let session = sourceSession(scenario)
        defer { session.invalidateAndCancel() }
        let updater = SoftwareUpdater(currentVersion: "1.0.0", session: session)
        updater.setChannel(channel)
        await updater.checkForUpdates()
        let release = try #require(updater.state.availableRelease)
        let version = scenario == "oldNewest" ? "1.9.0" : scenario == "newUnavailable" ? "1.8.0" : "2.0.0"
        #expect(release.version.description == version + (channel == .beta ? "-beta.1" : ""))
        let expectedRepository = ["oldNewest", "newUnavailable"].contains(scenario) ? "misswell/MacPilot" : "jollyfon/MacPilot"
        #expect(release.archiveURL.path.hasPrefix("/\(expectedRepository)/releases/download/"))
    }

    @MainActor @Test(arguments: [AppChannel.stable, .beta])
    func anOutageOfBothReleaseRepositoriesRemainsAnUpdateFailure(channel: AppChannel) async {
        let session = sourceSession("allFailed")
        defer { session.invalidateAndCancel() }
        let updater = SoftwareUpdater(currentVersion: "1.0.0", session: session)
        updater.setChannel(channel)
        await updater.checkForUpdates()
        if case .failed = updater.state {} else { Issue.record("Both unavailable feeds must report failure") }
    }

    @MainActor @Test
    func aReachableEmptyBetaFeedCanCompleteWhenTheOtherRepositoryIsUnavailable() async {
        let session = sourceSession("empty")
        defer { session.invalidateAndCancel() }
        let updater = SoftwareUpdater(currentVersion: "1.0.0", session: session)
        updater.setChannel(.beta)
        await updater.checkForUpdates()
        #expect(updater.state == .upToDate)
    }

    @MainActor @Test
    func theNewRepositoryKeepsItsOwnStableWebFallback() async throws {
        let session = sourceSession("newWeb")
        defer { session.invalidateAndCancel() }
        let updater = SoftwareUpdater(currentVersion: "1.0.0", session: session)
        await updater.checkForUpdates()
        let release = try #require(updater.state.availableRelease)
        #expect(release.version.description == "2.0.0")
        #expect(release.archiveURL.path.hasPrefix("/jollyfon/MacPilot/releases/download/"))
    }

    @MainActor @Test
    func aRateLimitedBetaAPIFallsBackToTheReleasePage() async throws {
        let session = sourceSession("betaWeb")
        defer { session.invalidateAndCancel() }
        let updater = SoftwareUpdater(currentVersion: "1.0.0", session: session)
        updater.setChannel(.beta)
        await updater.checkForUpdates()

        let release = try #require(updater.state.availableRelease)
        #expect(release.version.description == "2.0.0-beta.3")
        #expect(release.isPrerelease)
        #expect(release.archiveURL.path.hasPrefix("/jollyfon/MacPilot/releases/download/v2.0.0-beta.3/"))
    }

    @Test func theBetaTagParserIgnoresStableTagsAndOtherRepositories() {
        let html = Data("""
        <a href="/misswell/MacPilot/releases/tag/v1.2.2-beta.9">b9</a>
        <a href="/misswell/MacPilot/releases/tag/v1.2.2-beta.10">b10</a>
        <a href="/misswell/MacPilot/releases/tag/v1.2.1">stable</a>
        <a href="/other/MacPilot/releases/tag/v9.0.0-beta.1">other</a>
        """.utf8)
        #expect(ReleaseFetcher.selectBetaTag(fromListPage: html, repository: "misswell/MacPilot") == "v1.2.2-beta.10")
    }

    @Test func cancellationOfAReleaseSourceIsNotSwallowedAsAFallbackFailure() async {
        let session = sourceSession("cancel")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ReleaseFetcher.fetchLatest(channel: .beta, session: session, currentVersion: "1.0.0")
            Issue.record("Expected cancellation")
        } catch { #expect((error as? URLError)?.code == .cancelled) }
    }

    @Test func betaPaginationSelectsTheNewestVersionAcrossBothRepositories() async throws {
        let session = sourceSession("pagedBeta")
        defer { session.invalidateAndCancel() }
        let release = try #require(try await ReleaseFetcher.fetchBeta(session: session, currentVersion: "1.0.0"))
        #expect(release.version.description == "2.0.0-beta.10")
    }

    @MainActor @Test(arguments: [false, true])
    func theVersionCatalogMergesDuplicatesAndSurvivesOneUnavailableRepository(oldUnavailable: Bool) async throws {
        let service = ReleaseCatalogService(currentVersion: "1.0.0", architecture: .arm64, performRequest: { request in
            let url = try #require(request.url)
            let old = url.path.contains("misswell/MacPilot")
            let status = old && oldUnavailable ? 404 : 200
            let repository = old ? "misswell/MacPilot" : "jollyfon/MacPilot"
            let versions = old ? ["1.9.0", "2.0.0"] : ["1.9.0", "2.1.0-beta.1"]
            let data = try JSONSerialization.data(withJSONObject: versions.map { sourceRelease($0, repository: repository) })
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        await service.load(forceRefresh: true)
        let entries = try #require(service.installableReleases())
        #expect(entries.count == (oldUnavailable ? 2 : 3))
        let shared = try #require(entries.first { $0.release.version.description == "1.9.0" })
        let expectedRepository = oldUnavailable ? "jollyfon/MacPilot" : "misswell/MacPilot"
        #expect(shared.release.archiveURL.path.hasPrefix("/\(expectedRepository)/releases/download/"))
    }
}

extension UpdateArchiveDownloaderTests {
    @Test func bothApprovedRepositoriesUseMirrorsAndUnrelatedRepositoriesStayDirect() {
        #expect(AppIdentity.updateRepositories == ["misswell/MacPilot", "jollyfon/MacPilot"])
        for repository in AppIdentity.updateRepositories {
            let url = URL(string: "https://github.com/\(repository)/releases/download/v1.2.3/MacPilot-1.2.3-arm64-macos.zip")!
            let sources = UpdateArchiveDownloader.sources(for: url)
            #expect(sources.map(\.host) == ["xget.xi-xu.me", "ghfast.top", "gh-proxy.org", "github.com"])
            #expect(sources.first?.path.hasPrefix("/gh/\(repository)/releases/download/") == true)
            #expect(sources.last == url)
        }
        for repository in ["unrelated/MacPilot", "jollyfon/MacPilot-extra", "misswell/OtherApp"] {
            let url = URL(string: "https://github.com/\(repository)/releases/download/v1.2.3/MacPilot.zip")!
            #expect(UpdateArchiveDownloader.sources(for: url) == [url])
        }
    }
}

private func sourceSession(_ scenario: String) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateSourceURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-MacPilot-Test-Scenario": scenario]
    return URLSession(configuration: configuration)
}

private func sourceRelease(_ version: String, repository: String) -> [String: Any] {
    ["tag_name": "v\(version)", "body": "", "draft": false, "prerelease": version.contains("-beta."),
     "assets": [["name": "MacPilot-\(version)-macos.zip",
                  "browser_download_url": "https://github.com/\(repository)/releases/download/v\(version)/MacPilot-\(version)-macos.zip",
                  "digest": "sha256:" + String(repeating: "b", count: 64)]]]
}

private final class UpdateSourceURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = request.value(forHTTPHeaderField: "X-MacPilot-Test-Scenario") ?? ""
        let old = url.path.contains("misswell/MacPilot")
        if scenario == "cancel", !old { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        if scenario == "betaWeb" {
            let repository = old ? "misswell/MacPilot" : "jollyfon/MacPilot"
            let tag = old ? "v1.9.0-beta.1" : "v2.0.0-beta.3"
            var body = Data()
            var code = 200
            if url.host == "api.github.com" {
                code = 403
                body = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
            } else if url.path.hasSuffix("/releases") {
                // The public release page lists prereleases the API hides.
                body = Data("""
                <a href="/\(repository)/releases/tag/\(tag)">\(tag)</a>
                <a href="/\(repository)/releases/tag/v1.0.0">v1.0.0</a>
                <a href="/someone-else/MacPilot/releases/tag/v9.9.9-beta.9">other</a>
                """.utf8)
            } else if url.path.contains("/releases/expanded_assets/") {
                let version = String(tag.dropFirst())
                body = Data("""
                <a href="/\(repository)/releases/download/\(tag)/MacPilot-\(version)-\(AppArchitecture.current.rawValue)-macos.zip">zip</a>
                <span>sha256:\(String(repeating: "b", count: 64))</span>
                """.utf8)
            }
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var status = 200
        if scenario == "allFailed" || (old && ["oldUnavailable", "empty", "newWeb", "cancel"].contains(scenario)) || (!old && scenario == "newUnavailable") { status = 404 }
        if scenario == "newWeb", !old, url.host == "api.github.com" { status = 403 }
        let stable = url.path.hasSuffix("/latest")
        var version = old ? (scenario == "oldNewest" ? "1.9.0" : "1.8.0") : (scenario == "oldNewest" ? "1.8.0" : "2.0.0")
        var headers: [String: String] = [:]
        if !stable { version += "-beta.1" }
        if scenario == "pagedBeta", !old {
            let firstPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value == "1"
            version = firstPage ? "1.1.0-beta.2" : "2.0.0-beta.10"
            if firstPage { headers["Link"] = "<https://api.github.com/releases?page=2>; rel=\"next\"" }
        }
        var responseURL = url
        var data: Data
        do {
            if scenario == "newWeb", url.host == "github.com" {
                if stable { responseURL = URL(string: "https://github.com/jollyfon/MacPilot/releases/tag/v2.0.0")! }
                data = Data("<a href=\"/jollyfon/MacPilot/releases/download/v2.0.0/MacPilot-2.0.0-macos.zip\">sha256:\(String(repeating: "b", count: 64))".utf8)
            } else {
                let release = sourceRelease(version, repository: old ? "misswell/MacPilot" : "jollyfon/MacPilot")
                data = try JSONSerialization.data(withJSONObject: stable ? release : (scenario == "empty" ? [] : [release]))
            }
            let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
