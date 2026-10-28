import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network
import Testing

struct RemoteVideoTransportTests {
    @Test func reservationBlocksCompetingPacketsAndCanBeReleased() throws {
        let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
        let transport = RemoteVideoTransport(connection: connection, secret: Data(repeating: 1, count: 32), isServer: true)
        let reservation = try #require(transport.reserveSend())
        #expect(transport.reserveSend() == nil)
        #expect(!transport.send(RemoteVideoPacket(frameType: .diagnostics)))
        reservation.cancel()
        let next = try #require(transport.reserveSend())
        reservation.cancel()
        #expect(transport.reserveSend() == nil)
        next.cancel()
        #expect(transport.reserveSend() != nil)
        transport.cancel()
        #expect(transport.reserveSend() == nil)
    }
    @Test(.timeLimit(.minutes(1))) @MainActor
    func independentVideoSocketAuthenticatesAndRejectsAQueuedFrameBacklog() async throws {
        let harness = VideoSocketHarness()
        let result = try await harness.run()
        #expect(result.accepted == 1)
        #expect(result.received == Data(repeating: 65, count: 4096))
    }
}

private struct VideoSocketResult: Sendable {
    let accepted: Int
    let received: Data
}

@MainActor
private final class VideoSocketHarness {
    private var listener: NWListener?
    private var client: RemoteVideoTransport?
    private var server: RemoteVideoTransport?
    private var continuation: CheckedContinuation<VideoSocketResult, Error>?
    private var accepted: Int?
    private var received: Data?
    private let secret = Data(repeating: 17, count: 32)
    private var deadline: Task<Void, Never>?

    func run() async throws -> VideoSocketResult {
        let listener = try NWListener(using: RemoteVideoTransport.parameters(), on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state, let port = self.listener?.port { self.connect(port) }
                    if case .failed = state { self.fail() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: DispatchQueue(label: "com.misswell.macpilot.video.test.listener"))
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.fail()
            }
        }
    }

    private func connect(_ port: NWEndpoint.Port) {
        let client = RemoteVideoTransport(connection: NWConnection(host: "127.0.0.1", port: port,
            using: RemoteVideoTransport.parameters()), secret: secret, isServer: false)
        self.client = client
        client.onReady = { [weak client] in client?.send(RemoteVideoPacket(frameType: .hello)) }
        client.onPacket = { [weak self] packet in
            Task { @MainActor in self?.received = packet.payload; self?.finishIfReady() }
        }
        client.onFailure = { [weak self] in Task { @MainActor in self?.fail() } }
        client.start()
    }

    private func accept(_ connection: NWConnection) {
        let server = RemoteVideoTransport(connection: connection, secret: secret, isServer: true)
        self.server = server
        server.onPacket = { [weak self, weak server] packet in
            guard packet.frameType == .hello, let server else { return }
            // This loop is on the socket queue; no send completion can run
            // until it returns. Only the first reservation may succeed.
            var accepted = 0
            for _ in 0..<100 {
                if server.send(RemoteVideoPacket(frameType: .keyFrame, payload: Data(repeating: 65, count: 4096))) {
                    accepted += 1
                }
            }
            Task { @MainActor in self?.accepted = accepted; self?.finishIfReady() }
        }
        server.onFailure = { [weak self] in Task { @MainActor in self?.fail() } }
        server.start()
    }

    private func finishIfReady() {
        guard let accepted, let received, let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(returning: VideoSocketResult(accepted: accepted, received: received))
    }

    private func fail() {
        guard let continuation else { return }
        self.continuation = nil; stop()
        continuation.resume(throwing: RemoteProtocolError.invalidMessage)
    }

    private func stop() {
        deadline?.cancel(); deadline = nil
        listener?.cancel(); listener = nil
        client?.cancel(); server?.cancel()
        client = nil; server = nil
    }
}
