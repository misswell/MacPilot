import Combine
import Foundation
import AppKit
import OSLog

@MainActor
final class AwakeSessionManager: ObservableObject {
    // Active sessions are intentionally in-memory. The Awake spec's startup
    // policy says manual sessions do not survive an app restart; wake and
    // clock-change notifications still re-evaluate sessions that remain live.
    @Published private(set) var sessions: [AwakeSession] = []
    @Published private(set) var desiredAwakeState = DesiredAwakeState.inactive
    @Published private(set) var powerState = PowerState.unknown
    @Published private(set) var safetyProtectionActive = false
    @Published private(set) var lastAssertionFailure: AwakeAssertionFailure?
    @Published private(set) var settings = AwakeSettings.standard

    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Session")
    private let assertionController: any AwakeAssertionControlling
    private let powerStateProvider: any AwakePowerStateProviding
    private let now: () -> Date
    private var maintenanceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var powerMonitoringToken: UUID?
    private var isShutdown = false

    /// Called by `MacPilotModel` when the user-facing Awake preferences change.
    var persist: (() -> Void)?

    init(
        assertionController: any AwakeAssertionControlling = AwakeAssertionController(),
        powerStateProvider: any AwakePowerStateProviding = PowerStateProvider(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.assertionController = assertionController
        self.powerStateProvider = powerStateProvider
        self.now = now
        powerState = powerStateProvider.currentPowerState()
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
        refreshPowerState()
    }

    func applyLoadedSettings(_ newSettings: AwakeSettings) {
        settings = newSettings
        powerState = powerStateProvider.currentPowerState()
        refreshDesiredState()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        maintenanceTask?.cancel()
        maintenanceTask = nil
        stopPowerMonitoring()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if case .failure(let failure) = assertionController.releaseAll() {
            lastAssertionFailure = failure
        }
    }

    private func markSessionEnded(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].state == .active else { return }
        sessions[index].state = .ended
        logger.notice("Session ended: \(id.uuidString, privacy: .public)")
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
        guard safetyProtectionActive else { return }
        let activeIDs = activeSessions.map(\.id)
        for id in activeIDs { markSessionEnded(id) }
        if !activeIDs.isEmpty || !wasActive {
            logger.notice("Low-battery safety policy ended \(activeIDs.count, privacy: .public) session(s)")
        }
    }

    private var isBelowBatteryThreshold: Bool {
        guard settings.safetyPolicy.lowBatteryProtectionEnabled,
              let batteryLevel = powerState.batteryLevel else { return false }
        return batteryLevel < Double(settings.safetyPolicy.minimumBatteryLevel)
    }

    private func applyAssertions() {
        let active = activeSessions
        let desired = DesiredAwakeState(
            preventSystemSleep: active.contains { $0.policy.preventSystemSleep },
            preventDisplaySleep: active.contains { $0.policy.preventDisplaySleep },
            preventClosedLidSleep: active.contains { $0.policy.preventClosedLidSleep }
        )
        desiredAwakeState = desired
        switch assertionController.apply(desired) {
        case .success:
            lastAssertionFailure = nil
        case .failure(let failure):
            lastAssertionFailure = failure
            logger.error("Assertion update failed: \(failure.localizedDescription, privacy: .public)")
        }
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

    private func handlePowerSourceChange() {
        guard !isShutdown, isActive else { return }
        powerState = powerStateProvider.currentPowerState()
        expireSessions(at: now())
        applySafetyPolicy()
        applyAssertions()
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
                self?.refreshPowerState()
            }
        })

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDesiredState()
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
