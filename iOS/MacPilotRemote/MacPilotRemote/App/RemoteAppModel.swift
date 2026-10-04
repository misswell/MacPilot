import CoreHaptics
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
/// the connection race, reconnection and command execution.
///
/// Every reachable path to the Mac is dialled at the same time and the first one
/// to finish authenticating becomes the session. Higher-priority paths continue
/// racing and replace it only after completing their own authentication.
@MainActor
final class RemoteAppModel: ObservableObject {
    static let handshakeRetryTimeout: TimeInterval = 15
    static let dialRetryTimeout: TimeInterval = 4

    static func shouldRetryHandshake(isTransportReady: Bool, startedAt: Date, now: Date) -> Bool {
        isTransportReady && now.timeIntervalSince(startedAt) >= handshakeRetryTimeout
    }

    static func shouldRetryDial(isTransportReady: Bool, startedAt: Date, now: Date) -> Bool {
        !isTransportReady && now.timeIntervalSince(startedAt) >= dialRetryTimeout
    }

    /// A disconnect must replace the current supervisor even when its task is
    /// still winding down. Otherwise the stale task handle can make
    /// `startConnectSupervisor()` return without installing a new retry loop.
    static func shouldRestartSupervisorAfterDisconnect(
        isForeground: Bool,
        hasPairingTarget: Bool
    ) -> Bool {
        isForeground && !hasPairingTarget
    }

    struct PairingPrompt: Identifiable, Equatable {
        let id = UUID()
        let name: String
    }

    /// One of the ways the phone can reach the Mac.
    ///
    /// LAN and AWDL use interface-bound Bonjour results (plus remembered addresses).
    /// Bonjour/remembered remain labels for the single first-pairing attempt.
    enum RacePath: String, Equatable {
        /// The `_macpilot._tcp` result Bonjour is advertising right now.
        case bonjour
        case localNetwork
        case awdl
        /// The host and port that worked last time.
        case remembered
        /// An L2CAP channel the Mac opened to this phone.
        case bluetooth

        /// The Settings row label for this path, routed through `RemoteText` so
        /// the diagnostics follow the app language like everything else.
        var textKey: String {
            switch self {
            case .localNetwork: "connectionMethodLocalNetwork"
            case .awdl: "connectionMethodAwdl"
            case .bonjour: "racePathBonjour"
            case .remembered: "racePathRemembered"
            case .bluetooth: "racePathBluetooth"
            }
        }
    }

    /// A dial in flight.
    ///
    /// Each candidate is a complete `RemoteConnectionManager` — transport,
    /// framing, handshake and session — so the winner can be promoted without
    /// replaying anything on the wire.
    private struct Candidate {
        let path: RacePath
        let manager: RemoteConnectionManager
        let method: RemoteConnectionMethod
        let startedAt = Date()
    }

    /// The newest level the user asked for. Held rather than sent immediately
    /// because a drag emits updates faster than the link can answer them.
    private struct PendingLevel {
        let kind: RemoteLevelKind
        let value: Double
        let muted: Bool?
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
    /// The Mac's Dock groups, when it advertises the capability. `nil` until
    /// the first fetch answers, and cleared whenever the connection resets.
    @Published private(set) var dockGroupsSnapshot: RemoteDockGroupsSnapshot?
    /// The group (or single member) a launch is currently in flight for, so
    /// rows show progress instead of looking dead.
    @Published private(set) var launchingDockGroupID: String?
    @Published private(set) var launchingDockAppID: UUID?
    /// Members the Mac could not launch in the last group launch, listed in
    /// the info banner.
    @Published private(set) var dockGroupsMissingApps: [String] = []
    @Published var pairingPrompt: PairingPrompt?
    @Published private(set) var metrics = RemoteMetrics()
    /// Which link carries the session and through which interface, e.g.
    /// "网络 · en0" or "蓝牙". Surfaced in Settings so the transport can be
    /// checked on a real network instead of inferred from logs.
    @Published private(set) var transportDescription = "—"
    /// True while the phone is actually advertising its Bluetooth channel, so the
    /// diagnostic can show that the path is armed rather than silently missing.
    @Published private(set) var bleFallbackAdvertising = false
    /// Which paths the current race is dialling, e.g. `["Bonjour", "地址直连",
    /// "蓝牙"]`. Surfaced in Settings so "all three at once" is visible instead
    /// of having to be inferred from which one happened to win.
    @Published private(set) var racingPaths: [RacePath] = []
    /// Last thing Bluetooth did, so a failed Bluetooth dial is diagnosable from
    /// the phone instead of only from the Mac's log.
    @Published private(set) var lastBLEMessage: String?
    /// Every link event, Bluetooth and network alike, in the order it happened.
    /// A race is only debuggable if the losing paths leave a trace too.
    @Published private(set) var linkDiagnostics: [String] = []
    private let bleLogger = Logger(subsystem: "com.misswell.macpilot.remote", category: "BLE")

    let store: PairedMacStore
    let controlPreferences = RemoteControlPreferences()
    let discovery = RemoteDiscoveryService()
    /// The link carrying the session. A race promotes its winner here, so this
    /// is replaced rather than reused; higher-ranked candidates keep running.
    private(set) var connection = RemoteConnectionManager()
    /// The Bluetooth path, dialled on the same footing as the network ones.
    ///
    /// The phone is the peripheral: the Mac connects to us. That is the only BLE
    /// direction these two devices establish reliably, and it also means the
    /// phone decides whether this path exists at all.
    let ble = RemoteBLEPeripheral()

    private var activeMac: PairedMac?
    /// A Mac the user tapped in Devices that is not in the paired store yet, so
    /// it cannot be reached through `activeMac`.
    private var pairingTarget: DiscoveredMac?
    private var manualTarget: ManualMacAddress?
    /// Every dial still in flight. `connection` is never one of these.
    private var candidates: [Candidate] = []
    private var activeMethod: RemoteConnectionMethod?
    @Published private(set) var connectionGeneration = 0

    var connectionPriority: [RemoteConnectionMethod] { store.connectionPriority }

    func moveConnectionPriority(from source: IndexSet, to destination: Int) {
        var order = connectionPriority
        order.move(fromOffsets: source, toOffset: destination)
        store.setConnectionPriority(order)
        pruneCandidates()
        if connection.isReady, connection.transportKind != .bluetooth, !shouldTry(.bluetooth) {
            stopBLEFallback()
        }
        restartConnectSupervisor()
    }

    private func shouldTry(_ method: RemoteConnectionMethod) -> Bool {
        !connection.isReady || RemoteConnectionPriority.shouldReplace(activeMethod, with: method, order: connectionPriority)
    }

    private func pruneCandidates() {
        for candidate in candidates where !shouldTry(candidate.method) {
            removeCandidate(candidate.manager)
        }
    }
    /// Timings a candidate reported immediately before it was promoted.
    ///
    /// `RemoteConnectionManager` measures the transport and handshake on the line
    /// above the one that announces the session, so a winning candidate is still
    /// an ordinary candidate at that moment. Applying them on promotion is the
    /// only way Settings can show how long the race that won actually took.
    private var pendingMetrics: [ObjectIdentifier: (connect: Int?, handshake: Int?)] = [:]
    private var supervisorTask: Task<Void, Never>?
    /// Bumped on every start/stop so a finishing supervisor run cannot clear the
    /// handle of a newer one.
    private var supervisorGeneration = 0
    private var isForeground = true
    private var hasEverConnected = false
    private var didStart = false
    private var discoveryStartedAt: Date?
    /// Coalescing state for slider drags: at most one level request is in
    /// flight, and `pendingLevel` always holds the last value produced.
    private var pendingLevel: PendingLevel?
    private var isSendingLevel = false
    /// Guards the state refresh so a connect plus a foreground event cannot both
    /// send one.
    private var isRefreshingState = false

    /// Retry cadence while the app is in the foreground. The first entries are
    /// deliberately tight: the user has just opened the app and is watching.
    private let connectRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 1.5, 2, 3, 5]
    /// Check upgrades on the fast LAN cadence; candidates have separate lifetimes.
    private let connectAttemptTimeout = RemoteAppModel.dialRetryTimeout
    private var isBLEDiagnosticRun: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACPILOT_BLE_DIAGNOSTIC"] == "1"
        #else
        false
        #endif
    }

    init(store: PairedMacStore = PairedMacStore()) {
        self.store = store
        controlPreferences.objectWillChange
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &storeChanges)
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
        discovery.onResultsChanged = { [weak self] macs in
            self?.handleDiscovery(macs)
        }
        discoveryStartedAt = Date()
        discovery.start()

        ble.onLog = { [weak self] message in
            guard let self else { return }
            self.bleLog(message)
            self.bleFallbackAdvertising = self.ble.isAdvertising
        }
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

    /// Recreate the Bonjour browser when its initial browse missed a Mac.
    func searchDevices() {
        discovery.stop()
        handleDiscovery([])
        discoveryStartedAt = Date()
        discovery.start()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            // iOS tears down the DNS-SD session behind the browse while the app
            // is suspended: the browser carried across either reports failed or
            // never re-delivers its results, so every dial would race against
            // stale endpoints and the Mac would never be found again. Rebuild
            // discovery before the reconnect race starts.
            discovery.restart()
            appendLinkDiagnostic("foreground: discovery rebuilt")
            // Re-arm with a fresh, tight cadence and an immediate Bluetooth
            // advertisement: opening the app is exactly when the user expects a
            // connection, and the radio can have moved on while it was away.
            startBLEFallback()
            startConnectSupervisor()
            // Brightness and volume can have moved while the app was away (the
            // keyboard's own keys), and the panel would otherwise show stale
            // values until the next keep-alive.
            refreshState()
        case .background:
            // No background sockets in V1; close cleanly so the Mac releases
            // the connection instead of waiting for a timeout.
            isForeground = false
            stopConnectSupervisor()
            stopBLEFallback()
            cancelCandidates()
            connection.disconnect(report: false)
            connectionState = hasEverConnected ? .reconnecting : .idle
        default:
            break
        }
    }

    /// Points one candidate's callbacks at this model.
    ///
    /// Candidate failures stay in diagnostics. Only the current manager updates
    /// visible state, and a fully authenticated higher-priority candidate can replace it.
    private func wire(_ manager: RemoteConnectionManager, path: RacePath) {
        manager.onDiagnostic = { [weak self] message in
            self?.raceLog("\(path.rawValue): \(message)")
        }
        manager.onStateChange = { [weak self, weak manager] state in
            guard let self, let manager, self.isCurrent(manager) else { return }
            // Only promote the visible state; failures and disconnects are
            // driven by the dedicated callbacks below. The connection already
            // asks for a fresh state as soon as the session is ready, so
            // brightness and volume arrive with the handshake.
            if state == .connected || state == .pairing || state == .authenticating {
                self.connectionState = state
            }
        }
        manager.onDeviceResolved = { [weak self, weak manager] deviceID, name, endpoint in
            guard let self, let manager else { return }
            guard !self.isCurrent(manager) else {
                self.activeMethod = manager.transportKind == .bluetooth ? .bluetooth
                    : (manager.linkDescription.hasPrefix("awdl") ? .awdl : .localNetwork)
                self.handleConnected(deviceID: deviceID, name: name, endpoint: endpoint)
                return
            }
            guard self.candidates.contains(where: { $0.manager === manager }) else { return }
            self.raceLog("race won by \(path.rawValue)")
            let resolvedMethod: RemoteConnectionMethod = manager.transportKind == .bluetooth ? .bluetooth
                : (manager.linkDescription.hasPrefix("awdl") ? .awdl : .localNetwork)
            guard self.shouldTry(resolvedMethod) else {
                self.removeCandidate(manager)
                return
            }
            self.promote(manager)
            self.handleConnected(deviceID: deviceID, name: name, endpoint: endpoint)
        }
        manager.onMacState = { [weak self, weak manager] state in
            guard let self, let manager, self.isCurrent(manager) else { return }
            self.macState = state
        }
        manager.onPairingPrompt = { [weak self, weak manager] _, name in
            guard let self, let manager else { return }
            if !self.isCurrent(manager) {
                guard !self.connection.isReady else {
                    self.removeCandidate(manager)
                    return
                }
                guard self.candidates.contains(where: { $0.manager === manager }) else { return }
                // Two candidates can reach the pairing exchange, but the Mac
                // shows exactly one code, so only one link may carry it.
                // Whichever asks first gets to be that link.
                self.raceLog("pairing carried by \(path.rawValue)")
                self.promote(manager)
                self.connectionState = .pairing
            }
            self.pairingPrompt = PairingPrompt(name: name)
        }
        manager.onLatency = { [weak self, weak manager] milliseconds in
            guard let self, let manager, self.isCurrent(manager) else { return }
            self.latencyMs = milliseconds
            self.metrics.commandRTTMs = milliseconds
        }
        manager.onFailure = { [weak self, weak manager] error in
            guard let self, let manager else { return }
            guard self.isCurrent(manager) else {
                guard self.candidates.contains(where: { $0.manager === manager }) else { return }
                self.raceLog("race: \(path.rawValue) failed (\(error.messageKey))")
                self.removeCandidate(manager)
                if self.manualTarget != nil {
                    self.errorKey = error.messageKey
                    self.connectionState = .failed(self.text(error.messageKey))
                    self.stopConnectSupervisor()
                }
                return
            }
            self.errorKey = error.messageKey
            if self.pairingTarget != nil {
                self.connectionState = .failed(self.text(error.messageKey))
                self.pairingPrompt = nil
                self.stopConnectSupervisor()
            } else {
                // `fail()` reports the error without necessarily emitting a
                // separate disconnect callback. Keep the foreground retry
                // loop alive for this path too.
                self.connectionState = .reconnecting
                self.refreshTransportDescription()
                self.startBLEFallback()
                self.restartConnectSupervisor()
            }
        }
        manager.onDisconnected = { [weak self, weak manager] in
            guard let self, let manager else { return }
            guard self.isCurrent(manager) else {
                self.removeCandidate(manager)
                return
            }
            self.handleDisconnected()
        }
        manager.onMetrics = { [weak self, weak manager] connect, handshake in
            guard let self, let manager else { return }
            guard self.isCurrent(manager) else {
                guard self.candidates.contains(where: { $0.manager === manager }) else { return }
                // A candidate reports its transport and handshake timings on the
                // line before it announces the session, so at this instant the
                // winner is still an ordinary candidate. Hold them for the
                // promotion instead of dropping the only measurement of the race.
                self.pendingMetrics[ObjectIdentifier(manager)] = (connect, handshake)
                return
            }
            self.metrics.connectLatencyMs = connect
            self.metrics.handshakeLatencyMs = handshake
        }
    }

    private func isCurrent(_ manager: RemoteConnectionManager) -> Bool {
        connection === manager
    }

    // MARK: - Connection

    /// Owns dialling while the app is in the foreground.
    ///
    /// This is the only retry authority. That matters more than it sounds: it used
    /// to be two mechanisms racing each other — a 500ms "fast path" cancelled its
    /// own in-flight connection when the remembered address was slow (a cold
    /// link-local neighbour lookup easily exceeds that), and nothing restarted it,
    /// because discovery only reports *changes* and the Mac was already in its
    /// results. The app then sat on "searching" indefinitely.
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

    // MARK: - Bluetooth path

    /// Advertise while disconnected or while Bluetooth can improve the current link.
    private func startBLEFallback() {
        guard manualTarget == nil, isForeground, shouldTry(.bluetooth) else { return }
        ble.start()
        bleFallbackAdvertising = ble.isAdvertising
    }

    private func stopBLEFallback() {
        ble.stop()
        bleFallbackAdvertising = false
    }

    /// The Mac opened a channel to us. It joins the race immediately rather than
    /// waiting for the network to fail: whichever link authenticates first wins,
    /// and refusing to dial here would make the fastest path conditional on the
    /// slowest one.
    private func adoptBLEChannel(_ channel: CBL2CAPChannel) {
        bleFallbackAdvertising = ble.isAdvertising
        guard manualTarget == nil, shouldTry(.bluetooth) else {
            close(channel)
            return
        }
        guard let target = raceTarget else {
            close(channel)
            return
        }
        // A pairing exchange must stay on a single link (see `isRacingFirstPairing`):
        // the Mac shows one code and a second link would derive its own.
        if connectionState == .pairing {
            bleLog("BLE channel declined: Bluetooth is not the pairing link")
            close(channel)
            return
        }
        if !candidates.isEmpty, isRacingFirstPairing {
            bleLog("BLE channel declined: a first pairing is already in flight")
            close(channel)
            return
        }
        // A channel is single use and the Mac opens one per advertisement, so an
        // older Bluetooth candidate would only be holding a dead link.
        removeCandidate(path: .bluetooth)
        bleLog("BLE channel delivered; joining the race")
        addCandidate(
            path: .bluetooth,
            transport: makeBLETransport(channel),
            deviceID: target.deviceID,
            name: target.name
        )
    }

    private func makeBLETransport(_ channel: CBL2CAPChannel) -> L2CAPStreamTransport {
        let transport = L2CAPStreamTransport(channel: channel)
        let traceID = UUID().uuidString.prefix(8)
        transport.onDiagnostic = { [weak self] message in self?.bleLog("[\(traceID)] \(message)") }
        bleLog("BLE [\(traceID)] adopting channel psm=\(channel.psm)")
        return transport
    }

    /// Declining a channel leaves it open on the Mac as a silent client until its
    /// idle timeout reaps it, so an unused one is closed here.
    private func close(_ channel: CBL2CAPChannel) {
        channel.inputStream.close()
        channel.outputStream.close()
    }

    private func bleLog(_ message: String) {
        #if DEBUG
        print("BLE diagnostic: \(message)")
        #endif
        lastBLEMessage = message
        bleLogger.info("\(message, privacy: .public)")
        appendLinkDiagnostic(message)
    }

    /// Records a race event. Losing paths have to leave a trace too, otherwise a
    /// race that picked the slower link looks exactly like one that had no choice.
    private func raceLog(_ message: String) {
        #if DEBUG
        print("race: \(message)")
        #endif
        appendLinkDiagnostic("race: \(message)")
    }

    private func appendLinkDiagnostic(_ message: String) {
        linkDiagnostics.append("\(Date().ISO8601Format()) \(message)")
        if linkDiagnostics.count > 160 {
            linkDiagnostics.removeFirst(linkDiagnostics.count - 160)
        }
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

    // MARK: - The race

    /// Owns dialling while the app is in the foreground.
    ///
    /// Dial all paths while disconnected, then retry only higher-priority paths.
    /// An upgrade attempt never changes the visible connected state or closes
    /// the usable session before the replacement has authenticated.
    private func runConnectSupervisor() async {
        var attempt = 0

        while !Task.isCancelled {
            if connectionState.isConnected {
                if activeMethod == connectionPriority.first { return }
                startBLEFallback()
                addNetworkCandidates()
                // Retry only unfinished higher-priority paths. The current link stays usable.
                await pause(connectAttemptTimeout)
                if Task.isCancelled { return }
                retryExpiredCandidates()
                await pause(connectRetryDelays.last ?? 5)
                continue
            }
            // Never interrupt a handshake: the user may be typing a pair code.
            if connectionState == .pairing || connectionState == .authenticating {
                await pause(0.5)
                continue
            }
            if attempt > 0 {
                let delay = connectRetryDelays[min(attempt - 1, connectRetryDelays.count - 1)]
                await pause(delay)
                if Task.isCancelled { return }
            }

            startRace()
            if !isRacingFirstPairing { addNetworkCandidates() }
            startBLEFallback()
            guard !candidates.isEmpty else {
                // Nothing reachable yet. Discovery restarts this loop the moment
                // it produces an address, so the backoff is only a safety net.
                connectionState = .discovering
                attempt += 1
                await pause(0.5)
                continue
            }

            // Each candidate expires independently. A fast LAN redial must not
            // restart peer discovery, and handshake time begins at transport ready.
            while !Task.isCancelled, !candidates.isEmpty {
                if connectionState.isConnected
                    || connectionState == .pairing
                    || connectionState == .authenticating { break }
                retryExpiredCandidates()
                // Redial expired LAN candidates without resetting a cold AWDL
                // candidate's radio setup or a ready candidate's handshake.
                if !isRacingFirstPairing { addNetworkCandidates() }
                await pause(0.2)
            }

            if connectionState.isConnected
                || connectionState == .pairing
                || connectionState == .authenticating {
                attempt = 0
                await pause(0.2)
                continue
            }
            attempt += 1
            await pause(0.2)
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func retryExpiredCandidates() {
        let now = Date()
        let expired = candidates.filter {
            RemoteConnectionRetryPolicy.shouldRetry(
                method: $0.method, startedAt: $0.startedAt,
                transportReadyAt: $0.manager.transportReadyAt, now: now
            )
        }
        for candidate in expired {
            let phase = candidate.manager.isTransportReady ? "handshake" : "dial"
            raceLog("\(phase) timeout for \(candidate.path.rawValue); retrying")
            removeCandidate(candidate.manager)
        }
    }

    /// Where this race should point, if anywhere.
    ///
    /// A first-time pairing target comes from the Devices tab and is not in the
    /// paired store yet, so it cannot be found through `activeMac`.
    private var raceTarget: (deviceID: UUID, name: String, discovered: NWEndpoint?, remembered: NWEndpoint?)? {
        if let pairing = pairingTarget {
            return (pairing.id, pairing.name, pairing.endpoint, nil)
        }
        guard let mac = activeMac ?? store.preferredMac, let deviceID = mac.deviceID else { return nil }
        let online = discovery.onlineEndpoint(for: deviceID)
        return (deviceID, online?.name ?? mac.name, online?.endpoint, mac.rememberedEndpoint)
    }

    /// True when the links already racing are running a **first** pairing.
    ///
    /// That exchange must stay single path: the Mac displays exactly one code and
    /// two concurrent pair requests each derive their own, so a race could leave
    /// the user reading the code for the link that is about to be discarded.
    /// Once a long term key exists the proof is computed per connection from the
    /// shared secret, and racing is safe again.
    private var isRacingFirstPairing: Bool {
        if manualTarget != nil { return true }
        guard let target = raceTarget else { return false }
        return !RemoteKeychain.hasPairingKey(for: target.deviceID.uuidString)
    }

    /// Sends every reachable path out at once.
    private func startRace() {
        guard candidates.isEmpty, !isBLEDiagnosticRun else { return }
        errorKey = nil
        if !discovery.isBrowsing { discovery.start() }
        if let manualTarget {
            addCandidate(path: .remembered, transport: NetworkRemoteTransport(to: manualTarget.endpoint),
                         deviceID: nil, name: manualTarget.host)
            return
        }
        guard let target = raceTarget else {
            connectionState = .discovering
            return
        }
        // The Bluetooth path takes part from the first attempt; it is the only
        // one that works with no shared network at all.
        startBLEFallback()

        // A first pairing is deliberately single-path; `isRacingFirstPairing`
        // explains why. Everything else goes out in parallel.
        if !isRacingFirstPairing {
            addNetworkCandidates()
        } else if let endpoint = target.discovered ?? target.remembered {
            addCandidate(
                path: target.discovered == nil ? .remembered : .bonjour,
                transport: NetworkRemoteTransport(to: endpoint),
                deviceID: target.deviceID,
                name: target.name
            )
        }
    }

    private func addNetworkCandidates() {
        guard isForeground, !isRacingFirstPairing, let target = raceTarget else { return }
        var endpoints = discovery.endpoints(for: target.deviceID)
        // Browser results can be late or absent after an interface change. A
        // saved Bonjour name can still resolve the Mac's current peer address.
        if let service = store.mac(id: target.deviceID)?.rememberedServiceEndpoint,
           !endpoints.contains(where: { $0.method == .awdl }) {
            endpoints.append((.awdl, service))
        }
        if let remembered = target.remembered {
            let method: RemoteConnectionMethod
            if case let .hostPort(host, _) = remembered,
               RemoteInterfaceName.scope(of: String(describing: host))?.hasPrefix("awdl") == true {
                method = .awdl
            } else {
                method = .localNetwork
            }
            endpoints.append((method, remembered))
        }
        if let manual = store.mac(id: target.deviceID)?.manualEndpoint {
            endpoints.append((.localNetwork, manual))
        }
        for (method, endpoint) in endpoints where shouldTry(method) {
            let path: RacePath = method == .awdl ? .awdl : .localNetwork
            let identity = String(describing: endpoint)
            guard !candidates.contains(where: { $0.method == method && $0.manager.dialEndpoint == identity }) else { continue }
            addCandidate(path: path, transport: NetworkRemoteTransport(to: endpoint, method: method),
                         deviceID: target.deviceID, name: target.name, method: method, endpoint: identity)
        }
    }

    /// Starts one dial. The candidate owns its own transport, framing and
    /// handshake, so two candidates cannot interfere with each other.
    private func addCandidate(
        path: RacePath,
        transport: RemoteTransport,
        deviceID: UUID?,
        name: String,
        method: RemoteConnectionMethod? = nil,
        endpoint: String? = nil
    ) {
        let manager = RemoteConnectionManager()
        manager.dialEndpoint = endpoint
        wire(manager, path: path)
        candidates.append(Candidate(path: path, manager: manager, method: method ?? (path == .bluetooth ? .bluetooth : .localNetwork)))
        refreshRacingPaths()
        if !connectionState.isConnected,
           connectionState != .pairing,
           connectionState != .authenticating {
            connectionState = .connecting
        }
        raceLog("dialling \(path.rawValue) endpoint=\(endpoint ?? "discovered service")")
        manager.connect(
            using: transport,
            deviceID: deviceID,
            name: name,
            clientID: store.clientID,
            clientName: store.clientName,
            allowsPairing: isRacingFirstPairing
        )
    }

    private func removeCandidate(_ manager: RemoteConnectionManager) {
        guard let index = candidates.firstIndex(where: { $0.manager === manager }) else { return }
        let candidate = candidates.remove(at: index)
        refreshRacingPaths()
        pendingMetrics.removeValue(forKey: ObjectIdentifier(candidate.manager))
        candidate.manager.disconnect(report: false)
    }

    private func removeCandidate(path: RacePath) {
        guard let index = candidates.firstIndex(where: { $0.path == path }) else { return }
        let candidate = candidates.remove(at: index)
        refreshRacingPaths()
        pendingMetrics.removeValue(forKey: ObjectIdentifier(candidate.manager))
        candidate.manager.disconnect(report: false)
    }

    /// Ends every dial except `keeper`, which stays in the race.
    private func cancelCandidates(except keeper: RemoteConnectionManager? = nil) {
        let doomed = candidates.filter { $0.manager !== keeper }
        candidates.removeAll { $0.manager !== keeper }
        refreshRacingPaths()
        for candidate in doomed {
            pendingMetrics.removeValue(forKey: ObjectIdentifier(candidate.manager))
            candidate.manager.disconnect(report: false)
        }
    }

    /// Swaps only authenticated links; lower-ranked attempts cannot take over.
    private func promote(_ manager: RemoteConnectionManager) {
        guard let winner = candidates.first(where: { $0.manager === manager }) else { return }
        let previous = connection
        let switching = previous.isReady
        if !manager.isReady { cancelCandidates(except: manager) }
        candidates.removeAll { $0.manager === manager }
        connection = manager
        activeMethod = manager.transportKind == .bluetooth ? .bluetooth
            : (manager.linkDescription.hasPrefix("awdl") ? .awdl : .localNetwork)
        previous.disconnect(report: false)
        runningCommand = nil
        latencyMs = nil
        metrics.commandRTTMs = nil
        pendingLevel = nil
        isSendingLevel = false
        isRefreshingState = false
        isRefreshingDockGroups = false
        if manager.isReady { pruneCandidates() }
        refreshRacingPaths()
        if switching { raceLog("upgraded to \(activeMethod?.rawValue ?? winner.method.rawValue)") }
        connectionGeneration += 1
    }

    private func refreshRacingPaths() {
        racingPaths = Array(Set(candidates.map(\.path.rawValue))).sorted().compactMap(RacePath.init(rawValue:))
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
        if connectionState.isConnected {
            addNetworkCandidates()
            startConnectSupervisor()
            return
        }
        guard connectionState != .pairing,
              connectionState != .authenticating else { return }
        if pairingTarget != nil, errorKey != nil { return }

        // Discovery updates must only add a path to the selected Mac. Otherwise
        // a second nearby Mac can silently take over during a reconnect.
        guard let selectedID = pairingTarget?.id ?? activeMac?.deviceID ?? store.preferredMac?.deviceID,
              let target = macs.first(where: { $0.id == selectedID }) else { return }
        if pairingTarget == nil { activeMac = store.mac(id: target.id) }

        if isRacingFirstPairing {
            if candidates.isEmpty { restartConnectSupervisor() }
        } else {
            addNetworkCandidates()
            startConnectSupervisor()
        }
    }

    private func handleConnected(deviceID: UUID, name: String, endpoint: RemoteConnectionManager.ResolvedEndpoint) {
        let enteredAddress = manualTarget
        manualTarget = nil
        let wasPairing = pairingTarget != nil
        hasEverConnected = true
        pairingTarget = nil
        // The winner measured its transport and handshake just before it was
        // promoted, so its timings are waiting here rather than on `metrics`.
        if let pending = pendingMetrics.removeValue(forKey: ObjectIdentifier(connection)) {
            metrics.connectLatencyMs = pending.connect
            metrics.handshakeLatencyMs = pending.handshake
        }
        // A working link makes Bluetooth redundant, and an idle advertisement
        // only costs both devices power. The exception is Bluetooth itself: the
        // L2CAP channel belongs to the peripheral, so stopping the peripheral
        // while it is the link carrying this session would close the stream we
        // just connected with.
        if connection.transportKind != .bluetooth && !shouldTry(.bluetooth) {
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
        if let enteredAddress, var mac = store.mac(id: deviceID) {
            mac.manualHost = enteredAddress.host
            mac.manualPort = enteredAddress.port
            store.upsert(mac)
        }
        store.markConnected(
            id: deviceID,
            endpoint: NWEndpointSnapshot(
                host: endpoint.host,
                port: endpoint.port,
                serviceName: endpoint.serviceName
            ),
            name: name
        )
        if wasPairing { store.preferredMacID = deviceID.uuidString }
        activeMac = store.mac(id: deviceID)
        startConnectSupervisor()
    }

    private func handleDisconnected() {
        guard connectionState != .idle else { return }
        if pairingTarget != nil {
            pairingPrompt = nil
            errorKey = "errorNetwork"
            connectionState = .failed(text("errorNetwork"))
            stopConnectSupervisor()
            return
        }
        connectionState = hasEverConnected ? .reconnecting : .failed(text("errorNetwork"))
        refreshTransportDescription()
        startBLEFallback()
        if Self.shouldRestartSupervisorAfterDisconnect(
            isForeground: isForeground,
            hasPairingTarget: pairingTarget != nil
        ) {
            restartConnectSupervisor()
        }
    }

    /// User driven connect from the Devices tab, used for first-time pairing.
    func pair(with mac: DiscoveredMac) {
        resetConnectionForTarget()
        pairingTarget = mac
        activeMac = store.mac(id: mac.id)
        connectionState = .connecting
        startBLEFallback()
        startConnectSupervisor()
    }

    /// Identity is learned from the authenticated handshake, never from the entered address.
    func connect(to address: ManualMacAddress) {
        resetConnectionForTarget()
        manualTarget = address
        pairingTarget = DiscoveredMac(id: UUID(), name: address.host, endpoint: address.endpoint,
                                      version: "", protocolVersion: RemoteProtocolVersion.current, capabilities: [])
        activeMac = nil
        connectionState = .connecting
        startConnectSupervisor()
    }

    var pairingTargetID: UUID? { pairingTarget?.id }

    func connect(to mac: PairedMac) {
        guard mac.deviceID != nil else { return }
        if activeMac?.id == mac.id, connectionState.isConnected { return }
        resetConnectionForTarget()
        pairingTarget = nil
        activeMac = mac
        store.preferredMacID = mac.id
        connectionState = .connecting
        startBLEFallback()
        startConnectSupervisor()
    }

    private func resetConnectionForTarget() {
        manualTarget = nil
        stopConnectSupervisor()
        stopBLEFallback()
        cancelCandidates()
        connection.disconnect(report: false)
        // A fresh manager makes late callbacks from the previous Mac irrelevant.
        connection = RemoteConnectionManager()
        activeMethod = nil
        macState = nil
        latencyMs = nil
        errorKey = nil
        infoKey = nil
        runningCommand = nil
        dockGroupsSnapshot = nil
        dockGroupsMissingApps = []
        launchingDockGroupID = nil
        launchingDockAppID = nil
        pendingLevel = nil
        isSendingLevel = false
        isRefreshingState = false
        hasEverConnected = false
        pendingMetrics = [:]
        metrics.connectLatencyMs = nil
        metrics.handshakeLatencyMs = nil
        metrics.commandRTTMs = nil
        metrics.executionLatencyMs = nil
        transportDescription = "—"
        pairingPrompt = nil
    }

    func retry() {
        errorKey = nil
        // Drop whatever is in flight so the user sees a fresh race now instead of
        // waiting out the current one's window.
        cancelCandidates()
        connection.disconnect(report: false)
        // The silent disconnect above leaves the visible state at `.connected`,
        // and the supervisor returns immediately when it sees that — the fresh
        // race would never dial and the link would stay dead. Step the state
        // down first.
        connectionState = hasEverConnected ? .reconnecting : .connecting
        stopConnectSupervisor()
        startConnectSupervisor()
    }

    // MARK: - Pairing

    func submitPairCode(_ code: String) {
        guard connection.isPairing else {
            errorKey = "errorNetwork"
            return
        }
        errorKey = nil
        connection.submitPairCode(code)
    }

    func cancelPairing() {
        resetConnectionForTarget()
        pairingTarget = nil
        activeMac = store.preferredMac
        connectionState = activeMac == nil ? .discovering : .connecting
        if activeMac != nil {
            startBLEFallback()
            startConnectSupervisor()
        }
    }

    // MARK: - Devices

    var pairedMacs: [PairedMac] { store.pairedMacs }

    var selectedMacID: String? { activeMac?.id ?? store.preferredMac?.id }

    var activeMacName: String {
        pairingTarget?.name ?? activeMac?.name ?? store.preferredMac?.name ?? "MacPilot"
    }

    func isDefault(_ mac: PairedMac) -> Bool { store.preferredMacID == mac.id }

    func setDefault(_ mac: PairedMac) {
        store.preferredMacID = mac.id
    }

    func forget(_ mac: PairedMac) {
        let wasActive = activeMac?.id == mac.id
        store.remove(id: UUID(uuidString: mac.id) ?? UUID())
        if wasActive {
            if let next = store.preferredMac {
                connect(to: next)
            } else {
                resetConnectionForTarget()
                activeMac = nil
                connectionState = .discovering
            }
        }
    }

    func removeAllPairings() {
        resetConnectionForTarget()
        store.removeAll()
        activeMac = nil
        pairingTarget = nil
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

    @Published var desktopModifiers: UInt8 = 0

    var supportsRemoteDesktop: Bool { connection.supportsRemoteDesktop }
    var supportsMediaControl: Bool { connection.supportsMediaControl }
    func beginRemoteVideo(displayID: UInt32?) async throws -> (RemoteVideoOffer, String) {
        try await connection.beginRemoteVideo(displayID: displayID)
    }
    func endRemoteVideo() async { _ = try? await connection.send(.endRemoteVideo, timeout: 3) }
    func desktopClick(_ pointer: RemotePointerRequest) async -> Bool {
        guard let data = try? JSONEncoder().encode(pointer) else { return false }
        return (try? await connection.send(.remotePointer, payload: data, timeout: 3).success) == true
    }
    @discardableResult
    func desktopKey(_ key: RemoteKeyRequest) async -> Bool {
        guard let data = try? JSONEncoder().encode(key) else { return false }
        return (try? await connection.send(.remoteKey, payload: data, timeout: 3).success) == true
    }

    // MARK: - Realtime input (trackpad)

    /// The Mac advertised the realtime input channel. An older Mac build did
    /// not, and the trackpad entry explains that instead of failing blindly.
    var supportsRealtimeInput: Bool { connection.supportsRealtimeInput }

    /// Whether the connected Mac reads graded pressure from press events.
    var supportsInputPressure: Bool { connection.supportsInputPressure }

    /// Whether the connected Mac understands the continuous press stream.
    var supportsInputPressureStream: Bool { connection.supportsInputPressureStream }

    /// Whether the connected Mac serves Dock groups. Decides whether the home
    /// screen offers the section at all.
    var supportsDockGroups: Bool { connection.supportsDockGroups }

    /// Quality of the link currently carrying the session, from the trackpad's
    /// point of view. AWDL rides the same network transport — the race that
    /// picks the session already prefers the fastest path, and AWDL is
    /// normally exactly that — so only Bluetooth is called out.
    var realtimeInputLinkKind: RemoteTransportKind? { connection.transportKind }

    /// Arms the realtime channel for the trackpad page. Failure carries the
    /// error text key; success tells the trackpad which side owns pointer
    /// acceleration.
    func beginRealtimeInput() async -> Result<RemoteConnectionManager.RealtimeInputSession, RemoteConnectionManager.RealtimeInputError> {
        await connection.beginRealtimeInput()
    }

    func endRealtimeInput() async {
        await connection.endRealtimeInput()
    }

    /// Hands one binary input batch to the connection. Fire and forget: the
    /// trackpad coalesced it already, and a failed send means a dead link the
    /// state callbacks will report anyway.
    func sendRealtimeInput(_ batch: RemoteInputBatch) {
        connection.sendRealtimeInput(batch)
    }

    func beginTextInput(focused: Bool = false) async -> Bool { await connection.beginTextInput(focused: focused) }

    func sendTextInput(_ operation: RemoteTextInputOperation) async -> Bool {
        let modifiers = desktopModifiers
        desktopModifiers = 0
        if modifiers != 0, supportsRemoteDesktop {
            switch operation {
            case .insert(let text) where text.count == 1:
                return await desktopKey(RemoteKeyRequest(key: .character, modifiers: modifiers, character: text))
            case .deleteBackward:
                return await desktopKey(RemoteKeyRequest(key: .delete, modifiers: modifiers))
            case .returnKey:
                return await desktopKey(RemoteKeyRequest(key: .enter, modifiers: modifiers))
            default: break
            }
        }
        return await connection.sendTextInput(operation)
    }

    func endTextInput() async { await connection.endTextInput() }

    // MARK: - Commands

    func perform(_ command: RemoteCommand) async {
        guard connectionState.isConnected else {
            errorKey = "errorNotPaired"
            return
        }
        if [.mediaPrevious, .mediaPlayPause, .mediaNext].contains(command), !supportsMediaControl {
            errorKey = "mediaNeedsUpdate"
            return
        }
        let manager = connection
        runningCommand = command
        defer { if isCurrent(manager) { runningCommand = nil } }

        let started = Date()
        do {
            let response = try await manager.send(command)
            guard isCurrent(manager) else { return }
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
            guard isCurrent(manager) else { return }
            errorKey = error.messageKey
            Haptics.warning()
        } catch {
            guard isCurrent(manager) else { return }
            errorKey = "errorNetwork"
            Haptics.warning()
        }
    }

    func beginCommand(_ command: RemoteCommand) {
        Haptics.impact()
    }

    // MARK: - Dock groups

    private var isRefreshingDockGroups = false

    /// Fetches the Mac's Dock groups. Runs after connecting and after every
    /// launch, so the rows reflect what the Mac itself sees.
    func refreshDockGroups() {
        guard connectionState.isConnected, connection.supportsDockGroups, !isRefreshingDockGroups else { return }
        isRefreshingDockGroups = true
        let manager = connection
        Task { [weak self] in
            guard let self else { return }
            defer { if self.isCurrent(manager) { self.isRefreshingDockGroups = false } }
            guard let response = try? await manager.send(.getDockGroups), self.isCurrent(manager) else { return }
            self.dockGroupsSnapshot = RemoteDockGroupsSnapshot.decoded(from: response.payload)
        }
    }

    /// Launches every member of one group. The reply carries the refreshed
    /// snapshot; a short follow-up fetch catches members whose process took a
    /// moment to register as running.
    func launchDockGroup(id: String) {
        guard launchingDockGroupID == nil, launchingDockAppID == nil else { return }
        launchingDockGroupID = id
        Haptics.impact()
        sendDockGroupLaunch(RemoteDockGroupLaunchRequest(groupID: id)) { [weak self] in
            self?.launchingDockGroupID = nil
        }
    }

    /// Launches or activates a single member of a group.
    func launchDockGroupApp(groupID: String, appID: UUID) {
        guard launchingDockGroupID == nil, launchingDockAppID == nil else { return }
        launchingDockAppID = appID
        Haptics.impact()
        sendDockGroupLaunch(RemoteDockGroupLaunchRequest(groupID: groupID, appID: appID)) { [weak self] in
            self?.launchingDockAppID = nil
        }
    }

    private func sendDockGroupLaunch(
        _ request: RemoteDockGroupLaunchRequest,
        onSettled: @escaping () -> Void
    ) {
        guard connectionState.isConnected, connection.supportsDockGroups else {
            errorKey = "errorNotPaired"
            onSettled()
            return
        }
        let manager = connection
        Task { [weak self] in
            guard let self else { return }
            defer { onSettled() }
            let payload = try? request.encoded()
            let response: RemoteResponse
            do {
                // Launching a whole group opens the members one by one; a big
                // group on a cold Mac can outlast the default 10 s window.
                response = try await manager.send(
                    request.appID == nil ? .launchDockGroup : .launchDockGroupApp,
                    payload: payload,
                    timeout: 30
                )
            } catch {
                guard self.isCurrent(manager) else { return }
                self.reportDockGroupFailure(error)
                return
            }
            guard self.isCurrent(manager) else { return }
            if let state = response.state { self.macState = state }
            if response.success {
                if let snapshot = RemoteDockGroupsSnapshot.decoded(from: response.payload) {
                    self.dockGroupsSnapshot = snapshot
                }
                let missing = RemoteDockGroupsSnapshot.decoded(from: response.payload)?.missingApps ?? []
                self.dockGroupsMissingApps = missing
                self.infoKey = missing.isEmpty ? "dockGroupLaunchDone" : "dockGroupLaunchMissing"
                Haptics.success()
                // Running state lags the launch: the process has to come up
                // before the Mac's snapshot shows it.
                try? await Task.sleep(for: .seconds(2))
                guard self.isCurrent(manager) else { return }
                self.refreshDockGroups()
            } else if let code = response.error?.code {
                self.errorKey = code.messageKey
                Haptics.warning()
            }
        }
    }

    private func reportDockGroupFailure(_ error: Error) {
        if let remoteError = error as? RemoteConnectionError {
            errorKey = remoteError.messageKey
        } else {
            errorKey = "errorNetwork"
        }
        Haptics.warning()
    }

    // MARK: - Output levels

    /// True when the Mac reported at least one level the panel can drive. A Mac
    /// build that predates these controls reports neither, which is how the app
    /// decides to explain itself instead of showing a dead slider.
    var hasLevelControls: Bool {
        RemoteLevelKind.allCases.contains { $0.value(in: macState) != nil }
    }

    /// Sends a level without blocking the UI.
    ///
    /// Dragging a slider produces far more updates than the link should carry,
    /// so only the newest one matters: at most one request is in flight and the
    /// queue collapses to the last value the user's finger produced. That keeps
    /// the slider responsive on Bluetooth and guarantees the final value — not
    /// an intermediate one — is what the Mac ends up at.
    func setLevel(_ kind: RemoteLevelKind, value: Double, muted: Bool? = nil) {
        guard connectionState.isConnected else {
            errorKey = "errorNotPaired"
            return
        }
        pendingLevel = PendingLevel(kind: kind, value: min(max(value, 0), 1), muted: muted)
        guard !isSendingLevel else { return }
        isSendingLevel = true
        let manager = connection
        Task { await drainPendingLevels(using: manager) }
    }

    /// Asks the Mac for a fresh state. The panel reads brightness and volume
    /// from `MacRemoteState`, so this is what picks up changes made on the Mac
    /// itself (the volume keys, or a brightness key) without waiting for the 15
    /// second keep-alive.
    func refreshState() {
        // A foreground event can repeat while the previous round trip is still
        // open; one is enough.
        guard connection.isReady, !isRefreshingState else { return }
        isRefreshingState = true
        let manager = connection
        Task { [weak self] in
            guard let self else { return }
            defer { if self.isCurrent(manager) { self.isRefreshingState = false } }
            guard let response = try? await manager.send(.getState), self.isCurrent(manager) else { return }
            if let state = response.state { self.macState = state }
        }
    }

    private func drainPendingLevels(using manager: RemoteConnectionManager) async {
        while isCurrent(manager), let next = pendingLevel {
            pendingLevel = nil
            do {
                let payload = try RemoteLevelRequest(value: next.value, muted: next.muted).encoded()
                let response = try await manager.send(next.kind.command, payload: payload)
                guard isCurrent(manager) else { return }
                if let state = response.state { macState = state }
                if !response.success, let code = response.error?.code {
                    errorKey = code.messageKey
                    Haptics.warning()
                }
            } catch let error as RemoteConnectionError {
                guard isCurrent(manager) else { return }
                errorKey = error.messageKey
                Haptics.warning()
            } catch {
                guard isCurrent(manager) else { return }
                errorKey = "errorNetwork"
                Haptics.warning()
            }
        }
        if isCurrent(manager) { isSendingLevel = false }
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
    /// CoreHaptics engine for the graded press feedback, created lazily and
    /// restarted after the system stops it.
    private static var hapticEngine: CHHapticEngine?

    static func impact() {
        #if canImport(UIKit)
        // iPads carry no Taptic engine; the synthesized trackpad tap stands
        // in for the buzz so the click still answers the finger.
        if UIDevice.current.userInterfaceIdiom == .pad {
            TrackpadClickSound.play()
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    /// The simulated press actuated: a light transient for an ordinary press,
    /// a heavy one once it grades near full pressure. iPads answer with the
    /// click sound, pitched up for the deep press.
    static func press(deep: Bool) {
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad {
            TrackpadClickSound.play(deep: deep)
            return
        }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UIImpactFeedbackGenerator(style: deep ? .heavy : .light).impactOccurred()
            return
        }
        do {
            let engine = try ensureHapticEngine()
            let events: [CHHapticEvent] = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: deep ? 1.0 : 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: deep ? 0.9 : 0.5),
                    ],
                    relativeTime: 0
                ),
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.start()
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: deep ? .heavy : .light).impactOccurred()
        }
        #endif
    }

    #if canImport(UIKit)
    private static func ensureHapticEngine() throws -> CHHapticEngine {
        if let hapticEngine { return hapticEngine }
        let engine = try CHHapticEngine()
        engine.resetHandler = { [weak engine] in try? engine?.start() }
        engine.isAutoShutdownEnabled = true
        try engine.start()
        hapticEngine = engine
        return engine
    }
    #endif

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
