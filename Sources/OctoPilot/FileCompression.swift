import Foundation
import Darwin
import CryptoKit
import SwiftUI

struct FolderCompressionSettings: Codable, Equatable, Sendable {
    static let recommendedExtensions = [
        "txt", "log", "md", "json", "jsonl", "xml", "csv", "tsv", "yaml", "yml"
    ]

    var folderPath: String?
    var fileExtensions: [String]
    var minimumFileSize: Int64
    var stableSeconds: TimeInterval
    var minimumSavingsPercent: Int
    var automaticallyCompress: Bool

    init(
        folderPath: String? = nil,
        fileExtensions: [String] = Self.recommendedExtensions,
        minimumFileSize: Int64 = 1_048_576,
        stableSeconds: TimeInterval = 600,
        minimumSavingsPercent: Int = 10,
        automaticallyCompress: Bool = false
    ) {
        self.folderPath = folderPath
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
        guard now.timeIntervalSince(facts.modifiedAt) >= settings.stableSeconds else {
            return .excluded(.recentlyModified)
        }
        return .eligible
    }
}

struct FileCompressionCandidate: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let relativePath: String
    let logicalSize: Int64
    let allocatedSize: Int64
    let modifiedAt: Date
    let deviceID: UInt64
    let inode: UInt64
    let modificationNanoseconds: Int64
    let changeNanoseconds: Int64
}

struct FileCompressionScan: Equatable, Sendable {
    let folderURL: URL
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
        guard let folderPath = settings.folderPath else { throw AppleFileCompressionError.folderNotSelected }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppleFileCompressionError.folderUnavailable
        }
        let fileSystem = try fileSystemName(at: folderURL)
        guard fileSystem == "apfs" || fileSystem == "hfs" else {
            throw AppleFileCompressionError.unsupportedFileSystem(fileSystem)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw AppleFileCompressionError.folderUnavailable
        }

        let policy = FileCompressionPolicy(settings: settings)
        var candidates: [FileCompressionCandidate] = []
        var compressedFiles: [FileCompressionCandidate] = []

        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: Self.resourceKeys)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                let protectedFlags = UInt32(UF_IMMUTABLE)
                    | UInt32(SF_IMMUTABLE)
                    | UInt32(SF_RESTRICTED)
                    | UInt32(SF_DATALESS)
                guard info.st_flags & protectedFlags == 0 else { continue }
                let logicalSize = Int64(values.fileSize ?? Int(info.st_size))
                let allocatedSize = Int64(values.totalFileAllocatedSize ?? Int(info.st_blocks * 512))
                let compressed = isCompressed(info)
                guard compressed || !hasExtendedAttribute("com.apple.ResourceFork", at: url) else { continue }
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
                let candidate = FileCompressionCandidate(
                    url: url,
                    relativePath: relativePath(of: url, from: folderURL),
                    logicalSize: logicalSize,
                    allocatedSize: allocatedSize,
                    modifiedAt: facts.modifiedAt,
                    deviceID: UInt64(info.st_dev),
                    inode: UInt64(info.st_ino),
                    modificationNanoseconds: modificationNanoseconds(info),
                    changeNanoseconds: changeNanoseconds(info)
                )
                if compressed {
                    guard facts.isRegularFile,
                          !facts.isSymbolicLink,
                          facts.linkCount == 1,
                          !facts.isCloudPlaceholder,
                          hasManagedCompressionAttribute(at: url) else { continue }
                    compressedFiles.append(candidate)
                } else {
                    guard policy.eligibility(of: facts, now: now) == .eligible else { continue }
                    candidates.append(candidate)
                }
            } catch {
                continue
            }
        }

        return FileCompressionScan(
            folderURL: folderURL,
            candidates: candidates.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            compressedFiles: compressedFiles.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        )
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
            } catch AppleFileCompressionError.compressionUnavailable,
                    AppleFileCompressionError.fileInUse {
                result.skippedCount += 1
            } catch AppleFileCompressionError.recoveryCopyPreserved(let path) {
                result.failedCount += 1
                result.failedFiles.append(candidate.relativePath)
                result.recoveryFiles.append(path)
                result.failures.append(.recoveryCopyPreserved(path))
            } catch let error as AppleFileCompressionError {
                result.failedCount += 1
                result.failedFiles.append(candidate.relativePath)
                result.failures.append(error)
            } catch {
                result.failedCount += 1
                result.failedFiles.append(candidate.relativePath)
                result.failures.append(.commandFailed(error.localizedDescription))
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
                result.failedFiles.append(candidate.relativePath)
                result.recoveryFiles.append(path)
                result.failures.append(.recoveryCopyPreserved(path))
            } catch let error as AppleFileCompressionError {
                result.failedCount += 1
                result.failedFiles.append(candidate.relativePath)
                result.failures.append(error)
            } catch {
                result.failedCount += 1
                result.failedFiles.append(candidate.relativePath)
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
            && source.extendedAttributes == copy.extendedAttributes
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
    @Published private(set) var settings = FolderCompressionSettings()
    @Published private(set) var scan: FileCompressionScan?
    @Published private(set) var lastResult: FileCompressionOperationResult?
    @Published private(set) var lastActionWasRestore = false
    @Published private(set) var isScanning = false
    @Published private(set) var isProcessing = false
    @Published private(set) var error: AppleFileCompressionError?

    var persist: (() -> Void)?
    private var isLoading = false
    private var monitoringTask: Task<Void, Never>?
    private let engine = AppleFileCompressionEngine()

    deinit {
        monitoringTask?.cancel()
    }

    func applyLoadedSettings(_ settings: FolderCompressionSettings) {
        isLoading = true
        self.settings = settings
        isLoading = false
    }

    func activateFromConfiguration() {
        updateMonitoring()
    }

    func selectFolder(_ url: URL) {
        updateSettings { $0.folderPath = url.standardizedFileURL.path }
        scan = nil
        lastResult = nil
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
    }

    func setMinimumSavingsPercent(_ value: Int) {
        updateSettings { $0.minimumSavingsPercent = value }
    }

    func setAutomaticallyCompress(_ enabled: Bool) {
        updateSettings { $0.automaticallyCompress = enabled }
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
        updateMonitoring()
    }

    private func updateMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        guard settings.automaticallyCompress, settings.folderPath != nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.scanNow()
                guard !Task.isCancelled else { return }
                await self.compressCandidates()
            }
        }
    }
}

struct FileCompressionView: View {
    @EnvironmentObject private var appModel: OctoPilotModel
    @ObservedObject var compression: FolderCompressionModel
    @State private var extensionText = ""

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
                    Text(compression.settings.folderPath ?? t("compressionNoFolder"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(t("compressionChooseFolder"), action: chooseFolder)
                    .buttonStyle(.bordered)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { compression.settings.automaticallyCompress },
                set: { compression.setAutomaticallyCompress($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("compressionAutomatic"))
                    Text(t("compressionAutomaticHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(compression.settings.folderPath == nil)
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
                .disabled(compression.settings.folderPath == nil || compression.isScanning || compression.isProcessing)
            }

            if let error = compression.error {
                Label(errorText(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if let scan = compression.scan {
                scanSummary(scan)
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

            if let result = compression.lastResult {
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
                        Text(item.0.relativePath)
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = t("compressionChoose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        compression.selectFolder(url)
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
