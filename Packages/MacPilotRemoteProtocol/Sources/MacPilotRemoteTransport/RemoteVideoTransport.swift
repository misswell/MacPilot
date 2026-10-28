import Foundation
import MacPilotRemoteProtocol
import Network

/// One bounded encrypted video socket. No callbacks enter the control queue.
/// Mutable socket/codec state belongs to queue; the lock only reserves the
/// single send slot before scheduling work, preventing an async backlog.
public final class RemoteVideoTransport: @unchecked Sendable {
    public let queue = DispatchQueue(label: "com.misswell.macpilot.video.network", qos: .utility)
    private let connection: NWConnection
    private var sender: RemoteVideoCodec
    private var receiver: RemoteVideoCodec
    private var buffer = Data()
    private var sendCounter: UInt64 = 0
    private var activeSend: UInt64?
    private let lock = NSLock()
    private var busy = false
    private var closed = false
    private var reservationID: UInt64?
    private var nextReservationID: UInt64 = 0
    public var onReady: (@Sendable () -> Void)?
    public var onPacket: (@Sendable (RemoteVideoPacket) -> Void)?
    public var onFailure: (@Sendable () -> Void)?
    public var onSendCompleted: (@Sendable (Double) -> Void)?

    public init(connection: NWConnection, secret: Data, isServer: Bool) {
        self.connection = connection
        sender = RemoteVideoCodec(secret: secret, serverToClient: isServer)
        receiver = RemoteVideoCodec(secret: secret, serverToClient: !isServer)
    }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed, .cancelled: self.fail()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public final class SendReservation: @unchecked Sendable {
        fileprivate weak var transport: RemoteVideoTransport?
        fileprivate let id: UInt64
        fileprivate init(transport: RemoteVideoTransport, id: UInt64) { self.transport = transport; self.id = id }
        public func cancel() { transport?.releaseReservation(id) }
        deinit { cancel() }
    }

    public func reserveSend() -> SendReservation? {
        lock.withLock {
            guard !closed, !busy else { return nil }
            busy = true
            nextReservationID &+= 1
            reservationID = nextReservationID
            return SendReservation(transport: self, id: nextReservationID)
        }
    }

    private func releaseReservation(_ id: UInt64) {
        lock.withLock {
            guard reservationID == id else { return }
            reservationID = nil
            busy = false
        }
    }

    /// False means congestion, never "queued for later". An encoder that
    /// drops a reference frame must force an IDR before resuming.
    @discardableResult
    public func send(_ packet: RemoteVideoPacket) -> Bool {
        guard let reservation = reserveSend() else { return false }
        return send(packet, using: reservation)
    }

    @discardableResult
    public func send(_ packet: RemoteVideoPacket, using reservation: SendReservation) -> Bool {
        let accepted = lock.withLock {
            guard !closed, reservation.transport === self, reservationID == reservation.id else { return false }
            reservationID = nil
            return true
        }
        guard accepted else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.lock.withLock({ self.closed }) else { return }
            do {
                let data = try self.sender.encode(packet)
                let start = ProcessInfo.processInfo.systemUptime
                self.sendCounter += 1
                let sendID = self.sendCounter
                self.activeSend = sendID
                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.activeSend == sendID else { return }
                    self.fail()
                }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.activeSend = nil
                    self.lock.withLock { self.busy = false }
                    if error != nil { self.fail() }
                    else { self.onSendCompleted?((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                })
            } catch { self.fail() }
        }
        return true
    }

    public func cancel() {
        lock.withLock { closed = true; reservationID = nil; busy = false }
        connection.cancel()
    }

    private func fail() {
        let notify = lock.withLock {
            guard !closed else { return false }
            closed = true
            reservationID = nil
            busy = false
            return true
        }
        connection.cancel()
        if notify { onFailure?() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            if let data {
                self.buffer.append(data)
                do {
                    let frames = try RemoteVideoCodec.extractFrames(from: &self.buffer)
                    for frame in frames { self.onPacket?(try self.receiver.decode(frame)) }
                } catch { self.fail(); return }
            }
            if done || error != nil { self.fail() }
            else if !self.lock.withLock({ self.closed }) { self.receive() }
        }
    }
}
