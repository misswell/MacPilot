import Testing
@testable import MacPilot

struct BLEUnlockPerformanceTests {
    @Test func deviceRefreshBurstIsCoalescedIntoOnePublication() {
        var batcher = BLEDeviceListRefreshBatcher()

        for _ in 0..<500 {
            batcher.requestRefresh()
        }

        let firstPublication = batcher.takePendingRefresh()
        let secondPublication = batcher.takePendingRefresh()

        #expect(firstPublication)
        #expect(!secondPublication)
    }
}
