import Foundation
import Testing
@testable import MacPilot

struct UpdateArchiveDownloaderTests {
    private let original = URL(string: "https://github.com/\(AppIdentity.githubRepository)/releases/download/v1.2.3/MacPilot.zip")!

    @Test func mirrorPreservesEscapingAndDirectIsLast() {
        let url = URL(string: original.absoluteString + "?name=a%20b")!
        let sources = UpdateArchiveDownloader.sources(for: url)
        #expect(sources.map(\.host) == ["xget.xi-xu.me", "github.com"])
        #expect(sources[0].absoluteString.contains("/gh/\(AppIdentity.githubRepository)/releases/download/"))
        #expect(sources[0].absoluteString.hasSuffix("?name=a%20b"))
        #expect(sources.last == url)
        let unrelated = URL(string: "https://example.com/update.zip")!
        #expect(UpdateArchiveDownloader.sources(for: unrelated) == [unrelated])
    }

    @Test(arguments: ["timeout", "http", "digest", "success", "cancel"])
    func fallsBackOnlyWhenMirrorFails(mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good")
        let bad = directory.appendingPathComponent("bad")
        try Data("verified archive".utf8).write(to: good)
        try Data("corrupt archive".utf8).write(to: bad)
        let release = SoftwareRelease(version: SoftwareVersion("1.2.3")!, releaseNotes: "", archiveURL: original,
                                      sha256: try UpdatePackageValidator.sha256(of: good))
        var attempts: [URL] = []
        do {
            let result = try await UpdateArchiveDownloader.download(release: release) { request in
                let url = try #require(request.url)
                attempts.append(url)
                #expect(request.timeoutInterval == 15)
                let mirror = url != original
                if mirror && mode == "timeout" { throw URLError(.timedOut) }
                if mirror && mode == "cancel" { throw URLError(.cancelled) }
                let status = mirror && mode == "http" ? 503 : 200
                let file = mirror && (mode == "digest" || mode == "http") ? bad : good
                return (file, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            #expect(mode != "cancel")
            #expect(result == good)
            #expect(attempts.count == (mode == "success" ? 1 : 2))
            if mode == "http" || mode == "digest" {
                #expect(!FileManager.default.fileExists(atPath: bad.path))
            }
        } catch {
            #expect(mode == "cancel")
            #expect((error as? URLError)?.code == .cancelled)
            #expect(attempts.count == 1)
        }
    }

    @Test func reportsFailureWhenEverySourceFails() async throws {
        let release = SoftwareRelease(version: SoftwareVersion("1.2.3")!, releaseNotes: "", archiveURL: original,
                                      sha256: String(repeating: "0", count: 64))
        var attempts: [URL] = []
        do {
            _ = try await UpdateArchiveDownloader.download(release: release) { request in
                attempts.append(try #require(request.url))
                throw URLError(.cannotConnectToHost)
            }
            Issue.record("Expected all sources to fail")
        } catch {
            #expect((error as? URLError)?.code == .cannotConnectToHost)
            #expect(attempts == UpdateArchiveDownloader.sources(for: original))
        }
    }
}
