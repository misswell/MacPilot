import Foundation
import MacPilotPowerIPC
import OSLog

// MacPilotPowerHelper — minimal root LaunchDaemon.
//
// It owns exactly one capability: flipping `/usr/bin/pmset -a disablesleep`.
// There is no generic command execution surface, and the watchdog restores the
// original power configuration if the MacPilot app stops proving it is alive.

let logger = Logger(subsystem: "com.misswell.macpilot", category: "PowerHelper")
let manager = SleepDisabledManager()

// Restore a stale setting left behind by a crashed app before serving requests.
manager.recoverIfStale(reason: "launch")
manager.startWatchdog()

let service = PowerHelperService(manager: manager)
let listener = NSXPCListener(machServiceName: MacPilotPowerService.machServiceName)
listener.delegate = service
listener.resume()

// launchd sends SIGTERM when it is shutting the daemon down. Release an owned
// setting so a helper restart during shutdown never leaves the Mac in a state
// where it cannot sleep with the lid closed.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
terminationSource.setEventHandler {
    logger.notice("Received SIGTERM; releasing owned power state")
    manager.releaseIfOwned()
    exit(EXIT_SUCCESS)
}
terminationSource.resume()

RunLoop.current.run()
