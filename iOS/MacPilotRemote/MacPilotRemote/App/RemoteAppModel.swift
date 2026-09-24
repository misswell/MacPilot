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
/// to finish authenticating becomes the session. The paths are independent all
/// the way down, so a slow one can never hold up a fast one, and the loser is
/// torn down before the winner is promoted.
@MainActor
final class RemoteAppModel: ObservableObject {
    struct PairingPrompt: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    /// One of the ways the phone can reach the Mac.
    ///
    /// They are deliberately parallel rather than ordered: Bonjour is the
    /// address that is right now, the remembered host/port is the one that was
    /// right last time, and Bluetooth is the only path that needs no shared
    /// network at all.
    enum RacePath: String, Equatable {
        /// The `_macpilot._tcp` result Bonjour is advertising right now.
        case bonjour
        /// The host and port that worked last time.
        case remembered
        /// An L2CAP channel the Mac opened to this phone.
        case bluetooth

        /// The Settings row label for this path, routed through `RemoteText` so
        /// the diagnostics follow the app language like everything else.
        var textKey: String {
            switch self {
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
    let discovery = RemoteDiscoveryService()
    /// The link carrying the session. A race promotes its winner here, so this
    /// is replaced rather than reused; every loser is torn down before the swap.
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
    /// Every dial still in flight. `connection` is never one of these.
    private var candidates: [Candidate] = []
    /// Timings a candidate reported immediately before it was promoted.
    ///
    /// `RemoteConnectionManager` measures the transport and handshake on the line
    /// above the one that announces the session, so a winning candidate is still
    /// an ordinary candidate at that moment. Applying them on promotion is the
    /// only way Settings can show how long the race that won actually took.
    private var pendingMetrics: (connect: Int?, handshake: Int?)?
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
    /// A stale remembered address can sit in `.waiting` indefinitely, so a race
    /// in which no candidate produced a transport within this long is dropped and
    /// redialled — by then Bonjour usually has a fresh endpoint. A candidate
    /// whose transport is already up is never cut here: that one is mid
    /// handshake and cutting it would throw the attempt away.
    private let connectAttemptTimeout: TimeInterval = 4
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
    /// Every closure checks whether its manager is still the session before it
    /// touches UI state. That is the whole trick behind the race: the losers keep
    /// running — and keep failing, reconnecting and reporting — without any of it
    /// reaching the user, and the first one to authenticate simply becomes
    /// `connection`.
    private func wire(_ manager: RemoteConnectionManager, path: RacePath) {
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
                self.handleConnected(deviceID: deviceID, name: name, endpoint: endpoint)
                return
            }
            guard self.candidates.contains(where: { $0.manager === manager }) else { return }
            self.raceLog("race won by \(path.rawValue)")
            self.promote(manager)
            self.handleConnected(deviceID: deviceID, name: name, endpoint: endpoint)
        }
        manager.onMacState = { [weak self, weak manager] state in
            guard let self, let manager, self.isCurrent(manager) else { return }
            self.macState = state
        }
        manager.onPairingPrompt = { [weak self, weak manager] deviceID, name in
            guard let self, let manager else { return }
            if !self.isCurrent(manager) {
                guard self.candidates.contains(where: { $0.manager === manager }) else { return }
                // Two candidates can reach the pairing exchange, but the Mac
                // shows exactly one code, so only one link may carry it.
                // Whichever asks first gets to be that link.
                self.raceLog("pairing carried by \(path.rawValue)")
                self.promote(manager)
                self.connectionState = .pairing
            }
            self.pairingPrompt = PairingPrompt(id: deviceID, name: name)
        }
        manager.onLatency = { [weak self, weak manager] milliseconds in
            guard let self, let manager, self.isCurrent(manager) else { return }
            self.latencyMs = milliseconds
            self.metrics.commandRTTMs = milliseconds
        }
        manager.onFailure = { [weak self, weak manager] error in
            guard let self, let manager else { return }
            guard self.isCurrent(manager) else {
                self.raceLog("race: \(path.rawValue) failed (\(error.messageKey))")
                self.removeCandidate(manager)
                return
            }
            self.errorKey = error.messageKey
            self.connectionState = .failed(self.text(error.messageKey))
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
                // A candidate reports its transport and handshake timings on the
                // line before it announces the session, so at this instant the
                // winner is still an ordinary candidate. Hold them for the
                // promotion instead of dropping the only measurement of the race.
                self.pendingMetrics = (connect, handshake)
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

    /// Advertising runs whenever the app is in the foreground and not connected.
    ///
    /// It deliberately no longer waits for the network to fail: Bluetooth is one
    /// of the three paths dialled at once, and the phone is the peripheral, so
    /// advertising is what makes the path exist at all. The cost is a radio
    /// advertisement for as long as the app is open and disconnected; the moment
    /// a session is up — on any link — advertising stops again.
    private func startBLEFallback() {
        guard isForeground, !connectionState.isConnected else { return }
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
        bleFallbackAdvertising = false
        guard !connectionState.isConnected else {
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
    /// This is the only retry authority, and it is now also the only place that
    /// decides *what* to dial: every reachable path goes out at once and the
    /// first one to authenticate wins. It used to be a strict priority order,
    /// which meant a stale remembered address could hold the whole connection
    /// back for the full attempt timeout while a fresh Bonjour result sat unused.
    private func runConnectSupervisor() async {
        var attempt = 0

        while !Task.isCancelled {
            if connectionState.isConnected { return }
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
            guard !candidates.isEmpty else {
                // Nothing reachable yet. Discovery restarts this loop the moment
                // it produces an address, so the backoff is only a safety net.
                connectionState = .discovering
                attempt += 1
                await pause(0.5)
                continue
            }

            // Wait out this race. It ends when a link is promoted, when one of
            // them is mid-handshake, or when none of them produced a transport
            // inside the window.
            let deadline = Date().addingTimeInterval(connectAttemptTimeout)
            while !Task.isCancelled, !candidates.isEmpty {
                if connectionState.isConnected
                    || connectionState == .pairing
                    || connectionState == .authenticating { break }
                // A transport that is up means a handshake is in flight. Give it
                // as long as it needs: cutting it would throw the attempt away.
                if candidates.contains(where: { $0.manager.isTransportReady }) {
                    await pause(0.2)
                    continue
                }
                if Date() >= deadline { break }
                await pause(0.2)
            }

            if connectionState.isConnected
                || connectionState == .pairing
                || connectionState == .authenticating {
                attempt = 0
                await pause(0.2)
                continue
            }
            if !candidates.isEmpty {
                raceLog("no link in \(Int(connectAttemptTimeout))s; redialling")
                cancelCandidates()
            }
            attempt += 1
            await pause(0.2)
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
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
        guard let target = raceTarget else { return false }
        return !RemoteKeychain.hasPairingKey(for: target.deviceID.uuidString)
    }

    /// Sends every reachable path out at once.
    private func startRace() {
        guard candidates.isEmpty, !isBLEDiagnosticRun else { return }
        errorKey = nil
        if !discovery.isBrowsing { discovery.start() }
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
            if let endpoint = target.discovered {
                addCandidate(
                    path: .bonjour,
                    transport: NetworkRemoteTransport(to: endpoint),
                    deviceID: target.deviceID,
                    name: target.name
                )
            }
            if let endpoint = target.remembered, !sameAddress(endpoint, target.discovered) {
                addCandidate(
                    path: .remembered,
                    transport: NetworkRemoteTransport(to: endpoint),
                    deviceID: target.deviceID,
                    name: target.name
                )
            }
        } else if let endpoint = target.discovered ?? target.remembered {
            addCandidate(
                path: target.discovered == nil ? .remembered : .bonjour,
                transport: NetworkRemoteTransport(to: endpoint),
                deviceID: target.deviceID,
                name: target.name
            )
        }
    }

    /// Starts one dial. The candidate owns its own transport, framing and
    /// handshake, so two candidates cannot interfere with each other.
    private func addCandidate(
        path: RacePath,
        transport: RemoteTransport,
        deviceID: UUID?,
        name: String
    ) {
        let manager = RemoteConnectionManager()
        wire(manager, path: path)
        candidates.append(Candidate(path: path, manager: manager))
        refreshRacingPaths()
        if !connectionState.isConnected,
           connectionState != .pairing,
           connectionState != .authenticating {
            connectionState = .connecting
        }
        raceLog("dialling \(path.rawValue)")
        manager.connect(
            using: transport,
            deviceID: deviceID,
            name: name,
            clientID: store.clientID,
            clientName: store.clientName
        )
    }

    private func removeCandidate(_ manager: RemoteConnectionManager) {
        guard let index = candidates.firstIndex(where: { $0.manager === manager }) else { return }
        let candidate = candidates.remove(at: index)
        refreshRacingPaths()
        candidate.manager.disconnect(report: false)
    }

    private func removeCandidate(path: RacePath) {
        guard let index = candidates.firstIndex(where: { $0.path == path }) else { return }
        let candidate = candidates.remove(at: index)
        refreshRacingPaths()
        candidate.manager.disconnect(report: false)
    }

    /// Ends every dial except `keeper`, which stays in the race.
    private func cancelCandidates(except keeper: RemoteConnectionManager? = nil) {
        let doomed = candidates.filter { $0.manager !== keeper }
        candidates.removeAll { $0.manager !== keeper }
        refreshRacingPaths()
        for candidate in doomed {
            candidate.manager.disconnect(report: false)
        }
    }

    /// Makes a candidate the session and tears down everything it beat.
    private func promote(_ manager: RemoteConnectionManager) {
        cancelCandidates(except: manager)
        candidates.removeAll { $0.manager === manager }
        refreshRacingPaths()
        connection = manager
    }

    private func refreshRacingPaths() {
        racingPaths = candidates.map(\.path)
    }

    /// Compares two endpoints by their printable form. Only used to avoid dialling
    /// the Bonjour address a second time under the guise of "the remembered one".
    private func sameAddress(_ lhs: NWEndpoint?, _ rhs: NWEndpoint?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return String(describing: lhs) == String(describing: rhs)
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

        // Discovery updates must only add a path to the selected Mac. Otherwise
        // a second nearby Mac can silently take over during a reconnect.
        guard let selectedID = pairingTarget?.id ?? activeMac?.deviceID ?? store.preferredMac?.deviceID,
              let target = macs.first(where: { $0.id == selectedID }) else { return }
        if pairingTarget == nil { activeMac = store.mac(id: target.id) }

        // The supervisor owns dialling. A race that is already in flight gets the
        // freshly resolved address added to it: a remembered address can be
        // stale, and this is the moment Bonjour hands over the right one.
        if candidates.isEmpty {
            restartConnectSupervisor()
        } else if !candidates.contains(where: { $0.path == .bonjour }),
                  RemoteKeychain.hasPairingKey(for: target.id.uuidString) {
            addCandidate(
                path: .bonjour,
                transport: NetworkRemoteTransport(to: target.endpoint),
                deviceID: target.id,
                name: target.name
            )
        }
    }

    private func handleConnected(deviceID: UUID, name: String, endpoint: RemoteConnectionManager.ResolvedEndpoint) {
        let wasPairing = pairingTarget != nil
        hasEverConnected = true
        pairingTarget = nil
        stopConnectSupervisor()
        // The winner measured its transport and handshake just before it was
        // promoted, so its timings are waiting here rather than on `metrics`.
        if let pending = pendingMetrics {
            metrics.connectLatencyMs = pending.connect
            metrics.handshakeLatencyMs = pending.handshake
            pendingMetrics = nil
        }
        // A working link makes Bluetooth redundant, and an idle advertisement
        // only costs both devices power. The exception is Bluetooth itself: the
        // L2CAP channel belongs to the peripheral, so stopping the peripheral
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
        if wasPairing { store.preferredMacID = deviceID.uuidString }
        activeMac = store.mac(id: deviceID)
    }

    private func handleDisconnected() {
        guard connectionState != .idle else { return }
        connectionState = hasEverConnected ? .reconnecting : .failed(text("errorNetwork"))
        refreshTransportDescription()
        startBLEFallback()
        startConnectSupervisor()
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
        stopConnectSupervisor()
        stopBLEFallback()
        cancelCandidates()
        connection.disconnect(report: false)
        // A fresh manager makes late callbacks from the previous Mac irrelevant.
        connection = RemoteConnectionManager()
        macState = nil
        latencyMs = nil
        errorKey = nil
        infoKey = nil
        runningCommand = nil
        pendingLevel = nil
        isSendingLevel = false
        isRefreshingState = false
        hasEverConnected = false
        pendingMetrics = nil
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
        stopConnectSupervisor()
        startConnectSupervisor()
    }

    // MARK: - Pairing

    func submitPairCode(_ code: String) {
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

    // MARK: - Commands

    func perform(_ command: RemoteCommand) async {
        guard connectionState.isConnected else {
            errorKey = "errorNotPaired"
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
