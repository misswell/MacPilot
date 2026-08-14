import Testing
@testable import MacPilot

struct BLEUnlockPerformanceTests {
    @Test func bluetoothStartupDoesNotPromptBeforeExplicitUserAction() {
        #expect(!BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .notDetermined,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: false
        ))
        #expect(BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .notDetermined,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: true
        ))
    }

    @Test func bluetoothStartupRestoresOnlyPreviouslyDecidedAccess() {
        #expect(BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .allowedAlways,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: false
        ))
        #expect(!BLEUnlockAuthorizationGate.shouldInitializeCentralManager(
            authorization: .denied,
            settingsEnabled: true,
            hasMonitoredDevice: true,
            explicitUserAction: false
        ))
    }

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
