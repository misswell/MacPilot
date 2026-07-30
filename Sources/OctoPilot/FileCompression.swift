import Foundation
import Darwin
import CryptoKit
import SwiftUI

struct FolderCompressionSettings: Codable, Equatable, Sendable {
    static let recommendedExtensions = [
        "txt", "log", "md", "json", "jsonl", "xml", "csv", "tsv", "yaml", "yml"
    ]

    var folderPaths: [String]
    var fileExtensions: [String]
    var minimumFileSize: Int64
    var stableSeconds: TimeInterval
    var minimumSavingsPercent: Int
    var automaticallyCompress: Bool

    init(
        folderPaths: [String] = [],
        fileExtensions: [String] = Self.recommendedExtensions,
        minimumFileSize: Int64 = 1_048_576,
        stableSeconds: TimeInterval = 600,
        minimumSavingsPercent: Int = 10,
        automaticallyCompress: Bool = false
    ) {
        self.folderPaths = Self.normalizedFolderPaths(folderPaths)
        self.fileExtensions = Self.normalizedExtensions(fileExtensions)
        self.minimumFileSize = minimumFileSize
        self.stableSeconds = stableSeconds
        self.minimumSavingsPercent = minimumSavingsPercent
        self.automaticallyCompress = automaticallyCompress
    }

    var normalizedFileExtensions: Set<String> {
        Set(Self.normalizedExtensions(fileExtensions))
    }

    private static func normalizedExtensions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizedFolderPaths(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = URL(fileURLWithPath: trimmed, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private enum CodingKeys: String, CodingKey {
        case folderPaths
        case folderPath
        case fileExtensions
        case minimumFileSize
        case stableSeconds
        case minimumSavingsPercent
        case automaticallyCompress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paths = try container.decodeIfPresent([String].self, forKey: .folderPaths)
            ?? container.decodeIfPresent(String.self, forKey: .folderPath).map { [$0] }
            ?? []
        self.init(
            folderPaths: paths,
            fileExtensions: try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? Self.recommendedExtensions,
            minimumFileSize: try container.decodeIfPresent(Int64.self, forKey: .minimumFileSize) ?? 1_048_576,
            stableSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .stableSeconds) ?? 600,
            minimumSavingsPercent: try container.decodeIfPresent(Int.self, forKey: .minimumSavingsPercent) ?? 10,
            automaticallyCompress: try container.decodeIfPresent(Bool.self, forKey: .automaticallyCompress) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderPaths, forKey: .folderPaths)
        try container.encode(fileExtensions, forKey: .fileExtensions)
        try container.encode(minimumFileSize, forKey: .minimumFileSize)
        try container.encode(stableSeconds, forKey: .stableSeconds)
        try container.encode(minimumSavingsPercent, forKey: .minimumSavingsPercent)
        try container.encode(automaticallyCompress, forKey: .automaticallyCompress)
    }
}

struct FileCompressionFacts: Equatable, Sendable {
    let pathExtension: String
    let logicalSize: Int64
    var allocatedSize: Int64
    let modifiedAt: Date
    var isRegularFile = true
    var isSymbolicLink = false
    var linkCount: UInt64 = 1
    var isCloudPlaceholder = false
}

enum FileCompressionExclusion: Equatable, Sendable {
    case fileType
    case fileExtension
    case tooSmall
    case tooLargeForSystemCompression
    case recentlyModified
    case hardLinked
    case cloudPlaceholder
    case sparse
}

enum FileCompressionEligibility: Equatable, Sendable {
    case eligible
    case excluded(FileCompressionExclusion)
}

struct FileCompressionPolicy: Sendable {
    static let maximumCompressibleFileSize: Int64 = 512 * 1_024 * 1_024

    let settings: FolderCompressionSettings

    func eligibility(of facts: FileCompressionFacts, now: Date = Date()) -> FileCompressionEligibility {
        guard facts.isRegularFile, !facts.isSymbolicLink else { return .excluded(.fileType) }
        guard facts.linkCount == 1 else { return .excluded(.hardLinked) }
        guard !facts.isCloudPlaceholder else { return .excluded(.cloudPlaceholder) }
        guard facts.allocatedSize >= facts.logicalSize else {
            return .excluded(.sparse)
        }
        guard settings.normalizedFileExtensions.contains(facts.pathExtension.lowercased()) else {
            return .excluded(.fileExtension)
        }
        guard facts.logicalSize >= settings.minimumFileSize else { return .excluded(.tooSmall) }
        guard facts.logicalSize <= Self.maximumCompressibleFileSize else {
            return .excluded(.tooLargeForSystemCompression)
        }
        guard now.timeIntervalSince(facts.modifiedAt) >= settings.stableSeconds else {
            return .excluded(.recentlyModified)
        }
        return .eligible
    }
}

struct FileCompressionCandidate: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let monitoredFolderURL: URL
    let relativePath: String
    let logicalSize: Int64
    let allocatedSize: Int64
    let modifiedAt: Date
    let deviceID: UInt64
    let inode: UInt64
    let modificationNanoseconds: Int64
    let changeNanoseconds: Int64

    var displayPath: String {
        url.path
    }
}

struct FileCompressionFolderIssue: Equatable, Sendable {
    let folderURL: URL
    let error: AppleFileCompressionError

    var isRetryableForAutomaticCompression: Bool {
        switch error {
        case .folderUnavailable, .scanFailed:
            true
        default:
            false
        }
    }
}

struct FileCompressionScan: Equatable, Sendable {
    let folderURLs: [URL]
    let folderIssues: [FileCompressionFolderIssue]
    let candidates: [FileCompressionCandidate]
    let compressedFiles: [FileCompressionCandidate]

    var candidateBytes: Int64 { candidates.reduce(0) { $0 + $1.logicalSize } }
    var candidateAllocatedBytes: Int64 { candidates.reduce(0) { $0 + $1.allocatedSize } }
    var compressedLogicalBytes: Int64 { compressedFiles.reduce(0) { $0 + $1.logicalSize } }
    var compressedAllocatedBytes: Int64 { compressedFiles.reduce(0) { $0 + $1.allocatedSize } }
}

struct FileCompressionOperationResult: Equatable, Sendable {
    var compressedCount = 0
    var restoredCount = 0
    var skippedCount = 0
    var failedCount = 0
    var bytesSaved: Int64 = 0
    var failedFiles: [String] = []
    var recoveryFiles: [String] = []
    var failures: [AppleFileCompressionError] = []
    var retryableFiles: [String] = []
}

enum AppleFileCompressionError: LocalizedError, Equatable, Sendable {
    case folderNotSelected
    case folderUnavailable
    case unsupportedFileSystem(String)
    case scanFailed(String)
    case fileChanged
    case compressionUnavailable
    case verificationFailed
    case commandFailed(String)
    case coordinationFailed(String)
    case fileInUse
    case monitoringUnavailable
    case recoveryCopyPreserved(String)
    case replacementFailed

    var errorDescription: String? {
        switch self {
        case .folderNotSelected: "No folder is selected."
        case .folderUnavailable: "The selected folder is unavailable."
        case .unsupportedFileSystem(let name): "The selected folder uses \(name), not APFS or HFS+."
        case .scanFailed(let message): "Could not scan the folder: \(message)"
        case .fileChanged: "The file changed after it was scanned."
        case .compressionUnavailable: "macOS did not compress this file."
        case .verificationFailed: "The compressed copy did not match the original file."
        case .commandFailed(let message): "The macOS compression command failed: \(message)"
        case .coordinationFailed(let message): "The file could not be coordinated safely: \(message)"
        case .fileInUse: "The file is open in another process."
        case .monitoringUnavailable: "Folder change monitoring could not be started."
        case .recoveryCopyPreserved(let path): "The original file was preserved for recovery at \(path)."
        case .replacementFailed: "The original file could not be replaced atomically."
        }
    }
}

struct AppleFileCompressionEngine: Sendable {
    private static let managedCompressionAttribute = "com.misswell.octopilot.filesystem-compressed"
    private static let compressionExtendedAttributes = [
        managedCompressionAttribute,
        "com.apple.decmpfs",
        "com.apple.ResourceFork"
    ]
    // macOS synthesizes provenance for the new inode and may regenerate an existing value.
    private static let systemGeneratedExtendedAttributes = [
        "com.apple.provenance"
    ]

    private struct FileIdentity: Hashable {
        let deviceID: UInt64
        let inode: UInt64
    }

    private final class ScanIssueCollector {
        private(set) var message: String?

        func record(path: String, error: Error) {
            record(path: path, message: error.localizedDescription)
        }

        func record(path: String, message: String) {
            guard self.message == nil else { return }
            self.message = "\(path): \(message)"
        }
    }

    private struct MetadataSnapshot: Equatable {
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let flags: UInt32
        let birthNanoseconds: Int64
        let modificationNanoseconds: Int64
        let accessControlList: String?
        let extendedAttributes: [String: Data]
    }

    private enum ScannedFile {
        case candidate(FileCompressionCandidate)
        case compressed(FileCompressionCandidate)

        var candidate: FileCompressionCandidate {
            switch self {
            case .candidate(let candidate), .compressed(let candidate): candidate
            }
        }
    }
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    func scan(settings: FolderCompressionSettings, now: Date = Date()) throws -> FileCompressionScan {
        guard !settings.folderPaths.isEmpty else { throw AppleFileCompressionError.folderNotSelected }
        let folderURLs = settings.folderPaths.map {
            URL(fileURLWithPath: FileCompressionPath.canonical($0), isDirectory: true)
        }
        let policy = FileCompressionPolicy(settings: settings)
        var candidates: [FileCompressionCandidate] = []
        var compressedFiles: [FileCompressionCandidate] = []
        var folderIssues: [FileCompressionFolderIssue] = []
        var seenFiles = Set<FileIdentity>()

        for folderURL in folderURLs {
            do {
                let (enumerator, issueCollector) = try fileEnumerator(at: folderURL)
                for case let url as URL in enumerator {
                    do {
                        guard let scannedFile = try scannedFile(
                            at: url,
                            monitoredFolderURL: folderURL,
                            policy: policy,
                            now: now
                        ) else { continue }
                        let candidate = scannedFile.candidate
                        let identity = FileIdentity(deviceID: candidate.deviceID, inode: candidate.inode)
                        guard seenFiles.insert(identity).inserted else { continue }
                        switch scannedFile {
                        case .candidate:
                            candidates.append(candidate)
                        case .compressed:
                            compressedFiles.append(candidate)
                        }
                    } catch {
                        issueCollector.record(path: url.path, error: error)
                    }
                }
                if let message = issueCollector.message {
                    folderIssues.append(FileCompressionFolderIssue(folderURL: folderURL, error: .scanFailed(message)))
                }
            } catch let error as AppleFileCompressionError {
                folderIssues.append(FileCompressionFolderIssue(folderURL: folderURL, error: error))
            } catch {
                folderIssues.append(FileCompressionFolderIssue(folderURL: folderURL, error: .scanFailed(error.localizedDescription)))
            }
        }

        return FileCompressionScan(
            folderURLs: folderURLs,
            folderIssues: folderIssues,
            candidates: candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
            compressedFiles: compressedFiles.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        )
    }

    func scanChangedPaths(
        _ paths: Set<String>,
        settings: FolderCompressionSettings,
        now: Date = Date()
    ) throws -> [FileCompressionCandidate] {
        guard !settings.folderPaths.isEmpty else { throw AppleFileCompressionError.folderNotSelected }
        let folderURLs = settings.folderPaths.map {
            URL(fileURLWithPath: FileCompressionPath.canonical($0), isDirectory: true)
        }
        let policy = FileCompressionPolicy(settings: settings)
        var candidates: [FileCompressionCandidate] = []
        var seenFiles = Set<FileIdentity>()

        func inspect(_ url: URL, monitoredFolderURL: URL) throws {
            guard let scannedFile = try scannedFile(
                at: url,
                monitoredFolderURL: monitoredFolderURL,
                policy: policy,
                now: now
            ), case .candidate(let candidate) = scannedFile else { return }
            let identity = FileIdentity(deviceID: candidate.deviceID, inode: candidate.inode)
            guard seenFiles.insert(identity).inserted else { return }
            candidates.append(candidate)
        }

        for path in paths {
            let url = URL(fileURLWithPath: FileCompressionPath.canonical(path))
            guard let folderURL = monitoredRoot(containing: url, from: folderURLs) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard try !targetIsHiddenOrInsidePackage(url, root: folderURL, isDirectory: isDirectory.boolValue) else {
                continue
            }
            if isDirectory.boolValue {
                let (enumerator, issueCollector) = try fileEnumerator(at: url)
                for case let childURL as URL in enumerator {
                    do {
                        try inspect(childURL, monitoredFolderURL: folderURL)
                    } catch {
                        issueCollector.record(path: childURL.path, error: error)
                    }
                }
                if let message = issueCollector.message {
                    throw AppleFileCompressionError.scanFailed(message)
                }
            } else {
                try inspect(url, monitoredFolderURL: folderURL)
            }
        }
        return candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    func compress(
        _ candidates: [FileCompressionCandidate],
        settings: FolderCompressionSettings
    ) -> FileCompressionOperationResult {
        var result = FileCompressionOperationResult()
        for candidate in candidates {
            do {
                let saved = try coordinatedWrite(at: candidate.url) { sourceURL in
                    try compress(
                        candidate,
                        sourceURL: sourceURL,
                        minimumSavingsPercent: settings.minimumSavingsPercent
                    )
                }
                result.compressedCount += 1
                result.bytesSaved += saved
            } catch AppleFileCompressionError.compressionUnavailable {
                result.skippedCount += 1
            } catch AppleFileCompressionError.fileInUse {
                result.skippedCount += 1
                result.retryableFiles.append(candidate.displayPath)
            } catch AppleFileCompressionError.recoveryCopyPreserved(let path) {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.recoveryFiles.append(path)
                result.failures.append(.recoveryCopyPreserved(path))
            } catch let error as AppleFileCompressionError {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(error)
                switch error {
                case .fileChanged, .commandFailed, .coordinationFailed, .replacementFailed:
                    result.retryableFiles.append(candidate.displayPath)
                default:
                    break
                }
            } catch {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(.commandFailed(error.localizedDescription))
                result.retryableFiles.append(candidate.displayPath)
            }
        }
        return result
    }

    func restore(_ candidates: [FileCompressionCandidate]) -> FileCompressionOperationResult {
        var result = FileCompressionOperationResult()
        for candidate in candidates {
            do {
                try coordinatedWrite(at: candidate.url) { sourceURL in
                    try restore(candidate, sourceURL: sourceURL)
                }
                result.restoredCount += 1
            } catch AppleFileCompressionError.recoveryCopyPreserved(let path) {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.recoveryFiles.append(path)
                result.failures.append(.recoveryCopyPreserved(path))
            } catch let error as AppleFileCompressionError {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(error)
            } catch {
                result.failedCount += 1
                result.failedFiles.append(candidate.displayPath)
                result.failures.append(.commandFailed(error.localizedDescription))
            }
        }
        return result
    }

    private func compress(
        _ candidate: FileCompressionCandidate,
        sourceURL: URL,
        minimumSavingsPercent: Int
    ) throws -> Int64 {
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0,
              matches(candidate, info: sourceInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let sourceMetadata = try metadataSnapshot(at: sourceURL, info: sourceInfo, excludingCompressionArtifacts: true)
        let sourceAllocatedSize = Int64(sourceInfo.st_blocks * 512)
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".octopilot-compression-\(UUID().uuidString)")
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        try runDitto(
            arguments: ["--hfsCompression", "--noclone", sourceURL.path, temporaryURL.path]
        )
        try restoreVisibleDates(from: sourceInfo, to: temporaryURL)
        try synchronizeExtendedAttributes(sourceMetadata.extendedAttributes, at: temporaryURL)

        var compressedInfo = stat()
        guard lstat(temporaryURL.path, &compressedInfo) == 0,
              isCompressed(compressedInfo) else {
            throw AppleFileCompressionError.compressionUnavailable
        }
        let compressedMetadata = try metadataSnapshot(
            at: temporaryURL,
            info: compressedInfo,
            excludingCompressionArtifacts: true
        )
        guard preservedMetadataMatches(sourceMetadata, compressedMetadata) else {
            throw AppleFileCompressionError.verificationFailed
        }
        let compressedAllocatedSize = Int64(compressedInfo.st_blocks * 512)
        let savedBytes = sourceAllocatedSize - compressedAllocatedSize
        guard sourceAllocatedSize > 0,
              savedBytes > 0,
              savedBytes * 100 >= sourceAllocatedSize * Int64(max(0, minimumSavingsPercent)) else {
            throw AppleFileCompressionError.compressionUnavailable
        }
        guard try sha256(of: sourceURL) == sha256(of: temporaryURL) else {
            throw AppleFileCompressionError.verificationFailed
        }
        try setManagedCompressionAttribute(at: temporaryURL)

        var unchangedInfo = stat()
        guard lstat(sourceURL.path, &unchangedInfo) == 0,
              matches(candidate, info: unchangedInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let unchangedMetadata = try metadataSnapshot(at: sourceURL, info: unchangedInfo)
        guard try !isOpenByAnotherProcess(sourceURL) else {
            throw AppleFileCompressionError.fileInUse
        }
        guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
            throw AppleFileCompressionError.replacementFailed
        }
        do {
            var displacedInfo = stat()
            guard lstat(temporaryURL.path, &displacedInfo) == 0,
                  matchesAfterExchange(before: unchangedInfo, after: displacedInfo),
                  try metadataSnapshot(at: temporaryURL, info: displacedInfo) == unchangedMetadata else {
                throw AppleFileCompressionError.fileChanged
            }
        } catch {
            guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
                shouldRemoveTemporary = false
                throw AppleFileCompressionError.recoveryCopyPreserved(temporaryURL.path)
            }
            throw error
        }
        return savedBytes
    }

    private func restore(_ candidate: FileCompressionCandidate, sourceURL: URL) throws {
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0,
              matches(candidate, info: sourceInfo),
              isCompressed(sourceInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let sourceMetadata = try metadataSnapshot(at: sourceURL, info: sourceInfo, excludingCompressionArtifacts: true)
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".octopilot-restoration-\(UUID().uuidString)")
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        try runDitto(
            arguments: [
                "--nohfsCompression",
                "--nopreserveHFSCompression",
                "--noclone",
                sourceURL.path,
                temporaryURL.path
            ]
        )
        try restoreVisibleDates(from: sourceInfo, to: temporaryURL)
        try synchronizeExtendedAttributes(sourceMetadata.extendedAttributes, at: temporaryURL)

        var restoredInfo = stat()
        guard lstat(temporaryURL.path, &restoredInfo) == 0,
              !isCompressed(restoredInfo),
              try sha256(of: sourceURL) == sha256(of: temporaryURL) else {
            throw AppleFileCompressionError.verificationFailed
        }
        let restoredMetadata = try metadataSnapshot(
            at: temporaryURL,
            info: restoredInfo,
            excludingCompressionArtifacts: true
        )
        guard preservedMetadataMatches(sourceMetadata, restoredMetadata) else {
            throw AppleFileCompressionError.verificationFailed
        }
        try removeManagedCompressionAttribute(at: temporaryURL)
        var unchangedInfo = stat()
        guard lstat(sourceURL.path, &unchangedInfo) == 0,
              matches(candidate, info: unchangedInfo) else {
            throw AppleFileCompressionError.fileChanged
        }
        let unchangedMetadata = try metadataSnapshot(at: sourceURL, info: unchangedInfo)
        guard try !isOpenByAnotherProcess(sourceURL) else {
            throw AppleFileCompressionError.fileInUse
        }
        guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
            throw AppleFileCompressionError.replacementFailed
        }
        do {
            var displacedInfo = stat()
            guard lstat(temporaryURL.path, &displacedInfo) == 0,
                  matchesAfterExchange(before: unchangedInfo, after: displacedInfo),
                  try metadataSnapshot(at: temporaryURL, info: displacedInfo) == unchangedMetadata else {
                throw AppleFileCompressionError.fileChanged
            }
        } catch {
            guard atomicExchange(sourceURL: sourceURL, replacementURL: temporaryURL) else {
                shouldRemoveTemporary = false
                throw AppleFileCompressionError.recoveryCopyPreserved(temporaryURL.path)
            }
            throw error
        }
    }

    private func scannedFile(
        at url: URL,
        monitoredFolderURL: URL,
        policy: FileCompressionPolicy,
        now: Date
    ) throws -> ScannedFile? {
        let values = try url.resourceValues(forKeys: Self.resourceKeys)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw AppleFileCompressionError.scanFailed(String(cString: strerror(errno)))
        }
        let protectedFlags = UInt32(UF_IMMUTABLE)
            | UInt32(SF_IMMUTABLE)
            | UInt32(SF_RESTRICTED)
            | UInt32(SF_DATALESS)
        guard info.st_flags & protectedFlags == 0 else { return nil }
        let logicalSize = Int64(values.fileSize ?? Int(info.st_size))
        let allocatedSize = Int64(values.totalFileAllocatedSize ?? Int(info.st_blocks * 512))
        let compressed = isCompressed(info)
        guard compressed || !hasExtendedAttribute("com.apple.ResourceFork", at: url) else { return nil }
        let facts = FileCompressionFacts(
            pathExtension: url.pathExtension,
            logicalSize: logicalSize,
            allocatedSize: compressed ? logicalSize : allocatedSize,
            modifiedAt: values.contentModificationDate ?? Date.distantPast,
            isRegularFile: values.isRegularFile == true,
            isSymbolicLink: values.isSymbolicLink == true,
            linkCount: UInt64(info.st_nlink),
            isCloudPlaceholder: values.isUbiquitousItem == true
                && values.ubiquitousItemDownloadingStatus != .current
        )
        if compressed {
            guard facts.isRegularFile,
                  !facts.isSymbolicLink,
                  facts.linkCount == 1,
                  !facts.isCloudPlaceholder,
                  hasManagedCompressionAttribute(at: url) else { return nil }
        } else {
            guard policy.eligibility(of: facts, now: now) == .eligible else { return nil }
        }
        let candidate = FileCompressionCandidate(
            url: url,
            monitoredFolderURL: monitoredFolderURL,
            relativePath: relativePath(of: url, from: monitoredFolderURL),
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            modifiedAt: facts.modifiedAt,
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modificationNanoseconds: modificationNanoseconds(info),
            changeNanoseconds: changeNanoseconds(info)
        )
        return compressed ? .compressed(candidate) : .candidate(candidate)
    }

    private func monitoredRoot(containing url: URL, from roots: [URL]) -> URL? {
        roots
            .filter { path(url.path, isInside: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    private func targetIsHiddenOrInsidePackage(_ url: URL, root: URL, isDirectory: Bool) throws -> Bool {
        let relative = relativePath(of: url, from: root)
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return true }
        var current = isDirectory ? url : url.deletingLastPathComponent()
        while current.path != root.path, path(current.path, isInside: root.path) {
            if try current.resourceValues(forKeys: [.isPackageKey]).isPackage == true { return true }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return false
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func relativePath(of url: URL, from folderURL: URL) -> String {
        let rootPath = folderURL.resolvingSymlinksInPath().path
        let filePath = url.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    private func fileSystemName(at url: URL) throws -> String {
        var fileSystem = statfs()
        guard statfs(url.path, &fileSystem) == 0 else {
            throw AppleFileCompressionError.folderUnavailable
        }
        return withUnsafePointer(to: &fileSystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
    }

    private func fileEnumerator(
        at folderURL: URL
    ) throws -> (FileManager.DirectoryEnumerator, ScanIssueCollector) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppleFileCompressionError.folderUnavailable
        }
        let fileSystem = try fileSystemName(at: folderURL)
        guard fileSystem == "apfs" || fileSystem == "hfs" else {
            throw AppleFileCompressionError.unsupportedFileSystem(fileSystem)
        }
        let issueCollector = ScanIssueCollector()
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                issueCollector.record(path: url.path, error: error)
                return true
            }
        ) else {
            throw AppleFileCompressionError.folderUnavailable
        }
        return (enumerator, issueCollector)
    }

    private func isCompressed(_ info: stat) -> Bool {
        info.st_flags & UInt32(UF_COMPRESSED) != 0
    }

    private func matches(_ candidate: FileCompressionCandidate, info: stat) -> Bool {
        UInt64(info.st_dev) == candidate.deviceID
            && UInt64(info.st_ino) == candidate.inode
            && Int64(info.st_size) == candidate.logicalSize
            && modificationNanoseconds(info) == candidate.modificationNanoseconds
            && changeNanoseconds(info) == candidate.changeNanoseconds
            && info.st_nlink == 1
    }

    private func matchesAfterExchange(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec
            && before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec
            && before.st_mode == after.st_mode
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_flags == after.st_flags
            && after.st_nlink == 1
    }

    private func modificationNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    private func changeNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
    }

    private func birthNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec)
    }

    private func restoreVisibleDates(from info: stat, to url: URL) throws {
        let creationDate = Date(
            timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)
                + TimeInterval(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        )
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        try FileManager.default.setAttributes(
            [.creationDate: creationDate, .modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
    }

    private func metadataSnapshot(
        at url: URL,
        info: stat,
        excludingCompressionArtifacts: Bool = false
    ) throws -> MetadataSnapshot {
        var flags = info.st_flags
        var attributes = try extendedAttributes(at: url)
        if excludingCompressionArtifacts {
            flags &= ~UInt32(UF_COMPRESSED)
            for name in Self.compressionExtendedAttributes { attributes[name] = nil }
        }
        return MetadataSnapshot(
            mode: info.st_mode,
            owner: info.st_uid,
            group: info.st_gid,
            flags: flags,
            birthNanoseconds: birthNanoseconds(info),
            modificationNanoseconds: modificationNanoseconds(info),
            accessControlList: accessControlListText(at: url),
            extendedAttributes: attributes
        )
    }

    private func preservedMetadataMatches(_ source: MetadataSnapshot, _ copy: MetadataSnapshot) -> Bool {
        source.mode == copy.mode
            && source.owner == copy.owner
            && source.group == copy.group
            && source.flags == copy.flags
            && abs(source.birthNanoseconds - copy.birthNanoseconds) <= 1_000
            && abs(source.modificationNanoseconds - copy.modificationNanoseconds) <= 1_000
            && source.accessControlList == copy.accessControlList
            && Self.preservedExtendedAttributesMatch(source: source.extendedAttributes, copy: copy.extendedAttributes)
    }

    static func preservedExtendedAttributesMatch(source: [String: Data], copy: [String: Data]) -> Bool {
        var normalizedSource = source
        var normalizedCopy = copy
        for name in Self.systemGeneratedExtendedAttributes {
            guard source[name] == nil || copy[name] != nil else { return false }
            normalizedSource[name] = nil
            normalizedCopy[name] = nil
        }
        return normalizedSource == normalizedCopy
    }

    private func hasExtendedAttribute(_ name: String, at url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private func extendedAttributes(at url: URL) throws -> [String: Data] {
        let byteCount = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard byteCount >= 0 else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
        guard byteCount > 0 else { return [:] }
        var nameBuffer = [CChar](repeating: 0, count: byteCount)
        let actualByteCount = listxattr(url.path, &nameBuffer, nameBuffer.count, XATTR_NOFOLLOW)
        guard actualByteCount >= 0 else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
        let nameBytes = nameBuffer.prefix(actualByteCount).map { UInt8(bitPattern: $0) }
        let names = nameBytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: Data] = [:]
        for name in names {
            let valueSize = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
            var value = Data(count: valueSize)
            let readSize = value.withUnsafeMutableBytes { bytes in
                getxattr(url.path, name, bytes.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
            }
            guard readSize == valueSize else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
            result[name] = value
        }
        return result
    }

    private func synchronizeExtendedAttributes(_ expected: [String: Data], at url: URL) throws {
        let preservedBySystem = Set(Self.compressionExtendedAttributes + Self.systemGeneratedExtendedAttributes)
        let current = try extendedAttributes(at: url)
        for name in current.keys where expected[name] == nil && !preservedBySystem.contains(name) {
            guard removexattr(url.path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
        }
        for (name, value) in expected where !Self.systemGeneratedExtendedAttributes.contains(name) {
            let status = value.withUnsafeBytes { bytes in
                setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
            guard status == 0 else {
                throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
            }
        }
    }

    private func accessControlListText(at url: URL) -> String? {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private func isOpenByAnotherProcess(_ url: URL) throws -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", url.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try Self.fileIsOpen(lsofStatus: process.terminationStatus, output: output)
    }

    static func fileIsOpen(lsofStatus: Int32, output: Data) throws -> Bool {
        let message = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch lsofStatus {
        case 0:
            return true
        case 1 where message.isEmpty:
            return false
        default:
            throw AppleFileCompressionError.commandFailed(message)
        }
    }

    private func hasManagedCompressionAttribute(at url: URL) -> Bool {
        getxattr(url.path, Self.managedCompressionAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private func setManagedCompressionAttribute(at url: URL) throws {
        let value = Array("1".utf8)
        let status = value.withUnsafeBytes { bytes in
            setxattr(
                url.path,
                Self.managedCompressionAttribute,
                bytes.baseAddress,
                bytes.count,
                0,
                XATTR_NOFOLLOW
            )
        }
        guard status == 0 else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
    }

    private func removeManagedCompressionAttribute(at url: URL) throws {
        guard removexattr(url.path, Self.managedCompressionAttribute, XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
            throw AppleFileCompressionError.commandFailed(String(cString: strerror(errno)))
        }
    }

    private func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppleFileCompressionError.commandFailed(output)
        }
    }

    private func coordinatedWrite<T>(at url: URL, operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            operationResult = Result { try operation(coordinatedURL) }
        }
        if let coordinationError {
            throw AppleFileCompressionError.coordinationFailed(coordinationError.localizedDescription)
        }
        guard let operationResult else {
            throw AppleFileCompressionError.coordinationFailed("No coordinated file was provided.")
        }
        return try operationResult.get()
    }

    private func atomicExchange(sourceURL: URL, replacementURL: URL) -> Bool {
        replacementURL.path.withCString { replacementPath in
            sourceURL.path.withCString { sourcePath in
                renamex_np(replacementPath, sourcePath, UInt32(RENAME_SWAP)) == 0
            }
        }
    }
}

@MainActor
final class FolderCompressionModel: ObservableObject {
    private enum AutomaticScanScope: Sendable {
        case allFolders
        case folders(Set<String>)
        case dueChanges(FileCompressionDueChanges)
    }

    private enum AutomaticScanOutcome: Sendable {
        case completed(retryablePaths: Set<String>, retryableRoots: Set<String>)
        case scanFailed(AppleFileCompressionError)
    }

    private struct AutomaticScanWork: Sendable {
        var candidates: [FileCompressionCandidate] = []
        var folderIssues: [FileCompressionFolderIssue] = []
    }

    @Published private(set) var settings = FolderCompressionSettings()
    @Published private(set) var scan: FileCompressionScan?
    @Published private(set) var lastResult: FileCompressionOperationResult?
    @Published private(set) var lastActionWasRestore = false
    @Published private(set) var isScanning = false
    @Published private(set) var isProcessing = false
    @Published private(set) var error: AppleFileCompressionError?

    var persist: (() -> Void)?
    private var isLoading = false
    private let engine = AppleFileCompressionEngine()
    private let eventMonitor = FileCompressionEventMonitor()
    private var pendingChanges = FileCompressionPendingChanges()
    private var pendingDeadlineTask: Task<Void, Never>?
    private var initialScanTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var monitoringGeneration = UUID()
    private var retryBackoff = FileCompressionRetryBackoff()

    deinit {
        eventMonitor.stop()
        pendingDeadlineTask?.cancel()
        initialScanTask?.cancel()
        reconciliationTask?.cancel()
    }

    func applyLoadedSettings(_ settings: FolderCompressionSettings) {
        isLoading = true
        self.settings = settings
        isLoading = false
    }

    func activateFromConfiguration() {
        updateMonitoring(initialScanRoots: Set(settings.folderPaths))
    }

    func addFolders(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        let previousPaths = settings.folderPaths
        updateSettings {
            $0.folderPaths = FolderCompressionSettings(folderPaths: $0.folderPaths + paths).folderPaths
        }
        scan = nil
        lastResult = nil
        error = nil
        if settings.folderPaths != previousPaths {
            updateMonitoring(
                initialScanRoots: Set(settings.folderPaths).subtracting(previousPaths),
                preservePendingChanges: true
            )
        }
    }

    func removeFolder(path: String) {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let previousPaths = settings.folderPaths
        updateSettings { $0.folderPaths.removeAll { $0 == normalizedPath } }
        scan = nil
        lastResult = nil
        error = nil
        if settings.folderPaths != previousPaths {
            updateMonitoring(initialScanRoots: nil, preservePendingChanges: true)
        }
    }

    func updateExtensions(_ text: String) {
        let values = text.components(separatedBy: CharacterSet(charactersIn: ",;，； \n\t"))
        updateSettings { $0.fileExtensions = FolderCompressionSettings(fileExtensions: values).fileExtensions }
        scan = nil
    }

    func useRecommendedExtensions() {
        updateSettings { $0.fileExtensions = FolderCompressionSettings.recommendedExtensions }
        scan = nil
    }

    func setMinimumFileSize(_ value: Int64) {
        updateSettings { $0.minimumFileSize = value }
        scan = nil
    }

    func setStableSeconds(_ value: TimeInterval) {
        updateSettings { $0.stableSeconds = value }
        scan = nil
        guard settings.automaticallyCompress else { return }
        pendingChanges.rescheduleAll(stableSeconds: value)
        schedulePendingChanges(generation: monitoringGeneration)
    }

    func setMinimumSavingsPercent(_ value: Int) {
        updateSettings { $0.minimumSavingsPercent = value }
    }

    func setAutomaticallyCompress(_ enabled: Bool) {
        updateSettings { $0.automaticallyCompress = enabled }
        updateMonitoring(initialScanRoots: enabled ? Set(settings.folderPaths) : nil)
    }

    func scanNow() async {
        guard !isScanning, !isProcessing else { return }
        isScanning = true
        error = nil
        let currentSettings = settings
        do {
            scan = try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.scan(settings: currentSettings)
            }.value
        } catch let compressionError as AppleFileCompressionError {
            scan = nil
            error = compressionError
        } catch {
            scan = nil
            self.error = .scanFailed(error.localizedDescription)
        }
        isScanning = false
    }

    func compressCandidates() async {
        guard !isProcessing else { return }
        if scan == nil { await scanNow() }
        guard let candidates = scan?.candidates, !candidates.isEmpty else { return }
        isProcessing = true
        error = nil
        lastActionWasRestore = false
        let currentSettings = settings
        lastResult = await Task.detached(priority: .userInitiated) { [engine] in
            engine.compress(candidates, settings: currentSettings)
        }.value
        isProcessing = false
        await scanNow()
    }

    func restoreCompressedFiles() async {
        guard !isProcessing, let compressedFiles = scan?.compressedFiles, !compressedFiles.isEmpty else { return }
        isProcessing = true
        error = nil
        lastActionWasRestore = true
        lastResult = await Task.detached(priority: .userInitiated) { [engine] in
            engine.restore(compressedFiles)
        }.value
        isProcessing = false
        await scanNow()
    }

    private func updateSettings(_ update: (inout FolderCompressionSettings) -> Void) {
        update(&settings)
        guard !isLoading else { return }
        persist?()
    }

    private func updateMonitoring(
        initialScanRoots: Set<String>?,
        preservePendingChanges: Bool = false
    ) {
        let resumeEventID = preservePendingChanges ? eventMonitor.resumeEventID : nil
        stopMonitoring(clearPendingChanges: !preservePendingChanges)
        if preservePendingChanges {
            pendingChanges.retainPaths(inside: Set(settings.folderPaths))
        }
        guard settings.automaticallyCompress, !settings.folderPaths.isEmpty else { return }

        let generation = monitoringGeneration
        let started = eventMonitor.start(
            paths: settings.folderPaths,
            sinceWhen: resumeEventID
        ) { [weak self] delivery in
            Task { @MainActor [weak self] in
                guard let self,
                      self.receiveCompressionEvents(
                        delivery.batch,
                        generation: generation
                      ) else { return }
                self.eventMonitor.acknowledge(delivery)
            }
        }
        guard started else {
            error = .monitoringUnavailable
            return
        }
        schedulePendingChanges(generation: generation)

        if let initialScanRoots, !initialScanRoots.isEmpty {
            initialScanTask = Task { [weak self] in
                await self?.waitAndPerformAutomaticScan(
                    .folders(initialScanRoots),
                    generation: generation
                )
            }
        }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
                guard let self else { return }
                await self.waitAndPerformAutomaticScan(.allFolders, generation: generation)
            }
        }
    }

    private func stopMonitoring(clearPendingChanges: Bool = true) {
        monitoringGeneration = UUID()
        eventMonitor.stop()
        pendingDeadlineTask?.cancel()
        initialScanTask?.cancel()
        reconciliationTask?.cancel()
        pendingDeadlineTask = nil
        initialScanTask = nil
        reconciliationTask = nil
        if clearPendingChanges {
            pendingChanges.removeAll()
        }
        retryBackoff.reset()
    }

    private func receiveCompressionEvents(
        _ batch: FileCompressionChangeBatch,
        generation: UUID
    ) -> Bool {
        guard generation == monitoringGeneration, settings.automaticallyCompress else { return false }
        retryBackoff.reset()
        pendingChanges.record(batch, stableSeconds: settings.stableSeconds)
        schedulePendingChanges(generation: generation)
        return true
    }

    private func schedulePendingChanges(
        generation: UUID,
        notBefore: Date? = nil
    ) {
        pendingDeadlineTask?.cancel()
        guard generation == monitoringGeneration, let nextDeadline = pendingChanges.nextDeadline else {
            pendingDeadlineTask = nil
            return
        }
        let deadline = max(nextDeadline, notBefore ?? .distantPast)
        let delay = max(0, deadline.timeIntervalSinceNow)
        pendingDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            await self.processPendingChanges(generation: generation)
        }
    }

    private func processPendingChanges(generation: UUID) async {
        guard generation == monitoringGeneration, settings.automaticallyCompress else { return }
        guard !isScanning, !isProcessing else {
            schedulePendingChanges(
                generation: generation,
                notBefore: Date().addingTimeInterval(2)
            )
            return
        }
        let dueChanges = pendingChanges.takeDue()
        guard !dueChanges.isEmpty else {
            schedulePendingChanges(generation: generation)
            return
        }
        let scope = AutomaticScanScope.dueChanges(dueChanges)
        let outcome = await performAutomaticScan(scope, generation: generation)
        handleAutomaticScanOutcome(outcome, scope: scope, generation: generation)
        schedulePendingChanges(generation: generation)
    }

    private func waitAndPerformAutomaticScan(
        _ scope: AutomaticScanScope,
        generation: UUID
    ) async {
        while !Task.isCancelled, generation == monitoringGeneration, settings.automaticallyCompress {
            if !isScanning, !isProcessing {
                let outcome = await performAutomaticScan(scope, generation: generation)
                handleAutomaticScanOutcome(outcome, scope: scope, generation: generation)
                schedulePendingChanges(generation: generation)
                return
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func performAutomaticScan(
        _ scope: AutomaticScanScope,
        generation: UUID
    ) async -> AutomaticScanOutcome {
        guard generation == monitoringGeneration, !isScanning, !isProcessing else {
            return .scanFailed(.scanFailed("Automatic compression is busy."))
        }
        isScanning = true
        scan = nil
        error = nil
        let currentSettings = settings
        let work: AutomaticScanWork
        do {
            work = try await Task.detached(priority: .utility) { [engine] in
                switch scope {
                case .allFolders:
                    let scan = try engine.scan(settings: currentSettings)
                    return AutomaticScanWork(
                        candidates: scan.candidates,
                        folderIssues: scan.folderIssues
                    )
                case .folders(let roots):
                    var rootSettings = currentSettings
                    rootSettings.folderPaths = roots.sorted()
                    let scan = try engine.scan(settings: rootSettings)
                    return AutomaticScanWork(
                        candidates: scan.candidates,
                        folderIssues: scan.folderIssues
                    )
                case .dueChanges(let changes):
                    var found = try engine.scanChangedPaths(
                        changes.changedPaths,
                        settings: currentSettings
                    )
                    var folderIssues: [FileCompressionFolderIssue] = []
                    if !changes.rootsRequiringFullScan.isEmpty {
                        var rootSettings = currentSettings
                        rootSettings.folderPaths = changes.rootsRequiringFullScan.sorted()
                        let scan = try engine.scan(settings: rootSettings)
                        found.append(contentsOf: scan.candidates)
                        folderIssues.append(contentsOf: scan.folderIssues)
                    }
                    var seen = Set<String>()
                    return AutomaticScanWork(
                        candidates: found.filter {
                            seen.insert("\($0.deviceID):\($0.inode)").inserted
                        },
                        folderIssues: folderIssues
                    )
                }
            }.value
        } catch let compressionError as AppleFileCompressionError {
            error = compressionError
            isScanning = false
            return .scanFailed(compressionError)
        } catch {
            let scanError = AppleFileCompressionError.scanFailed(error.localizedDescription)
            self.error = scanError
            isScanning = false
            return .scanFailed(scanError)
        }
        isScanning = false
        if let firstIssue = work.folderIssues.first {
            error = firstIssue.error
        }

        let retryableRoots = Set(work.folderIssues.compactMap { issue in
            issue.isRetryableForAutomaticCompression ? issue.folderURL.path : nil
        })

        guard generation == monitoringGeneration, settings.automaticallyCompress else {
            return .completed(retryablePaths: [], retryableRoots: [])
        }
        guard !work.candidates.isEmpty else {
            return .completed(retryablePaths: [], retryableRoots: retryableRoots)
        }
        isProcessing = true
        lastActionWasRestore = false
        let result = await Task.detached(priority: .utility) { [engine] in
            engine.compress(work.candidates, settings: currentSettings)
        }.value
        lastResult = result
        scan = nil
        isProcessing = false
        return .completed(
            retryablePaths: Set(result.retryableFiles),
            retryableRoots: retryableRoots
        )
    }

    private func handleAutomaticScanOutcome(
        _ outcome: AutomaticScanOutcome,
        scope: AutomaticScanScope,
        generation: UUID
    ) {
        guard generation == monitoringGeneration, settings.automaticallyCompress else { return }
        let retryChanges: FileCompressionDueChanges
        switch outcome {
        case .completed(let retryablePaths, let retryableRoots):
            guard !retryablePaths.isEmpty || !retryableRoots.isEmpty else {
                retryBackoff.reset()
                return
            }
            retryChanges = FileCompressionDueChanges(
                changedPaths: retryablePaths,
                rootsRequiringFullScan: retryableRoots
            )
        case .scanFailed(let error):
            switch error {
            case .folderNotSelected, .unsupportedFileSystem, .monitoringUnavailable:
                retryBackoff.reset()
                return
            default:
                break
            }
            switch scope {
            case .allFolders:
                retryChanges = FileCompressionDueChanges(
                    rootsRequiringFullScan: Set(settings.folderPaths)
                )
            case .folders(let roots):
                retryChanges = FileCompressionDueChanges(rootsRequiringFullScan: roots)
            case .dueChanges(let changes):
                retryChanges = changes
            }
        }
        guard let retryDelay = retryBackoff.consumeDelay() else { return }
        pendingChanges.requeue(retryChanges, delaySeconds: retryDelay)
    }
}

struct FileCompressionView: View {
    @EnvironmentObject private var appModel: OctoPilotModel
    @ObservedObject var compression: FolderCompressionModel
    @State private var extensionText = ""
    @State private var folderPendingRemoval: String?
    @State private var showsAutomaticCompressionInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("fileCompression"))
                    .font(.system(size: 30, weight: .bold))
                Text(t("fileCompressionSubtitle"))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 22)

            ScrollView {
                VStack(spacing: 16) {
                    folderCard
                    rulesCard
                    resultsCard
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 30)
            }
        }
        .onAppear { extensionText = compression.settings.fileExtensions.joined(separator: ", ") }
        .onChange(of: compression.settings.fileExtensions) { _, newValue in
            extensionText = newValue.joined(separator: ", ")
        }
        .alert(
            t("compressionRemoveFolderTitle"),
            isPresented: Binding(
                get: { folderPendingRemoval != nil },
                set: { if !$0 { folderPendingRemoval = nil } }
            ),
            presenting: folderPendingRemoval
        ) { path in
            Button(t("compressionRemoveFolder"), role: .destructive) {
                compression.removeFolder(path: path)
                folderPendingRemoval = nil
            }
            Button(t("cancel"), role: .cancel) {
                folderPendingRemoval = nil
            }
        } message: { path in
            Text(t("compressionRemoveFolderMessage", path))
        }
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.cyan.opacity(0.13))
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(t("compressionFolder"))
                        .font(.headline)
                    Text(compression.settings.folderPaths.isEmpty
                         ? t("compressionNoFolder")
                         : t("compressionFolderCount", compression.settings.folderPaths.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("compressionAddFolders"), action: chooseFolders)
                    .buttonStyle(.bordered)
                    .disabled(compression.isScanning || compression.isProcessing)
            }

            Divider()

            if !compression.settings.folderPaths.isEmpty {
                VStack(spacing: 0) {
                    ForEach(compression.settings.folderPaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.cyan)
                                .frame(width: 18)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                folderPendingRemoval = path
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(t("compressionRemoveFolder"))
                            .disabled(compression.isScanning || compression.isProcessing)
                        }
                        .padding(.vertical, 7)
                    }
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t("compressionAutomatic"))
                    Button {
                        showsAutomaticCompressionInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help(t("compressionAutomaticInfoHelp"))
                    .popover(isPresented: $showsAutomaticCompressionInfo, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(t("compressionAutomaticInfo"), systemImage: "wave.3.right.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.cyan)
                            Text(t("compressionAutomaticInfoBody"))
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .frame(width: 390, alignment: .leading)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { compression.settings.automaticallyCompress },
                        set: { compression.setAutomaticallyCompress($0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel(t("compressionAutomatic"))
                }
                Text(t("compressionAutomaticHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(compression.settings.folderPaths.isEmpty)
        }
        .compressionCard()
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("compressionRules"), systemImage: "slider.horizontal.3")
                .font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(t("compressionExtensions"))
                    Spacer()
                    Button(t("compressionRecommended")) {
                        compression.useRecommendedExtensions()
                    }
                    .buttonStyle(.link)
                }
                HStack {
                    TextField("txt, log, json", text: $extensionText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyExtensions() }
                    Button(t("compressionApply"), action: applyExtensions)
                }
                Text(t("compressionExtensionsHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 22) {
                rulePicker(
                    title: t("compressionMinimumSize"),
                    selection: Binding(
                        get: { compression.settings.minimumFileSize },
                        set: { compression.setMinimumFileSize($0) }
                    ),
                    values: [1_048_576, 5_242_880, 10_485_760, 52_428_800],
                    label: { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                )
                rulePicker(
                    title: t("compressionStableFor"),
                    selection: Binding(
                        get: { Int64(compression.settings.stableSeconds) },
                        set: { compression.setStableSeconds(TimeInterval($0)) }
                    ),
                    values: [600, 1_800, 3_600],
                    label: { t("compressionMinutesValue", Int($0 / 60)) }
                )
                rulePicker(
                    title: t("compressionMinimumSavings"),
                    selection: Binding(
                        get: { Int64(compression.settings.minimumSavingsPercent) },
                        set: { compression.setMinimumSavingsPercent(Int($0)) }
                    ),
                    values: [10, 20, 30],
                    label: { "\($0)%" }
                )
            }

            Label(t("compressionSafetyHint"), systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .compressionCard()
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(t("compressionAnalysis"), systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                Spacer()
                if compression.isScanning || compression.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(t("compressionScanNow")) {
                    Task { await compression.scanNow() }
                }
                .disabled(compression.settings.folderPaths.isEmpty || compression.isScanning || compression.isProcessing)
            }

            if let error = compression.error {
                Label(errorText(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if let scan = compression.scan {
                scanSummary(scan)
                folderIssuePreview(scan)
                filePreview(scan)
                operationButtons(scan)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(t("compressionScanPrompt"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if compression.isProcessing {
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(t(compression.lastActionWasRestore ? "compressionRestoring" : "compressionCompressing"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else if let result = compression.lastResult {
                Divider()
                Label(resultText(result), systemImage: result.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(result.failedCount == 0 ? .green : .orange)
                if let failure = result.failedFiles.first {
                    Text(t("compressionFailedFile", failure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let failure = result.failures.first {
                    Text(errorText(failure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let recovery = result.recoveryFiles.first {
                    Text(t("compressionRecoveryPreserved", recovery))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .compressionCard()
    }

    @ViewBuilder
    private func folderIssuePreview(_ scan: FileCompressionScan) -> some View {
        if !scan.folderIssues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(scan.folderIssues, id: \.folderURL) { issue in
                    Label(
                        t("compressionFolderIssue", issue.folderURL.path, errorText(issue.error)),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                }
            }
        }
    }

    private func scanSummary(_ scan: FileCompressionScan) -> some View {
        HStack(spacing: 0) {
            summaryMetric(
                value: "\(scan.candidates.count)",
                label: t("compressionCandidates"),
                detail: t(
                    "compressionSizeDetail",
                    byteString(scan.candidateBytes),
                    byteString(scan.candidateAllocatedBytes)
                ),
                color: .cyan
            )
            Divider().frame(height: 54).padding(.horizontal, 22)
            summaryMetric(
                value: "\(scan.compressedFiles.count)",
                label: t("compressionAlreadyCompressed"),
                detail: t("compressionUses", byteString(scan.compressedAllocatedBytes)),
                color: .indigo
            )
            Divider().frame(height: 54).padding(.horizontal, 22)
            summaryMetric(
                value: byteString(max(0, scan.compressedLogicalBytes - scan.compressedAllocatedBytes)),
                label: t("compressionSpaceSaved"),
                detail: t("compressionLogical", byteString(scan.compressedLogicalBytes)),
                color: .green
            )
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(Color.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func filePreview(_ scan: FileCompressionScan) -> some View {
        let items = Array((scan.candidates.map { ($0, false) } + scan.compressedFiles.map { ($0, true) }).prefix(8))
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.0.id) { index, item in
                    HStack(spacing: 10) {
                        Image(systemName: item.1 ? "archivebox.fill" : "doc.text")
                            .foregroundStyle(item.1 ? .indigo : .secondary)
                            .frame(width: 18)
                        Text(item.0.displayPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(t(
                            "compressionSizeDetail",
                            byteString(item.0.logicalSize),
                            byteString(item.0.allocatedSize)
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    if index < items.count - 1 { Divider() }
                }
            }
        }
    }

    private func operationButtons(_ scan: FileCompressionScan) -> some View {
        HStack {
            Button {
                Task { await compression.compressCandidates() }
            } label: {
                Label(t("compressionCompressFiles", scan.candidates.count), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderedProminent)
            .disabled(scan.candidates.isEmpty || compression.isProcessing)

            Button {
                Task { await compression.restoreCompressedFiles() }
            } label: {
                Label(t("compressionRestoreFiles", scan.compressedFiles.count), systemImage: "arrow.uturn.backward")
            }
            .disabled(scan.compressedFiles.isEmpty || compression.isProcessing)
            Spacer()
        }
    }

    private func summaryMetric(value: String, label: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label).font(.caption.weight(.medium))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func rulePicker(
        title: String,
        selection: Binding<Int64>,
        values: [Int64],
        label: @escaping (Int64) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in Text(label(value)).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = t("compressionChoose")
        guard panel.runModal() == .OK else { return }
        compression.addFolders(panel.urls)
        Task { await compression.scanNow() }
    }

    private func applyExtensions() {
        compression.updateExtensions(extensionText)
        extensionText = compression.settings.fileExtensions.joined(separator: ", ")
    }

    private func resultText(_ result: FileCompressionOperationResult) -> String {
        if compression.lastActionWasRestore {
            return t("compressionRestoreResult", result.restoredCount, result.failedCount)
        }
        return t(
            "compressionCompressResult",
            result.compressedCount,
            byteString(result.bytesSaved),
            result.skippedCount,
            result.failedCount
        )
    }

    private func errorText(_ error: AppleFileCompressionError) -> String {
        switch error {
        case .folderNotSelected:
            t("compressionErrorNoFolder")
        case .folderUnavailable:
            t("compressionErrorFolderUnavailable")
        case .unsupportedFileSystem(let name):
            t("compressionErrorFileSystem", name)
        case .scanFailed(let message):
            t("compressionErrorScan", message)
        case .fileChanged:
            t("compressionErrorFileChanged")
        case .compressionUnavailable:
            t("compressionErrorUnavailable")
        case .verificationFailed:
            t("compressionErrorVerification")
        case .commandFailed(let message):
            t("compressionErrorCommand", message)
        case .coordinationFailed(let message):
            t("compressionErrorCoordination", message)
        case .fileInUse:
            t("compressionErrorFileInUse")
        case .monitoringUnavailable:
            t("compressionErrorMonitoringUnavailable")
        case .recoveryCopyPreserved(let path):
            t("compressionRecoveryPreserved", path)
        case .replacementFailed:
            t("compressionErrorReplacement")
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: appModel.language, arguments: arguments)
    }
}

private extension View {
    func compressionCard() -> some View {
        self
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}
