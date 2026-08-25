import Foundation
import Testing
@testable import MacPilot

private final class DiagnosticLogWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct DiagnosticLogTests {
    @Test func diagnosticLogWritesAreQueuedOffTheCallingThread() {
        let queue = DispatchQueue(label: "com.misswell.macpilot.tests.diagnostic-log")
        let probe = DiagnosticLogWriteProbe()
        queue.suspend()
        defer { queue.resume() }

        DiagnosticLogWriteScheduling.enqueue(on: queue) {
            probe.mark()
        }

        #expect(!probe.didRun)
    }

    @Test func logRetentionKeepsOnlyTheLastHour() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        func line(at date: Date, message: String) -> String {
            "[\(formatter.string(from: date))] [Test] \(message)"
        }

        let oneHour: TimeInterval = 60 * 60
        let content = [
            line(at: now.addingTimeInterval(-oneHour - 1), message: "old"),
            line(at: now.addingTimeInterval(-oneHour), message: "boundary"),
            line(at: now.addingTimeInterval(-60), message: "recent"),
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
