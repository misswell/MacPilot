import Foundation

/// Keeps the Finder extension's heartbeat task aligned with main-app lifecycle
/// notifications without depending on a live Finder host in tests.
@MainActor
final class FinderSyncHeartbeatLifecycle {
    private var heartbeatIsRunning = false
    private var mainAppHasQuit = false
    private var bootstrapRequested = false

    var isHeartbeatRunning: Bool { heartbeatIsRunning }

    func extensionDidLaunch(
        startHeartbeat: () -> Void,
        requestConfiguration: () -> Void
    ) {
        guard !mainAppHasQuit, !bootstrapRequested, !heartbeatIsRunning else { return }
        bootstrapRequested = true
        // Ask once. Finder may launch an enabled extension while the main
        // feature is off; no timer is justified until an authenticated reply.
        requestConfiguration()
    }

    func configurationDidArrive(startHeartbeat: () -> Void) -> Bool {
        guard !mainAppHasQuit else { return false }
        if !heartbeatIsRunning {
            heartbeatIsRunning = true
            startHeartbeat()
        }
        return true
    }

    func mainAppDidQuit(stopHeartbeat: () -> Void) {
        mainAppHasQuit = true
        guard heartbeatIsRunning else { return }
        heartbeatIsRunning = false
        stopHeartbeat()
    }

    func mainAppDidStart(
        startHeartbeat: () -> Void,
        requestConfiguration: () -> Void
    ) {
        mainAppHasQuit = false
        bootstrapRequested = true
        if !heartbeatIsRunning {
            heartbeatIsRunning = true
            startHeartbeat()
        }

        // A fresh request doubles as the app's immediate alive signal. The
        // main app responds with current configuration; no timer restart is
        // needed when duplicate `.running` messages arrive.
        requestConfiguration()
    }
}
