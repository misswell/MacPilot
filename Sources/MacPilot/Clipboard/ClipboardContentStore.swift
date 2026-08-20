import Foundation

/// 剪切板内容文件的磁盘存储。
///
/// 剪贴板历史（尤其是图片）不应常驻内存，也不应 base64 进 JSON。
/// 这里把每条内容按 `itemID-index` 写成独立文件，内存/JSON 只保留
/// 类型、文件名和大小，展示或粘贴时才从磁盘按需读取。
enum ClipboardContentStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacPilot/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

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
        try? Data(contentsOf: directory.appendingPathComponent(file))
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
}
