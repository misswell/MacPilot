import Combine
import AppKit
import Foundation
import OSLog
import Security
import UniformTypeIdentifiers

/// Upload backends supported by the screenshot uploader.
///
/// PicList and PicGo expose the same local `/upload` protocol.  Keeping that
/// protocol as the default lets users use any provider supported by PicList
/// without embedding provider SDKs or credentials in MacPilot.
enum ImageHostingProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case picListServer
    case customMultipart

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .picListServer: return "scImageHostingPicList"
        case .customMultipart: return "scImageHostingCustom"
        }
    }
}

struct ImageHostingSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var uploadAfterCapture: Bool
    var provider: ImageHostingProvider
    var endpoint: String
    var fileFieldName: String
    var publicURLPrefix: String
    var timeoutSeconds: Int

    init(
        isEnabled: Bool = false,
        uploadAfterCapture: Bool = false,
        provider: ImageHostingProvider = .picListServer,
        endpoint: String = "http://127.0.0.1:36677/upload",
        fileFieldName: String = "files",
        publicURLPrefix: String = "",
        timeoutSeconds: Int = 30
    ) {
        self.isEnabled = isEnabled
        self.uploadAfterCapture = uploadAfterCapture
        self.provider = provider
        self.endpoint = endpoint
        let trimmedFieldName = fileFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileFieldName = trimmedFieldName.isEmpty ? "files" : trimmedFieldName
        self.publicURLPrefix = publicURLPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeoutSeconds = max(5, min(300, timeoutSeconds))
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, uploadAfterCapture, provider, endpoint
        case fileFieldName, publicURLPrefix, timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            uploadAfterCapture: try container.decodeIfPresent(Bool.self, forKey: .uploadAfterCapture) ?? false,
            provider: try container.decodeIfPresent(ImageHostingProvider.self, forKey: .provider) ?? .picListServer,
            endpoint: try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "http://127.0.0.1:36677/upload",
            fileFieldName: try container.decodeIfPresent(String.self, forKey: .fileFieldName) ?? "files",
            publicURLPrefix: try container.decodeIfPresent(String.self, forKey: .publicURLPrefix) ?? "",
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
        )
    }

    var isEndpointValid: Bool {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    var isConfigured: Bool {
        isEnabled && isEndpointValid
    }
}

enum ImageHostingError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidEndpoint
    case fileUnavailable
    case requestFailed(String)
    case serverRejected(statusCode: Int, message: String)
    case invalidResponse
    case noPublicURL

    var errorDescription: String? {
        localizedDescription(language: .system)
    }

    func localizedDescription(language: AppLanguage) -> String {
        switch self {
        case .notConfigured:
            return AppText.value("scImageHostingNotConfigured", language: language)
        case .invalidEndpoint:
            return AppText.value("scImageHostingInvalidEndpoint", language: language)
        case .fileUnavailable:
            return AppText.value("scImageHostingFileUnavailable", language: language)
        case .requestFailed(let message):
            return AppText.value("scImageHostingRequestFailed", language: language, message)
        case .serverRejected(let statusCode, let message):
            return AppText.value("scImageHostingServerRejected", language: language, statusCode, message)
        case .invalidResponse:
            return AppText.value("scImageHostingInvalidResponse", language: language)
        case .noPublicURL:
            return AppText.value("scImageHostingNoPublicURL", language: language)
        }
    }
}

struct CloudUploadResult: Sendable {
    let publicURL: URL
    let key: String
}

@MainActor
enum ImageHostingClipboard {
    static func copy(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
    }
}

/// Builds the small JSON request used by the PicList/PicGo local server.
/// The image bytes remain on disk; only the absolute path is sent to the
/// local server, which is the same contract used by PicList's integrations.
enum ImageHostingRequestFactory {
    static func picListRequest(
        endpoint: URL,
        fileURL: URL,
        credential: String?,
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        let normalizedCredential = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
        var requestURL = endpoint
        if let normalizedCredential, !normalizedCredential.isEmpty {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.removeAll { $0.name.caseInsensitiveCompare("key") == .orderedSame }
            queryItems.append(URLQueryItem(name: "key", value: normalizedCredential))
            components?.queryItems = queryItems
            requestURL = components?.url ?? endpoint
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        applyCredential(normalizedCredential, to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["list": [fileURL.path]])
        return request
    }

    static func multipartRequest(
        endpoint: URL,
        mimeType: String,
        boundary: String,
        credential: String?,
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        request.setValue(mimeType, forHTTPHeaderField: "X-MacPilot-Image-Type")
        applyCredential(credential, to: &request)
        return request
    }

    private static func applyCredential(_ credential: String?, to request: inout URLRequest) {
        guard let credential, !credential.isEmpty else { return }
        let authorization = credential.lowercased().hasPrefix("bearer ")
            ? credential
            : "Bearer " + credential
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        // PicGo Core accepts this header as well. Sending both keeps the
        // default compatible with older PicList/PicGo server builds.
        request.setValue(credential, forHTTPHeaderField: "X-PicGo-Secret")
    }
}

/// Extracts a public URL from the response shapes used by PicList/PicGo and
/// common custom image-hosting APIs.
enum ImageHostingResponseParser {
    static func publicURL(from data: Data, prefix: String) -> URL? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let url = firstPublicURL(in: object, prefix: prefix) {
                return url
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return resolve(text.trimmingCharacters(in: .whitespacesAndNewlines), prefix: prefix)
    }

    private static func firstPublicURL(in value: Any, prefix: String) -> URL? {
        if let string = value as? String {
            return resolve(string, prefix: prefix)
        }
        if let values = value as? [Any] {
            for value in values {
                if let url = firstPublicURL(in: value, prefix: prefix) { return url }
            }
            return nil
        }
        guard let dictionary = value as? [String: Any] else { return nil }

        // Prefer the fields used by PicGo Core before scanning arbitrary API
        // payloads, so a local source path in an `origin` field is ignored.
        let preferredKeys = ["imgUrl", "imageUrl", "url", "link", "src", "result", "urls", "data", "items"]
        for key in preferredKeys {
            guard let nested = dictionary[key],
                  let url = firstPublicURL(in: nested, prefix: prefix) else { continue }
            return url
        }
        for nested in dictionary.values {
            if let url = firstPublicURL(in: nested, prefix: prefix) { return url }
        }
        return nil
    }

    private static func resolve(_ value: String, prefix: String) -> URL? {
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), isPublicURL(url) {
            return url
        }
        guard !prefix.isEmpty,
              let prefixURL = URL(string: prefix),
              isPublicURL(prefixURL),
              let relativeURL = URL(string: value, relativeTo: prefixURL)?.absoluteURL,
              isPublicURL(relativeURL) else {
            return nil
        }
        return relativeURL
    }

    private static func isPublicURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}

/// Performs an upload without retaining the screenshot bytes in the app.
/// PicList uploads a path through its local API. Custom endpoints use a
/// temporary multipart body on disk and URLSession's file upload API, keeping
/// peak memory bounded by a small copy buffer rather than the image size.
struct ImageHostingUploadClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(
        fileURL: URL,
        configuration: ImageHostingSettings,
        credential: String?
    ) async throws -> CloudUploadResult {
        guard configuration.isEnabled else { throw ImageHostingError.notConfigured }
        guard configuration.isEndpointValid,
              let endpoint = URL(string: configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ImageHostingError.invalidEndpoint
        }
        try await waitForFile(at: fileURL)

        let data: Data
        let response: URLResponse
        switch configuration.provider {
        case .picListServer:
            let request = ImageHostingRequestFactory.picListRequest(
                endpoint: endpoint,
                fileURL: fileURL,
                credential: credential,
                timeoutInterval: TimeInterval(configuration.timeoutSeconds)
            )
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ImageHostingError.requestFailed(error.localizedDescription)
            }
        case .customMultipart:
            let boundary = "MacPilotBoundary-" + UUID().uuidString
            let bodyURL: URL
            do {
                bodyURL = try makeMultipartBody(
                    for: fileURL,
                    fieldName: configuration.fileFieldName,
                    boundary: boundary
                )
            } catch {
                throw ImageHostingError.requestFailed(error.localizedDescription)
            }
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let request = ImageHostingRequestFactory.multipartRequest(
                endpoint: endpoint,
                mimeType: mimeType,
                boundary: boundary,
                credential: credential,
                timeoutInterval: TimeInterval(configuration.timeoutSeconds)
            )
            do {
                (data, response) = try await session.upload(for: request, fromFile: bodyURL)
            } catch {
                throw ImageHostingError.requestFailed(error.localizedDescription)
            }
        }

        try validate(response: response, body: data, provider: configuration.provider)
        guard let publicURL = ImageHostingResponseParser.publicURL(
            from: data,
            prefix: configuration.publicURLPrefix
        ) else {
            throw ImageHostingError.noPublicURL
        }
        return CloudUploadResult(publicURL: publicURL, key: publicURL.absoluteString)
    }

    private func waitForFile(at url: URL) async throws {
        guard url.isFileURL else { throw ImageHostingError.fileUnavailable }
        var previousSize: Int64?
        var stableObservations = 0
        for attempt in 0..<100 {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = (attributes[.size] as? NSNumber)?.int64Value,
               size > 0 {
                if size == previousSize {
                    stableObservations += 1
                } else {
                    stableObservations = 0
                }
                previousSize = size
                if stableObservations >= 1 {
                    return
                }
            } else {
                previousSize = nil
                stableObservations = 0
            }
            if attempt < 99 {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw ImageHostingError.fileUnavailable
    }

    private func validate(
        response: URLResponse,
        body: Data,
        provider: ImageHostingProvider
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageHostingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImageHostingError.serverRejected(
                statusCode: httpResponse.statusCode,
                message: responseMessage(from: body)
            )
        }

        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let success = object["success"] as? Bool {
            if !success {
                throw ImageHostingError.serverRejected(
                    statusCode: httpResponse.statusCode,
                    message: responseMessage(from: body)
                )
            }
            return
        }

        if provider == .picListServer {
            throw ImageHostingError.invalidResponse
        }
    }

    private func responseMessage(from body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = object["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
        }
        if let message = String(data: body, encoding: .utf8) {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
        }
        return AppText.value(
            "scImageHostingServerRejectedDefaultMessage",
            language: .system
        )
    }

    private func makeMultipartBody(
        for fileURL: URL,
        fieldName: String,
        boundary: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-upload-" + UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)

        do {
            let destination = try FileHandle(forWritingTo: bodyURL)
            defer { try? destination.close() }
            let safeFieldName = escapedHeaderValue(fieldName)
            let safeFileName = escapedHeaderValue(fileURL.lastPathComponent)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            try destination.write(contentsOf: Data(
                ("--" + boundary + "\r\nContent-Disposition: form-data; name=\""
                    + safeFieldName + "\"; filename=\"" + safeFileName
                    + "\"\r\nContent-Type: " + mimeType + "\r\n\r\n").utf8
            ))

            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try destination.write(contentsOf: chunk)
            }
            try destination.write(contentsOf: Data(("\r\n--" + boundary + "--\r\n").utf8))
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private func escapedHeaderValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }
}

enum ImageHostingCredentialStore {
    private static let service = "com.misswell.macpilot.image-hosting"
    private static var account: String { NSUserName() }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ credential: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credential.utf8),
            kSecAttrLabel as String: "MacPilot Image Hosting"
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var item = query
        item.merge(attributes) { _, newValue in newValue }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

@MainActor
final class CloudManager: ObservableObject {
    static let shared = CloudManager()

    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ImageHosting")

    @Published private(set) var settings = ImageHostingSettings()
    @Published private(set) var hasCredential: Bool
    @Published private(set) var lastError: String?

    private init() {
        hasCredential = ImageHostingCredentialStore.load() != nil
    }

    var isConfigured: Bool { settings.isConfigured }

    func apply(settings: ImageHostingSettings) {
        self.settings = settings
    }

    @discardableResult
    func storeCredential(_ credential: String) -> Bool {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let stored = ImageHostingCredentialStore.save(value)
        hasCredential = stored
        if !stored {
            lastError = AppText.value("scImageHostingCredentialSaveFailed", language: .system)
        } else {
            lastError = nil
        }
        return stored
    }

    @discardableResult
    func clearCredential() -> Bool {
        let removed = ImageHostingCredentialStore.remove()
        if removed {
            hasCredential = false
            lastError = nil
        }
        return removed
    }

    func upload(fileURL: URL) async throws -> CloudUploadResult {
        let configuration = settings
        guard configuration.isConfigured else {
            let error = ImageHostingError.notConfigured
            lastError = error.localizedDescription
            throw error
        }
        let credential = ImageHostingCredentialStore.load()
        do {
            let result = try await Task.detached(priority: .utility) {
                try await ImageHostingUploadClient().upload(
                    fileURL: fileURL,
                    configuration: configuration,
                    credential: credential
                )
            }.value
            hasCredential = ImageHostingCredentialStore.load() != nil
            lastError = nil
            Self.logger.info("Image hosting upload completed")
            return result
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("Image hosting upload failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

}
