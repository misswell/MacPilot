import Combine
import Foundation
import MacPilotRemoteProtocol
import Network
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The single source of truth for the remote UI.
///
/// Views never touch `NWConnection`; they call this model, which owns discovery,
/// the fast-path race, reconnection and command execution.
@MainActor
final class RemoteAppModel: ObservableObject {
    struct PairingPrompt: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    @Published private(set) var connectionState: RemoteConnectionState = .idle
    @Published private(set) var discoveredMacs: [DiscoveredMac] = []
    /// Mirrored from `discovery` because a nested `ObservableObject` does not
    /// republish its changes through this model, so views reading it directly
    /// would never refresh.
    @Published private(set) var localNetworkDenied = false
    @Published private(set) var unrecognizedServiceCount = 0
    @Published private(set) var macState: MacRemoteState?
    @Published private(set) var latencyMs: Int?
    @Published private(set) var errorKey: String?
    @Published private(set) var infoKey: String?
    @Published private(set) var runningCommand: RemoteCommand?
    @Published var pairingPrompt: PairingPrompt?
    @Published private(set) var metrics = RemoteMetrics()

    let store: PairedMacStore
    let discovery = RemoteDiscoveryService()
    let connection = RemoteConnectionManager()

    private var activeMac: PairedMac?
    private var reconnectTask: Task<Void, Never>?
    private var fastPathTask: Task<Void, Never>?
    private var reconnectIndex = 0
    private var hasEverConnected = false
    private var didStart = false
    private var discoveryStartedAt: Date?

    /// Reconnect backoff while the app is in the foreground.
    private let reconnectDelays: [TimeInterval] = [0, 0.5, 1, 2, 5]
    /// The remembered address gets a short head start before Bonjour takes over.
    private let fastPathGrace: Duration = .milliseconds(500)

    init(store: PairedMacStore = PairedMacStore()) {
        self.store = store
        // Views observe this model, not the store it forwards to, and a nested
        // `ObservableObject` does not republish through its parent. Without this
        // bridge, deleting a device or setting a default would not refresh the
        // list until some unrelated change happened to redraw it.
        store.objectWillChange
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &storeChanges)
    }

    private var storeChanges = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func start() async {
        guard !didStart else { return }
        didStart = true
        wireCallbacks()
        discovery.onResultsChanged = { [weak self] macs in
            self?.handleDiscovery(macs)
        }
        discoveryStartedAt = Date()
        discovery.start()

        if let preferred = store.preferredMac {
            activeMac = preferred
            connectionState = .connecting
            startFastPath(preferred)
        } else {
            connectionState = .discovering
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !connectionState.isConnected, activeMac != nil || store.preferredMac != nil {
                attemptReconnect()
            }
        case .background:
            // No background sockets in V1; close cleanly so the Mac releases
            // the connection instead of waiting for a timeout.
            connection.disconnect(report: false)
            connectionState = hasEverConnected ? .reconnecting : .idle
        default:
            break
        }
    }

    private func wireCallbacks() {
        connection.onStateChange = { [weak self] state in
            guard let self else { return }
            // Only promote the visible state; failures and disconnects are
            // driven by the dedicated callbacks below.
            if state == .connected || state == .pairing || state == .authenticating {
                self.connectionState = state
            }
        }
        connection.onDeviceResolved = { [weak self] deviceID, name, endpoint in
            self?.handleConnected(deviceID: deviceID, name: name, endpoint: endpoint)
        }
        connection.onMacState = { [weak self] state in
            self?.macState = state
        }
        connection.onPairingPrompt = { [weak self] deviceID, name in
            self?.pairingPrompt = PairingPrompt(id: deviceID, name: name)
        }
        connection.onLatency = { [weak self] milliseconds in
            self?.latencyMs = milliseconds
            self?.metrics.commandRTTMs = milliseconds
        }
        connection.onFailure = { [weak self] error in
            guard let self else { return }
            self.errorKey = error.messageKey
            self.connectionState = .failed(self.text(error.messageKey))
        }
        connection.onDisconnected = { [weak self] in
            self?.handleDisconnected()
        }
        connection.onMetrics = { [weak self] connect, handshake in
            guard let self else { return }
            self.metrics.connectLatencyMs = connect
            self.metrics.handshakeLatencyMs = handshake
        }
    }

    // MARK: - Connection

    private func startFastPath(_ mac: PairedMac) {
        guard let endpoint = mac.rememberedEndpoint, let deviceID = mac.deviceID else { return }
        connect(to: endpoint, deviceID: deviceID, name: mac.name)
        fastPathTask?.cancel()
        fastPathTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.fastPathGrace ?? .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            // The remembered address did not come up in time; let Bonjour win.
            if !self.connection.isTransportReady {
                self.connection.disconnect(report: false)
                self.connectionState = .discovering
            }
        }
    }

    /// Re-adopts Macs whose long-term key is still in the Keychain but whose
    /// visible entry is missing, which happens after a reinstall or when an
    /// earlier build never wrote the record. The stored key is the real proof
    /// of pairing, so such a Mac must not be offered for pairing again — and it
    /// has to be re-adopted before the paired-target search below, otherwise it
    /// is never auto-connected either.
    private func adoptAlreadyPairedMacs(from macs: [DiscoveredMac]) {
        for mac in macs where !store.isPaired(id: mac.id)
            && RemoteKeychain.hasPairingKey(for: mac.id.uuidString) {
            store.ensurePaired(id: mac.id, name: mac.name)
        }
    }

    private func handleDiscovery(_ macs: [DiscoveredMac]) {
        discoveredMacs = macs
        localNetworkDenied = discovery.isPermissionDenied
        unrecognizedServiceCount = discovery.unrecognizedServiceCount
        adoptAlreadyPairedMacs(from: macs)
        if metrics.discoveryLatencyMs == nil, !macs.isEmpty, let started = discoveryStartedAt {
            metrics.discoveryLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
        }
        guard !connectionState.isConnected,
              connectionState != .pairing,
              connectionState != .authenticating else { return }

        // Prefer the default Mac, then any other paired Mac. Unpaired Macs are
        // only connected when the user explicitly asks to pair.
        let pairedTarget = macs.first { discovered in
            store.isPaired(id: discovered.id)
                && (store.preferredMacID == discovered.id.uuidString || store.preferredMacID == nil)
        } ?? macs.first { store.isPaired(id: $0.id) }

        guard let target = pairedTarget else {
            // Keep a real failure visible instead of silently flipping back.
            if case .failed = connectionState { return }
            connectionState = .discovering
            return
        }
        guard connection.connectingDeviceID != target.id else { return }
        activeMac = store.mac(id: target.id)
        connect(to: target.endpoint, deviceID: target.id, name: target.name)
    }

    private func connect(to endpoint: NWEndpoint, deviceID: UUID, name: String) {
        errorKey = nil
        connectionState = .connecting
        connection.connect(
            to: endpoint,
            deviceID: deviceID,
            name: name,
            clientID: store.clientID,
            clientName: store.clientName
        )
    }

    private func handleConnected(deviceID: UUID, name: String, endpoint: RemoteConnectionManager.ResolvedEndpoint) {
        hasEverConnected = true
        reconnectIndex = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionState = .connected
        errorKey = nil
        pairingPrompt = nil
        // Record the device before `markConnected`, which only updates an
        // existing entry. Pairing itself writes nothing here, so a Mac would
        // otherwise stay listed as new forever and never become the default.
        store.ensurePaired(id: deviceID, name: name)
        store.markConnected(
            id: deviceID,
            endpoint: NWEndpointSnapshot(
                host: endpoint.host,
                port: endpoint.port,
                serviceName: endpoint.serviceName
            ),
            name: name
        )
        activeMac = store.mac(id: deviceID)
    }

    private func handleDisconnected() {
        guard connectionState != .idle else { return }
        connectionState = hasEverConnected ? .reconnecting : .failed(text("errorNetwork"))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let index = min(reconnectIndex, reconnectDelays.count - 1)
        let delay = reconnectDelays[index]
        reconnectIndex += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard !connectionState.isConnected else { return }
        if !discovery.isBrowsing { discovery.start() }

        if let mac = activeMac ?? store.preferredMac, let deviceID = mac.deviceID {
            if let online = discovery.onlineEndpoint(for: deviceID) {
                connect(to: online.endpoint, deviceID: online.id, name: online.name)
                return
            }
            if let endpoint = mac.rememberedEndpoint {
                connect(to: endpoint, deviceID: deviceID, name: mac.name)
                return
            }
        }
        connectionState = .discovering
    }

    /// User driven connect from the Devices tab, used for first-time pairing.
    func pair(with mac: DiscoveredMac) {
        activeMac = store.mac(id: mac.id)
        errorKey = nil
        connect(to: mac.endpoint, deviceID: mac.id, name: mac.name)
    }

    func connect(to mac: PairedMac) {
        guard let deviceID = mac.deviceID else { return }
        activeMac = mac
        store.preferredMacID = mac.id
        if let online = discovery.onlineEndpoint(for: deviceID) {
            connect(to: online.endpoint, deviceID: deviceID, name: online.name)
        } else if let endpoint = mac.rememberedEndpoint {
            connect(to: endpoint, deviceID: deviceID, name: mac.name)
        } else {
            connectionState = .discovering
        }
    }

    func retry() {
        reconnectIndex = 0
        attemptReconnect()
    }

    // MARK: - Pairing

    func submitPairCode(_ code: String) {
        connection.submitPairCode(code)
    }

    func cancelPairing() {
        pairingPrompt = nil
        connection.cancelPairing()
        connectionState = .discovering
    }

    // MARK: - Devices

    var pairedMacs: [PairedMac] { store.pairedMacs }

    func isDefault(_ mac: PairedMac) -> Bool { store.preferredMacID == mac.id }

    func setDefault(_ mac: PairedMac) {
        store.preferredMacID = mac.id
    }

    func forget(_ mac: PairedMac) {
        let wasActive = activeMac?.id == mac.id
        store.remove(id: UUID(uuidString: mac.id) ?? UUID())
        if wasActive {
            connection.disconnect(report: false)
            activeMac = nil
            connectionState = .discovering
        }
    }

    func removeAllPairings() {
        connection.disconnect(report: false)
        store.removeAll()
        activeMac = nil
        macState = nil
        connectionState = .discovering
    }

    func status(for mac: PairedMac) -> MacPresence {
        guard let deviceID = mac.deviceID else { return .offline }
        if connectionState.isConnected, activeMac?.id == mac.id { return .connected }
        return discovery.onlineEndpoint(for: deviceID) != nil ? .online : .offline
    }

    enum MacPresence {
        case connected
        case online
        case offline
    }

    // MARK: - Commands

    func perform(_ command: RemoteCommand) async {
        guard connectionState.isConnected else {
            errorKey = "errorNotPaired"
            return
        }
        runningCommand = command
        defer { runningCommand = nil }

        let started = Date()
        do {
            let response = try await connection.send(command)
            metrics.executionLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
            if let state = response.state { macState = state }
            if response.success {
                infoKey = "actionDone"
                Haptics.success()
            } else if let code = response.error?.code {
                // Already-locked/already-unlocked are informational, not errors.
                switch code {
                case .alreadyLocked, .alreadyUnlocked:
                    infoKey = code.messageKey
                default:
                    errorKey = code.messageKey
                }
                Haptics.warning()
            }
        } catch let error as RemoteConnectionError {
            errorKey = error.messageKey
            Haptics.warning()
        } catch {
            errorKey = "errorNetwork"
            Haptics.warning()
        }
    }

    func beginCommand(_ command: RemoteCommand) {
        Haptics.impact()
    }

    func clearMessages() {
        errorKey = nil
        infoKey = nil
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        RemoteText.value(key, arguments)
    }
}

/// Small wrapper so the haptics stay out of the views and off the Mac target.
@MainActor
enum Haptics {
    static func impact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
