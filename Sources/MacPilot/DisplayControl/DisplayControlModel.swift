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
    private var sessionID: String?
    private var appliedSessionID: String?
    private var inhibitedSessionID: String?
    private var hasObservedDisconnection = false
    private var operationEpoch = UUID()
    private let showsConfirmation: Bool
    private let prepareVisibleOutputs: () -> Bool
    private let controlStateChanged: (Bool) -> Void
    private var confirmationPanel: NSPanel?

    init(client: (any DisplayRecoverySending)? = nil, monitor: UUSessionMonitor? = nil,
         showsConfirmation: Bool = true, prepareVisibleOutputs: (() -> Bool)? = nil,
         controlStateChanged: ((Bool) -> Void)? = nil,
         recoveryService: (any DisplayRecoveryRegistering)? = nil) {
        self.client = client ?? DisplayRecoveryClient()
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
                self.hasObservedDisconnection = true
                self.inhibitedSessionID = nil
            } else if observation.status == .connected, !self.hasObservedDisconnection {
                // Starting/restarting the GUI during an existing connection
                // must not undo startup recovery or a previous emergency release.
                self.inhibitedSessionID = id
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
        if snapshot == nil || holdsControl || hasRecoveryObligation || isBusy
            || isPreparingHelper || errorKey != nil || uuObservation.status != .disconnected {
            return .seconds(1)
        }
        return .seconds(15)
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
        hasObservedDisconnection = false
        if showsConfirmation { DisplayControlTermination.owner = self }
        syncMonitor()
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                do { try await Task.sleep(for: self.pollInterval) } catch { return }
            }
        }
    }

    func stop() {
        isRunning = false
        monitor.stop()
        pollTask?.cancel()
        pollTask = nil
        restore()
        // Recovery outlives GUI teardown: helper lease expiration also restores
        // if termination ends this asynchronous request before it is delivered.
    }

    func restoreBeforeTermination() async -> Bool {
        let wasRunning = isRunning
        isRunning = false
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
        guard !isPreparingHelper, !isBusy, !hasControl else { return }
        guard recoveryShortcutConflict?() != true else { errorKey = "displayRecoveryShortcutConflict"; return }
        isPreparingHelper = true
        defer { isPreparingHelper = false }
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
        let epoch = operationEpoch
        do {
            let response = try await client.send(.init(command: .status))
            if epoch == operationEpoch { apply(response) }
        }
        catch { errorKey = "displayHelperUnavailable" }
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
        // Emergency release cannot be rejected merely because a topology reply
        // or a confirmation changed the generation since the last poll.
        perform(.init(command: .restore, targetUUID: targetUUID), restoring: true)
    }

    func applyRemotePolicy() {
        guard canChange, uuObservation.status == .connected, let sessionID else {
            errorKey = "displayUURequired"
            return
        }
        guard settings.uuPolicy != .none else { return }
        appliedSessionID = sessionID
        inhibitedSessionID = nil
        let generation = snapshot?.generation
        switch settings.uuPolicy {
        case .none: break
        case .keepPhysical:
            guard !settings.targetUUID.isEmpty else { errorKey = "displaySelectTarget"; return }
            perform(.init(command: .keepOnly, targetUUID: settings.targetUUID, generation: generation,
                          remoteSessionID: sessionID, policy: .remotePhysical))
        case .virtualOnly, .addVirtual:
            guard settings.hasValidVirtualSize else { errorKey = "displayInvalidSize"; return }
            perform(.init(command: .prepareVirtual,
                          virtualSpec: .init(width: settings.virtualWidth, height: settings.virtualHeight, hiDPI: settings.hiDPI),
                          generation: generation, remoteSessionID: sessionID,
                          policy: settings.uuPolicy == .virtualOnly ? .remoteVirtualOnly : .remoteVirtualWithPhysical))
        }
    }

    func confirm() {
        guard !isBusy, snapshot?.confirmationDeadline != nil else { return }
        if isConfirmingVirtual {
            guard uuObservation.status == .connected, sessionID != nil else { restore(); return }
        }
        perform(.init(command: isConfirmingVirtual ? .confirmVirtual : .confirmChange,
                      generation: snapshot?.generation, remoteSessionID: sessionID, confirmed: true))
    }

    private func syncMonitor() {
        if isRunning && settings.uuPolicy != .none { monitor.start() }
        else {
            monitor.stop(); uuObservation = .init(status: .disconnected); sessionID = nil
            hasObservedDisconnection = false
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
                remoteSessionID: uuObservation.status == .connected ? sessionID : nil))
            guard isRunning, !Task.isCancelled, epoch == operationEpoch else { return }
            let hadControl = hasControl
            apply(response)
            if hadControl && response.state == .idle { inhibitedSessionID = sessionID }
            if !hasControl, uuObservation.status == .connected, let sessionID,
               sessionID != inhibitedSessionID, sessionID != appliedSessionID, settings.uuPolicy != .none {
                applyRemotePolicy()
            }
        } catch { errorKey = "displayHelperUnavailable" }
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
                self.errorKey = "displayHelperUnavailable"
            }
            self.isBusy = false
            // A command may acquire a lease while the idle loop is asleep.
            if self.isRunning { self.restartPolling() }
        }
    }

    private func apply(_ response: DisplayControlResponse) {
        let nextError = response.message.map { "displayError_" + $0 }
        if errorKey != nextError { errorKey = nextError }
        // Also clear an optimistic control mark when a rejected command returns
        // the same idle snapshot as before it was sent.
        controlStateChanged(![.idle, .unavailable].contains(response.state))
        guard snapshot != response else { return }
        snapshot = response
        if response.confirmationDeadline != nil { now = Date() }
        updateConfirmationPanel()
    }

    private func updateConfirmationPanel() {
        guard showsConfirmation else { return }
        guard snapshot?.confirmationDeadline != nil else {
            confirmationPanel?.close(); confirmationPanel = nil
            return
        }
        let target = isConfirmingVirtual ? snapshot?.virtualDisplayUUID : displays.first(where: \.isMain)?.uuid
        guard let display = displays.first(where: { $0.uuid == target }),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
              }) else { return } // Never put remote confirmation on an arbitrary physical screen.
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
}

@MainActor
enum DisplayControlTermination {
    static weak var owner: DisplayControlModel?
    static var isWaiting = false
    static var mayForceExit: Bool {
        !isWaiting && owner?.hasControl != true && owner?.isBusy != true
    }
}
