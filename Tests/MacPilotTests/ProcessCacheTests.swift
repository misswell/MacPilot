import Foundation
import Testing
@testable import MacPilot

@Suite
struct ProcessCacheTests {
    @Test func collectorSharesShortLivedInventoryAndCanReleaseIt() {
        final class ReadCount: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let reads = ReadCount()
        let collector = ProcessCollector(reader: {
            reads.increment()
            return [RunningProcessInfo(pid: 42, name: "test", executablePath: nil, startedAt: nil)]
        })
        #expect(collector.sample(maxAge: 10).count == 1)
        #expect(collector.sample(maxAge: 10).count == 1)
        #expect(reads.count == 1)
        collector.clear()
        #expect(collector.sample(maxAge: 10).count == 1)
        #expect(reads.count == 2)
    }

    @Test func processPathIsReadOncePerPIDAndStartTime() {
        let cache = ProcessCache()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var reads = 0
        let first = cache.path(for: 42, startedAt: startedAt) {
            reads += 1
            return "/Applications/First.app/Contents/MacOS/First"
        }
        let same = cache.path(for: 42, startedAt: startedAt) {
            reads += 1
            return "/Applications/Wrong.app/Contents/MacOS/Wrong"
        }
        let reusedPID = cache.path(for: 42, startedAt: startedAt.addingTimeInterval(1)) {
            reads += 1
            return "/Applications/Second.app/Contents/MacOS/Second"
        }
        #expect(first == same)
        #expect(reusedPID?.contains("Second.app") == true)
        #expect(reads == 2)
    }

    @Test func stoppedProcessesAreReleased() {
        let cache = ProcessCache()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        _ = cache.path(for: 42, startedAt: startedAt) { "/Applications/First.app" }
        cache.retain([])
        let newValue = cache.path(for: 42, startedAt: startedAt) { "/Applications/Second.app" }
        #expect(newValue == "/Applications/Second.app")
    }
}
