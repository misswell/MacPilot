import Foundation
import Darwin

/// The UI-facing scanner exposes only bounded summaries. The compression
/// service still consumes the same streaming enumeration for file operations.
struct FileScanner: Sendable {
    private let engine = AppleFileCompressionEngine()

    func scanSummary(settings: FolderCompressionSettings) throws -> FileCompressionScan {
        try engine.scanSummary(settings: settings)
    }
}

// Scanner code is kept outside the compression service so enumeration and
// cancellation can evolve independently of file replacement.
extension AppleFileCompressionEngine {
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
        var candidates: [FileCompressionCandidate] = []
        var compressedFiles: [FileCompressionCandidate] = []
        var folderIssues: [FileCompressionFolderIssue] = []
        let folderURLs = try scanEach(settings: settings, now: now) { event in
            switch event {
            case .candidate(let file): candidates.append(file)
            case .compressed(let file): compressedFiles.append(file)
            case .folderIssue(let issue): folderIssues.append(issue)
            }
        }
        return FileCompressionScan(
            folderURLs: folderURLs,
            folderIssues: folderIssues,
            candidates: candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
            compressedFiles: compressedFiles.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        )
    }

    /// The UI keeps only eight sample rows while retaining exact totals.
    func scanSummary(settings: FolderCompressionSettings, now: Date = Date()) throws -> FileCompressionScan {
        var candidates: [FileCompressionCandidate] = []
        var compressedFiles: [FileCompressionCandidate] = []
        var folderIssues: [FileCompressionFolderIssue] = []
        var candidateCount = 0
        var compressedCount = 0
        var candidateBytes: Int64 = 0
        var candidateAllocatedBytes: Int64 = 0
        var compressedLogicalBytes: Int64 = 0
        var compressedAllocatedBytes: Int64 = 0
        let folders = try scanEach(settings: settings, now: now) { event in
            switch event {
            case .candidate(let file):
                candidateCount += 1
                candidateBytes += file.logicalSize
                candidateAllocatedBytes += file.allocatedSize
                if candidates.count < 8 { candidates.append(file) }
            case .compressed(let file):
                compressedCount += 1
                compressedLogicalBytes += file.logicalSize
                compressedAllocatedBytes += file.allocatedSize
                if compressedFiles.count < 8 { compressedFiles.append(file) }
            case .folderIssue(let issue):
                folderIssues.append(issue)
            }
        }
        return FileCompressionScan(
            folderURLs: folders,
            folderIssues: folderIssues,
            candidates: candidates,
            compressedFiles: compressedFiles,
            candidateCount: candidateCount,
            compressedCount: compressedCount,
            candidateBytes: candidateBytes,
            candidateAllocatedBytes: candidateAllocatedBytes,
            compressedLogicalBytes: compressedLogicalBytes,
            compressedAllocatedBytes: compressedAllocatedBytes
        )
    }

    func compressedPage(
        settings: FolderCompressionSettings,
        search: String,
        sort: FileCompressionSortOrder,
        after cursor: FileCompressionCandidate?,
        limit: Int = 100
    ) throws -> FileCompressionPage {
        let pageSize = max(1, limit)
        var files: [FileCompressionCandidate] = []
        var matchingCount = 0
        var afterCursorCount = 0
        let isBefore: (FileCompressionCandidate, FileCompressionCandidate) -> Bool = { lhs, rhs in
            let lhsSize = sort == .logicalSize ? lhs.logicalSize : lhs.allocatedSize
            let rhsSize = sort == .logicalSize ? rhs.logicalSize : rhs.allocatedSize
            if lhsSize != rhsSize { return lhsSize > rhsSize }
            return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
        _ = try scanEach(settings: settings, now: Date()) { event in
            guard case .compressed(let file) = event,
                  search.isEmpty || file.displayPath.localizedCaseInsensitiveContains(search) else { return }
            matchingCount += 1
            if let cursor, !isBefore(cursor, file) { return }
            afterCursorCount += 1
            files.append(file)
            files.sort(by: isBefore)
            if files.count > pageSize { files.removeLast() }
        }
        return FileCompressionPage(
            files: files,
            matchingCount: matchingCount,
            hasMore: afterCursorCount > pageSize
        )
    }

    func scanStream(
        settings: FolderCompressionSettings,
        now: Date = Date()
    ) -> AsyncThrowingStream<FileCompressionScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    _ = try scanEach(settings: settings, now: now) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Automatic compression consumes candidates as they are discovered, so
    /// large monitored folders never retain an array of every file.
    func scanAndCompress(settings: FolderCompressionSettings) throws -> (FileCompressionOperationResult, [FileCompressionFolderIssue]) {
        var result = FileCompressionOperationResult()
        var issues: [FileCompressionFolderIssue] = []
        try scanEach(settings: settings, now: Date()) { event in
            try Task.checkCancellation()
            switch event {
            case .candidate(let candidate):
                result.merge(compress([candidate], settings: settings))
            case .folderIssue(let issue):
                issues.append(issue)
            case .compressed:
                break
            }
        }
        return (result, issues)
    }

    func scanAndRestore(settings: FolderCompressionSettings) throws -> FileCompressionOperationResult {
        var result = FileCompressionOperationResult()
        _ = try scanEach(settings: settings, now: Date()) { event in
            try Task.checkCancellation()
            if case .compressed(let candidate) = event {
                result.merge(restore([candidate]))
            }
        }
        return result
    }

    func compressChangedPaths(
        _ paths: Set<String>,
        settings: FolderCompressionSettings
    ) throws -> FileCompressionOperationResult {
        var result = FileCompressionOperationResult()
        try scanChangedPathsEach(paths, settings: settings) { candidate in
            try Task.checkCancellation()
            result.merge(compress([candidate], settings: settings))
        }
        return result
    }

    @discardableResult
    private func scanEach(
        settings: FolderCompressionSettings,
        now: Date,
        emit: (FileCompressionScanEvent) throws -> Void
    ) throws -> [URL] {
        guard !settings.folderPaths.isEmpty else { throw AppleFileCompressionError.folderNotSelected }
        let folderURLs = settings.folderPaths.map {
            URL(fileURLWithPath: FileCompressionPath.canonical($0), isDirectory: true)
        }
        let policy = FileCompressionPolicy(settings: settings)
        var seenFiles = Set<FileIdentity>()

        for folderURL in folderURLs {
            try Task.checkCancellation()
            do {
                let (enumerator, issueCollector) = try fileEnumerator(at: folderURL)
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
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
                            try emit(.candidate(candidate))
                        case .compressed:
                            try emit(.compressed(candidate))
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        issueCollector.record(path: url.path, error: error)
                    }
                }
                if let message = issueCollector.message {
                    try emit(.folderIssue(FileCompressionFolderIssue(folderURL: folderURL, error: .scanFailed(message))))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppleFileCompressionError {
                try emit(.folderIssue(FileCompressionFolderIssue(folderURL: folderURL, error: error)))
            } catch {
                try emit(.folderIssue(FileCompressionFolderIssue(folderURL: folderURL, error: .scanFailed(error.localizedDescription))))
            }
        }
        return folderURLs
    }

    func scanChangedPaths(
        _ paths: Set<String>,
        settings: FolderCompressionSettings,
        now: Date = Date()
    ) throws -> [FileCompressionCandidate] {
        var candidates: [FileCompressionCandidate] = []
        try scanChangedPathsEach(paths, settings: settings, now: now) { candidates.append($0) }
        return candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    func scanChangedPathsEach(
        _ paths: Set<String>,
        settings: FolderCompressionSettings,
        now: Date = Date(),
        emit: (FileCompressionCandidate) throws -> Void
    ) throws {
        guard !settings.folderPaths.isEmpty else { throw AppleFileCompressionError.folderNotSelected }
        let folderURLs = settings.folderPaths.map {
            URL(fileURLWithPath: FileCompressionPath.canonical($0), isDirectory: true)
        }
        let policy = FileCompressionPolicy(settings: settings)
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
            try emit(candidate)
        }

        for path in paths {
            try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    do {
                        try inspect(childURL, monitoredFolderURL: folderURL)
                    } catch is CancellationError {
                        throw CancellationError()
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

}
