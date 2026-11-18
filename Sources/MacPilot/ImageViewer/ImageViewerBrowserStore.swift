import Foundation
import UniformTypeIdentifiers

enum ImageViewerFileKind {
    static let extensions: Set<String> = [
        "jpeg", "jpg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "ico", "icns",
        "webp", "avif", "jxl", "jp2", "j2k", "dng", "raw", "cr2", "nef", "arw", "orf", "rw2", "pdf", "sketch"
    ]

    static func isCandidate(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let suffix = url.pathExtension.lowercased()
        return extensions.contains(suffix) || UTType(filenameExtension: suffix)?.conforms(to: .image) == true
    }
}

struct ImageViewerFolderIndex: Sendable {
    let files: [URL]
    let truncated: Bool

    static func scan(_ folder: URL, limit: Int = 20_000, cancelled: () -> Bool) throws -> Self {
        guard limit > 0, !cancelled() else { throw CancellationError() }
        var scanError: Error?
        guard let contents = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, error in scanError = error; return false }
        ) else { throw ImageViewerReadError.unreadable }
        var files: [URL] = []
        var truncated = false
        for case let url as URL in contents {
            if cancelled() { throw CancellationError() }
            guard ImageViewerFileKind.isCandidate(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                  values.isRegularFile == true
                    || (values.isDirectory == true && url.pathExtension.lowercased() == "sketch") else { continue }
            if files.count == limit { truncated = true; break }
            files.append(url.standardizedFileURL)
        }
        if let scanError { throw scanError }
        try files.sort { left, right in
            if cancelled() { throw CancellationError() }
            return Self.precedes(left, right)
        }
        if cancelled() { throw CancellationError() }
        return Self(files: files, truncated: truncated)
    }

    static func precedes(_ left: URL, _ right: URL) -> Bool {
        let order = left.lastPathComponent.localizedStandardCompare(right.lastPathComponent)
        return order == .orderedAscending || (order == .orderedSame && left.path < right.path)
    }
}

struct ImageViewerBrowserStore {
    private(set) var url: URL
    private(set) var page = 1
    private(set) var pageCount = 1
    private(set) var index: ImageViewerFolderIndex?
    private(set) var selection: Int?

    init(url: URL) { self.url = url }

    mutating func install(_ index: ImageViewerFolderIndex) {
        self.index = index
        selection = index.files.firstIndex(of: url)
    }

    func neighbor(_ offset: Int) -> URL? {
        guard let files = index?.files, !files.isEmpty else { return nil }
        if let selection {
            let next = selection + offset
            return files.indices.contains(next) ? files[next] : nil
        }
        let after = files.firstIndex { ImageViewerFolderIndex.precedes(url, $0) } ?? files.count
        let next = offset > 0 ? after : after - 1
        return files.indices.contains(next) ? files[next] : nil
    }

    mutating func move(_ offset: Int) -> Bool {
        guard let next = neighbor(offset) else { return false }
        url = next
        selection = index?.files.firstIndex(of: next)
        page = 1
        pageCount = 1
        return true
    }

    mutating func updatePageCount(_ count: Int) {
        pageCount = max(1, count)
        page = min(page, pageCount)
    }

    mutating func go(to next: Int) -> Bool {
        guard (1...pageCount).contains(next), next != page else { return false }
        page = next
        return true
    }
}
