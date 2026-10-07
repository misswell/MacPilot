import Combine
import Foundation
import AppKit
import OSLog

@MainActor
final class AwakeSessionManager: ObservableObject, ManagedFeature {
    let identifier = "awake"
    var isRunning: Bool { !observers.isEmpty }
    func start() { activateFromConfiguration() }
    func stop() { deactivateFromConfiguration() }
    /// Upper bound on ended sessions kept for the UI's recent history.
    private static let maximumRetainedEndedSessions = 20
    /// Upper bound on concurrently active sessions. Every menu click starts a
    /// session and all of them are re-evaluated on each maintenance tick, so
    /// repeated clicks must not accumulate dozens of live sessions.
    private static let maximumActiveSessions = 8
    // Active sessions are intentionally in-memory. The Awake spec's startup
    // policy says manual sessions do not survive an app restart; wake and
    // clock-change notifications still re-evaluate sessions that remain live.
    @Published private(set) var sessions: [AwakeSession] = []
    @Published private(set) var isSystemAssertionActive = false
    @Published private(set) var isDisplayAssertionActive = false
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
    private let observers = ObserverBag()
    private var powerMonitoringToken: UUID?
    private var powerReconnectToken: UUID?
    private var lastOnExternalPower: Bool?
    private var sleepStartedAt: Date?
    private var isDisplayAsleep = false
    private var warnedBatteryThreshold = false
    private var isShutdown = false
    private let maintenanceInterval: TimeInterval
    /// Whether the aggregate closed-lid policy is currently requested, so the
    /// controller is only toggled on real transitions.
    private var closedLidSleepRequested = false
    private var isLidMonitoring = false
    /// Only wake the display on lid open when MacPilot was the one that slept
    /// it for this lid close.
    private var displayWasSleptByMacPilotForLidClose = false

    /// Called by `MacPilotModel` when the user-facing Awake preferences change.
    var persist: (() -> Void)?
    weak var profileStore: AwakeProfileStore?

    init(
        assertionController: any AwakeAssertionControlling = AwakeAssertionController(),
        powerStateProvider: any AwakePowerStateProviding = PowerStateProvider(),
        notifyBatteryWarning: @escaping (Int) -> Void = { AwakeNotifications.showBatteryWarning(threshold: $0) },
        now: @escaping () -> Date = { Date() },
        closedLidSleepController: (any ClosedLidSleepControlling)? = nil,
        lidStateMonitor: (any LidStateMonitoring)? = nil,
        displayStateProvider: any AwakeDisplayStateProviding = DisplayStateProvider(),
        sleepDisplay: @escaping @MainActor () -> Void = DisplayPower.sleepDisplay,
        wakeDisplay: @escaping () -> Void = DisplayPower.wakeDisplay,
        maintenanceInterval: TimeInterval = 60
    ) {
        self.maintenanceInterval = max(0.25, maintenanceInterval)
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
        // The system observers are installed by `applyLoadedSettings` once the
        // persisted master switch is known, not here: at construction the
        // settings are still `.standard`.
    }

    var activeSessions: [AwakeSession] {
        sessions.filter { $0.state == .active }
    }

    var activeSessionCount: Int { activeSessions.count }
    var isActive: Bool { !activeSessions.isEmpty }
    var hasManualSession: Bool { activeSessions.contains { $0.source == .manual } }
    /// 用户主动开始的会话（手动或来自方案）。方案启动会接管这些会话。
    var activeInteractiveSessions: [AwakeSession] {
        activeSessions.filter { $0.source.isInteractive }
    }
    var hasInteractiveSession: Bool { !activeInteractiveSessions.isEmpty }
    var isKeepingAwake: Bool { isSystemAssertionActive || isDisplayAssertionActive || isClosedLidSleepActive }

    var sharedPowerStateProvider: any AwakePowerStateProviding { powerStateProvider }

    /// Ask the privileged helper to register, if it is not registered yet.
    /// Never called at launch; only from the closed-lid UI or the enable flow.
    func prepareClosedLidService() async {
        guard let closedLidSleepController else { return }
        await closedLidSleepController.prepareIfNeeded()
        syncClosedLidServiceState()
        closedLidSleepController.reenableIfPending()
    }

    func openClosedLidServiceSettings() {
        closedLidSleepController?.openSystemSettings()
    }

    /// Re-read the privileged service status from the system.
    ///
    /// `ClosedLidSleepController.serviceState` is a snapshot taken when its
    /// helper was constructed, and registration is a system-level decision the
    /// user settles outside the app: enabling the daemon in System Settings →
    /// Login Items, or macOS finishing a registration that was still pending at
    /// launch. Without this refresh the Awake card keeps rendering the status it
    /// read once at startup — a stale "the background power service is
    /// unavailable in this build" banner that never clears, even though the
    /// service is registered and running.
    ///
    /// Approval also interrupts the enable itself, not just the banner: the
    /// controller bails out while the record sits in `.requiresApproval`, and
    /// nothing inside the process watches for the approval. `reenableIfPending`
    /// is what finishes the interrupted enable once the service turns up ready.
    func refreshClosedLidServiceState() {
        syncClosedLidServiceState()
        closedLidSleepController?.reenableIfPending()
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
        pruneExcessActiveSessions(keeping: session.id)
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

    /// Starts a session from a saved profile. The profile is a configuration
    /// template: its stored end condition and policy are applied verbatim, so
    /// the session behaves exactly like the setup captured at save time.
    /// The battery-protection and power-adapter options are global session
    /// options in `AwakeSettings`, so like the protection sheet's confirm
    /// path, applying a profile writes them back for every start path.
    @discardableResult
    func startProfileSession(
        from profile: AwakeSessionProfile,
        replacingActiveSessions: Bool = false
    ) -> UUID? {
        guard settings.isEnabled else { return nil }
        if replacingActiveSessions {
            let replacedIDs = activeInteractiveSessions.map(\.id)
            for id in replacedIDs { markSessionEnded(id) }
            if !replacedIDs.isEmpty {
                logger.notice("Switching profiles ended \(replacedIDs.count, privacy: .public) interactive session(s)")
            }
        }
        let configuration = profile.configuration
        let shouldRequestBatteryAuthorization =
            configuration.warnBeforeBatteryTermination
            && !settings.defaultSession.warnBeforeBatteryTermination
        updateSettings { settings in
            configuration.applyProtectionSettings(to: &settings)
        }
        if shouldRequestBatteryAuthorization {
            AwakeNotifications.requestAuthorization()
        }
        let id = startSession(
            source: .profile(name: profile.name),
            endCondition: configuration.endCondition,
            policy: configuration.policy
        )
        refreshPowerState()
        return id
    }

    /// Auto-starts the configured launch profile when the app starts. Only
    /// fills an idle state; returns nil (nothing started) when disabled, a
    /// session is already running, or the configured profile was deleted, so
    /// the caller can fall back to the default session.
    @discardableResult
    func startLaunchProfileSessionIfEnabled(from store: AwakeProfileStore) -> UUID? {
        guard settings.isEnabled, activeSessions.isEmpty else { return nil }
        let automaticProfiles = store.profiles.filter { $0.configuration.autoStartOnLaunch }
        if !automaticProfiles.isEmpty {
            var firstSessionID: UUID?
            for profile in automaticProfiles {
                if let date = profile.configuration.untilDate, date <= now() { continue }
                let id = store.launch(profile.id, in: self)
                if firstSessionID == nil { firstSessionID = id }
            }
            if let firstSessionID { return firstSessionID }
        }
        // 兼容旧版本保存的启动方案选择；新表单不再写入这个选择。
        guard settings.defaultSession.launchProfileEnabled else { return nil }
        guard let profileID = settings.defaultSession.launchProfileID,
              let profile = store.profile(id: profileID) else { return nil }
        logger.notice("Auto-starting launch profile: \(profile.name, privacy: .public)")
        return startProfileSession(from: profile)
    }

    /// Called once by `MacPilotModel` after the stored configuration loads.
    /// Auto-start only fills an idle state, so repeated calls are no-ops.
    @discardableResult
    func startDefaultSessionOnLaunchIfEnabled() -> UUID? {
        guard settings.isEnabled else { return nil }
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
        refreshClosedLidServiceState()
        guard settings.isEnabled, activeSessions.isEmpty else { return }
        if let profileStore {
            let automaticProfiles = profileStore.profiles.filter { $0.configuration.autoStartOnWake }
            for profile in automaticProfiles {
                if let date = profile.configuration.untilDate, date <= now() { continue }
                profileStore.launch(profile.id, in: self)
            }
        }
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

    /// Ends every session the user started on purpose (manual and profile
    /// sessions). Automatic trigger sessions keep running and re-evaluate on
    /// their own, matching how they behave everywhere else.
    func endAllInteractiveSessions() {
        let ids = activeInteractiveSessions.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { markSessionEnded(id) }
        refreshDesiredState()
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

    func applyLoadedSettings(_ newSettings: AwakeSettings, activate: Bool = true) {
        // 结束时间计算已统一为「使用计时器」：不再提供选择，旧配置里
        // 残留的「睡眠期间暂停计时」在加载时归一，所有会话都按墙钟计时。
        var newSettings = newSettings
        newSettings.defaultPolicy.endCalculation = .timer
        settings = newSettings
        if activate {
            activateFromConfiguration()
        } else {
            deactivateFromConfiguration()
        }
    }

    /// Starts the observers and power reconnect monitor needed by the stored
    /// Awake settings. This is separate from loading so the Home switch can
    /// keep the feature completely dormant until the user enables it.
    func activateFromConfiguration() {
        guard !isShutdown else { return }
        if settings.isEnabled {
            installSystemObservers()
        } else {
            removeSystemObservers()
        }
        powerState = powerStateProvider.currentPowerState()
        updatePowerReconnectMonitoring()
        refreshDesiredState()
    }

    /// Releases Awake's runtime assertions and observers while keeping the
    /// settings object reusable if the Home switch is turned on again.
    func deactivateFromConfiguration() {
        guard !isShutdown else { return }
        endAllSessions()
        removeSystemObservers()
        stopLidMonitoring()
        closedLidSleepController?.setEnabled(false)
        powerState = powerStateProvider.currentPowerState()
        updatePowerReconnectMonitoring()
        refreshDesiredState()
    }

    /// Master switch. Turning it off ends every session (so no power assertion is
    /// left held), removes the system observers and hands the closed-lid setting
    /// back; turning it on re-arms them.
    func setEnabled(_ enabled: Bool) {
        guard !isShutdown, settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            installSystemObservers()
            logger.notice("Awake enabled")
        } else {
            endAllSessions()
            removeSystemObservers()
            stopLidMonitoring()
            closedLidSleepController?.setEnabled(false)
            logger.notice("Awake disabled")
        }
        powerState = powerStateProvider.currentPowerState()
        updatePowerReconnectMonitoring()
        refreshDesiredState()
        persist?()
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
        removeSystemObservers()
        stopLidMonitoring()
        closedLidSleepController?.shutdown()
        syncClosedLidServiceState()
        if case .failure(let failure) = assertionController.releaseAll() {
            lastAssertionFailure = failure
        }
        syncAssertionState()
    }

    /// Removes every process-level observer this manager installed. Safe to call
    /// repeatedly, and paired with `installSystemObservers()`'s emptiness guard.
    private func removeSystemObservers() {
        observers.removeAll()
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

    /// Ends the oldest active sessions once the active set exceeds its bound,
    /// never the session that was just started.
    private func pruneExcessActiveSessions(keeping id: UUID) {
        let active = sessions.filter { $0.state == .active }
        guard active.count > Self.maximumActiveSessions else { return }
        let excess = active.count - Self.maximumActiveSessions
        for session in active.prefix(excess) where session.id != id {
            logger.notice("Ending excess active session \(session.id.uuidString, privacy: .public)")
            endSession(session.id)
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
        let desired = AwakePolicyEngine.desiredState(sessions: sessions, displayAsleep: isDisplayAsleep)
        if desiredAwakeState != desired {
            desiredAwakeState = desired
            logger.notice("Awake policy changed: system=\(desired.preventSystemSleep, privacy: .public), display=\(desired.preventDisplaySleep, privacy: .public), closedLid=\(desired.preventClosedLidSleep, privacy: .public)")
        }
        switch assertionController.apply(desired) {
        case .success:
            lastAssertionFailure = nil
        case .failure(let failure):
            lastAssertionFailure = failure
            logger.error("Assertion update failed: \(failure.localizedDescription, privacy: .public)")
        }
        syncAssertionState()
        applyClosedLidSleep(desired.preventClosedLidSleep)
    }

    private func syncAssertionState() {
        let systemActive = assertionController.isSystemAssertionActive
        let displayActive = assertionController.isDisplayAssertionActive
        if isSystemAssertionActive != systemActive { isSystemAssertionActive = systemActive }
        if isDisplayAssertionActive != displayActive { isDisplayAssertionActive = displayActive }
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
        guard !activeSessions.isEmpty || lastAssertionFailure != nil else {
            maintenanceTask = nil
            stopPowerMonitoring()
            return
        }
        if activeSessions.isEmpty { stopPowerMonitoring() } else { startPowerMonitoring() }

        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay: TimeInterval
                // Drop the strong reference before sleeping, particularly for
                // unlimited sessions whose maintenance task never expires.
                do {
                    guard let self else { return }
                    self.expireSessions(at: self.now())
                    self.applySafetyPolicy()
                    self.applyAssertions()
                    self.deferScreenSaverIfEnabled()

                    if self.activeSessions.isEmpty { self.stopPowerMonitoring() }
                    guard !self.activeSessions.isEmpty || self.lastAssertionFailure != nil else {
                        self.maintenanceTask = nil
                        return
                    }

                    let expirationDelay = self.activeSessions.compactMap(\.expectedEndAt).min()
                        .map { $0.timeIntervalSince(self.now()) } ?? self.maintenanceInterval
                    delay = min(max(expirationDelay, 0.25), self.maintenanceInterval)
                }
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
        scheduleMaintenance()
    }

    private func installSystemObservers() {
        // Idempotent: the master switch can re-arm the feature after it was
        // turned off, and the observers must not be installed twice.
        guard observers.isEmpty, !isShutdown else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.add(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }, center: workspaceCenter)

        observers.add(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemSleep()
            }
        }, center: workspaceCenter)

        observers.add(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplaysDidSleep()
            }
        }, center: workspaceCenter)

        observers.add(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplaysDidWake()
            }
        }, center: workspaceCenter)

        let clockChange = Notification.Name("NSSystemClockDidChangeNotification")
        observers.add(NotificationCenter.default.addObserver(
            forName: clockChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDesiredState()
            }
        }, center: .default)
    }
}
