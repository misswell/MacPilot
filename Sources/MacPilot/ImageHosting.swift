import Combine
import AppKit
import Foundation
import OSLog
import Security
import UniformTypeIdentifiers

/// Direct repository upload providers supported by the screenshot uploader.
///
/// Both providers use their repository Contents API. Keeping the provider as
/// a small value type makes the request, credential, and raw URL rules
/// explicit without bringing a third-party image-hosting SDK into the app.
enum ImageHostingProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case github
    case gitee

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .github: return "scImageHostingGitHub"
        case .gitee: return "scImageHostingGitee"
        }
    }

    var apiBaseURL: URL {
        switch self {
        case .github:
            return URL(string: "https://api.github.com")!
        case .gitee:
            return URL(string: "https://gitee.com/api/v5")!
        }
    }

    var rawBaseURL: URL {
        switch self {
        case .github:
            return URL(string: "https://raw.githubusercontent.com")!
        case .gitee:
            return URL(string: "https://gitee.com")!
        }
    }
}

struct ImageHostingSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var provider: ImageHostingProvider
    var repositoryOwner: String
    var repositoryName: String
    var branch: String
    var directory: String
    var timeoutSeconds: Int

    init(
        isEnabled: Bool = false,
        provider: ImageHostingProvider = .github,
        repositoryOwner: String = "",
        repositoryName: String = "",
        branch: String = "main",
        directory: String = "screenshots",
        timeoutSeconds: Int = 30
    ) {
        self.isEnabled = isEnabled
        self.provider = provider
        self.repositoryOwner = repositoryOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repositoryName = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeoutSeconds = max(5, min(300, timeoutSeconds))
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, provider, repositoryOwner, repositoryName, branch, directory, timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawProvider = try container.decodeIfPresent(String.self, forKey: .provider)
        let provider = rawProvider.flatMap(ImageHostingProvider.init(rawValue:)) ?? .github

        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            provider: provider,
            repositoryOwner: try container.decodeIfPresent(String.self, forKey: .repositoryOwner) ?? "",
            repositoryName: try container.decodeIfPresent(String.self, forKey: .repositoryName) ?? "",
            branch: try container.decodeIfPresent(String.self, forKey: .branch) ?? "main",
            directory: try container.decodeIfPresent(String.self, forKey: .directory) ?? "screenshots",
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
        )
    }

    var normalizedDirectory: String {
        directory
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." && !$0.contains("\\") }
            .joined(separator: "/")
    }

    var isRepositoryValid: Bool {
        validRepositoryPart(repositoryOwner)
            && validRepositoryPart(repositoryName)
            && validBranch(branch)
            && validDirectory(directory)
    }

    var isConfigured: Bool {
        isEnabled && isRepositoryValid
    }

    /// Generates a unique repository path for every explicit upload. A fresh
    /// path avoids GitHub/Gitee's update-with-SHA requirement when a user
    /// uploads the same local screenshot more than once.
    func remotePath(for fileURL: URL, uploadID: UUID = UUID()) -> String {
        let originalName = fileURL.deletingPathExtension().lastPathComponent
        let safeStem = sanitizedFileName(originalName.isEmpty ? "screenshot" : originalName)
        let extensionName = sanitizedFileName(
            fileURL.pathExtension.lowercased().isEmpty ? "png" : fileURL.pathExtension.lowercased()
        )
        let shortID = uploadID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let fileName = "\(safeStem)-\(shortID).\(extensionName)"
        let components = normalizedDirectory.isEmpty ? [] : [normalizedDirectory]
        return (components + [fileName]).joined(separator: "/")
    }

    private func validRepositoryPart(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.contains("/")
            && !trimmed.contains("\\")
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func validBranch(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbiddenCharacters = CharacterSet(charactersIn: " ~^:?*[\\")
        return !trimmed.isEmpty
            && trimmed != "@"
            && !trimmed.hasPrefix("/")
            && !trimmed.hasSuffix("/")
            && !trimmed.hasSuffix(".")
            && !trimmed.contains("..")
            && !trimmed.contains("@{")
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !trimmed.unicodeScalars.contains(where: forbiddenCharacters.contains)
    }

    private func validDirectory(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.split(separator: "/", omittingEmptySubsequences: true).contains("..")
            && !value.contains("\\")
    }

    private func sanitizedFileName(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return Character(String(scalar))
        }
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "screenshot" : sanitized
    }
}

enum ImageHostingError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidRepository
    case missingCredential
    case fileUnavailable
    case unsupportedFile
    case encodingFailed
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
        case .invalidRepository:
            return AppText.value("scImageHostingInvalidRepository", language: language)
        case .missingCredential:
            return AppText.value("scImageHostingMissingCredential", language: language)
        case .fileUnavailable:
            return AppText.value("scImageHostingFileUnavailable", language: language)
        case .unsupportedFile:
            return AppText.value("scImageHostingUnsupportedFile", language: language)
        case .encodingFailed:
            return AppText.value("scImageHostingFileWriteFailed", language: language)
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

/// Temporary image encoding is deliberately separate from the network client.
/// Callers hand it a CGImage only for the duration of an explicit upload; the
/// PNG is then on disk and the API request streams that file in small chunks.
@MainActor
enum ImageHostingUploadFile {
    private struct SendableImage: @unchecked Sendable {
        let value: CGImage
    }

    static func writePNG(image: CGImage) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-upload-\(UUID().uuidString).png")
        let sendableImage = SendableImage(value: image)
        do {
            try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    try encodePNG(image: sendableImage.value, to: url)
                }
            }.value
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is ImageHostingError { throw error }
            throw ImageHostingError.encodingFailed
        }
    }

    private nonisolated static func encodePNG(image: CGImage, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageHostingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageHostingError.encodingFailed
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
}

/// Shared orchestration for the two explicit image-upload entry points.
/// Staging and network transfer stay together so every caller gets the same
/// cleanup and disk-backed upload behavior.
@MainActor
enum ImageHostingUploadCoordinator {
    static func upload(image: CGImage) async throws -> CloudUploadResult {
        let fileURL = try await ImageHostingUploadFile.writePNG(image: image)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try await CloudManager.shared.upload(fileURL: fileURL)
    }
}

/// Request construction for the GitHub/Gitee Contents APIs.
enum ImageHostingRequestFactory {
    static func contentAPIRequest(
        provider: ImageHostingProvider,
        owner: String,
        repository: String,
        remotePath: String,
        credential: String,
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: contentAPIURL(
            provider: provider,
            owner: owner,
            repository: repository,
            remotePath: remotePath
        ))
        request.httpMethod = "PUT"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacPilot", forHTTPHeaderField: "User-Agent")
        switch provider {
        case .github:
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        case .gitee:
            request.setValue("token \(credential)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func contentAPIURL(
        provider: ImageHostingProvider,
        owner: String,
        repository: String,
        remotePath: String
    ) -> URL {
        var url = provider.apiBaseURL
        for component in ["repos", owner, repository, "contents"] {
            url.appendPathComponent(component)
        }
        for component in remotePath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        return url
    }
}

/// Extracts the direct image URL returned by a Contents API response.
enum ImageHostingResponseParser {
    static func publicURL(from data: Data) -> URL? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return firstPublicURL(in: object)
    }

    private static func firstPublicURL(in value: Any) -> URL? {
        if let string = value as? String {
            return resolve(string)
        }
        if let values = value as? [Any] {
            for value in values {
                if let url = firstPublicURL(in: value) { return url }
            }
            return nil
        }
        guard let dictionary = value as? [String: Any] else { return nil }

        // `content.download_url` is the direct raw image URL on both APIs.
        // Keep html_url below raw/download fields in case a provider returns
        // both in a slightly different response shape.
        let preferredKeys = [
            "download_url", "downloadUrl", "raw_url", "rawUrl",
            "url", "link", "src", "content", "result", "data"
        ]
        for key in preferredKeys {
            guard let nested = dictionary[key],
                  let url = firstPublicURL(in: nested) else { continue }
            return url
        }
        for nested in dictionary.values {
            if let url = firstPublicURL(in: nested) { return url }
        }
        return nil
    }

    private static func resolve(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

/// Streams a local image through the JSON Base64 field required by the
/// Contents APIs. Only a small source chunk and its encoded counterpart are
/// resident at a time; the full image is never assembled as Data.
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
        guard configuration.isRepositoryValid else { throw ImageHostingError.invalidRepository }
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credential.isEmpty else {
            throw ImageHostingError.missingCredential
        }
        guard fileURL.isFileURL else { throw ImageHostingError.fileUnavailable }
        guard let type = UTType(filenameExtension: fileURL.pathExtension),
              type.conforms(to: .image) else {
            throw ImageHostingError.unsupportedFile
        }
        try await waitForFile(at: fileURL)

        let remotePath = configuration.remotePath(for: fileURL)
        let bodyURL: URL
        do {
            bodyURL = try makeContentAPIRequestBody(
                for: fileURL,
                branch: configuration.branch,
                message: "Upload screenshot \(fileURL.lastPathComponent)"
            )
        } catch let error as ImageHostingError {
            throw error
        } catch {
            throw ImageHostingError.encodingFailed
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let request = ImageHostingRequestFactory.contentAPIRequest(
            provider: configuration.provider,
            owner: configuration.repositoryOwner,
            repository: configuration.repositoryName,
            remotePath: remotePath,
            credential: credential,
            timeoutInterval: TimeInterval(configuration.timeoutSeconds)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        } catch {
            throw ImageHostingError.requestFailed(error.localizedDescription)
        }

        try validate(response: response, body: data)
        let fallbackURL = rawURL(
            provider: configuration.provider,
            owner: configuration.repositoryOwner,
            repository: configuration.repositoryName,
            branch: configuration.branch,
            remotePath: remotePath
        )
        guard let publicURL = ImageHostingResponseParser.publicURL(from: data) ?? fallbackURL else {
            throw ImageHostingError.noPublicURL
        }
        return CloudUploadResult(publicURL: publicURL, key: remotePath)
    }

    private func waitForFile(at url: URL) async throws {
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
                if stableObservations >= 1 { return }
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

    private func validate(response: URLResponse, body: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageHostingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImageHostingError.serverRejected(
                statusCode: httpResponse.statusCode,
                message: responseMessage(from: body)
            )
        }
    }

    private func makeContentAPIRequestBody(
        for fileURL: URL,
        branch: String,
        message: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilot-content-api-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)

        do {
            let destination = try FileHandle(forWritingTo: bodyURL)
            defer { try? destination.close() }
            try destination.write(contentsOf: Data("{\"message\":".utf8))
            try writeJSONString(message, to: destination)
            try destination.write(contentsOf: Data(",\"content\":\"".utf8))

            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            var carry = Data()
            while let chunk = try source.read(upToCount: 128 * 1024), !chunk.isEmpty {
                carry.append(chunk)
                let encodableCount = carry.count - (carry.count % 3)
                if encodableCount > 0 {
                    let encoded = Data(carry.prefix(encodableCount)).base64EncodedData()
                    try destination.write(contentsOf: encoded)
                    carry.removeFirst(encodableCount)
                }
            }
            if !carry.isEmpty {
                try destination.write(contentsOf: carry.base64EncodedData())
            }

            try destination.write(contentsOf: Data("\",\"branch\":".utf8))
            try writeJSONString(branch, to: destination)
            try destination.write(contentsOf: Data("}".utf8))
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private func writeJSONString(_ value: String, to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        try handle.write(contentsOf: data)
    }

    private func responseMessage(from body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["message", "detail", "error"] {
                if let message = object[key] as? String {
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
                }
            }
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

    private func rawURL(
        provider: ImageHostingProvider,
        owner: String,
        repository: String,
        branch: String,
        remotePath: String
    ) -> URL? {
        var url = provider.rawBaseURL
        for component in [owner, repository] {
            url.appendPathComponent(component)
        }
        switch provider {
        case .github:
            url.appendPathComponent(branch)
        case .gitee:
            url.appendPathComponent("raw")
            url.appendPathComponent(branch)
        }
        for component in remotePath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        return url
    }
}

enum ImageHostingCredentialStore {
    private static let service = "com.misswell.macpilot.image-hosting"

    private static func account(for provider: ImageHostingProvider) -> String {
        "\(NSUserName()).\(provider.rawValue)"
    }

    static func load(for provider: ImageHostingProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ credential: String, for provider: ImageHostingProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider)
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(credential.utf8),
            kSecAttrLabel as String: "MacPilot \(provider.rawValue.capitalized) Image Hosting Token"
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var item = query
        item.merge(attributes) { _, newValue in newValue }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(for provider: ImageHostingProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider)
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
        hasCredential = ImageHostingCredentialStore.load(for: .github) != nil
    }

    var isConfigured: Bool { settings.isConfigured }

    func apply(settings: ImageHostingSettings) {
        self.settings = settings
        hasCredential = ImageHostingCredentialStore.load(for: settings.provider) != nil
    }

    @discardableResult
    func storeCredential(_ credential: String) -> Bool {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let stored = ImageHostingCredentialStore.save(value, for: settings.provider)
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
        let removed = ImageHostingCredentialStore.remove(for: settings.provider)
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
        let credential = ImageHostingCredentialStore.load(for: configuration.provider)
        do {
            let result = try await Task.detached(priority: .utility) {
                try await ImageHostingUploadClient().upload(
                    fileURL: fileURL,
                    configuration: configuration,
                    credential: credential
                )
            }.value
            hasCredential = ImageHostingCredentialStore.load(for: configuration.provider) != nil
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
