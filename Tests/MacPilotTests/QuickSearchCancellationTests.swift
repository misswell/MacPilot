import Foundation
import MacPilotDockGroupsCore
import Testing
@testable import MacPilot

struct QuickSearchCancellationTests {
    @Test func cancelledMetadataScanDoesNotReadLaterApplications() async {
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let reads = MetadataReadCount()
        let references = (0..<3).map {
            DockGroupApp(bundleIdentifier: nil, path: "/test/\($0).app", name: "\($0)")
        }
        let task = Task.detached {
            ApplicationInventory.entries(for: references) { url in
                reads.increment()
                signalStarted.yield(())
                _ = resume.wait(timeout: .now() + 5)
                return QuickSearchAppInfoReader.read(fromAppAt: url)
            }
        }
        let didStart = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = started.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        task.cancel()
        resume.signal()
        let entries = await task.value
        signalStarted.finish()
        #expect(didStart)
        #expect(entries.isEmpty)
        #expect(reads.value == 1)
    }
}

private final class MetadataReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
