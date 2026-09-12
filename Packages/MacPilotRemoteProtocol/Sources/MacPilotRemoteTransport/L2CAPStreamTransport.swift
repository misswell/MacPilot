import CoreBluetooth
import Foundation

/// A BLE L2CAP channel presented as a byte stream.
///
/// This is why BLE was cheap to add: `CoreBluetooth` hands back Foundation
/// streams, not packets, so the existing 4-byte framing and ChaChaPoly layer
/// sit on top of it unchanged. Only the link below differs.
@MainActor
public final class L2CAPStreamTransport: RemoteTransport {
    public let kind: RemoteTransportKind = .bluetooth

    public var onStateChange: (@MainActor (RemoteTransportState) -> Void)?
    public var onReceive: (@MainActor (Data) -> Void)?

    /// A BLE link has no address in the IP sense and no Bonjour name.
    public var linkDescription: String { "BLE" }
    public var remoteHost: String? { nil }
    public var remotePort: UInt16? { nil }
    public var remoteServiceName: String? { nil }

    private let pump: StreamPump
    private var didCancel = false

    public init(channel: CBL2CAPChannel) {
        self.pump = StreamPump(input: channel.inputStream, output: channel.outputStream)
    }

    /// The pump only ever needed a stream pair; `CBL2CAPChannel` is just how the
    /// pair arrives in production. This seam exists so the short-write and close
    /// paths can be driven from a test instead of only on a real device.
    init(input: InputStream, output: OutputStream) {
        self.pump = StreamPump(input: input, output: output)
    }

    public func start() {
        pump.onChunk = { data in
            Task { @MainActor [weak self] in self?.onReceive?(data) }
        }
        pump.onClosed = { reason in
            Task { @MainActor [weak self] in
                guard let self, !self.didCancel else { return }
                self.onStateChange?(reason.map { .failed($0) } ?? .closed)
            }
        }
        onStateChange?(.connecting)
        pump.start()
        // An L2CAP channel arrives already open, so there is no link-level
        // handshake to await; the wire handshake runs above this layer.
        onStateChange?(.ready)
    }

    public func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        guard !didCancel else {
            completion(RemoteTransportError.cancelled)
            return
        }
        pump.enqueue(data)
        completion(nil)
    }

    public func cancel() {
        guard !didCancel else { return }
        didCancel = true
        pump.stop()
    }
}

/// Drains a pair of `Stream`s off the main actor.
///
/// `CBL2CAPChannel` gives Foundation streams rather than an `NWConnection`, so
/// there is no delegate queue to piggyback on. A dedicated thread with a short
/// poll keeps the main actor free and avoids RunLoop plumbing; the payloads
/// here are a few hundred bytes, so the poll costs nothing measurable.
private final class StreamPump: @unchecked Sendable {
    private let input: InputStream
    private let output: OutputStream
    private let lock = NSLock()
    private var pending: [Data] = []
    private var stopped = false

    var onChunk: (@Sendable (Data) -> Void)?
    var onClosed: (@Sendable (String?) -> Void)?

    init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }

    func start() {
        input.open()
        output.open()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.misswell.macpilot.remote.transport.l2cap"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func enqueue(_ data: Data) {
        lock.lock()
        pending.append(data)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        input.close()
        output.close()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            var didWork = false

            if input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    onChunk?(Data(buffer[0..<count]))
                    didWork = true
                } else if count < 0 {
                    onClosed?(input.streamError?.localizedDescription ?? "read failed")
                    return
                }
            }

            if let next = peekPending(), output.hasSpaceAvailable {
                let written = next.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return output.write(base, maxLength: next.count)
                }
                if written > 0 {
                    consumePending(written, of: next)
                    didWork = true
                } else if written < 0 {
                    onClosed?(output.streamError?.localizedDescription ?? "write failed")
                    return
                }
            }

            if !didWork {
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    private func peekPending() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return pending.first
    }

    private func consumePending(_ written: Int, of chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let first = pending.first, first.count == chunk.count else { return }
        if written == first.count {
            pending.removeFirst()
        } else {
            pending[0] = first.dropFirst(written)
        }
    }
}
