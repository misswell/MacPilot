import AppKit
import Combine
import Foundation
import OSLog

struct TriggerRuntimeState: Equatable, Sendable {
    var conditionMatched = false
    var sessionActive = false
    var matchingSince: Date?
    var unmatchingSince: Date?
    var lastTransitionAt: Date?
}

@MainActor
final class AwakeTriggerEngine: ObservableObject {
    @Published private(set) var triggers: [AwakeTrigger] = []
    @Published private(set) var runtimeStates: [UUID: TriggerRuntimeState] = [:]
    @Published private(set) var systemState: AwakeTriggerSystemState

    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Trigger")
    private let sessionManager: AwakeSessionManager
    private let powerStateProvider: any AwakePowerStateProviding
    private let applicationStateProvider: any AwakeApplicationStateProviding
    private let processStateProvider: any AwakeProcessStateProviding
    private let displayStateProvider: any AwakeDisplayStateProviding
    private let now: () -> Date
    private var powerMonitoringToken: UUID?
    private var applicationMonitoring = false
    private var processMonitoring = false
    private var displayMonitoring = false
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isShutdown = false

    /// Called after a trigger definition changes so it is stored with the
    /// other MacPilot preferences.
    var persist: (() -> Void)?

    init(
        sessionManager: AwakeSessionManager,
        powerStateProvider: (any AwakePowerStateProviding)? = nil,
        applicationStateProvider: any AwakeApplicationStateProviding = ApplicationStateProvider(),
        processStateProvider: any AwakeProcessStateProviding = ProcessStateProvider(),
        displayStateProvider: any AwakeDisplayStateProviding = DisplayStateProvider(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.sessionManager = sessionManager
        self.powerStateProvider = powerStateProvider ?? sessionManager.sharedPowerStateProvider
        self.applicationStateProvider = applicationStateProvider
        self.processStateProvider = processStateProvider
        self.displayStateProvider = displayStateProvider
        self.now = now
        systemState = AwakeTriggerSystemState(
            application: applicationStateProvider.currentState,
            process: processStateProvider.currentState,
            power: self.powerStateProvider.currentPowerState(),
            display: displayStateProvider.currentState
        )
        installSystemObservers()
    }

    var activeTriggerCount: Int {
        runtimeStates.values.filter(\.sessionActive).count
    }

    func trigger(for id: UUID) -> AwakeTrigger? {
        triggers.first { $0.id == id }
    }

    func runtimeState(for id: UUID) -> TriggerRuntimeState {
        runtimeStates[id] ?? TriggerRuntimeState()
    }

    func applyLoadedTriggers(_ loadedTriggers: [AwakeTrigger]) {
        let oldIDs = Set(triggers.map(\.id))
        for id in oldIDs { endTriggerSession(id) }
        cancelAllPendingTasks()
        triggers = loadedTriggers
        runtimeStates = Dictionary(
            uniqueKeysWithValues: loadedTriggers.map { ($0.id, TriggerRuntimeState()) }
        )
        synchronizeMonitors()
        evaluateAll()
    }

    func addTrigger(_ trigger: AwakeTrigger) {
        guard !triggers.contains(where: { $0.id == trigger.id }) else { return }
        triggers.append(trigger)
        runtimeStates[trigger.id] = TriggerRuntimeState()
        persist?()
        synchronizeMonitors()
        evaluateTrigger(trigger.id)
    }

    func updateTrigger(_ trigger: AwakeTrigger) {
        guard let index = triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        let oldTrigger = triggers[index]
        triggers[index] = trigger
        let requiresSessionRefresh = oldTrigger.enabled != trigger.enabled
            || oldTrigger.conditions != trigger.conditions
            || oldTrigger.operatorType != trigger.operatorType
            || oldTrigger.sessionPolicy != trigger.sessionPolicy
            || oldTrigger.timingPolicy != trigger.timingPolicy
        if requiresSessionRefresh {
            cancelPendingTask(for: trigger.id)
            endTriggerSession(trigger.id)
            runtimeStates[trigger.id] = TriggerRuntimeState()
        }
        persist?()
        synchronizeMonitors()
        evaluateTrigger(trigger.id)
    }

    func setTriggerEnabled(_ id: UUID, enabled: Bool) {
        guard let index = triggers.firstIndex(where: { $0.id == id }), triggers[index].enabled != enabled else { return }
        triggers[index].enabled = enabled
        if !enabled { cancelPendingTask(for: id) }
        persist?()
        synchronizeMonitors()
        evaluateTrigger(id)
    }

    func removeTrigger(_ id: UUID) {
        guard triggers.contains(where: { $0.id == id }) else { return }
        cancelPendingTask(for: id)
        endTriggerSession(id)
        triggers.removeAll { $0.id == id }
        runtimeStates[id] = nil
        persist?()
        synchronizeMonitors()
    }

    func refreshAll() {
        guard !isShutdown else { return }
        if applicationMonitoring { applicationStateProvider.refreshNow() }
        if processMonitoring { processStateProvider.refreshNow() }
        if displayMonitoring { displayStateProvider.refreshNow() }
        updateSystemState()
        evaluateAll()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelAllPendingTasks()
        if applicationMonitoring { applicationStateProvider.stopMonitoring() }
        if processMonitoring { processStateProvider.stopMonitoring() }
        if displayMonitoring { displayStateProvider.stopMonitoring() }
        applicationMonitoring = false
        processMonitoring = false
        displayMonitoring = false
        if let token = powerMonitoringToken {
            powerMonitoringToken = nil
            powerStateProvider.removeMonitoringObserver(token)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func synchronizeMonitors() {
        guard !isShutdown else { return }
        let required = triggers
            .filter(\.enabled)
            .reduce(into: Set<AwakeTriggerMonitorKind>()) { result, trigger in
                result.formUnion(trigger.requiredMonitorKinds)
            }

        if required.contains(.application) {
            if !applicationMonitoring {
                applicationMonitoring = true
                applicationStateProvider.startMonitoring { [weak self] in
                    self?.handleApplicationStateChange()
                }
            }
        } else if applicationMonitoring {
            applicationMonitoring = false
            applicationStateProvider.stopMonitoring()
        }

        if required.contains(.process) {
            if !processMonitoring {
                processMonitoring = true
                processStateProvider.startMonitoring { [weak self] in
                    self?.handleProcessStateChange()
                }
            }
        } else if processMonitoring {
            processMonitoring = false
            processStateProvider.stopMonitoring()
        }

        if required.contains(.display) {
            if !displayMonitoring {
                displayMonitoring = true
                displayStateProvider.startMonitoring { [weak self] in
                    self?.handleDisplayStateChange()
                }
            }
        } else if displayMonitoring {
            displayMonitoring = false
            displayStateProvider.stopMonitoring()
        }

        if required.contains(.power) {
            if powerMonitoringToken == nil {
                powerMonitoringToken = powerStateProvider.addMonitoringObserver { [weak self] in
                    self?.handlePowerStateChange()
                }
            }
        } else if let token = powerMonitoringToken {
            powerMonitoringToken = nil
            powerStateProvider.removeMonitoringObserver(token)
        }

        updateSystemState()
    }

    private func evaluateAll() {
        for trigger in triggers {
            evaluateTrigger(trigger.id)
        }
    }

    private func evaluateTrigger(_ id: UUID) {
        guard let trigger = trigger(for: id) else { return }
        var runtime = runtimeStates[id] ?? TriggerRuntimeState()
        let matches = trigger.matches(systemState)
        runtime.conditionMatched = matches

        let sessionIsActive = sessionManager.activeSessions.contains {
            $0.source == .trigger(id)
        }
        if runtime.sessionActive && !sessionIsActive {
            runtime.sessionActive = false
            runtime.lastTransitionAt = now()
        }

        if matches {
            runtime.unmatchingSince = nil
            if !runtime.sessionActive && !sessionManager.safetyProtectionActive {
                if trigger.timingPolicy.activationDelay == 0 {
                    activateTrigger(id, trigger: trigger, runtime: &runtime)
                } else {
                    let currentDate = now()
                    if runtime.matchingSince == nil { runtime.matchingSince = currentDate }
                    let elapsed = currentDate.timeIntervalSince(runtime.matchingSince ?? currentDate)
                    if elapsed >= trigger.timingPolicy.activationDelay {
                        activateTrigger(id, trigger: trigger, runtime: &runtime)
                    } else {
                        scheduleEvaluation(
                            for: id,
                            after: trigger.timingPolicy.activationDelay - elapsed
                        )
                    }
                }
            }
        } else {
            runtime.matchingSince = nil
            if runtime.sessionActive {
                if trigger.timingPolicy.deactivationDelay == 0 {
                    deactivateTrigger(id, runtime: &runtime)
                } else {
                    let currentDate = now()
                    if runtime.unmatchingSince == nil { runtime.unmatchingSince = currentDate }
                    let elapsed = currentDate.timeIntervalSince(runtime.unmatchingSince ?? currentDate)
                    if elapsed >= trigger.timingPolicy.deactivationDelay {
                        deactivateTrigger(id, runtime: &runtime)
                    } else {
                        scheduleEvaluation(
                            for: id,
                            after: trigger.timingPolicy.deactivationDelay - elapsed
                        )
                    }
                }
            } else {
                cancelPendingTask(for: id)
            }
        }

        runtimeStates[id] = runtime
    }

    private func activateTrigger(
        _ id: UUID,
        trigger: AwakeTrigger,
        runtime: inout TriggerRuntimeState
    ) {
        cancelPendingTask(for: id)
        runtime.matchingSince = nil
        runtime.unmatchingSince = nil
        guard !runtime.sessionActive else { return }
        _ = sessionManager.startSession(
            source: .trigger(id),
            endCondition: .trigger(id),
            policy: trigger.sessionPolicy
        )
        runtime.sessionActive = true
        runtime.lastTransitionAt = now()
        logger.notice("Trigger activated: \(id.uuidString, privacy: .public)")
    }

    private func deactivateTrigger(_ id: UUID, runtime: inout TriggerRuntimeState) {
        cancelPendingTask(for: id)
        runtime.matchingSince = nil
        runtime.unmatchingSince = nil
        sessionManager.endSessions(source: .trigger(id))
        runtime.sessionActive = false
        runtime.lastTransitionAt = now()
        logger.notice("Trigger deactivated: \(id.uuidString, privacy: .public)")
    }

    private func endTriggerSession(_ id: UUID) {
        sessionManager.endSessions(source: .trigger(id))
        if var runtime = runtimeStates[id] {
            runtime.sessionActive = false
            runtime.matchingSince = nil
            runtime.unmatchingSince = nil
            runtimeStates[id] = runtime
        }
    }

    private func scheduleEvaluation(for id: UUID, after delay: TimeInterval) {
        guard pendingTasks[id] == nil else { return }
        let delay = max(0.01, delay)
        pendingTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingTasks[id] = nil
            self.evaluateTrigger(id)
        }
    }

    private func cancelPendingTask(for id: UUID) {
        pendingTasks[id]?.cancel()
        pendingTasks[id] = nil
    }

    private func cancelAllPendingTasks() {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks.removeAll()
    }

    private func updateSystemState() {
        systemState = AwakeTriggerSystemState(
            application: applicationStateProvider.currentState,
            process: processStateProvider.currentState,
            power: powerStateProvider.currentPowerState(),
            display: displayStateProvider.currentState
        )
    }

    private func handleApplicationStateChange() {
        guard !isShutdown else { return }
        updateSystemState()
        evaluateAll()
    }

    private func handleProcessStateChange() {
        guard !isShutdown else { return }
        updateSystemState()
        evaluateAll()
    }

    private func handleDisplayStateChange() {
        guard !isShutdown else { return }
        updateSystemState()
        evaluateAll()
    }

    private func handlePowerStateChange() {
        guard !isShutdown else { return }
        // Refreshing through the session manager first applies the battery
        // safety policy before a matching trigger can create a new session.
        sessionManager.refreshPowerState()
        updateSystemState()
        evaluateAll()
    }

    private func installSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        })

        for name in [
            Notification.Name("NSSystemClockDidChangeNotification"),
            Notification.Name("NSSystemTimeZoneDidChangeNotification")
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshAll() }
            })
        }
    }
}
