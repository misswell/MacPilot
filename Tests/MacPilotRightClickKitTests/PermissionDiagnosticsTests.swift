import Foundation
import Testing
@testable import MacPilotRightClickKit

struct PermissionDiagnosticsTests {
    @Test func eventsRemainSingleLineAndIdentifyTheProcessSession() {
        let line = PermissionDiagnostics.formattedLine("read.begin\nforged\rentry",
            timestamp: "2026-09-08T15:00:00.000Z", bundle: "test.bundle", pid: 123, session: "session-a")
        #expect(line == "[2026-09-08T15:00:00.000Z] bundle=test.bundle pid=123 session=session-a read.begin forged entry\n")
    }

    @Test func retentionOnlyRemovesExpiredPermissionLogFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for name in ["permissions-old.log", "permissions-recent.log", "unrelated.log"] {
            let url = directory.appendingPathComponent(name)
            try Data("test".utf8).write(to: url)
            if name != "permissions-recent.log" {
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: url.path)
            }
        }
        try PermissionDiagnostics.pruneOldSessions(in: directory, now: now)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("permissions-old.log").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("permissions-recent.log").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated.log").path))
    }
}
