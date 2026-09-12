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

/// Drains a pair of `Stream`s on a thread that owns their run loop.
///
/// `CBL2CAPChannel` gives Foundation streams rather than an `NWConnection`, so
/// there is no delegate queue to piggyback on, and the streams carry one hard
/// requirement: they must be scheduled on, opened on and used from a single
/// thread that is running its run loop.
///
/// Opening them on the caller's thread and polling them from another one fails
/// on a real L2CAP channel with "bad file descriptor" — the channel is reported
/// ready and then errors out before a single byte moves. That is invisible to
/// the unit tests, because the bound-pair streams they use tolerate it.
///
/// So the pump owns its thread end to end: it schedules and opens both streams
/// there, drives reads and writes from `StreamDelegate` events, and marshals the
/// one call that arrives from outside — `enqueue` — onto the same thread.
private final class StreamPump: NSObject, @unchecked Sendable, StreamDelegate {
    private let input: InputStream
    private let output: OutputStream
    private let lock = NSLock()
    private var pending: [Data] = []
    private var stopped = false
    private weak var thread: Thread?

    var onChunk: (@Sendable (Data) -> Void)?
    var onClosed: (@Sendable (String?) -> Void)?

    init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.misswell.macpilot.remote.transport.l2cap"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    func enqueue(_ data: Data) {
        lock.lock()
        pending.append(data)
        lock.unlock()
        // Touching the streams from here would break the single-thread rule, so
        // hand the write to the run loop that owns them.
        if let thread {
            perform(#selector(writePending), on: thread, with: nil, waitUntilDone: false)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        // The streams are closed by the thread that opened them.
        if let thread {
            perform(#selector(shutDown), on: thread, with: nil, waitUntilDone: false)
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()

        // The run loop delivers the stream events; the bounded wait only exists
        // so a stop request is noticed promptly.
        while !isStopped {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        }
        input.close()
        output.close()
    }

    @objc private func shutDown() {
        // Nothing to do beyond the loop noticing: this runs on the pump thread,
        // which is what makes the close legal.
        _ = isStopped
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            writePending()
        case .endEncountered:
            finish(aStream.streamError?.localizedDescription)
        case .errorOccurred:
            finish(aStream.streamError?.localizedDescription ?? "stream error")
        default:
            break
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped, input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                onChunk?(Data(buffer[0..<count]))
            } else if count < 0 {
                finish(input.streamError?.localizedDescription ?? "read failed")
                return
            } else {
                break
            }
        }
    }

    @objc private func writePending() {
        while !isStopped, output.hasSpaceAvailable, let next = peekPending() {
            let written = next.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: next.count)
            }
            if written > 0 {
                consumePending(written, of: next)
            } else if written < 0 {
                finish(output.streamError?.localizedDescription ?? "write failed")
                return
            } else {
                break
            }
        }
    }

    private func finish(_ reason: String?) {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        onClosed?(reason)
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
