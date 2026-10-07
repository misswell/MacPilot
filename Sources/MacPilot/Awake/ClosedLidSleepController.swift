import Foundation
import MacPilotPowerIPC
import OSLog

/// What the Awake session manager and the settings UI need from the
/// closed-lid power service.
///
/// The protocol is synchronous on purpose: `AwakeSessionManager.applyAssertions()`
/// is a synchronous MainActor function, and keeping the enabling call
/// synchronous makes the aggregation deterministic. All privileged work still
/// happens asynchronously behind the scenes.
@MainActor
protocol ClosedLidSleepControlling: AnyObject {
    var serviceState: ClosedLidSleepServiceState { get }
    var isActive: Bool { get }
    var lastFailure: ClosedLidSleepFailure? { get }
    var systemSleepDisabled: Bool? { get }

    /// Invoked on the main actor whenever any published value changes.
    var onStateChange: (@MainActor () -> Void)? { get set }

    func prepareIfNeeded() async
    func openSystemSettings()
    func setEnabled(_ enabled: Bool)
    /// Finishes an enable that registration interrupted: the user approves the
    /// daemon outside the app. Also verifies already-active protection against
    /// the real system setting when the user returns to the settings page.
    func reenableIfPending()
    func shutdown()
}

/// Turns the aggregate `preventClosedLidSleep` state into the system-level
/// `SleepDisabled` power setting through the privileged helper.
///
/// This controller owns no session logic: it only follows the desired flag and
/// keeps the helper's watchdog fed while the flag is on.
@MainActor
final class ClosedLidSleepController: ClosedLidSleepControlling {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.ClosedLid")
    private let helper: any PowerHelperServicing
    private let heartbeatInterval: Duration
    private let reconnectDelays: [Duration]

    private(set) var serviceState: ClosedLidSleepServiceState
    private(set) var isActive = false
    private(set) var lastFailure: ClosedLidSleepFailure?
    private(set) var systemSleepDisabled: Bool?

    var onStateChange: (@MainActor () -> Void)?

    private var desiredEnabled = false
    private var ownsSleepDisabled = false
    /// Monotonic: set once the helper confirmed it turned `disablesleep` on, and
    /// cleared only after a *confirmed* release. A failed release must not make
    /// the app forget that the system setting may still be applied, or the
    /// synchronous release at quit would be skipped and the Mac would stay
    /// unable to sleep with the lid closed.
    private var mayOwnSleepDisabled = false
    private var reconnectAttempt = 0
    private var workTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var isShutdown = false

    init(
        helper: any PowerHelperServicing = PrivilegedPowerHelper(),
        heartbeatInterval: Duration = .seconds(30),
        reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    ) {
        self.helper = helper
        self.heartbeatInterval = heartbeatInterval
        self.reconnectDelays = reconnectDelays
        self.serviceState = helper.registrationState
    }

    var isServiceReady: Bool {
        if case .ready = helper.registrationState { return true }
        if case .enabled = serviceState { return true }
        return false
    }

    func prepareIfNeeded() async {
        guard !isShutdown else { return }
        await ensureRegistration()
        guard !isShutdown, !Task.isCancelled else { return }
        notifyStateChange()
    }

    func openSystemSettings() {
        helper.openSystemSettings()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isShutdown else { return }
        guard enabled != desiredEnabled else { return }
        desiredEnabled = enabled
        logger.notice("Closed-lid sleep \(enabled ? "requested" : "released", privacy: .public)")
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.desiredEnabled {
                await self.enableIfNeeded()
            } else {
                await self.releaseIfNeeded()
            }
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        workTask?.cancel()
        workTask = nil
        // The setting must go back immediately on a normal quit; the helper
        // watchdog is only the crash backstop. `mayOwnSleepDisabled` is included
        // so a release that failed earlier still gets one more synchronous try.
        if ownsSleepDisabled || isActive || mayOwnSleepDisabled {
            helper.releaseSynchronously()
        }
        ownsSleepDisabled = false
        mayOwnSleepDisabled = false
        desiredEnabled = false
        isActive = false
        notifyStateChange()
    }

    // MARK: - Enabling

    private func enableIfNeeded() async {
        // `reenableIfPending` and `setEnabled` replace `workTask` with cancel;
        // a task that has not reached its first suspension would otherwise run
        // to completion next to its replacement and duplicate the request.
        guard !Task.isCancelled else { return }
        reconnectAttempt = 0
        await ensureRegistration()
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        switch helper.registrationState {
        case .ready:
            break
        case .notRegistered, .requiresApproval, .unavailable:
            isActive = false
            serviceState = helper.registrationState
            if helper.registrationState == .unavailable {
                lastFailure = .helperUnavailable()
            }
            notifyStateChange()
            return
        case .enabling, .enabled, .error:
            break
        }

        serviceState = .enabling
        notifyStateChange()
        let result = await helper.setSleepDisabled(true)
        guard !isShutdown, desiredEnabled, !Task.isCancelled else { return }
        switch result {
        case .success(let owned):
            ownsSleepDisabled = owned
            if owned { mayOwnSleepDisabled = true }
            if await verifyOrRepairAppliedState() {
                logger.notice("Closed-lid sleep verified (owned=\(owned, privacy: .public))")
            }
        case .failure(let failure):
            ownsSleepDisabled = false
            recordFailure(failure)
            logger.error("Closed-lid sleep enable failed: \(failure.message, privacy: .public)")
        }
        if desiredEnabled, !isShutdown, !Task.isCancelled { startHeartbeat() }
        notifyStateChange()
    }

    private func releaseIfNeeded() async {
        guard !Task.isCancelled else { return }
        stopHeartbeat()
        reconnectAttempt = 0
        let result = await helper.setSleepDisabled(false)
        guard !desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        switch result {
        case .success:
            ownsSleepDisabled = false
            mayOwnSleepDisabled = false
            isActive = false
            systemSleepDisabled = nil
            lastFailure = nil
            serviceState = helper.registrationState
            logger.notice("Closed-lid sleep released")
            // The feature is off and the setting is confirmed released, so the
            // cached privileged connection is no longer needed.
            await helper.invalidate()
        case .failure(let failure):
            ownsSleepDisabled = false
            isActive = false
            lastFailure = failure
            serviceState = .error(failure.message)
            logger.error("Closed-lid sleep release failed: \(failure.message, privacy: .public)")
        }
        notifyStateChange()
    }

    private func ensureRegistration() async {
        switch helper.registrationState {
        case .notRegistered:
            do {
                try helper.register()
                lastFailure = nil
            } catch {
                // A throw does not always mean a dead end: the daemon
                // registration dance reports POSIX 1 "Operation not permitted"
                // while the system record still advances to `.requiresApproval`.
                // Only a record that is still absent afterwards is a real
                // failure; anything else is progress the state below must pick
                // up.
                if case .notRegistered = helper.registrationState {
                    let failure = (error as? ClosedLidSleepFailure)
                        ?? .registrationFailed(error.localizedDescription)
                    lastFailure = failure
                    serviceState = .error(failure.message)
                    return
                }
                lastFailure = nil
            }
        case .ready, .requiresApproval, .unavailable, .enabling, .enabled, .error:
            break
        }
        serviceState = helper.registrationState
    }

    func reenableIfPending() {
        guard desiredEnabled, isServiceReady, !isShutdown else { return }
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isActive {
                await self.checkAndRepairAppliedState()
            } else {
                await self.enableIfNeeded()
            }
        }
    }

    /// An XPC success or a helper-owned flag cannot prove that lid sleep is
    /// blocked. Only the system value may publish protection as active.
    private func verifyAppliedState() async -> Bool {
        let result = await helper.sleepDisabled()
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return false }
        switch result {
        case .success(true):
            systemSleepDisabled = true
            isActive = true
            serviceState = .enabled
            lastFailure = nil
        case .success(false):
            recordFailure(.requestFailed("Closed-lid sleep prevention is not active."), systemValue: false)
        case .failure(let failure):
            recordFailure(failure)
        }
        notifyStateChange()
        return isActive
    }

    private func recordFailure(_ failure: ClosedLidSleepFailure, systemValue: Bool? = nil) {
        isActive = false
        systemSleepDisabled = systemValue
        lastFailure = failure
        serviceState = .error(failure.message)
    }

    private func verifyOrRepairAppliedState() async -> Bool {
        if await verifyAppliedState() { return true }
        if desiredEnabled, !isShutdown, !Task.isCancelled, systemSleepDisabled == false {
            await repairLostSetting()
        }
        return isActive
    }

    /// A daemon from the previous app version may still be running. Its
    /// ownership shortcut can acknowledge an enable without applying it. The
    /// system is already unprotected here, so release the stale ownership first
    /// and then apply once. Both operations preserve the helper's ownership
    /// boundary; no daemon restart or extra system authorization is needed.
    private func repairLostSetting() async {
        guard desiredEnabled, !isShutdown, !Task.isCancelled, systemSleepDisabled == false else { return }
        serviceState = .enabling
        notifyStateChange()
        let release = await helper.setSleepDisabled(false)
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        if case .failure(let failure) = release {
            recordFailure(failure)
            notifyStateChange()
            return
        }
        ownsSleepDisabled = false
        // Keep the conservative quit-time release armed until the complete
        // repair has finished; a new enable is about to be sent.
        let result = await helper.setSleepDisabled(true)
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        switch result {
        case .success(let owned):
            ownsSleepDisabled = owned
            if owned { mayOwnSleepDisabled = true }
            _ = await verifyAppliedState()
        case .failure(let failure):
            recordFailure(failure)
        }
        notifyStateChange()
    }

    private func checkAndRepairAppliedState() async {
        if await verifyAppliedState() { return }
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        if systemSleepDisabled == false {
            logger.notice("Closed-lid sleep setting was lost; reapplying protection")
            await repairLostSetting()
        } else {
            await attemptReconnect()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.heartbeatInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.sendHeartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func sendHeartbeat() async {
        guard desiredEnabled, !isShutdown else { return }
        let result = await helper.heartbeat()
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        switch result {
        case .success:
            reconnectAttempt = 0
            await checkAndRepairAppliedState()
        case .failure(let failure):
            recordFailure(failure)
            logger.error("Heartbeat failed: \(failure.message, privacy: .public)")
            await attemptReconnect()
            return
        }
        notifyStateChange()
    }

    /// Bounded reconnect: never an infinite high-frequency retry loop. The
    /// helper watchdog remains the safety net if every attempt fails.
    private func attemptReconnect() async {
        guard desiredEnabled, !isShutdown, reconnectAttempt < reconnectDelays.count else {
            notifyStateChange()
            return
        }
        let delay = reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        guard desiredEnabled, !isShutdown else { return }
        logger.notice("Reconnecting to the background power service (attempt \(self.reconnectAttempt, privacy: .public))")
        let result = await helper.setSleepDisabled(true)
        guard desiredEnabled, !isShutdown, !Task.isCancelled else { return }
        switch result {
        case .success(let owned):
            ownsSleepDisabled = owned
            if owned { mayOwnSleepDisabled = true }
            _ = await verifyOrRepairAppliedState()
        case .failure(let failure):
            recordFailure(failure)
        }
        notifyStateChange()
    }

    private func notifyStateChange() {
        onStateChange?()
    }
}
