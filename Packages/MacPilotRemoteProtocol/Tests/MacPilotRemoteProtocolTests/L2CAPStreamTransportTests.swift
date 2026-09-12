import CoreFoundation
import Foundation
import Testing

@testable import MacPilotRemoteTransport

/// `L2CAPStreamTransport` drains its channel on a dedicated thread because
/// `CBL2CAPChannel` hands back Foundation streams rather than an `NWConnection`.
/// That means the read loop, the write loop and the short-write bookkeeping are
/// hand-written, and none of it runs in a unit test unless a stream pair is
/// supplied by hand — hence the internal initialiser these tests use.
///
/// A `CFStreamCreateBoundPair` is a loopback: whatever the pump writes to its
/// output stream reappears on its input stream. One test therefore covers the
/// send path and the receive path together.
@Suite("L2CAP stream transport")
struct L2CAPStreamTransportTests {
    // MARK: - Helpers

    /// A loopback stream pair. A deliberately small buffer makes the pump's
    /// writes come back short, which is the case worth exercising.
    private static func makeLoopbackStreams(bufferSize: Int) -> (input: InputStream, output: OutputStream) {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreateBoundPair(nil, &readStream, &writeStream, CFIndex(bufferSize))
        let input = readStream!.takeRetainedValue() as InputStream
        let output = writeStream!.takeRetainedValue() as OutputStream
        return (input, output)
    }

    private static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    /// The pump is a thread with a 4 ms poll, so delivery is asynchronous by
    /// nature. This yields the main actor so the delivery hops can run.
    @MainActor
    private static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    private final class Recorder {
        var chunks: [Data] = []
        var states: [RemoteTransportState] = []
        var concatenated: Data { chunks.reduce(into: Data()) { $0.append($1) } }
    }

    // MARK: - Tests

    @MainActor
    @Test("ready waits for both streams to finish opening")
    func startWaitsForStreamOpen() async {
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 1024)
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onStateChange = { recorder.states.append($0) }

        transport.start()

        #expect(recorder.states == [.connecting])
        let opened = await Self.waitUntil { recorder.states.contains(.ready) }
        #expect(opened)
        #expect(recorder.states == [.connecting, .ready])
        if case .connecting = recorder.states.first {} else {
            Issue.record("first state was \(String(describing: recorder.states.first))")
        }
        if case .ready = recorder.states.last {} else {
            Issue.record("last state was \(String(describing: recorder.states.last))")
        }
        transport.cancel()
    }

    @MainActor
    @Test("an empty send does not prevent later bytes from being sent")
    func emptySendDoesNotBlockQueue() async {
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 16)
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onReceive = { recorder.chunks.append($0) }
        transport.start()
        transport.send(Data()) { _ in }
        transport.send(Data([1, 2, 3])) { _ in }
        let arrived = await Self.waitUntil { recorder.concatenated.count == 3 }
        #expect(arrived)
        #expect(recorder.concatenated == Data([1, 2, 3]))
        transport.cancel()
    }

    @MainActor
    @Test("repeated start does not open another pump or repeat ready")
    func repeatedStartIsIgnored() async {
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 16)
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onStateChange = { recorder.states.append($0) }
        transport.start()
        transport.start()
        let opened = await Self.waitUntil { recorder.states.contains(.ready) }
        #expect(opened)
        #expect(recorder.states == [.connecting, .ready])
        transport.cancel()
    }

    @MainActor
    @Test("a stream open failure never reports ready and preserves the error")
    func openingFailureIsNotReady() async {
        let input = InputStream(data: Data([1]))
        let output = OutputStream(toFileAtPath: "/missing-\(UUID())/output", append: false)!
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onStateChange = { recorder.states.append($0) }
        transport.start()
        let failed = await Self.waitUntil {
            recorder.states.contains { if case .failed = $0 { true } else { false } }
        }
        #expect(failed)
        #expect(!recorder.states.contains(.ready))
        #expect(recorder.states.contains {
            if case .failed(let message) = $0 { message.contains("NSPOSIXErrorDomain") } else { false }
        })
        transport.cancel()
    }

    @MainActor
    @Test("a payload survives a channel whose writes come back short")
    func shortWritesDoNotLoseOrReorderBytes() async {
        // A 16-byte loopback buffer guarantees the pump cannot hand the whole
        // payload over in one write, so the remainder has to be carried across
        // several passes without being dropped or duplicated.
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 16)
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onReceive = { recorder.chunks.append($0) }

        transport.start()
        let sent = Self.payload(400)
        transport.send(sent) { _ in }

        let arrived = await Self.waitUntil { recorder.concatenated.count >= sent.count }
        #expect(arrived, "only \(recorder.concatenated.count) of \(sent.count) bytes came back")
        #expect(recorder.concatenated == sent)
        // Self-check: if the loopback buffer were ignored, the whole payload
        // would arrive as one chunk and this test would pass without ever
        // exercising the short-write path it exists for.
        #expect(recorder.chunks.count > 1, "payload arrived in one piece; short writes were never exercised")
        transport.cancel()
    }

    @MainActor
    @Test("back to back sends arrive in the order they were queued")
    func sendsKeepTheirOrder() async {
        // A small loopback buffer keeps the pump delivering in several passes
        // instead of swallowing everything in one read.
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 16)
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onReceive = { recorder.chunks.append($0) }

        transport.start()
        // One byte per queued chunk: order is what matters, not chunking, since
        // a stream is allowed to coalesce.
        let expected = Data((0..<64).map { UInt8($0) })
        for byte in expected {
            transport.send(Data([byte])) { _ in }
        }

        let arrived = await Self.waitUntil { recorder.concatenated.count >= expected.count }
        #expect(arrived, "only \(recorder.concatenated.count) of \(expected.count) bytes came back")
        #expect(recorder.concatenated == expected)
        #expect(recorder.chunks.count > 1, "everything arrived in one chunk; ordering was never under pressure")
        transport.cancel()
    }

    @MainActor
    @Test("sending after cancel fails instead of silently queueing")
    func sendAfterCancelReportsCancelled() {
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 1024)
        let transport = L2CAPStreamTransport(input: input, output: output)
        transport.start()
        transport.cancel()

        var reported: Error?
        transport.send(Data([1])) { reported = $0 }
        #expect(reported is RemoteTransportError)
        // Cancelling twice is a no-op rather than a second teardown.
        transport.cancel()
    }

    @MainActor
    @Test("cancel stops delivery and does not report a close")
    func cancelIsSilent() async {
        let (input, output) = Self.makeLoopbackStreams(bufferSize: 1024)
        let transport = L2CAPStreamTransport(input: input, output: output)
        let recorder = Recorder()
        transport.onReceive = { recorder.chunks.append($0) }
        transport.onStateChange = { recorder.states.append($0) }

        transport.start()
        transport.send(Data([9, 9, 9])) { _ in }
        _ = await Self.waitUntil { !recorder.chunks.isEmpty }
        transport.cancel()

        // Closing our own side is deliberate, so it must not surface as a
        // failure the reconnect logic would act on.
        try? await Task.sleep(for: .milliseconds(120))
        // Guard against a vacuous pass: cancel must not have suppressed the
        // two states `start()` reports.
        #expect(recorder.states.count >= 2)
        #expect(recorder.states.allSatisfy {
            if case .failed = $0 { return false }
            return true
        })
    }
}
