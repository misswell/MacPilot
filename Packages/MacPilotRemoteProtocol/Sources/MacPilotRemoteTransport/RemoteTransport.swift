import Foundation
import MacPilotRemoteProtocol

/// Which physical link carries a connection.
///
/// This is deliberately coarse: the wire protocol, framing and crypto are
/// identical on both, so nothing above this layer should branch on it except
/// diagnostics and the connect preference order.
public enum RemoteTransportKind: String, Sendable, CaseIterable {
    /// TCP — Bonjour or a remembered address, over Wi-Fi, Ethernet or AWDL.
    case network
    /// BLE L2CAP, a stream-oriented channel that needs no network at all.
    case bluetooth

    public var displayName: String {
        switch self {
        case .network: "网络"
        case .bluetooth: "蓝牙"
        }
    }
}

/// Link-level state, normalised across transports.
///
/// `Network.framework` and `CoreBluetooth` have quite different vocabularies;
/// mapping both onto these five cases is what lets one connection state machine
/// serve either link.
public enum RemoteTransportState: Equatable, Sendable {
    case connecting
    case ready
    /// Transient: the link is up but cannot currently carry data.
    case waiting(String)
    case failed(String)
    /// The link ended, either because the peer closed it or because it broke.
    case closed
}

/// One framed byte stream to the peer, whatever the link underneath.
///
/// Implementations deliver callbacks on the main actor; the connection layer
/// owns framing, crypto and the handshake and is unaware of TCP versus BLE.
@MainActor
public protocol RemoteTransport: AnyObject {
    var kind: RemoteTransportKind { get }

    /// Which link is actually carrying this connection, for diagnostics — the
    /// interface name (`en0`, `awdl0`) on a network link, `BLE` on Bluetooth.
    /// A link-local address carries its interface as a scope suffix, which is
    /// how the phone can tell Wi-Fi from peer-to-peer Wi-Fi.
    var linkDescription: String { get }

    var onStateChange: (@MainActor (RemoteTransportState) -> Void)? { get set }
    var onReceive: (@MainActor (Data) -> Void)? { get set }

    /// Peer address, when the link has one. Bluetooth links report nothing.
    var remoteHost: String? { get }
    var remotePort: UInt16? { get }
    var remoteServiceName: String? { get }

    func start()
    func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void)
    func cancel()
}

/// Shared helper for the scope suffix on a link-local address, e.g.
/// `fe80::cb5:90ee:a4af:3f3d%en0` — the only reliable way to learn which
/// interface a connection actually left through.
public enum RemoteInterfaceName {
    public static func scope(of address: String) -> String? {
        guard let percent = address.lastIndex(of: "%") else { return nil }
        let scope = address[address.index(after: percent)...]
        return scope.isEmpty ? nil : String(scope)
    }
}
