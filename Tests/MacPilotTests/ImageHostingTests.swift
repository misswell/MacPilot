import Foundation
import Testing
@testable import MacPilot

private final class UploadProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (request: URLRequest, body: Data)] = [:]

    func record(request: URLRequest, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        values[request.url?.path ?? ""] = (request: request, body: body)
    }

    func snapshot(forPath path: String) -> (request: URLRequest, body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        return values[path]
    }
}

private final class RecordingUploadURLProtocol: URLProtocol {
    static let state = UploadProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com" || request.url?.host == "gitee.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = readBody()
        Self.state.record(request: request, body: body)

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let isFailure = url.path.contains("MacPilot-failure-")
        let response = HTTPURLResponse(
            url: url,
            statusCode: isFailure ? 403 : 201,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let responseBody: Data
        if isFailure {
            responseBody = Data(#"{"message":"permission denied"}"#.utf8)
        } else if url.path.contains("MacPilot-fallback-") {
            responseBody = Data(#"{}"#.utf8)
        } else if url.path.hasPrefix("/api/v5/") {
            responseBody = Data(#"{"content":{"download_url":"https://gitee.com/octo/images/raw/main/screenshots/test.png"}}"#.utf8)
        } else {
            responseBody = Data(#"{"content":{"download_url":"https://raw.githubusercontent.com/octo/images/main/screenshots/test.png"}}"#.utf8)
        }
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody() -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }

        var result = Data()
        while stream.hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

struct ImageHostingTests {
    @Test func imageHostingDefaultsToDisabledGitHub() {
        let settings = ImageHostingSettings()

        #expect(settings.isEnabled == false)
        #expect(settings.provider == .github)
        #expect(settings.branch == "main")
        #expect(settings.directory == "screenshots")
        #expect(settings.isRepositoryValid == false)
        #expect(settings.isConfigured == false)
    }

    @Test func imageHostingSettingsClampUnsafeValues() {
        let settings = ImageHostingSettings(
            repositoryOwner: "  octo  ",
            repositoryName: " images ",
            branch: "main",
            timeoutSeconds: 0
        )

        #expect(settings.repositoryOwner == "octo")
        #expect(settings.repositoryName == "images")
        #expect(settings.timeoutSeconds == 5)
        #expect(settings.isRepositoryValid)
    }

    @Test func imageHostingSettingsRejectPathTraversal() {
        let settings = ImageHostingSettings(
            isEnabled: true,
            repositoryOwner: "octo",
            repositoryName: "images",
            branch: "feature/../private",
            directory: "screenshots/../private"
        )

        #expect(settings.isRepositoryValid == false)
        #expect(settings.normalizedDirectory == "screenshots/private")

        let validBranchSettings = ImageHostingSettings(
            isEnabled: true,
            repositoryOwner: "octo",
            repositoryName: "images",
            branch: "feature/screenshots",
            directory: "screenshots"
        )
        #expect(validBranchSettings.isRepositoryValid)
    }

    @Test func legacyImageHostingConfigurationFallsBackWithoutBreakingConfigLoad() throws {
        let data = Data(#"{"isEnabled":true,"provider":"picListServer","endpoint":"http://127.0.0.1:36677/upload","uploadAfterCapture":true}"#.utf8)
        let settings = try JSONDecoder().decode(ImageHostingSettings.self, from: data)

        #expect(settings.provider == .github)
        #expect(settings.isEnabled)
        #expect(settings.repositoryOwner.isEmpty)
        #expect(settings.repositoryName.isEmpty)
        #expect(settings.isConfigured == false)
    }

    @Test func contentAPIRequestUsesProviderSpecificURLAndAuthentication() throws {
        let githubRequest = ImageHostingRequestFactory.contentAPIRequest(
            provider: .github,
            owner: "octo",
            repository: "images",
            remotePath: "screenshots/test image.png",
            credential: "github-secret",
            timeoutInterval: 30
        )
        #expect(githubRequest.httpMethod == "PUT")
        #expect(githubRequest.url?.absoluteString == "https://api.github.com/repos/octo/images/contents/screenshots/test%20image.png")
        #expect(githubRequest.value(forHTTPHeaderField: "Authorization") == "Bearer github-secret")
        #expect(githubRequest.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")

        let giteeRequest = ImageHostingRequestFactory.contentAPIRequest(
            provider: .gitee,
            owner: "octo",
            repository: "images",
            remotePath: "screenshots/test.png",
            credential: "gitee-secret",
            timeoutInterval: 30
        )
        #expect(giteeRequest.url?.path == "/api/v5/repos/octo/images/contents/screenshots/test.png")
        #expect(giteeRequest.value(forHTTPHeaderField: "Authorization") == "token gitee-secret")
    }

    @Test func remotePathUsesConfiguredDirectoryAndFreshUploadID() throws {
        let settings = ImageHostingSettings(
            repositoryOwner: "octo",
            repositoryName: "images",
            directory: "screenshots"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/My screenshot.png")
        let uploadID = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let path = settings.remotePath(for: fileURL, uploadID: uploadID)

        #expect(path == "screenshots/My screenshot-0123456789AB.png")
    }

    @Test func githubUploadStreamsBase64ContentAndUsesReturnedRawURL() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-github-\(UUID().uuidString).png")
        let payload = Data("test-image-payload".utf8)
        try payload.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .github,
            repositoryOwner: "octo",
            repositoryName: "images",
            branch: "main",
            directory: "screenshots"
        )
        let result = try await ImageHostingUploadClient(
            session: URLSession(configuration: sessionConfiguration)
        ).upload(
            fileURL: sourceURL,
            configuration: settings,
            credential: "github-secret"
        )

        let snapshotPath = "/repos/octo/images/contents/\(result.key)"
        let snapshot = try #require(RecordingUploadURLProtocol.state.snapshot(forPath: snapshotPath))
        let body = try #require(JSONSerialization.jsonObject(with: snapshot.body) as? [String: Any])
        let encodedContent = try #require(body["content"] as? String)
        let decodedContent = try #require(Data(base64Encoded: encodedContent))

        #expect(result.publicURL.absoluteString == "https://raw.githubusercontent.com/octo/images/main/screenshots/test.png")
        #expect(result.key.hasPrefix("screenshots/MacPilot-github-"))
        #expect(snapshot.request.httpMethod == "PUT")
        #expect(snapshot.request.url?.path.hasPrefix("/repos/octo/images/contents/screenshots/") == true)
        #expect(snapshot.request.value(forHTTPHeaderField: "Authorization") == "Bearer github-secret")
        #expect(body["branch"] as? String == "main")
        #expect(decodedContent == payload)
        #expect(snapshot.body.range(of: payload) == nil)
    }

    @Test func giteeUploadUsesGiteeAPIAndAuthenticationScheme() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-gitee-\(UUID().uuidString).png")
        try Data("gitee-image".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .gitee,
            repositoryOwner: "octo",
            repositoryName: "images"
        )
        let result = try await ImageHostingUploadClient(
            session: URLSession(configuration: sessionConfiguration)
        ).upload(
            fileURL: sourceURL,
            configuration: settings,
            credential: "gitee-secret"
        )

        let snapshotPath = "/api/v5/repos/octo/images/contents/\(result.key)"
        let snapshot = try #require(RecordingUploadURLProtocol.state.snapshot(forPath: snapshotPath))
        #expect(snapshot.request.value(forHTTPHeaderField: "Authorization") == "token gitee-secret")
        #expect(result.publicURL.host == "gitee.com")
    }

    @Test func successfulUploadFallsBackToProviderRawURLWhenResponseOmitsIt() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-fallback-\(UUID().uuidString).png")
        try Data("fallback-image".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .github,
            repositoryOwner: "octo",
            repositoryName: "images"
        )
        let result = try await ImageHostingUploadClient(
            session: URLSession(configuration: sessionConfiguration)
        ).upload(
            fileURL: sourceURL,
            configuration: settings,
            credential: "github-secret"
        )

        #expect(result.publicURL.host == "raw.githubusercontent.com")
        #expect(result.publicURL.path.hasPrefix("/octo/images/main/screenshots/"))
    }

    @Test func uploadRequiresTokenAndRejectsNonImageFiles() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-text-\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let settings = ImageHostingSettings(
            isEnabled: true,
            repositoryOwner: "octo",
            repositoryName: "images"
        )

        do {
            _ = try await ImageHostingUploadClient().upload(
                fileURL: sourceURL,
                configuration: settings,
                credential: nil
            )
            Issue.record("an upload without a token should fail")
        } catch let error as ImageHostingError {
            #expect(error == .missingCredential)
        }

        do {
            _ = try await ImageHostingUploadClient().upload(
                fileURL: sourceURL,
                configuration: settings,
                credential: "github-secret"
            )
            Issue.record("a non-image upload should fail")
        } catch let error as ImageHostingError {
            #expect(error == .unsupportedFile)
        }
    }

    @Test func uploadReportsRepositoryPermissionErrors() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-failure-\(UUID().uuidString).png")
        try Data("failure-image".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let settings = ImageHostingSettings(
            isEnabled: true,
            repositoryOwner: "octo",
            repositoryName: "images"
        )

        do {
            _ = try await ImageHostingUploadClient(
                session: URLSession(configuration: sessionConfiguration)
            ).upload(
                fileURL: sourceURL,
                configuration: settings,
                credential: "github-secret"
            )
            Issue.record("a rejected repository upload should fail")
        } catch let error as ImageHostingError {
            #expect(error == .serverRejected(statusCode: 403, message: "permission denied"))
        }
    }

    @Test func imageHostingResponseParserReadsContentDownloadURL() throws {
        let payload = Data(
            #"{"content":{"download_url":"https://raw.githubusercontent.com/octo/images/main/a.png","html_url":"https://github.com/octo/images/blob/main/a.png"}}"#.utf8
        )

        let url = try #require(ImageHostingResponseParser.publicURL(from: payload))
        #expect(url.absoluteString == "https://raw.githubusercontent.com/octo/images/main/a.png")
    }

    @Test func imageHostingResponseParserRejectsResponseWithoutPublicURL() {
        let payload = Data(#"{"message":"created"}"#.utf8)
        #expect(ImageHostingResponseParser.publicURL(from: payload) == nil)
    }
}
