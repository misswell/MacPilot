import AppKit
import Combine
import Foundation
import MacPilotDisplayControlCore
import ServiceManagement
import SwiftUI

@MainActor
final class DisplayControlModel: ObservableObject, ManagedFeature {
    let identifier = "displayControl"
    @Published private(set) var isRunning = false
    @Published private(set) var settings = DisplayControlSettings()
    @Published private(set) var snapshot: DisplayControlResponse?
    @Published private(set) var errorKey: String?
    @Published private(set) var isBusy = false
    @Published private(set) var uuObservation = UUSessionObservation(status: .disconnected)
    @Published private(set) var now = Date()
    var language: AppLanguage = .system
    var persist: (() -> Void)?
    var recoveryShortcutConflict: (() -> Bool)?
    private let client: any DisplayRecoverySending
    private let monitor: UUSessionMonitor
    private let recoveryService: any DisplayRecoveryRegistering
    @Published private(set) var isPreparingHelper = false
    private var pollTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var serviceLifecycleTask: Task<Void, Never>?
    private var serviceLifecycleGeneration = UUID()
    private var resumeServiceRegistration = false
    private let managesServiceLifecycle: Bool
    private let hasInjectedClient: Bool
    private var sessionID: String?
    private var appliedSessionID: String?
    private var inhibitedSessionID: String?
    private var operationEpoch = UUID()
    private var consecutiveIdleFailures = 0
    private let showsConfirmation: Bool
    private let prepareVisibleOutputs: () -> Bool
    private let controlStateChanged: (Bool) -> Void
    private var confirmationPanel: NSPanel?
    private var guidancePanel: NSPanel?

    init(client: (any DisplayRecoverySending)? = nil, monitor: UUSessionMonitor? = nil,
         showsConfirmation: Bool = true, prepareVisibleOutputs: (() -> Bool)? = nil,
         controlStateChanged: ((Bool) -> Void)? = nil,
         recoveryService: (any DisplayRecoveryRegistering)? = nil) {
        self.client = client ?? DisplayRecoveryClient()
        self.hasInjectedClient = client != nil
        // Injected clients never acquire or remove the user's real service.
        self.managesServiceLifecycle = recoveryService != nil || (
            client == nil && !SmartCaptureToast.isTestHost && Bundle.main.bundleURL.pathExtension != "xctest"
        )
        self.recoveryService = recoveryService ?? DisplayRecoveryRegistration()
        self.monitor = monitor ?? UUSessionMonitor()
        self.showsConfirmation = showsConfirmation
        self.prepareVisibleOutputs = prepareVisibleOutputs ?? {
            if DisplayPower.isBlanked { DisplayPower.unblankDisplay() }
            return !DisplayPower.isBlanked
        }
        self.controlStateChanged = controlStateChanged ?? { DisplayPower.topologyControlIsActive = $0 }
        self.monitor.onChange = { [weak self] observation, id in
            guard let self else { return }
            let changed = self.uuObservation != observation || self.sessionID != id
            if self.uuObservation != observation { self.uuObservation = observation }
            self.sessionID = id
            if id == nil, observation.status == .disconnected {
                self.inhibitedSessionID = nil
            }
            if changed, self.isRunning { self.restartPolling() }
        }
    }

    var displays: [DisplayControlDisplay] { snapshot?.displays ?? [] }
    var helperReady: Bool { snapshot?.helperReady == true }
    var hasControl: Bool {
        guard let state = snapshot?.state else { return false }
        return ![.idle, .unavailable].contains(state)
    }
    // Owning an active configuration and owing recovery are different: a
    // recovery reply must never cause the GUI to renew a control lease.
    var holdsControl: Bool {
        guard let state = snapshot?.state else { return false }
        return [.active, .awaitingVirtualConfirmation, .awaitingKeepConfirmation].contains(state)
    }
    var hasRecoveryObligation: Bool {
        guard let state = snapshot?.state else { return false }
        return [.recovering, .recoveryRequired, .failed].contains(state)
    }
    /// Lease renewal and recovery stay responsive; an idle helper needs only
    /// occasional status checks. Commands and remote-session changes wake it.
    var pollInterval: Duration {
        if holdsControl || hasRecoveryObligation || isBusy
            || isPreparingHelper || uuObservation.status != .disconnected {
            return .seconds(1)
        }
        if consecutiveIdleFailures > 0 {
            return .seconds(min(60, 1 << min(consecutiveIdleFailures, 6)))
        }
        return snapshot == nil ? .seconds(1) : .seconds(15)
    }

    var remainingSeconds: Int {
        max(0, Int(ceil((snapshot?.confirmationDeadline ?? now).timeIntervalSince(now))))
    }
    var canChange: Bool {
        guard let snapshot else { return false }
        return isRunning && helperReady && !isBusy && !isPreparingHelper && snapshot.confirmationDeadline == nil
            && [.idle, .active].contains(snapshot.state)
    }
    var isConfirmingVirtual: Bool { snapshot?.state == .awaitingVirtualConfirmation }

    func t(_ key: String) -> String { AppText.value(key, language: language) }

    func applyLoadedSettings(_ value: DisplayControlSettings) { settings = value }
    func setEnabled(_ value: Bool) { settings.isEnabled = value; persist?() }

    func updateSettings(_ edit: (inout DisplayControlSettings) -> Void) {
        edit(&settings)
        persist?()
        // Changing a rule must not mutate the only output in the middle of a
        // connection. User can explicitly apply it after reviewing the new rule.
        if hasControl { restore() }
        syncMonitor()
    }

    func start() {
        guard !isRunning, settings.isEnabled else { return }
        isRunning = true
        serviceLifecycleGeneration = UUID()
        let generation = serviceLifecycleGeneration
        if serviceLifecycleTask != nil || resumeServiceRegistration {
            isBusy = true
            let pending = serviceLifecycleTask
            serviceLifecycleTask = Task { [weak self] in
                await pending?.value
                guard let self, self.isRunning,
                      generation == self.serviceLifecycleGeneration else { return }
                self.serviceLifecycleTask = nil
                self.isBusy = false
                guard self.activateServiceIfNeeded() else { return }
                self.beginRunning()
            }
            return
        }
        guard activateServiceIfNeeded() else { return }
        beginRunning()
    }

    /// Registration is persisted by launchd, while the in-memory resume flag
    /// is not. Re-enabling after a full app restart must restore it as well.
    private func activateServiceIfNeeded() -> Bool {
        guard managesServiceLifecycle else { return true }
        do {
            if recoveryService.status != .enabled, recoveryService.status != .requiresApproval {
                try recoveryService.register()
            }
            guard recoveryService.status == .enabled else {
                errorKey = "displayHelperApproval"
                return false
            }
            resumeServiceRegistration = false
            return true
        } catch {
            errorKey = "displayHelperInstallFailed"
            return false
        }
    }

    private func beginRunning() {
        isBusy = false
        if showsConfirmation { DisplayControlTermination.owner = self }
        syncMonitor()
        restartPolling()
    }

    private func restartPolling(immediately: Bool = true) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            if !immediately {
                guard let self else { return }
                do { try await Task.sleep(for: self.pollInterval) } catch { return }
            }
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                do { try await Task.sleep(for: self.pollInterval) } catch { return }
            }
        }
    }

    func stop() {
        isRunning = false
        serviceLifecycleGeneration = UUID()
        monitor.stop()
        pollTask?.cancel()
        pollTask = nil
        guard managesServiceLifecycle else {
            if hasInjectedClient { restore() }
            return
        }
        inhibitedSessionID = sessionID
        operationEpoch = UUID()
        operationTask?.cancel()
        operationTask = nil
        isBusy = false
        confirmationPanel?.close()
        confirmationPanel = nil
        guidancePanel?.close()
        guidancePanel = nil
        let pending = serviceLifecycleTask
        let generation = serviceLifecycleGeneration
        serviceLifecycleTask = Task { [weak self] in
            await pending?.value
            guard let self else { return }
            await self.releaseRecoveryService()
            if generation == self.serviceLifecycleGeneration, !self.isRunning {
                self.serviceLifecycleTask = nil
            }
        }
    }

    func removeUnusedServiceRegistration() {
        guard managesServiceLifecycle, !isRunning else { return }
        stop()
    }

    var isServiceCleanupPending: Bool { serviceLifecycleTask != nil }

    /// Finish recovery before removing launchd's registration. An unsuccessful
    /// recovery deliberately keeps the helper alive as a safety obligation.
    private func releaseRecoveryService() async {
        guard recoveryService.status == .enabled || recoveryService.status == .requiresApproval else {
            if !isRunning { snapshot = nil }
            return
        }
        resumeServiceRegistration = true
        if recoveryService.status == .enabled {
            var restored = false
            for attempt in 0..<5 {
                do {
                    let response = try await client.send(.init(command: attempt == 0 ? .restore : .status))
                    apply(response)
                    if response.state == .idle { restored = true; break }
                } catch { recordUnavailable() }
                if attempt < 4 { try? await Task.sleep(for: .seconds(1)) }
            }
            guard restored else { return }
        }
        do {
            try await recoveryService.unregister()
            if !isRunning { snapshot = nil }
        } catch {
            if errorKey != "displayHelperUnavailable" { errorKey = "displayHelperUnavailable" }
        }
    }

    func restoreBeforeTermination() async -> Bool {
        let wasRunning = isRunning
        isRunning = false
        serviceLifecycleGeneration = UUID()
        monitor.stop()
        pollTask?.cancel()
        pollTask = nil
        inhibitedSessionID = sessionID
        operationEpoch = UUID()
        operationTask?.cancel()
        operationTask = nil
        isBusy = false
        confirmationPanel?.close()
        confirmationPanel = nil
        guidancePanel?.close()
        guidancePanel = nil
        if managesServiceLifecycle {
            await serviceLifecycleTask?.value
            serviceLifecycleTask = nil
            if recoveryService.status != .enabled, !hasControl { return true }
        }
        for attempt in 0..<5 {
            do {
                let response = try await client.send(.init(command: attempt == 0 ? .restore : .status))
                apply(response)
                if response.state == .idle { return true }
            } catch { errorKey = "displayHelperUnavailable" }
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
        if wasRunning { start() }
        return false
    }

    func prepareHelper() {
        Task { await prepareHelperAndRefresh() }
    }

    func prepareHelperAndRefresh() async {
        guard !isPreparingHelper, !isBusy, !hasControl, serviceLifecycleTask == nil else { return }
        guard recoveryShortcutConflict?() != true else { errorKey = "displayRecoveryShortcutConflict"; return }
        isPreparingHelper = true
        pollTask?.cancel()
        pollTask = nil
        defer {
            isPreparingHelper = false
            if isRunning, !isBusy { restartPolling(immediately: false) }
        }
        do {
            if recoveryService.status == .enabled {
                do {
                    // An enabled registration can still point at an executable
                    // removed by an update. Only a live reply proves it works.
                    let response = try await client.send(.init(command: .status))
                    apply(response)
                    return
                } catch {
                    // An in-flight poll can reveal that this helper owns pending
                    // recovery. Do not cycle it once control has become active.
                    guard !hasControl else { return }
                    try await recoveryService.unregister()
                }
            }
            if recoveryService.status != .requiresApproval {
                try recoveryService.register()
            }
            guard recoveryService.status == .enabled else {
                errorKey = "displayHelperApproval"
                return
            }
            await refresh()
        } catch { errorKey = "displayHelperInstallFailed" }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func refresh() async {
        if isRunning {
            pollTask?.cancel()
            pollTask = nil
        }
        let epoch = operationEpoch
        do {
            let response = try await client.send(.init(command: .status))
            if epoch == operationEpoch, !Task.isCancelled { apply(response) }
        }
        catch {
            guard epoch == operationEpoch, !Task.isCancelled else { return }
            recordUnavailable()
        }
        guard epoch == operationEpoch, !Task.isCancelled else { return }
        if isRunning, !isPreparingHelper, !isBusy { restartPolling(immediately: false) }
    }

    func disable(_ display: DisplayControlDisplay) {
        guard canChange else { return }
        perform(.init(command: .disable, targetUUID: display.uuid, generation: snapshot?.generation, policy: .localPhysical))
    }

    func keepOnly(_ display: DisplayControlDisplay) {
        guard canChange, !display.isVirtual else { return }
        perform(.init(command: .keepOnly, targetUUID: display.uuid, generation: snapshot?.generation, policy: .localPhysical))
    }

    func restore(targetUUID: String? = nil) {
        inhibitedSessionID = sessionID
        appliedSessionID = nil
        // Supersede UI callbacks; helper also fences stale commands itself.
        operationEpoch = UUID()
        operationTask?.cancel()
        operationTask = nil
        confirmationPanel?.close()
        confirmationPanel = nil
        guidancePanel?.close()
        guidancePanel = nil
        // Emergency release cannot be rejected merely because a topology reply
        // or a confirmation changed the generation since the last poll.
        perform(.init(command: .restore, targetUUID: targetUUID), restoring: true)
    }

    /// Applies the UU rule for the current connection.
    ///
    /// `userInitiated` is true only for the button in the settings page. That
    /// explicit request is the one thing allowed to clear the per-session
    /// override left by a confirmation timeout or an emergency release; the
    /// automatic rule must never clear it and undo the user's restored desktop.
    func applyRemotePolicy(userInitiated: Bool = false) {
        guard canChange, uuObservation.status == .connected, let sessionID else {
            errorKey = "displayUURequired"
            DiagnosticLog.write("DisplayControl",
                "remote policy ignored reason=noUUState state=\(snapshot?.state.rawValue ?? "none") uu=\(uuObservation.status.rawValue)")
            return
        }
        guard let request = Self.remotePolicyRequest(
            settings: settings,
            sessionID: sessionID,
            generation: snapshot?.generation,
            userInitiated: userInitiated
        ) else {
            errorKey = settings.uuPolicy == .keepPhysical ? "displaySelectTarget" : "displayInvalidSize"
            return
        }
        appliedSessionID = sessionID
        inhibitedSessionID = nil
        DiagnosticLog.write("DisplayControl",
            "remote policy apply policy=\(settings.uuPolicy.rawValue) userInitiated=\(userInitiated) session=\(sessionID.prefix(8))")
        perform(request)
    }

    /// Builds the helper request for the UU rule.
    ///
    /// A pure seam so the automatic and the explicit paths can be proven to
    /// differ in exactly one field: `confirmed`, which the helper treats as
    /// permission to clear the per-session override.
    static func remotePolicyRequest(
        settings: DisplayControlSettings,
        sessionID: String,
        generation: UUID?,
        userInitiated: Bool
    ) -> DisplayControlRequest? {
        switch settings.uuPolicy {
        case .none:
            return nil
        case .keepPhysical:
            guard !settings.targetUUID.isEmpty else { return nil }
            return .init(command: .keepOnly, targetUUID: settings.targetUUID, generation: generation,
                         remoteSessionID: sessionID, confirmed: userInitiated, policy: .remotePhysical)
        case .virtualOnly, .addVirtual:
            guard settings.hasValidVirtualSize else { return nil }
            return .init(command: .prepareVirtual,
                         virtualSpec: .init(width: settings.virtualWidth, height: settings.virtualHeight, hiDPI: settings.hiDPI),
                         generation: generation, remoteSessionID: sessionID, confirmed: userInitiated,
                         policy: settings.uuPolicy == .virtualOnly ? .remoteVirtualOnly : .remoteVirtualWithPhysical)
        }
    }

    func confirm() {
        guard !isBusy, snapshot?.confirmationDeadline != nil else { return }
        if isConfirmingVirtual {
            guard uuObservation.status == .connected, sessionID != nil else { restore(); return }
        }
        perform(.init(command: isConfirmingVirtual ? .confirmVirtual : .confirmChange,
                      generation: snapshot?.generation, remoteSessionID: snapshot?.policy == .localPhysical ? nil : sessionID, confirmed: true))
    }

    private func syncMonitor() {
        if isRunning && settings.uuPolicy != .none { monitor.start() }
        else {
            monitor.stop(); uuObservation = .init(status: .disconnected); sessionID = nil
        }
    }

    private func poll() async {
        if snapshot?.confirmationDeadline != nil { now = Date() }
        guard !isBusy, !isPreparingHelper else { return }
        let epoch = operationEpoch
        do {
            let command: DisplayControlCommand
            if holdsControl {
                command = .heartbeat
            } else if hasRecoveryObligation {
                // Keep releasing the old transaction, including after an XPC
                // interruption. Do not automatically reapply this UU session.
                inhibitedSessionID = sessionID
                appliedSessionID = nil
                command = .restore
            } else {
                command = .status
            }
            let response = try await client.send(.init(command: command, generation: snapshot?.generation,
                remoteSessionID: command == .restore || snapshot?.policy == .localPhysical ? nil : (uuObservation.status == .connected ? sessionID : nil)))
            guard isRunning, !Task.isCancelled, epoch == operationEpoch else { return }
            let hadControl = hasControl
            apply(response)
            if hadControl && response.state == .idle { inhibitedSessionID = sessionID }
            if !hasControl, uuObservation.status == .connected, let sessionID,
               sessionID != inhibitedSessionID, sessionID != appliedSessionID, settings.uuPolicy != .none {
                applyRemotePolicy()
            }
        } catch {
            guard isRunning, !Task.isCancelled, epoch == operationEpoch else { return }
            recordUnavailable()
        }
    }

    private func recordUnavailable() {
        // Keep a pending/recovering helper transaction visible while transport
        // reconnects. The helper remains responsible for hardware recovery.
        if let state = snapshot?.state, [.managing, .recovering, .recoveryRequired].contains(state) {
            return
        }
        consecutiveIdleFailures = min(consecutiveIdleFailures + 1, 6)
        if errorKey != "displayHelperUnavailable" { errorKey = "displayHelperUnavailable" }
    }

    private func perform(_ request: DisplayControlRequest, restoring: Bool = false) {
        guard restoring || !isBusy else { return }
        guard restoring || prepareVisibleOutputs() else { errorKey = "displayError_recoveryIncomplete"; return }
        isBusy = true
        errorKey = nil
        operationEpoch = UUID()
        let token = operationEpoch
        if !restoring { controlStateChanged(true) }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.client.send(request)
                guard token == self.operationEpoch, !Task.isCancelled else { return }
                self.apply(response)
            } catch {
                guard token == self.operationEpoch, !Task.isCancelled else { return }
                if (error as? DisplayRecoveryClientError) == .timeout {
                    // A timed-out caller does not own cancellation of a helper
                    // transaction. Preserve our obligation until status resolves it.
                    if let response = try? await self.client.send(.init(command: .status)),
                       token == self.operationEpoch, !Task.isCancelled { self.apply(response) }
                } else { self.recordUnavailable() }
            }
            self.isBusy = false
            // A command may acquire a lease while the idle loop is asleep.
            if self.isRunning { self.restartPolling() }
        }
    }

    private func apply(_ response: DisplayControlResponse) {
        consecutiveIdleFailures = 0
        let nextError = response.message.map { "displayError_" + $0 }
        if errorKey != nextError { errorKey = nextError }
        // The helper is the only place the transaction state exists, so the
        // diagnostics file is the only way to explain a later "nothing happened"
        // report. Log transitions only, never every poll.
        if snapshot?.state != response.state || snapshot?.message != response.message {
            DiagnosticLog.write("DisplayControl",
                "state=\(response.state.rawValue) message=\(response.message ?? "none") uu=\(uuObservation.status.rawValue)"
                    + " session=\(sessionID.map { String($0.prefix(8)) } ?? "none")"
                    + " physical=\(response.displays.filter { !$0.isVirtual && $0.isUsable }.count)"
                    + " virtual=\(response.displays.filter { $0.isVirtual && $0.isUsable }.count)")
        }
        // Also clear an optimistic control mark when a rejected command returns
        // the same idle snapshot as before it was sent.
        controlStateChanged(![.idle, .unavailable].contains(response.state))
        guard snapshot != response else {
            updateTransientPanels()
            return
        }
        snapshot = response
        if response.confirmationDeadline != nil { now = Date() }
        updateTransientPanels()
    }

    private func updateTransientPanels() {
        guard showsConfirmation else { return }
        updateConfirmationPanel()
        updateGuidancePanel()
    }

    private func updateConfirmationPanel() {
        guard snapshot?.confirmationDeadline != nil else {
            confirmationPanel?.close(); confirmationPanel = nil
            return
        }
        let target = isConfirmingVirtual ? snapshot?.virtualDisplayUUID : displays.first(where: \.isMain)?.uuid
        guard let display = displays.first(where: { $0.uuid == target }),
              let screen = screen(for: display) else { return } // Never put remote confirmation on an arbitrary physical screen.
        if confirmationPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 220),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = t("displayRestoreTitle")
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: DisplayControlConfirmationView(control: self))
            confirmationPanel = panel
        }
        let frame = screen.visibleFrame
        confirmationPanel?.setFrameOrigin(NSPoint(x: frame.midX - 235, y: frame.midY - 110))
        confirmationPanel?.orderFrontRegardless()
    }

    /// The confirmation itself has to live on the virtual display, but until UU
    /// is switched to that display the user cannot see it — so the current
    /// physical screen gets a non-interactive note with the exact steps. This is
    /// guidance only: it can never confirm on the user's behalf.
    private func updateGuidancePanel() {
        guard snapshot?.state == .awaitingVirtualConfirmation else {
            guidancePanel?.close(); guidancePanel = nil
            return
        }
        if guidancePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 168),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = t("displayGuidanceTitle")
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: DisplayControlGuidanceView(control: self))
            guidancePanel = panel
        }
        if let screen = currentPhysicalScreen {
            let frame = screen.visibleFrame
            guidancePanel?.setFrameOrigin(NSPoint(x: frame.midX - 235, y: frame.midY + 150))
        }
        guidancePanel?.orderFrontRegardless()
    }

    private func screen(for display: DisplayControlDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
    }

    /// The screen the user is actually looking at: the virtual display only
    /// becomes main after the confirmation.
    private var currentPhysicalScreen: NSScreen? {
        let physical = displays.first(where: { $0.isMain && !$0.isVirtual })
            ?? displays.first(where: { !$0.isVirtual && $0.isUsable })
        return physical.flatMap(screen(for:)) ?? NSScreen.main
    }
}

@MainActor
enum DisplayControlTermination {
    static weak var owner: DisplayControlModel?
    static var isWaiting = false
    static var mayForceExit: Bool {
        !isWaiting && owner?.hasControl != true && owner?.isBusy != true
    }
}
