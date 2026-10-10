import Testing
@testable import MacPilotFinderSync

struct FinderSyncHeartbeatLifecycleTests {
    @Test @MainActor func runningAfterQuitRestartsHeartbeatAndRequestsFreshConfiguration() {
        let lifecycle = FinderSyncHeartbeatLifecycle()
        var effects: [String] = []

        lifecycle.extensionDidLaunch(
            startHeartbeat: { effects.append("start") },
            requestConfiguration: { effects.append("request-config") }
        )
        lifecycle.mainAppDidQuit { effects.append("stop") }
        lifecycle.mainAppDidStart(
            startHeartbeat: { effects.append("start") },
            requestConfiguration: { effects.append("request-config") }
        )

        #expect(effects == ["start", "request-config", "stop", "start", "request-config"])
        #expect(lifecycle.isHeartbeatRunning)
    }

    @Test @MainActor func repeatedRunningMessagesDoNotReplaceTheHeartbeatTask() {
        let lifecycle = FinderSyncHeartbeatLifecycle()
        var startCount = 0
        var stopCount = 0
        var configRequestCount = 0

        lifecycle.extensionDidLaunch(
            startHeartbeat: { startCount += 1 },
            requestConfiguration: { configRequestCount += 1 }
        )
        let onRunning = {
            lifecycle.mainAppDidStart(
                startHeartbeat: { startCount += 1 },
                requestConfiguration: { configRequestCount += 1 }
            )
        }

        onRunning()
        onRunning()

        #expect(startCount == 1)
        #expect(stopCount == 0)
        #expect(configRequestCount == 3)
        #expect(lifecycle.isHeartbeatRunning)

        lifecycle.mainAppDidQuit { stopCount += 1 }
        #expect(stopCount == 1)
        #expect(!lifecycle.isHeartbeatRunning)
    }

    @Test @MainActor func repeatedQuitMessagesStopTheHeartbeatOnlyOnce() {
        let lifecycle = FinderSyncHeartbeatLifecycle()
        var startCount = 0
        var stopCount = 0

        lifecycle.extensionDidLaunch(
            startHeartbeat: { startCount += 1 },
            requestConfiguration: {}
        )
        lifecycle.mainAppDidQuit { stopCount += 1 }
        lifecycle.mainAppDidQuit { stopCount += 1 }

        #expect(startCount == 1)
        #expect(stopCount == 1)
        #expect(!lifecycle.isHeartbeatRunning)
    }

    @Test @MainActor func runningBeforeExtensionBootstrapStartsOnlyOnce() {
        let lifecycle = FinderSyncHeartbeatLifecycle()
        var startCount = 0
        var configRequestCount = 0

        lifecycle.mainAppDidStart(
            startHeartbeat: { startCount += 1 },
            requestConfiguration: { configRequestCount += 1 }
        )

        #expect(startCount == 1)
        #expect(configRequestCount == 1)
        #expect(lifecycle.isHeartbeatRunning)

        lifecycle.extensionDidLaunch(
            startHeartbeat: { startCount += 1 },
            requestConfiguration: { configRequestCount += 1 }
        )

        #expect(startCount == 1)
        #expect(configRequestCount == 1)
        #expect(lifecycle.isHeartbeatRunning)
    }

    @Test @MainActor func quitBeforeDelayedExtensionBootstrapKeepsHeartbeatStopped() {
        let lifecycle = FinderSyncHeartbeatLifecycle()
        var startCount = 0
        var stopCount = 0
        var configRequestCount = 0

        lifecycle.mainAppDidQuit { stopCount += 1 }
        lifecycle.extensionDidLaunch(
            startHeartbeat: { startCount += 1 },
            requestConfiguration: { configRequestCount += 1 }
        )

        #expect(startCount == 0)
        #expect(stopCount == 0)
        #expect(configRequestCount == 0)
        #expect(!lifecycle.isHeartbeatRunning)

        lifecycle.mainAppDidStart(
            startHeartbeat: { startCount += 1 },
            requestConfiguration: { configRequestCount += 1 }
        )

        #expect(startCount == 1)
        #expect(configRequestCount == 1)
        #expect(lifecycle.isHeartbeatRunning)
    }
}
