import Combine
import Foundation
import AppKit
import OSLog

@MainActor
final class AwakeSessionManager: ObservableObject {
    /// Upper bound on ended sessions kept for the UI's recent history.
    private static let maximumRetainedEndedSessions = 20
    // Active sessions are intentionally in-memory. The Awake spec's startup
    // policy says manual sessions do not survive an app restart; wake and
    // clock-change notifications still re-evaluate sessions that remain live.
    @Published private(set) var sessions: [AwakeSession] = []
    @Published private(set) var desiredAwakeState = DesiredAwakeState.inactive
    @Published private(set) var powerState = PowerState.unknown
    @Published private(set) var safetyProtectionActive = false
    @Published private(set) var lastAssertionFailure: AwakeAssertionFailure?
    @Published private(set) var settings = AwakeSettings.standard

    /// Mirrors of the privileged closed-lid service so SwiftUI can observe
    /// them through this object. `ClosedLidSleepController` itself is not
    /// observed directly.
    @Published private(set) var closedLidServiceState: ClosedLidSleepServiceState = .unavailable
    @Published private(set) var isClosedLidSleepActive = false
    @Published private(set) var lastClosedLidFailure: ClosedLidSleepFailure?
    @Published private(set) var isLidClosed = false

    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Session")
    private let assertionController: any AwakeAssertionControlling
    private let powerStateProvider: any AwakePowerStateProviding
    private let notifyBatteryWarning: (Int) -> Void
    private let now: () -> Date
    private let closedLidSleepController: (any ClosedLidSleepControlling)?
    private let lidStateMonitor: (any LidStateMonitoring)?
    private let displayStateProvider: any AwakeDisplayStateProviding
    private let sleepDisplay: @MainActor () -> Void
    private let wakeDisplay: () -> Void
    private var maintenanceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var powerMonitoringToken: UUID?
    private var powerReconnectToken: UUID?
    private var lastOnExternalPower: Bool?
    private var sleepStartedAt: Date?
    private var isDisplayAsleep = false
    private var warnedBatteryThreshold = false
    private var isShutdown = false
    /// Whether the aggregate closed-lid policy is currently requested, so the
    /// controller is only toggled on real transitions.
    private var closedLidSleepRequested = false
    private var isLidMonitoring = false
    /// Only wake the display on lid open when MacPilot was the one that slept
    /// it for this lid close.
    private var displayWasSleptByMacPilotForLidClose = false

    /// Called by `MacPilotModel` when the user-facing Awake preferences change.
    var persist: (() -> Void)?

    init(
        assertionController: any AwakeAssertionControlling = AwakeAssertionController(),
        powerStateProvider: any AwakePowerStateProviding = PowerStateProvider(),
        notifyBatteryWarning: @escaping (Int) -> Void = { AwakeNotifications.showBatteryWarning(threshold: $0) },
        now: @escaping () -> Date = { Date() },
        closedLidSleepController: (any ClosedLidSleepControlling)? = nil,
        lidStateMonitor: (any LidStateMonitoring)? = nil,
        displayStateProvider: any AwakeDisplayStateProviding = DisplayStateProvider(),
        sleepDisplay: @escaping @MainActor () -> Void = DisplayPower.sleepDisplay,
        wakeDisplay: @escaping () -> Void = DisplayPower.wakeDisplay
    ) {
        self.assertionController = assertionController
        self.powerStateProvider = powerStateProvider
        self.notifyBatteryWarning = notifyBatteryWarning
        self.now = now
        self.closedLidSleepController = closedLidSleepController
        self.lidStateMonitor = lidStateMonitor
        self.displayStateProvider = displayStateProvider
        self.sleepDisplay = sleepDisplay
        self.wakeDisplay = wakeDisplay
        powerState = powerStateProvider.currentPowerState()
        closedLidServiceState = closedLidSleepController?.serviceState ?? .unavailable
        closedLidSleepController?.onStateChange = { [weak self] in
            self?.syncClosedLidServiceState()
        }
        installSystemObservers()
    }

    var activeSessions: [AwakeSession] {
        sessions.filter { $0.state == .active }
    }

    var activeSessionCount: Int { activeSessions.count }
    var isActive: Bool { !activeSessions.isEmpty }
    var hasManualSession: Bool { activeSessions.contains { $0.source == .manual } }
    var isSystemAssertionActive: Bool { assertionController.isSystemAssertionActive }
    var isDisplayAssertionActive: Bool { assertionController.isDisplayAssertionActive }
    var sharedPowerStateProvider: any AwakePowerStateProviding { powerStateProvider }

    /// Ask the privileged helper to register, if it is not registered yet.
    /// Never called at launch; only from the closed-lid UI or the enable flow.
    func prepareClosedLidService() async {
        guard let closedLidSleepController else { return }
        await closedLidSleepController.prepareIfNeeded()
        syncClosedLidServiceState()
    }

    func openClosedLidServiceSettings() {
        closedLidSleepController?.openSystemSettings()
    }

    func startSession(
        source: SessionSource,
        endCondition: SessionEndCondition,
        policy: SessionPolicy
    ) -> UUID {
        let session = AwakeSession(
            id: UUID(),
            source: source,
            startedAt: now(),
            endCondition: endCondition,
            policy: policy,
            state: .active
        )
        sessions.append(session)
        logger.notice("Session started: \(session.id.uuidString, privacy: .public)")
        refreshPowerState()
        return session.id
    }

    @discardableResult
    func startManualSession(endCondition: SessionEndCondition = .manual) -> UUID {
        startSession(source: .manual, endCondition: endCondition, policy: settings.defaultPolicy)
    }

    @discardableResult
    func startManualSession(duration: TimeInterval) -> UUID {
        startManualSession(endCondition: .duration(max(0, duration)))
    }

    @discardableResult
    func startManualSession(until date: Date) -> UUID {
        startManualSession(endCondition: .date(date))
    }

    /// Starts the default session: the persisted default duration (or
    /// manual end when unlimited) with the shared default policy.
    @discardableResult
    func startDefaultSession() -> UUID {
        startSession(
            source: .manual,
            endCondition: settings.defaultSession.endCondition,
            policy: settings.defaultPolicy
        )
    }

    /// Called once by `MacPilotModel` after the stored configuration loads.
    /// Auto-start only fills an idle state, so repeated calls are no-ops.
    @discardableResult
    func startDefaultSessionOnLaunchIfEnabled() -> UUID? {
        guard settings.defaultSession.autoStartOnLaunch, activeSessions.isEmpty else { return nil }
        logger.notice("Auto-starting default session on launch")
        return startDefaultSession()
    }

    /// Runs when the Mac wakes from sleep: sessions configured to pause
    /// during sleep resume their countdown first, stale sessions expire,
    /// then the default session starts only when nothing keeps the Mac awake.
    func handleSystemWake() {
        guard !isShutdown else { return }
        if let sleepStartedAt {
            shiftActiveDurationSessions(by: now().timeIntervalSince(sleepStartedAt))
            self.sleepStartedAt = nil
        }
        refreshPowerState()
        guard settings.defaultSession.autoStartOnWake, activeSessions.isEmpty else { return }
        logger.notice("Auto-starting default session after system wake")
        _ = startDefaultSession()
    }

    /// Runs when the Mac is about to sleep. Sessions opted into
    /// end-on-forced-sleep end now; the others survive and timed sessions
    /// may pause their countdown depending on their end-time calculation.
    func handleSystemSleep() {
        guard !isShutdown else { return }
        sleepStartedAt = now()
        let forcedIDs = activeSessions.filter { $0.policy.endOnForcedSleep }.map(\.id)
        for id in forcedIDs { markSessionEnded(id) }
        if !forcedIDs.isEmpty {
            logger.notice("Forced sleep ended \(forcedIDs.count, privacy: .public) session(s)")
        }
        refreshDesiredState()
    }

    /// The display went off. Sessions that allow it release system sleep
    /// prevention until the display wakes again.
    func handleDisplaysDidSleep() {
        isDisplayAsleep = true
        applyAssertionsForDisplayChange()
    }

    func handleDisplaysDidWake() {
        isDisplayAsleep = false
        applyAssertionsForDisplayChange()
    }

    private func applyAssertionsForDisplayChange() {
        guard !isShutdown, isActive else { return }
        applyAssertions()
    }

    private func shiftActiveDurationSessions(by interval: TimeInterval) {
        guard interval > 0 else { return }
        for index in sessions.indices where sessions[index].state == .active {
            guard case .duration = sessions[index].endCondition else { continue }
            guard sessions[index].policy.endCalculation == .pausesDuringSleep else { continue }
            sessions[index].startedAt = sessions[index].startedAt.addingTimeInterval(interval)
        }
    }

    func toggleManualSession() {
        if hasManualSession {
            endAllManualSessions()
        } else {
            _ = startManualSession()
        }
    }

    func endSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].state == .active else { return }
        sessions[index].state = .ended
        logger.notice("Session ended: \(id.uuidString, privacy: .public)")
        pruneEndedSessions()
        refreshDesiredState()
    }

    func endSessions(source: SessionSource) {
        let ids = activeSessions.filter { $0.source == source }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { markSessionEnded(id) }
        refreshDesiredState()
    }

    func endAllManualSessions() {
        endSessions(source: .manual)
    }

    func endAllSessions() {
        let ids = activeSessions.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { markSessionEnded(id) }
        refreshDesiredState()
    }

    func refreshDesiredState() {
        expireSessions(at: now())
        applySafetyPolicy()
        applyAssertions()
        deferScreenSaverIfEnabled()
        scheduleMaintenance()
    }

    func refreshPowerState() {
        powerState = powerStateProvider.currentPowerState()
        refreshDesiredState()
    }

    func updateSettings(_ mutate: (inout AwakeSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }
        settings = updated
        persist?()
        updatePowerReconnectMonitoring()
        refreshPowerState()
    }

    func applyLoadedSettings(_ newSettings: AwakeSettings) {
        settings = newSettings
        powerState = powerStateProvider.currentPowerState()
        updatePowerReconnectMonitoring()
        refreshDesiredState()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        maintenanceTask?.cancel()
        maintenanceTask = nil
        stopPowerMonitoring()
        if let token = powerReconnectToken {
            powerReconnectToken = nil
            powerStateProvider.removeMonitoringObserver(token)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        stopLidMonitoring()
        closedLidSleepController?.shutdown()
        syncClosedLidServiceState()
        if case .failure(let failure) = assertionController.releaseAll() {
            lastAssertionFailure = failure
        }
    }

    private func markSessionEnded(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].state == .active else { return }
        sessions[index].state = .ended
        logger.notice("Session ended: \(id.uuidString, privacy: .public)")
        pruneEndedSessions()
    }

    /// Bounds the session array: ended sessions are kept only as a short recent
    /// history, so a long-running process does not accumulate every session it
    /// ever started.
    private func pruneEndedSessions() {
        let endedCount = sessions.count { $0.state != .active }
        guard endedCount > Self.maximumRetainedEndedSessions else { return }
        var remainingToDrop = endedCount - Self.maximumRetainedEndedSessions
        sessions.removeAll { session in
            guard remainingToDrop > 0, session.state != .active else { return false }
            remainingToDrop -= 1
            return true
        }
    }

    private func expireSessions(at date: Date) {
        let expiredIDs = activeSessions.compactMap { session -> UUID? in
            guard let expectedEndAt = session.expectedEndAt, date >= expectedEndAt else { return nil }
            return session.id
        }
        guard !expiredIDs.isEmpty else { return }
        for id in expiredIDs { markSessionEnded(id) }
        logger.notice("Expired \(expiredIDs.count, privacy: .public) Awake session(s)")
    }

    private func applySafetyPolicy() {
        let wasActive = safetyProtectionActive
        safetyProtectionActive = isBelowBatteryThreshold
        guard safetyProtectionActive else {
            updateBatteryWarning()
            return
        }
        let activeIDs = activeSessions.map(\.id)
        for id in activeIDs { markSessionEnded(id) }
        warnedBatteryThreshold = false
        if !activeIDs.isEmpty || !wasActive {
            logger.notice("Low-battery safety policy ended \(activeIDs.count, privacy: .public) session(s)")
        }
    }

    private var isBelowBatteryThreshold: Bool {
        guard settings.safetyPolicy.lowBatteryProtectionEnabled,
              let batteryLevel = powerState.batteryLevel else { return false }
        if settings.defaultSession.ignoreBatteryLevelOnExternalPower, powerState.onExternalPower { return false }
        return batteryLevel < Double(settings.safetyPolicy.minimumBatteryLevel)
    }

    /// Internal for tests: whether the low-battery warning notification is
    /// due right now (level inside the 5-point window above the threshold).
    var isBatteryWarningDue: Bool {
        guard settings.defaultSession.warnBeforeBatteryTermination,
              settings.safetyPolicy.lowBatteryProtectionEnabled,
              !activeSessions.isEmpty,
              !warnedBatteryThreshold,
              !(settings.defaultSession.ignoreBatteryLevelOnExternalPower && powerState.onExternalPower),
              let batteryLevel = powerState.batteryLevel else { return false }
        return batteryLevel < Double(settings.safetyPolicy.minimumBatteryLevel + 5)
    }

    private func updateBatteryWarning() {
        if let batteryLevel = powerState.batteryLevel,
           batteryLevel > Double(settings.safetyPolicy.minimumBatteryLevel + 10) {
            warnedBatteryThreshold = false
        }
        guard isBatteryWarningDue else { return }
        warnedBatteryThreshold = true
        logger.notice("Battery is approaching the low-power threshold")
        notifyBatteryWarning(settings.safetyPolicy.minimumBatteryLevel)
    }

    func deferScreenSaverIfEnabled() {
        guard !isShutdown else { return }
        let blocking = activeSessions.filter { $0.policy.blockScreenSaver }
        guard let allowedAfterMinutes = blocking.map(\.policy.screenSaverIdleMinutes).min() else { return }
        let idleSeconds = AwakeIdleInput.sessionIdleSeconds()
        if AwakeIdleInput.shouldDeferScreenSaver(
            idleSeconds: idleSeconds,
            allowedAfterMinutes: allowedAfterMinutes,
            systemIdleLimitSeconds: AwakeIdleInput.systemScreenSaverIdleSeconds()
        ) {
            AwakeIdleInput.postIdleDeferringMouseEvent(logger: logger)
        }
    }

    private func applyAssertions() {
        let active = activeSessions
        // Keeping the Mac awake with the lid closed only makes sense while the
        // system itself is prevented from sleeping, so the closed-lid flag
        // forces system-sleep prevention on.
        let closedLidSleepPrevented = active.contains { $0.policy.preventClosedLidSleep }
        // System sleep prevention is released while the display is off only
        // when every session that prevents system sleep allows it, and never
        // while the Mac must keep running with the lid closed.
        let allAllowSleepWithDisplayOff = active
            .filter { $0.policy.preventSystemSleep }
            .allSatisfy { $0.policy.allowSystemSleepWhenDisplayOff }
        let displayOffReleasesSystemSleep = isDisplayAsleep
            && allAllowSleepWithDisplayOff
            && !closedLidSleepPrevented
        let desired = DesiredAwakeState(
            preventSystemSleep: (active.contains { $0.policy.preventSystemSleep } || closedLidSleepPrevented)
                && !displayOffReleasesSystemSleep,
            preventDisplaySleep: active.contains { $0.policy.preventDisplaySleep },
            preventClosedLidSleep: closedLidSleepPrevented
        )
        desiredAwakeState = desired
        switch assertionController.apply(desired) {
        case .success:
            lastAssertionFailure = nil
        case .failure(let failure):
            lastAssertionFailure = failure
            logger.error("Assertion update failed: \(failure.localizedDescription, privacy: .public)")
        }
        applyClosedLidSleep(desired.preventClosedLidSleep)
    }

    // MARK: - Closed-lid sleep

    private func applyClosedLidSleep(_ enabled: Bool) {
        if enabled != closedLidSleepRequested {
            closedLidSleepRequested = enabled
            closedLidSleepController?.setEnabled(enabled)
            if enabled {
                startLidMonitoring()
            } else {
                stopLidMonitoring()
            }
        }
        syncClosedLidServiceState()
    }

    private func startLidMonitoring() {
        guard !isLidMonitoring, let lidStateMonitor else { return }
        isLidMonitoring = true
        lidStateMonitor.start { [weak self] state in
            self?.handleLidStateChange(state)
        }
    }

    private func stopLidMonitoring() {
        guard isLidMonitoring, let lidStateMonitor else { return }
        isLidMonitoring = false
        lidStateMonitor.stop()
        isLidClosed = false
        displayWasSleptByMacPilotForLidClose = false
    }

    /// Reacts to a physical lid change. The built-in display is only turned
    /// off when no external display is attached, and only a display MacPilot
    /// slept this way is woken again on lid open.
    private func handleLidStateChange(_ state: LidState) {
        guard !isShutdown, closedLidSleepRequested else { return }
        isLidClosed = state == .closed
        switch state {
        case .closed:
            guard !displayWasSleptByMacPilotForLidClose else { return }
            displayStateProvider.refreshNow()
            guard displayStateProvider.currentState.externalDisplayCount == 0 else {
                logger.notice("Lid closed with an external display attached; leaving displays to macOS")
                return
            }
            displayWasSleptByMacPilotForLidClose = true
            logger.notice("Lid closed; turning off the built-in display")
            sleepDisplay()
        case .open:
            guard displayWasSleptByMacPilotForLidClose else { return }
            displayWasSleptByMacPilotForLidClose = false
            logger.notice("Lid opened; waking the display MacPilot turned off")
            wakeDisplay()
        case .unknown:
            break
        }
    }

    private func syncClosedLidServiceState() {
        let newState = closedLidSleepController?.serviceState ?? .unavailable
        let newActive = closedLidSleepController?.isActive ?? false
        let newFailure = closedLidSleepController?.lastFailure
        // Only publish real changes: `applyAssertions()` runs frequently while
        // a session is counting down.
        if closedLidServiceState != newState { closedLidServiceState = newState }
        if isClosedLidSleepActive != newActive { isClosedLidSleepActive = newActive }
        if lastClosedLidFailure != newFailure { lastClosedLidFailure = newFailure }
    }

    private func scheduleMaintenance() {
        maintenanceTask?.cancel()
        guard !activeSessions.isEmpty else {
            maintenanceTask = nil
            stopPowerMonitoring()
            return
        }
        startPowerMonitoring()

        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.expireSessions(at: self.now())
                self.applySafetyPolicy()
                self.applyAssertions()
                self.deferScreenSaverIfEnabled()

                guard !self.activeSessions.isEmpty else {
                    self.maintenanceTask = nil
                    return
                }

                guard let nextExpiration = self.activeSessions.compactMap(\.expectedEndAt).min() else {
                    self.maintenanceTask = nil
                    return
                }
                let expirationDelay = max(0.25, nextExpiration.timeIntervalSince(self.now()))
                let delay = min(max(expirationDelay, 0.25), 60)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func startPowerMonitoring() {
        guard powerMonitoringToken == nil else { return }
        powerMonitoringToken = powerStateProvider.addMonitoringObserver { [weak self] in
            self?.handlePowerSourceChange()
        }
    }

    private func stopPowerMonitoring() {
        guard let token = powerMonitoringToken else { return }
        powerMonitoringToken = nil
        powerStateProvider.removeMonitoringObserver(token)
    }

    /// Keeps a power observer alive even without active sessions when the
    /// power-reconnect auto-start is enabled.
    private func updatePowerReconnectMonitoring() {
        let required = settings.defaultSession.restartOnPowerReconnect && !isShutdown
        if required, powerReconnectToken == nil {
            lastOnExternalPower = powerStateProvider.currentPowerState().onExternalPower
            powerReconnectToken = powerStateProvider.addMonitoringObserver { [weak self] in
                self?.handlePowerSourceChange()
            }
        } else if !required, let token = powerReconnectToken {
            powerReconnectToken = nil
            lastOnExternalPower = nil
            powerStateProvider.removeMonitoringObserver(token)
        }
    }

    private func handlePowerSourceChange() {
        guard !isShutdown else { return }
        let wasOnExternalPower = lastOnExternalPower ?? powerState.onExternalPower
        powerState = powerStateProvider.currentPowerState()
        lastOnExternalPower = powerState.onExternalPower
        expireSessions(at: now())
        applySafetyPolicy()
        applyAssertions()
        deferScreenSaverIfEnabled()
        if settings.defaultSession.restartOnPowerReconnect,
           !wasOnExternalPower, powerState.onExternalPower,
           activeSessions.isEmpty {
            logger.notice("Power adapter reconnected; starting default session")
            _ = startDefaultSession()
        }
        if activeSessions.isEmpty {
            maintenanceTask?.cancel()
            maintenanceTask = nil
            stopPowerMonitoring()
        }
    }

    private func installSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        })

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemSleep()
            }
        })

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplaysDidSleep()
            }
        })

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplaysDidWake()
            }
        })

        let clockChange = Notification.Name("NSSystemClockDidChangeNotification")
        observers.append(NotificationCenter.default.addObserver(
            forName: clockChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDesiredState()
            }
        })
    }
}
