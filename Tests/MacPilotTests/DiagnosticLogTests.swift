import Foundation
import Testing
@testable import MacPilot

struct DiagnosticLogTests {
    @Test func logRetentionKeepsOnlyTheLastDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        func line(at date: Date, message: String) -> String {
            "[\(formatter.string(from: date))] [Test] \(message)"
        }

        let content = [
            line(at: now.addingTimeInterval(-24 * 60 * 60 - 1), message: "old"),
            line(at: now.addingTimeInterval(-24 * 60 * 60), message: "boundary"),
            line(at: now.addingTimeInterval(-60 * 60), message: "recent"),
            "legacy line without a timestamp"
        ].joined(separator: "\n") + "\n"

        let retained = DiagnosticLog.retainedLogContent(content, now: now)

        #expect(!retained.contains("old"))
        #expect(retained.contains("boundary"))
        #expect(retained.contains("recent"))
        #expect(!retained.contains("legacy line without a timestamp"))
        #expect(retained.hasSuffix("\n"))
    }
}
