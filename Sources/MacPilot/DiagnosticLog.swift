import Foundation
import OSLog

/// 落盘诊断日志。
///
/// 系统 unified log（`log show`）对低级别日志保留时间有限，排查问题时往往
/// 已经滚动掉。这里把关键模块的事件按时间戳追加写入
/// `~/Library/Logs/MacPilot/Diagnostics.log`，并在写入前清理超过 1 天的旧日志，
/// 保证始终能看到最近一天的记录。
enum DiagnosticLog {
    private static let lock = NSLock()

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/MacPilot", isDirectory: true)
    }()

    private static let fileURL = directory.appendingPathComponent("Diagnostics.log")

    /// 追加一条日志；`category` 用于区分模块（如 WindowSwitcher / WindowMerger / RightClickMenu）。
    static func write(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cleanExpiredLocked()
            let line = "[\(timestamp())] [\(category)] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try line.data(using: .utf8)?.write(to: fileURL)
            }
        } catch {
            // 日志失败不阻塞业务；写系统日志兜底
            Logger(subsystem: "com.misswell.macpilot", category: "DiagnosticLog")
                .error("Failed to write diagnostic log: \(error.localizedDescription)")
        }
    }

    /// 删除超过 1 天的日志文件，保证只保留最近一天。
    private static func cleanExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        for file in files where file.lastPathComponent.hasSuffix(".log") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
