import Foundation

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
    let candidateCount: Int
    let compressedCount: Int
    let candidateBytes: Int64
    let candidateAllocatedBytes: Int64
    let compressedLogicalBytes: Int64
    let compressedAllocatedBytes: Int64

    init(
        folderURLs: [URL],
        folderIssues: [FileCompressionFolderIssue],
        candidates: [FileCompressionCandidate],
        compressedFiles: [FileCompressionCandidate],
        candidateCount: Int? = nil,
        compressedCount: Int? = nil,
        candidateBytes: Int64? = nil,
        candidateAllocatedBytes: Int64? = nil,
        compressedLogicalBytes: Int64? = nil,
        compressedAllocatedBytes: Int64? = nil
    ) {
        self.folderURLs = folderURLs
        self.folderIssues = folderIssues
        self.candidates = candidates
        self.compressedFiles = compressedFiles
        self.candidateCount = candidateCount ?? candidates.count
        self.compressedCount = compressedCount ?? compressedFiles.count
        self.candidateBytes = candidateBytes ?? candidates.reduce(0) { $0 + $1.logicalSize }
        self.candidateAllocatedBytes = candidateAllocatedBytes ?? candidates.reduce(0) { $0 + $1.allocatedSize }
        self.compressedLogicalBytes = compressedLogicalBytes ?? compressedFiles.reduce(0) { $0 + $1.logicalSize }
        self.compressedAllocatedBytes = compressedAllocatedBytes ?? compressedFiles.reduce(0) { $0 + $1.allocatedSize }
    }
}

enum FileCompressionScanEvent: Sendable {
    case candidate(FileCompressionCandidate)
    case compressed(FileCompressionCandidate)
    case folderIssue(FileCompressionFolderIssue)
}

enum FileCompressionSortOrder: String, CaseIterable, Identifiable, Sendable {
    case logicalSize
    case allocatedSize
    var id: Self { self }
}

struct FileCompressionPage: Sendable {
    let files: [FileCompressionCandidate]
    let matchingCount: Int
    let hasMore: Bool
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

    mutating func merge(_ other: Self) {
        compressedCount += other.compressedCount
        restoredCount += other.restoredCount
        skippedCount += other.skippedCount
        failedCount += other.failedCount
        bytesSaved += other.bytesSaved
        failedFiles.append(contentsOf: other.failedFiles)
        recoveryFiles.append(contentsOf: other.recoveryFiles)
        failures.append(contentsOf: other.failures)
        retryableFiles.append(contentsOf: other.retryableFiles)
    }
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
