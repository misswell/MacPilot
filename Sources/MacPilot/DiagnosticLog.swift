import Foundation
import OSLog

/// Keeps diagnostic file I/O out of event taps and other latency-sensitive
/// callers. The queue is injected in tests so the scheduling contract is
/// testable without touching the user's diagnostic file.
enum DiagnosticLogWriteScheduling {
    static func enqueue(
        on queue: DispatchQueue,
        operation: @escaping @Sendable () -> Void
    ) {
        queue.async(execute: operation)
    }
}

/// 落盘诊断日志。
///
/// 系统 unified log（`log show`）对低级别日志保留时间有限，排查问题时往往
/// 已经滚动掉。这里把关键模块的事件按时间戳追加写入
/// `~/Library/Logs/MacPilot/Diagnostics.log`，并在写入前清理超过 1 天的旧日志，
/// 保证始终能看到最近一天的记录。
enum DiagnosticLog {
    private static let writeQueue = DispatchQueue(
        label: "com.misswell.macpilot.diagnostic-log-write",
        qos: .utility
    )
    private static let retentionInterval: TimeInterval = 24 * 60 * 60
    private static let cleanupInterval: TimeInterval = 60
    nonisolated(unsafe) private static var lastCleanupAt = Date.distantPast
    private static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || Bundle.main.bundleURL.pathExtension == "xctest"
            || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest/") }
    }()

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/MacPilot", isDirectory: true)
    }()

    private static let fileURL = directory.appendingPathComponent("Diagnostics.log")

    /// 追加一条日志；`category` 用于区分模块（如 WindowSwitcher / RightClickMenu）。
    static func write(_ category: String, _ message: String) {
        // BLE model tests exercise the same callbacks as the app. Do not let
        // those callbacks append synthetic UUIDs/settings to the user's
        // one-day diagnostic history.
        guard !isRunningTests else { return }

        // Evaluating the autoclosure is intentionally the only work performed
        // by the caller. Directory creation, cleanup, timestamp formatting,
        // and file writes all happen on the utility queue.
        let message = message
        DiagnosticLogWriteScheduling.enqueue(on: writeQueue) {
            append(category: category, message: message)
        }
    }

    private static func append(category: String, message: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            cleanExpired(now: now)
            let line = "[\(timestamp(for: now))] [\(category)] \(message)\n"
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

    /// 删除超过 1 天的日志行和日志文件，保证只保留最近一天。
    private static func cleanExpired(now: Date) {
        guard now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else { return }
        lastCleanupAt = now

        if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            let retained = retainedLogContent(contents, now: now)
            if retained != contents {
                try? retained.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            }
        }

        let cutoff = now.addingTimeInterval(-retentionInterval)
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

    /// Keeps only timestamped lines inside the retention window. Newly written
    /// lines always use the parseable format below; malformed partial lines are
    /// discarded so they cannot bypass the one-day retention guarantee.
    static func retainedLogContent(_ contents: String, now: Date) -> String {
        let formatter = makeTimestampFormatter()
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let retainedLines = contents
            .split(whereSeparator: \.isNewline)
            .filter { line in
                guard line.count >= 25 else { return false }
                let timestampText = String(line.dropFirst().prefix(23))
                guard let date = formatter.date(from: timestampText) else { return false }
                return date >= cutoff
            }
        guard !retainedLines.isEmpty else { return "" }
        return retainedLines.joined(separator: "\n") + "\n"
    }

    private static func makeTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }

    private static func timestamp(for date: Date) -> String {
        makeTimestampFormatter().string(from: date)
    }
}
