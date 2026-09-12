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
    public var onDiagnostic: (@MainActor (String) -> Void)?

    /// A BLE link has no address in the IP sense and no Bonjour name.
    public var linkDescription: String { "BLE" }
    public var remoteHost: String? { nil }
    public var remotePort: UInt16? { nil }
    public var remoteServiceName: String? { nil }

    private let pump: StreamPump
    /// Retain the channel for the full transport lifetime. The pump also holds
    /// it until its asynchronous stream teardown completes.
    private let channel: CBL2CAPChannel?
    private var didCancel = false
    private var didStart = false
    private var didFinish = false

    public init(channel: CBL2CAPChannel) {
        self.channel = channel
        self.pump = StreamPump(input: channel.inputStream, output: channel.outputStream, owner: channel)
    }

    /// The pump only ever needed a stream pair; `CBL2CAPChannel` is just how the
    /// pair arrives in production. This seam exists so the short-write and close
    /// paths can be driven from a test instead of only on a real device.
    init(input: InputStream, output: OutputStream) {
        self.channel = nil
        self.pump = StreamPump(input: input, output: output)
    }

    public func start() {
        guard !didStart, !didCancel else { return }
        didStart = true
        pump.onChunk = { data in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didCancel, !self.didFinish else { return }
                self.onReceive?(data)
            }
        }
        pump.onReady = {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didCancel, !self.didFinish else { return }
                self.onStateChange?(.ready)
            }
        }
        pump.onDiagnostic = { message in
            DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(message) }
        }
        pump.onClosed = { reason in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didCancel else { return }
                self.didFinish = true
                self.onStateChange?(reason.map { .failed($0) } ?? .closed)
            }
        }
        onStateChange?(.connecting)
        pump.start()
    }

    public func send(_ data: Data, completion: @escaping @MainActor (Error?) -> Void) {
        guard !didCancel, !didFinish else {
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

    deinit { pump.stop() }
}

/// Drains a pair of `Stream`s on a thread that owns their run loop.
///
/// `CBL2CAPChannel` gives Foundation streams rather than an `NWConnection`, so
/// there is no delegate queue to piggyback on, and the streams carry one hard
/// requirement: they must be scheduled on, opened on and used from a single
/// thread that is running its run loop.
///
/// The pump also owns teardown. A timer flushes bytes queued after the last
/// space-available event, without accessing streams from the calling actor.
private final class StreamPump: NSObject, @unchecked Sendable, StreamDelegate {
    private let input: InputStream
    private let output: OutputStream
    // The pump can outlive its transport while its thread finishes closing.
    // Keep the channel alive until that teardown has completed as well.
    private let owner: AnyObject?
    private let lock = NSLock()
    private var pending: [Data] = []
    private var stopped = false
    private var inputOpened = false
    private var outputOpened = false
    private var reportedReady = false
    private var receivedBytes = 0
    private var sentBytes = 0

    /// How often a queued write is retried when no stream event arrives.
    /// Only a fallback link pays this, and only while it is up.
    private let flushInterval: TimeInterval = 0.1

    var onChunk: (@Sendable (Data) -> Void)?
    var onClosed: (@Sendable (String?) -> Void)?
    var onReady: (@Sendable () -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?

    init(input: InputStream, output: OutputStream, owner: AnyObject? = nil) {
        self.input = input
        self.output = output
        self.owner = owner
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.misswell.macpilot.remote.transport.l2cap"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func enqueue(_ data: Data) {
        // Only touches the queue: the streams belong to the pump thread.
        lock.lock()
        pending.append(data)
        lock.unlock()
    }

    func stop() {
        // The thread that opened the streams is the one that closes them; the
        // bounded run loop wait picks this up promptly.
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        guard !isStopped else { return }
        onDiagnostic?("L2CAP pump opening streams")
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        if input.streamStatus == .error || output.streamStatus == .error {
            finish("stream open failed; \(snapshot())")
        }
        let openingDeadline = Date().addingTimeInterval(5)

        let tick = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.writePending()
        }
        RunLoop.current.add(tick, forMode: .default)

        // Stream events drive the link; the bounded wait only exists so a stop
        // request is noticed without depending on traffic.
        while !isStopped {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
            if !reportedReady, Date() >= openingDeadline {
                finish("stream open timed out; \(snapshot())")
            }
        }

        tick.invalidate()
        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
        input.delegate = nil
        output.delegate = nil
        withExtendedLifetime(owner) {}
        onDiagnostic?("L2CAP pump closed rx=\(receivedBytes) tx=\(sentBytes)")
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard !isStopped else { return }
        switch eventCode {
        case .openCompleted:
            if aStream === input { inputOpened = true }
            if aStream === output { outputOpened = true }
            onDiagnostic?("L2CAP \(aStream === input ? "input" : "output") openCompleted; \(snapshot())")
            if inputOpened, outputOpened, !reportedReady {
                reportedReady = true
                onReady?()
            }
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            writePending()
        case .endEncountered:
            finish(aStream.streamError.map { describe($0) })
        case .errorOccurred:
            finish("stream error; \(snapshot())")
        default:
            break
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped, input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                receivedBytes += count
                onDiagnostic?("L2CAP read=\(count) rx=\(receivedBytes)")
                onChunk?(Data(buffer[0..<count]))
            } else if count < 0 {
                finish("read=-1; \(snapshot())")
                return
            } else {
                finish(nil)
                return
            }
        }
    }

    private func writePending() {
        guard outputOpened else { return }
        while !isStopped, output.hasSpaceAvailable, let next = peekPending() {
            if next.isEmpty {
                consumePending(0, of: next)
                continue
            }
            let written = next.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: next.count)
            }
            if written > 0 {
                sentBytes += written
                onDiagnostic?("L2CAP wrote=\(written) tx=\(sentBytes)")
                consumePending(written, of: next)
            } else if written < 0 {
                finish("write=-1; \(snapshot())")
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
        onDiagnostic?("L2CAP ended: \(reason ?? "EOF") rx=\(receivedBytes) tx=\(sentBytes)")
        onClosed?(reason)
    }

    private func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain)/\(error.code): \(error.localizedDescription)"
    }

    private func snapshot() -> String {
        "in=\(input.streamStatus.rawValue) error=\(input.streamError.map(describe) ?? "none") "
            + "out=\(output.streamStatus.rawValue) error=\(output.streamError.map(describe) ?? "none")"
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
