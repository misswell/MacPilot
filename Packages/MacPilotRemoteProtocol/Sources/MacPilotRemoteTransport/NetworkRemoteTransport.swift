import Foundation
import Network

/// A TCP link: infrastructure Wi-Fi or Ethernet, or peer-to-peer Wi-Fi (AWDL)
/// when the endpoint resolves to an Apple peer-to-peer path.
///
/// This is shared by both apps so an outbound phone connection and an inbound
/// Mac connection cannot disagree about how the link behaves.
@MainActor
public final class NetworkRemoteTransport: RemoteTransport {
    public let kind: RemoteTransportKind = .network

    public var onStateChange: (@MainActor (RemoteTransportState) -> Void)?
    public var onReceive: (@MainActor (Data) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var didCancel = false

    /// Outbound: dial a Bonjour service or a remembered host/port.
    public convenience init(to endpoint: NWEndpoint, queue: DispatchQueue? = nil) {
        let parameters = NWParameters.tcp
        // Peer-to-peer only helps when Bonjour handed us a service to resolve;
        // a raw host/port fast path stays plain TCP.
        if case .service = endpoint {
            parameters.includePeerToPeer = true
        }
        self.init(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
    }

    /// Inbound: adopt a connection a listener already accepted.
    public init(connection: NWConnection, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.queue = queue ?? DispatchQueue(label: "com.misswell.macpilot.remote.transport.network")
    }    // MARK: - Diagnostics

    public var linkDescription: String {
        guard let local = connection.currentPath?.localEndpoint else { return kind.displayName }
        guard case let .hostPort(host, _) = local else { return kind.displayName }
        let text = "\(host)"
        // A link-local address carries its interface as a scope suffix; that is
        // the interface the connection actually left through.
        return RemoteInterfaceName.scope(of: text) ?? text
    }

    /// The resolved peer once the path exists; before that the endpoint we are
    /// still dialling (an accepted connection already knows its peer).
    private var peerEndpoint: NWEndpoint? {
        connection.currentPath?.remoteEndpoint ?? connection.endpoint
    }

    public var remoteHost: String? {
        guard let peer = peerEndpoint, case let .hostPort(host, _) = peer else { return nil }
        return "\(host)"
    }

    public var remotePort: UInt16? {
        guard let peer = peerEndpoint, case let .hostPort(_, port) = peer else { return nil }
        return port.rawValue
    }

    public var remoteServiceName: String? {
        guard case let .service(name, _, _, _) = connection.endpoint else { return nil }
        return name
    }

    // MARK: - Lifecycle

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        connection.start(queue: queue)
        receive()
    }

    public func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        guard !didCancel else {
            completion(RemoteTransportError.cancelled)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            Task { @MainActor in completion(error) }
        })
    }

    public func cancel() {
        guard !didCancel else { return }
        didCancel = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - Internals

    private func handle(_ state: NWConnection.State) {
        guard !didCancel else { return }
        switch state {
        case .setup:
            onStateChange?(.connecting)
        case .preparing:
            onStateChange?(.connecting)
        case .ready:
            onStateChange?(.ready)
        case let .waiting(error):
            onStateChange?(.waiting(error.localizedDescription))
        case let .failed(error):
            onStateChange?(.failed(error.localizedDescription))
        case .cancelled:
            onStateChange?(.closed)
        @unknown default:
            onStateChange?(.failed("unknown"))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.didCancel else { return }
                if let error {
                    self.onStateChange?(.failed(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    self.onReceive?(data)
                }
                if isComplete {
                    self.onStateChange?(.closed)
                    return
                }
                self.receive()
            }
        }
    }
}

public enum RemoteTransportError: LocalizedError {
    case cancelled
    case cannotOpenStream
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .cancelled: "cancelled"
        case .cannotOpenStream: "cannot open stream"
        case .notConnected: "not connected"
        }
    }
}
