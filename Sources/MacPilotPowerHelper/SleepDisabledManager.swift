import Foundation
import MacPilotPowerIPC
import OSLog
import os

/// Executes the two fixed `pmset` power operations and keeps the tiny amount
/// of ownership state that makes crash recovery safe.
///
/// The manager never runs a caller-provided command. The only executable it
/// ever launches is `/usr/bin/pmset` with a hard-coded argument list.
final class SleepDisabledManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "PowerHelper")
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    private let stateURL: URL
    private let state: OSAllocatedUnfairLock<SleepDisabledRuntimeState>
    private let queue = DispatchQueue(label: "com.misswell.macpilot.powerhelper.manager")
    private let now: @Sendable () -> Date

    private let heartbeatTimeout: TimeInterval
    private let watchdogInterval: TimeInterval
    private var watchdog: DispatchSourceTimer?

    init(
        stateDirectory: URL = URL(fileURLWithPath: MacPilotPowerService.stateDirectoryPath, isDirectory: true),
        heartbeatTimeout: TimeInterval = 90,
        watchdogInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stateURL = stateDirectory.appendingPathComponent(MacPilotPowerService.stateFileName)
        self.heartbeatTimeout = heartbeatTimeout
        self.watchdogInterval = watchdogInterval
        self.now = now
        self.state = OSAllocatedUnfairLock(initialState: Self.loadState(from: stateURL))
        logger.notice("Power helper started; owned=\(self.state.withLock { $0.macPilotOwnedSleepDisable }, privacy: .public)")
    }

    // MARK: - Public surface

    /// Reads the real system value from `pmset -g`.
    func currentSystemSleepDisabled() -> Bool? {
        runPMSet(arguments: ["-g"]).flatMap { output in
            SleepDisabledPlanner.parseSleepDisabled(fromPMSetOutput: output)
        }
    }

    /// Enables `SleepDisabled`, claiming ownership only when MacPilot is the
    /// one that changed it.
    func enable() -> Result<Bool, PowerHelperOperationError> {
        guard let current = currentSystemSleepDisabled() else {
            return .failure(PowerHelperOperationError("Could not read the current SleepDisabled setting."))
        }
        let snapshot = state.withLock { $0 }
        switch SleepDisabledPlanner.planEnable(currentSleepDisabled: current, state: snapshot) {
        case .noChange:
            let updated = SleepDisabledPlanner.stateAfterEnable(
                currentSleepDisabled: current,
                state: snapshot,
                now: now()
            )
            store(updated)
            logger.notice("SleepDisabled left unchanged by MacPilot; owned=\(updated.macPilotOwnedSleepDisable, privacy: .public)")
            return .success(updated.macPilotOwnedSleepDisable)
        case .enableByRunningPMSet:
            guard let output = runPMSet(arguments: ["-a", "disablesleep", "1"]) else {
                return .failure(PowerHelperOperationError("pmset could not enable SleepDisabled."))
            }
            _ = output
            guard currentSystemSleepDisabled() == true else {
                return .failure(PowerHelperOperationError("SleepDisabled did not stay enabled after pmset."))
            }
            let didOwn = snapshot.macPilotOwnedSleepDisable || !current
            var updated = snapshot
            updated.macPilotOwnedSleepDisable = didOwn
            updated.previousSleepDisabled = false
            updated.lastHeartbeat = now()
            store(updated)
            logger.notice("SleepDisabled enabled by MacPilot; owned=\(updated.macPilotOwnedSleepDisable, privacy: .public)")
            return .success(updated.macPilotOwnedSleepDisable)
        case .disableByRunningPMSet:
            return .failure(PowerHelperOperationError("Unexpected power state."))
        }
    }

    /// Releases `SleepDisabled` only when MacPilot owns it.
    func disable() -> Result<Bool, PowerHelperOperationError> {
        let snapshot = state.withLock { $0 }
        guard snapshot.macPilotOwnedSleepDisable else {
            logger.notice("Release ignored: MacPilot does not own SleepDisabled")
            return .success(false)
        }
        if currentSystemSleepDisabled() == true {
            guard runPMSet(arguments: ["-a", "disablesleep", "0"]) != nil else {
                return .failure(PowerHelperOperationError("pmset could not disable SleepDisabled."))
            }
        }
        let updated = SleepDisabledPlanner.stateAfterDisable(
            currentSleepDisabled: currentSystemSleepDisabled() ?? false,
            state: snapshot
        )
        store(updated)
        logger.notice("SleepDisabled released by MacPilot")
        return .success(false)
    }

    func recordHeartbeat() {
        let timestamp = now()
        state.withLock { current in
            current.lastHeartbeat = timestamp
        }
        persist()
    }

    var isOwned: Bool {
        state.withLock { $0.macPilotOwnedSleepDisable }
    }

    /// Releases a setting MacPilot still owns when the helper itself is being
    /// terminated, then persists the cleared state.
    func releaseIfOwned() {
        guard isOwned else { return }
        logger.notice("Releasing SleepDisabled during helper shutdown")
        _ = disable()
    }

    // MARK: - Watchdog

    func startWatchdog() {
        queue.async { [self] in
            recoverIfStale(reason: "startup")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
            timer.setEventHandler { [weak self] in
                self?.recoverIfStale(reason: "watchdog")
            }
            watchdog = timer
            timer.resume()
        }
    }

    /// Restores the setting when the app stopped proving it was alive.
    func recoverIfStale(reason: String) {
        let snapshot = state.withLock { $0 }
        guard SleepDisabledPlanner.shouldWatchdogRecover(
            state: snapshot,
            now: now(),
            timeout: heartbeatTimeout
        ) else { return }
        logger.error("Heartbeat timeout (\(reason, privacy: .public)); restoring SleepDisabled")
        _ = disable()
    }

    // MARK: - pmset

    /// Runs `/usr/bin/pmset` with fixed arguments and returns stdout on success.
    private func runPMSet(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = pmsetURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // Discard stderr instead of collecting it in an undrained pipe. All XPC
        // work is serialized on one queue, so a child that filled the stderr
        // buffer would block in write and wedge the daemon permanently in
        // `waitUntilExit()`.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("pmset launch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("pmset \(arguments.joined(separator: " "), privacy: .public) exited \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Persistence

    private func store(_ newState: SleepDisabledRuntimeState) {
        state.withLock { $0 = newState }
        persist()
    }

    private func persist() {
        let snapshot = state.withLock { $0 }
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(snapshot)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Could not persist helper state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadState(from url: URL) -> SleepDisabledRuntimeState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(SleepDisabledRuntimeState.self, from: data)) ?? .empty
    }
}
