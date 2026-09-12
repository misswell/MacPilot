import Foundation
import MacPilotRemoteProtocol
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

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.misswell.macpilot.remote.ios.browser")

    func start() {
        guard browser == nil else { return }
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
            Task { @MainActor in self?.handleState(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        self.browser = browser
        browser.start(queue: queue)
        isBrowsing = true
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discovered = []
        unrecognizedServiceCount = 0
    }

    /// The online endpoint for a known Mac, if Bonjour currently sees it.
    func onlineEndpoint(for deviceID: UUID) -> DiscoveredMac? {
        discovered.first { $0.id == deviceID }
    }

    private func handleState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isBrowsing = true
            lastError = nil
            isPermissionDenied = false
        case .failed(let error):
            isBrowsing = false
            lastError = error.localizedDescription
            Self.log.error("browser failed: \(error.localizedDescription, privacy: .public)")
            if case let .dns(code) = error, code == -65555 {
                // kDNSServiceErr_PolicyDenied: the user declined Local Network.
                isPermissionDenied = true
            }
        case .cancelled:
            isBrowsing = false
        default:
            break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var macs: [DiscoveredMac] = []
        var unrecognized = 0
        for result in results {
            guard let mac = Self.makeMac(from: result) else {
                unrecognized += 1
                Self.log.error(
                    "unidentified Bonjour result hasTXT=\(Self.hasTXTRecord(result), privacy: .public)"
                )
                continue
            }
            macs.append(mac)
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
