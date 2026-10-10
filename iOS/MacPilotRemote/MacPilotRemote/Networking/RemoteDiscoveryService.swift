import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network
import OSLog

/// Browses `_macpilot._tcp` on the local network and publishes the Macs it
/// finds. It never scans IP ranges and never asks the user for an address.
@MainActor
final class RemoteDiscoveryService: ObservableObject {
    @Published private(set) var discovered: [DiscoveredMac] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var lastError: String?
    /// Set when iOS refused the browse because Local Network access is denied.
    @Published private(set) var isPermissionDenied = false
    /// Bonjour returned these services but their TXT record was missing or
    /// unreadable, so they carry no device identity. This is tracked separately
    /// because dropping such results silently makes a broken browse look
    /// exactly like an empty network.
    @Published private(set) var unrecognizedServiceCount = 0

    private static let log = Logger(
        subsystem: "com.misswell.macpilot.remote",
        category: "discovery"
    )

    /// Raised whenever the visible Mac list changes.
    var onResultsChanged: (@MainActor ([DiscoveredMac]) -> Void)?
    /// State changes can arrive without results (notably PolicyDenied).
    var onStateChanged: (@MainActor () -> Void)?
    var onDiagnostic: (@MainActor (String) -> Void)?

    private var networkPaths: [UUID: [(method: RemoteConnectionMethod, endpoint: NWEndpoint)]] = [:]

    func endpoints(for deviceID: UUID) -> [(method: RemoteConnectionMethod, endpoint: NWEndpoint)] {
        networkPaths[deviceID] ?? []
    }

    private var browser: NWBrowser?
    /// Whether the current browser last reported itself usable. iOS tears down
    /// the DNS-SD session behind the browser while the app is suspended, so a
    /// browser carried across a background/foreground turn reports failed or
    /// simply stops delivering results; it must be recreated, never reused.
    private var isBrowserUsable = false
    private var browseGeneration = 0
    private let queue = DispatchQueue(label: "com.misswell.macpilot.remote.ios.browser")

    func start() {
        if let browser {
            if isBrowserUsable {
                // Still browsing; results arrive as changes.
                return
            }
            // A browser that reported failed would otherwise block every later
            // start() forever; recreate it.
            browser.cancel()
            self.browser = nil
        }
        browseGeneration += 1
        let generation = browseGeneration
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        // `bonjourWithTXTRecord` is mandatory here. The plain `.bonjour`
        // descriptor browses without TXT records, so every result arrives with
        // `metadata == .none`, carries no device identity, and gets filtered out.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: RemoteProtocolVersion.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.browseGeneration == generation else { return }
                self.handleState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browseGeneration == generation else { return }
                self.handle(results)
            }
        }
        self.browser = browser
        // Optimistic until the state handler reports otherwise: a browser that
        // is still preparing must not be churned by a concurrent start().
        isBrowserUsable = true
        browser.start(queue: queue)
        isBrowsing = true
    }

    /// Recreates the browse from scratch. Called when the app returns to the
    /// foreground: the suspended browser cannot be trusted to re-deliver its
    /// results, and every dial raced against its stale endpoints would keep
    /// failing even though the Mac is reachable.
    func restart() {
        stop()
        start()
    }

    func stop() {
        browseGeneration += 1
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        isBrowsing = false
        lastError = nil
        isPermissionDenied = false
        discovered = []
        networkPaths = [:]
        unrecognizedServiceCount = 0
        onStateChanged?()
    }

    /// The online endpoint for a known Mac, if Bonjour currently sees it.
    func onlineEndpoint(for deviceID: UUID) -> DiscoveredMac? {
        discovered.first { $0.id == deviceID }
    }

    // Internal so the real delegate adapter can be exercised without starting
    // a browser or requiring access to a physical Wi-Fi interface.
    func handleState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isBrowserUsable = true
            isBrowsing = true
            lastError = nil
            isPermissionDenied = false
            onDiagnostic?("Bonjour/AWDL browser ready")
        case .waiting(let error):
            // Waiting is recoverable: keep this browser alive so granting
            // permission or restoring an interface can take it back to ready.
            isBrowserUsable = true
            isBrowsing = true
            record(error, state: "waiting")
        case .failed(let error):
            isBrowserUsable = false
            isBrowsing = false
            record(error, state: "failed")
        case .cancelled:
            isBrowserUsable = false
            isBrowsing = false
        default:
            break
        }
        onStateChanged?()
    }

    private func record(_ error: NWError, state: String) {
        lastError = error.localizedDescription
        if case .dns(-65570) = error {
            // kDNSServiceErr_PolicyDenied. -65555 is NoAuth, not PolicyDenied.
            isPermissionDenied = true
        } else {
            isPermissionDenied = false
        }
        let message = "Bonjour/AWDL browser \(state): \(error)"
        Self.log.error("\(message, privacy: .public)")
        onDiagnostic?(message)
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var macs: [DiscoveredMac] = []
        networkPaths = [:]
        var unrecognized = 0
        for result in results {
            guard let mac = Self.makeMac(from: result) else {
                unrecognized += 1
                Self.log.error(
                    "unidentified Bonjour result hasTXT=\(Self.hasTXTRecord(result), privacy: .public)"
                )
                continue
            }
            if !macs.contains(where: { $0.id == mac.id }) { macs.append(mac) }
            if case let .service(name, type, domain, _) = result.endpoint {
                if result.interfaces.isEmpty {
                    networkPaths[mac.id, default: []].append((.localNetwork, result.endpoint))
                }
                for interface in result.interfaces {
                    let method: RemoteConnectionMethod = interface.name.hasPrefix("awdl") ? .awdl : .localNetwork
                    let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                    networkPaths[mac.id, default: []].append((method, endpoint))
                }
            }
        }
        macs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        unrecognizedServiceCount = unrecognized
        if macs.map(\.id) != discovered.map(\.id) {
            Self.log.info("discovered \(macs.count, privacy: .public) mac(s)")
        }
        discovered = macs
        onResultsChanged?(macs)
    }

    private static func hasTXTRecord(_ result: NWBrowser.Result) -> Bool {
        if case .bonjour = result.metadata { return true }
        return false
    }

    /// The TXT record is the source of truth for identity: names and IPs move,
    /// the permanent device UUID does not.
    private static func makeMac(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        }
        guard let info = RemoteServiceInfo(txtRecord: txt) else { return nil }
        return DiscoveredMac(
            id: info.deviceID,
            name: info.name,
            endpoint: result.endpoint,
            serviceName: name,
            version: info.version,
            protocolVersion: info.protocolVersion,
            capabilities: info.capabilities
        )
    }
}
