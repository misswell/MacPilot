import AppKit
import Foundation

/// 剪切板内容文件的磁盘存储。
///
/// 剪贴板历史（尤其是图片）不应常驻内存，也不应 base64 进 JSON。
/// 这里把每条内容按 `itemID-index` 写成独立文件，内存/JSON 只保留
/// 类型、文件名和大小，展示或粘贴时才从磁盘按需读取。
enum ClipboardContentStore {
    /// 内容文件目录；测试可临时覆盖（用后恢复 nil）。
    nonisolated(unsafe) static var directoryOverride: URL?

    private static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacPilot/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var directory: URL {
        directoryOverride ?? defaultDirectory
    }

    static func write(_ data: Data, itemID: UUID, index: Int) -> String? {
        let fileName = "\(itemID.uuidString)-\(index).bin"
        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func read(file: String) -> Data? {
        try? Data(contentsOf: fileURL(for: file))
    }

    static func fileURL(for file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    /// Replaces an inline value with a file reference when it is large enough
    /// (or is an image). Callers should use this at the history boundary so a
    /// producer cannot accidentally publish a large `Data` value into the
    /// long-lived history model.
    static func externalized(
        _ content: ClipboardContent,
        itemID: UUID,
        index: Int
    ) -> ClipboardContent {
        guard content.file == nil,
              let value = content.value,
              shouldExternalizeContent(type: content.type, dataSize: value.count),
              let file = write(value, itemID: itemID, index: index) else {
            return content
        }
        return ClipboardContent(type: content.type, file: file, size: value.count)
    }

    /// 删除一个条目对应的所有内容文件（文件名以 `itemID-` 开头）。
    static func delete(itemID: UUID) {
        let prefix = itemID.uuidString + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    static func deleteAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".bin") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Removes content files that are no longer referenced by the persisted
    /// history. The screenshot pasteboard cache uses a different extension and
    /// is intentionally left untouched.
    static func deleteUnreferencedFiles(referencedFileNames: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".bin") && !referencedFileNames.contains(file) {
            try? FileManager.default.removeItem(at: fileURL(for: file))
        }
    }

    /// 判断一段内容是否需要落盘（图片一律落盘；其他类型超过 64KB 落盘）。
    static func shouldExternalizeContent(type: String, dataSize: Int) -> Bool {
        let imageTypes: Set<String> = [
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.jpeg.rawValue,
            NSPasteboard.PasteboardType.heic.rawValue,
        ]
        return imageTypes.contains(type) || dataSize > 64 * 1024
    }
}
