import Combine
import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network
import OSLog
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
    /// Which link carries the session and through which interface, e.g.
    /// "网络 · en0" or "蓝牙". Surfaced in Settings so the transport can be
    /// checked on a real network instead of inferred from logs.
    @Published private(set) var transportDescription = "—"
    /// True while the phone is actually advertising the BLE fallback, so the
    /// diagnostic can show that the fallback is armed rather than silently
    /// missing.
    @Published private(set) var bleFallbackAdvertising = false
    /// Last thing the Bluetooth fallback did, so a failed fallback is
    /// diagnosable from the phone instead of only from the Mac's log.
    @Published private(set) var lastBLEMessage: String?
    @Published private(set) var bleDiagnostics: [String] = []
    private let bleLogger = Logger(subsystem: "com.misswell.macpilot.remote", category: "BLE")

    let store: PairedMacStore
    let discovery = RemoteDiscoveryService()
    let connection = RemoteConnectionManager()
    /// Second link, used when there is no usable network to the Mac. It is not a
    /// replacement: the network is faster whenever it works, so BLE only takes
    /// over after the network has visibly failed.
    ///
    /// The phone is the peripheral: the Mac connects to us. That is the only BLE
    /// direction these two devices establish reliably, and it also means the
    /// phone decides whether the fallback exists at all.
    let ble = RemoteBLEPeripheral()

    private var activeMac: PairedMac?
    private var supervisorTask: Task<Void, Never>?
    /// Bumped on every start/stop so a finishing supervisor run cannot clear the
    /// handle of a newer one.
    private var supervisorGeneration = 0
    private var isForeground = true
    private var hasEverConnected = false
    private var didStart = false
    private var discoveryStartedAt: Date?
    /// A channel the Mac opened to us, waiting for the network to fail.
    private var pendingBLEChannel: CBL2CAPChannel?
    /// Consecutive network attempts that produced no link. Drives the switch to
    /// Bluetooth; reset whenever a session starts or the app comes forward.
    private var connectAttempt = 0

    /// Retry cadence while the app is in the foreground. The first entries are
    /// deliberately tight: the user has just opened the app and is watching.
    private let connectRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 1.5, 2, 3, 5]
    /// A stale remembered address can sit in `.waiting` indefinitely, so an
    /// attempt that produced no transport within this long is dropped and
    /// retried — by then Bonjour usually has a fresh endpoint.
    private let connectAttemptTimeout: TimeInterval = 4
    /// How many network attempts fail before the BLE channel is used instead.
    private let bleFallbackAfterAttempts = 2
    private var isBLEDiagnosticRun: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACPILOT_BLE_DIAGNOSTIC"] == "1"
        #else
        false
        #endif
    }

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

        ble.onLog = { [weak self] message in self?.bleLog(message) }
        ble.onChannel = { [weak self] channel in self?.adoptBLEChannel(channel) }

        if let preferred = store.preferredMac {
            activeMac = preferred
            connectionState = .connecting
        } else {
            connectionState = .discovering
        }
        startBLEFallback()
        startConnectSupervisor()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            // Back to the top of the preference order: the network may well be
            // back, and the tight retry cadence is what the user is watching.
            connectAttempt = 0
            // Re-arm with a fresh, tight retry cadence: opening the app is
            // exactly when the user expects an immediate connection.
            startBLEFallback()
            startConnectSupervisor()
        case .background:
            // No background sockets in V1; close cleanly so the Mac releases
            // the connection instead of waiting for a timeout.
            isForeground = false
            stopConnectSupervisor()
            stopBLEFallback()
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

    /// Owns connecting while the app is in the foreground.
    ///
    /// This is the only retry authority. It used to be two mechanisms racing
    /// each other: a 500ms "fast path" cancelled its own in-flight connection
    /// when the remembered address was slow (a cold link-local neighbour lookup
    /// easily exceeds that), and nothing restarted it — discovery only reports
    /// *changes*, so with the Mac already in its results no further callback
    /// arrived. The app then sat on "searching" indefinitely while a manual tap,
    /// which takes the direct path, connected immediately.
    private func startConnectSupervisor() {
        guard isForeground, supervisorTask == nil else { return }
        supervisorGeneration += 1
        let generation = supervisorGeneration
        supervisorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runConnectSupervisor()
            // Only clear our own handle: a stop()/start() pair may already have
            // installed a newer run.
            if self.supervisorGeneration == generation {
                self.supervisorTask = nil
            }
        }
    }

    private func stopConnectSupervisor() {
        supervisorGeneration += 1
        supervisorTask?.cancel()
        supervisorTask = nil
    }

    private func restartConnectSupervisor() {
        stopConnectSupervisor()
        startConnectSupervisor()
    }

    // MARK: - Bluetooth fallback

    /// Name to show while the Mac is still unidentified; the handshake replaces
    /// it with the real one.
    private var blePeerName: String {
        activeMac?.name ?? store.preferredMac?.name ?? "Mac"
    }

    /// Advertising only runs in the foreground, only while disconnected, and only
    /// once the network has visibly failed. The phone is the peripheral, so this
    /// is what decides whether the fallback exists at all — keeping it off until
    /// it is needed is what stops the fallback from costing battery during a
    /// healthy session.
    private func startBLEFallback() {
        guard isForeground, !connectionState.isConnected else { return }
        guard isBLEDiagnosticRun || connectAttempt >= bleFallbackAfterAttempts else { return }
        ble.start()
        bleFallbackAdvertising = ble.isAdvertising
    }

    private func stopBLEFallback() {
        ble.stop()
        bleFallbackAdvertising = false
        discardPendingBLEChannel()
    }

    /// The Mac opened a channel to us. Hold it rather than dialling immediately:
    /// the network is faster whenever it works, and displacing a good Wi-Fi link
    /// with the slower one would be a regression.
    private func adoptBLEChannel(_ channel: CBL2CAPChannel) {
        discardPendingBLEChannel()
        pendingBLEChannel = channel
        bleFallbackAdvertising = false
        bleLog("BLE channel delivered; waiting to adopt streams")
        // If the network has already been failing, use it now instead of waiting
        // for the supervisor's next tick.
        if !connectionState.isConnected, connectAttempt >= bleFallbackAfterAttempts {
            restartConnectSupervisor()
        }
    }

    private func discardPendingBLEChannel() {
        guard let channel = pendingBLEChannel else { return }
        pendingBLEChannel = nil
        // An unused channel would sit open on the Mac as a silent client until
        // its idle timeout reaped it.
        channel.inputStream.close()
        channel.outputStream.close()
    }

    private func bleLog(_ message: String) {
        #if DEBUG
        print("BLE diagnostic: \(message)")
        #endif
        lastBLEMessage = message
        bleLogger.info("\(message, privacy: .public)")
        bleDiagnostics.append("\(Date().ISO8601Format()) \(message)")
        if bleDiagnostics.count > 120 { bleDiagnostics.removeFirst(bleDiagnostics.count - 120) }
    }

    /// Records which link is carrying the session so Settings can show it.
    private func refreshTransportDescription() {
        guard connectionState.isConnected, let kind = connection.transportKind else {
            transportDescription = "—"
            return
        }
        let link = connection.linkDescription
        transportDescription = link.isEmpty || link == kind.displayName
            ? kind.displayName
            : "\(kind.displayName) · \(link)"
    }

    private func runConnectSupervisor() async {
        var attempt = 0
        var attemptStartedAt = Date()

        while !Task.isCancelled {
            if connectionState.isConnected { return }
            // Never interrupt a handshake: the user may be typing a pair code.
            if connectionState == .pairing || connectionState == .authenticating {
                attempt = 0
                await pause(1)
                continue
            }
            // A transport exists, so the handshake is already under way.
            if connection.isTransportReady {
                await pause(0.3)
                continue
            }
            // Guard on "an attempt exists", not on "an attempt with a device
            // ID". A BLE channel has no device ID until the Mac identifies
            // itself in the handshake, so guarding on the ID alone let this loop
            // dial the network 200ms after the BLE transport was created —
            // `connect` tears the previous transport down first, which killed
            // the fallback link before it could send its hello.
            if connection.hasActiveAttempt {
                if Date().timeIntervalSince(attemptStartedAt) < connectAttemptTimeout {
                    // Let the attempt finish rather than stomping on it: calling
                    // connect() again would cancel a connection that is about
                    // to succeed.
                    await pause(0.2)
                    continue
                }
                connection.disconnect(report: false)
            }
            if attempt > 0 {
                let delay = connectRetryDelays[min(attempt - 1, connectRetryDelays.count - 1)]
                await pause(delay)
                if Task.isCancelled { return }
            }
            attemptReconnect(attempt: connectAttempt)
            connectAttempt += 1
            attemptStartedAt = Date()
            attempt += 1
            await pause(0.2)
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
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
        // Any attempt in flight wins, including a BLE one that has no device ID
        // yet. The supervisor retries regardless, so declining here is safe.
        guard !connection.hasActiveAttempt else { return }
        activeMac = store.mac(id: target.id)
        connect(to: target.endpoint, deviceID: target.id, name: target.name)
    }

    private func connect(to endpoint: NWEndpoint, deviceID: UUID, name: String) {
        guard !isBLEDiagnosticRun else { return }
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
        connectAttempt = 0
        stopConnectSupervisor()
        // A working link makes the fallback redundant, and an idle channel left
        // open only costs both devices power. The exception is the fallback
        // itself: the L2CAP channel belongs to the peripheral, so stopping it
        // while it is the link carrying this session would close the stream we
        // just connected with.
        if connection.transportKind != .bluetooth {
            stopBLEFallback()
        }
        connectionState = .connected
        errorKey = nil
        pairingPrompt = nil
        refreshTransportDescription()
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
        refreshTransportDescription()
        connectionState = hasEverConnected ? .reconnecting : .failed(text("errorNetwork"))
        startBLEFallback()
        startConnectSupervisor()
    }

    private func attemptReconnect(attempt: Int) {
        guard !connectionState.isConnected else { return }
        if !discovery.isBrowsing { discovery.start() }

        // BLE is the fallback, not the default: it works without any shared
        // network, but it is slower to establish and costs both devices power to
        // hold open. So it only takes over once the network has visibly failed.
        if attempt >= bleFallbackAfterAttempts {
            // Make the phone reachable and let the Mac open the fallback link.
            // This is the only path that starts advertising, which keeps a
            // healthy Wi-Fi session free of a redundant BLE link.
            startBLEFallback()
        }
        if attempt >= bleFallbackAfterAttempts, let channel = pendingBLEChannel {
            pendingBLEChannel = nil
            errorKey = nil
            refreshTransportDescription()
            connectionState = .connecting
            let transport = L2CAPStreamTransport(channel: channel)
            let traceID = UUID().uuidString.prefix(8)
            transport.onDiagnostic = { [weak self] message in self?.bleLog("[\(traceID)] \(message)") }
            bleLog("BLE [\(traceID)] adopting channel psm=\(channel.psm)")
            connection.connect(
                using: transport,
                deviceID: nil,
                name: blePeerName,
                clientID: store.clientID,
                clientName: store.clientName
            )
            return
        }

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
        startConnectSupervisor()
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
        startConnectSupervisor()
    }

    func retry() {
        errorKey = nil
        // Drop whatever is in flight so the user sees a fresh attempt now
        // instead of waiting out the current one's timeout.
        connection.disconnect(report: false)
        stopConnectSupervisor()
        startConnectSupervisor()
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
            stopConnectSupervisor()
            stopBLEFallback()
            connection.disconnect(report: false)
            activeMac = nil
            connectionState = .discovering
        }
    }

    func removeAllPairings() {
        stopConnectSupervisor()
        stopBLEFallback()
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
