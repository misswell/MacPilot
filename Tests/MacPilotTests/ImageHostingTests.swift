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
        request.url?.host == "upload.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = readBody()
        Self.state.record(request: request, body: body)

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let responseBody: Data
        if request.url?.path.hasPrefix("/failure-") == true {
            responseBody = Data(#"{"success":false,"message":"quota exceeded"}"#.utf8)
        } else if request.url?.path.hasPrefix("/piclist-") == true {
            responseBody = Data(#"{"success":true,"result":["https://img.example.com/test.png"]}"#.utf8)
        } else {
            responseBody = Data(#"{"result":["https://img.example.com/test.png"]}"#.utf8)
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
    @Test func imageHostingDefaultsToDisabledPicListLocalServer() {
        let settings = ImageHostingSettings()

        #expect(settings.isEnabled == false)
        #expect(settings.uploadAfterCapture == false)
        #expect(settings.provider == .picListServer)
        #expect(settings.endpoint == "http://127.0.0.1:36677/upload")
        #expect(settings.isEndpointValid)
    }

    @Test func imageHostingSettingsClampUnsafeValues() {
        let settings = ImageHostingSettings(
            endpoint: "not a URL",
            fileFieldName: "   ",
            timeoutSeconds: 0
        )

        #expect(settings.fileFieldName == "files")
        #expect(settings.timeoutSeconds == 5)
        #expect(settings.isEndpointValid == false)
    }

    @Test func imageHostingSettingsDecodeWithoutNewFieldsUsesSafeDefaults() throws {
        let settings = try JSONDecoder().decode(
            ImageHostingSettings.self,
            from: Data("{}".utf8)
        )

        #expect(settings == ImageHostingSettings())
    }

    @Test func picListRequestSendsOnlyTheDiskPath() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/MacPilot screenshot.png")
        let endpoint = try #require(URL(string: "http://127.0.0.1:36677/upload"))
        let request = ImageHostingRequestFactory.picListRequest(
            endpoint: endpoint,
            fileURL: fileURL,
            credential: "server-secret",
            timeoutInterval: 30
        )

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer server-secret")
        #expect(request.value(forHTTPHeaderField: "X-PicGo-Secret") == "server-secret")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value == "server-secret")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        #expect(object["list"] == [fileURL.path])
    }

    @Test func customMultipartUploadStreamsFileWithExpectedFormData() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-image-hosting-test-\(UUID().uuidString).png")
        let payload = Data("test-image-payload".utf8)
        try payload.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let endpointPath = "/upload-\(UUID().uuidString)"
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .customMultipart,
            endpoint: "https://upload.example.test\(endpointPath)",
            fileFieldName: "image"
        )

        let result = try await ImageHostingUploadClient(session: session).upload(
            fileURL: sourceURL,
            configuration: settings,
            credential: "multipart-secret"
        )

        let snapshot = try #require(RecordingUploadURLProtocol.state.snapshot(forPath: endpointPath))
        let contentType = try #require(snapshot.request.value(forHTTPHeaderField: "Content-Type"))
        let bodyText = try #require(String(data: snapshot.body, encoding: .utf8))

        #expect(result.publicURL.absoluteString == "https://img.example.com/test.png")
        #expect(snapshot.request.httpMethod == "POST")
        #expect(contentType.hasPrefix("multipart/form-data; boundary=MacPilotBoundary-"))
        #expect(snapshot.request.value(forHTTPHeaderField: "Authorization") == "Bearer multipart-secret")
        #expect(bodyText.contains("name=\"image\"; filename=\"\(sourceURL.lastPathComponent)\""))
        #expect(bodyText.contains("Content-Type: image/png"))
        #expect(bodyText.contains("test-image-payload"))
        #expect(bodyText.hasSuffix("\r\n"))
    }

    @Test func picListUploadSendsTheDiskPathAndParsesTheServerResult() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-piclist-test-\(UUID().uuidString).png")
        try Data("test-image-payload".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let endpointPath = "/piclist-\(UUID().uuidString)"
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .picListServer,
            endpoint: "https://upload.example.test\(endpointPath)"
        )

        let result = try await ImageHostingUploadClient(
            session: URLSession(configuration: sessionConfiguration)
        ).upload(
            fileURL: sourceURL,
            configuration: settings,
            credential: "piclist-secret"
        )

        let snapshot = try #require(RecordingUploadURLProtocol.state.snapshot(forPath: endpointPath))
        let requestURL = try #require(snapshot.request.url)
        let queryItems = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = try #require(JSONSerialization.jsonObject(with: snapshot.body) as? [String: [String]])

        #expect(result.publicURL.absoluteString == "https://img.example.com/test.png")
        #expect(queryItems.first(where: { $0.name == "key" })?.value == "piclist-secret")
        #expect(body["list"] == [sourceURL.path])
        #expect(snapshot.body.range(of: Data("test-image-payload".utf8)) == nil)
    }

    @Test func uploadTreatsSuccessFalseAsAnError() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-image-hosting-failure-\(UUID().uuidString).png")
        try Data("test-image-payload".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let endpointPath = "/failure-\(UUID().uuidString)"
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .picListServer,
            endpoint: "https://upload.example.test\(endpointPath)"
        )

        do {
            _ = try await ImageHostingUploadClient(
                session: URLSession(configuration: sessionConfiguration)
            ).upload(
                fileURL: sourceURL,
                configuration: settings,
                credential: nil
            )
            Issue.record("an unsuccessful PicList response should fail the upload")
        } catch let error as ImageHostingError {
            #expect(error == .serverRejected(statusCode: 200, message: "quota exceeded"))
        } catch {
            Issue.record("unexpected upload error: \(error.localizedDescription)")
        }
    }

    @Test func picListUploadRejectsAResponseWithoutSuccessFlag() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-piclist-invalid-response-\(UUID().uuidString).png")
        try Data("test-image-payload".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RecordingUploadURLProtocol.self]
        let endpointPath = "/missing-success-\(UUID().uuidString)"
        let settings = ImageHostingSettings(
            isEnabled: true,
            provider: .picListServer,
            endpoint: "https://upload.example.test\(endpointPath)"
        )

        do {
            _ = try await ImageHostingUploadClient(
                session: URLSession(configuration: sessionConfiguration)
            ).upload(
                fileURL: sourceURL,
                configuration: settings,
                credential: nil
            )
            Issue.record("a PicList response without success should fail the upload")
        } catch let error as ImageHostingError {
            #expect(error == .invalidResponse)
        } catch {
            Issue.record("unexpected upload error: \(error.localizedDescription)")
        }
    }

    @Test func imageHostingResponseReadsPicListImageURL() throws {
        let payload = Data(
            #"{"success":true,"result":["https://img.example.com/a.png"],"items":[{"imgUrl":"https://img.example.com/a.png"}]}"#.utf8
        )

        let url = try #require(
            ImageHostingResponseParser.publicURL(from: payload, prefix: "")
        )
        #expect(url.absoluteString == "https://img.example.com/a.png")
    }

    @Test func imageHostingResponseResolvesRelativeURLWithConfiguredPrefix() throws {
        let payload = Data(#"{"url":"/images/a.png"}"#.utf8)

        let url = try #require(
            ImageHostingResponseParser.publicURL(
                from: payload,
                prefix: "https://img.example.com/"
            )
        )
        #expect(url.absoluteString == "https://img.example.com/images/a.png")
    }

    @Test func imageHostingResponseRejectsAResponseWithoutPublicURL() {
        let payload = Data(#"{"success":false,"message":"upload failed"}"#.utf8)

        #expect(ImageHostingResponseParser.publicURL(from: payload, prefix: "") == nil)
    }
}
