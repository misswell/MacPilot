import Foundation
import Testing
@testable import MacPilot

@Suite
struct ProcessCacheTests {
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
