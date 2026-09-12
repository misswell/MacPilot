import CoreBluetooth
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network

/// Publishes `_macpilot._tcp` over Bonjour and accepts the iPhone connections.
///
/// The listener prefers the fixed port 43847 and falls back to a dynamic port,
/// always advertising the real value through Bonjour so the iPhone never needs
/// an IP address or a port.
///
/// A BLE peripheral runs alongside it as a second, network-independent link.
@MainActor
final class RemoteControlServer: ObservableObject, RemoteConnectionHost {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var port: UInt16? {
            if case let .running(port) = self { return port }
            return nil
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var connectedDeviceNames: [String] = []
    @Published private(set) var lastError: String?

    let deviceStore: RemoteDeviceStore
    let pairingManager: RemotePairingManager
    let screenControl: MacScreenControlService

    /// Raised when a pairing code becomes visible so the app can show it.
    var onPairingCodePresented: (@MainActor (String, String) -> Void)?

    private var listener: NWListener?
    private var connections: [UUID: RemoteConnection] = [:]
    private var isUsingDynamicPort = false
    private let logHandler: (String) -> Void

    /// Second link, for when there is no usable network between the two
    /// machines. Deliberately independent of the Bonjour listener: it starts
    /// even when the listener fails, and it needs no port.
    private lazy var blePeripheral: RemoteBLEPeripheral = {
        let peripheral = RemoteBLEPeripheral()
        peripheral.onLog = { [weak self] message in self?.log(message) }
        peripheral.onChannel = { [weak self] channel in self?.accept(channel: channel) }
        return peripheral
    }()

    init(
        deviceStore: RemoteDeviceStore,
        screenControl: MacScreenControlService,
        pairingManager: RemotePairingManager? = nil,
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.deviceStore = deviceStore
        self.screenControl = screenControl
        self.logHandler = log
        self.pairingManager = pairingManager ?? RemotePairingManager(log: log)
        self.pairingManager.onCodePresented = { [weak self] code, name in
            self?.onPairingCodePresented?(code, name)
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        let text = message()
        logHandler(text)
    }

    var isRunning: Bool { status.isRunning }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        status = .starting
        lastError = nil
        _ = deviceStore.ensureDeviceIdentity()

        // Keepalive only catches a peer whose device vanished — the other end's
        // kernel answers probes even when its app is frozen. The application
        // heartbeat in `RemoteConnection` covers that case.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveCount = 3
        tcpOptions.keepaliveInterval = 5

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true

        do {
            let port = NWEndpoint.Port(rawValue: RemoteProtocolVersion.preferredPort)
            let listener = try makeListener(parameters: parameters, port: port)
            configure(listener)
            self.listener = listener
            listener.start(queue: RemoteConnection.queue)
        } catch {
            log("listener creation failed error=\(error.localizedDescription); retrying on a dynamic port")
            startWithDynamicPort(parameters: parameters)
        }

        blePeripheral.start()
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        blePeripheral.stop()
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        connectedDeviceNames = []
        pairingManager.closeWindow()
        status = .stopped
        log("server stopped")
    }

    /// Restarts the listener, e.g. after the advertised name changed.
    func restart() {
        stop()
        if deviceStore.settings.isEnabled { start() }
    }

    private func startWithDynamicPort(parameters: NWParameters) {
        isUsingDynamicPort = true
        do {
            let listener = try makeListener(parameters: parameters, port: nil)
            configure(listener)
            self.listener = listener
            listener.start(queue: RemoteConnection.queue)
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            log("listener failed error=\(error.localizedDescription)")
        }
    }

    private func makeListener(parameters: NWParameters, port: NWEndpoint.Port?) throws -> NWListener {
        let listener: NWListener
        if let port {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters)
        }
        let info = RemoteServiceInfo(
            deviceID: deviceStore.deviceID,
            name: deviceStore.deviceName,
            version: AppVersionInfo.current().version.description,
            capabilities: [.lock, .displayOff, .wake, .unlock]
        )
        listener.service = NWListener.Service(
            name: Self.bonjourName(from: info.name),
            type: RemoteProtocolVersion.bonjourServiceType,
            txtRecord: NWTXTRecord(info.txtRecord())
        )
        return listener
    }

    private func configure(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            status = .running(port: port)
            log("server started port=\(port) name=\(deviceStore.deviceName)")
        case .failed(let error):
            if case let .posix(code) = error, code == .EADDRINUSE, !isUsingDynamicPort {
                log("preferred port in use; falling back to a dynamic port")
                listener?.stateUpdateHandler = nil
                listener?.cancel()
                listener = nil
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = true
                parameters.allowLocalEndpointReuse = true
                startWithDynamicPort(parameters: parameters)
                return
            }
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            log("listener failed error=\(error.localizedDescription)")
        case .cancelled:
            if status.isRunning { status = .stopped }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let remote = RemoteConnection(connection: connection, host: self)
        connections[remote.id] = remote
        remote.start()
        log("incoming connection accepted active=\(connections.count)")
    }

    /// A BLE client arrives as an already open L2CAP channel. Everything above
    /// the transport is the same code the TCP clients run.
    private func accept(channel: CBL2CAPChannel) {
        let remote = RemoteConnection(transport: L2CAPStreamTransport(channel: channel), host: self)
        connections[remote.id] = remote
        remote.start()
        log("incoming BLE connection accepted active=\(connections.count)")
    }

    // MARK: - Bonjour name

    /// Bonjour service names are limited to 63 bytes; trim long Mac names.
    private static func bonjourName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "MacPilot" : trimmed
        guard name.utf8.count > 63 else { return name }
        var result = ""
        for character in name {
            if (result + String(character)).utf8.count > 60 { break }
            result.append(character)
        }
        return result.isEmpty ? "MacPilot" : result
    }

    // MARK: - RemoteConnectionHost

    func remoteConnection(
        _ connection: RemoteConnection,
        didAuthenticate clientID: String,
        name: String,
        address: String?
    ) {
        deviceStore.markConnected(clientID: clientID, address: address)
        refreshConnectedNames()
    }

    func remoteConnectionDidClose(_ connection: RemoteConnection) {
        connections.removeValue(forKey: connection.id)
        pairingManager.cancel(connectionID: connection.id)
        refreshConnectedNames()
        log("connection closed active=\(connections.count)")
    }

    func remoteLog(_ message: String) {
        log(message)
    }

    private func refreshConnectedNames() {
        connectedDeviceNames = connections.values
            .filter(\.isAuthenticated)
            .compactMap(\.authenticatedClientName)
    }
}
