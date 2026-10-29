import Foundation
import MacPilotDisplayControlCore
import Testing
@testable import MacPilot

@MainActor
struct DisplayRecoveryClientTests {
    @Test func missingServiceReturnsUnavailableAndModelSurfacesHelperError() async {
        let client = missingServiceClient()
        var failure: Error?
        do {
            _ = try await client.send(.init(command: .status))
        } catch {
            failure = error
        }

        #expect(failure.map(isUnavailable) == true)

        let model = DisplayControlModel(
            client: client,
            monitor: UUSessionMonitor(read: { .init(status: .disconnected) }),
            showsConfirmation: false,
            prepareVisibleOutputs: { true },
            controlStateChanged: { _ in }
        )
        await model.refresh()
        #expect(model.errorKey == "displayHelperUnavailable")

        model.applyLoadedSettings(.init())
        model.setEnabled(true)
        model.start()
        #expect(await waitUntil { model.errorKey == "displayHelperUnavailable" })
        #expect(model.isRunning)
        model.stop()
        #expect(!model.isRunning)
    }

    @Test func anonymousListenerRepliesAcrossRealXPCFromBackgroundQueue() async throws {
        let server = AnonymousDisplayRecoveryServer(mode: .reply(delay: 0.01))
        defer { server.stop() }
        let client = clientConnected(to: server, timeout: .seconds(2))

        let response = try await client.send(.init(command: .status))

        #expect(response.state == .idle)
        #expect(response.helperReady)
        #expect(await server.waitForRequest())
    }

    @Test func timeoutWinsAgainstLateXPCReplyWithoutResumingTwice() async {
        let server = AnonymousDisplayRecoveryServer(mode: .hold)
        defer { server.stop() }
        let client = clientConnected(to: server, timeout: .milliseconds(40))

        var failure: Error?
        do {
            _ = try await client.send(.init(command: .status))
        } catch {
            failure = error
        }

        #expect(failure.map(isTimeout) == true)
        #expect(await server.waitForRequest())
        #expect(server.releaseHeldReply())
        try? await Task.sleep(for: .milliseconds(40))
        #expect(server.replyCount == 1)
    }

    @Test func invalidationRacingTheXPCReplyCompletesOnlyOnce() async {
        let server = AnonymousDisplayRecoveryServer(mode: .replyAndInvalidate(delay: 0.04))
        defer { server.stop() }
        let client = clientConnected(to: server, timeout: .seconds(2))

        var response: DisplayControlResponse?
        var failure: Error?
        do {
            response = try await client.send(.init(command: .status))
        } catch {
            failure = error
        }

        #expect(response != nil || failure.map(isUnavailable) == true)
        #expect(await server.waitForRequest())
        try? await Task.sleep(for: .milliseconds(120))
        #expect(server.replyCount == 1)
    }

    @Test func acceptedMutationPollsItsStableOperationIDAcrossRealXPC() async throws {
        let server = AnonymousDisplayRecoveryServer(mode: .operation(dropAcceptance: false))
        defer { server.stop() }
        let response = try await clientConnected(to: server, timeout: .seconds(1)).send(.init(command: .prepareVirtual))
        #expect(response.operationStatus == .completed)
        #expect(response.state == .active)
        #expect(server.mutationCount == 1)
        #expect(server.operationIDs.count >= 2)
        #expect(Set(server.operationIDs).count == 1)
    }

    @Test func timedOutAcceptanceQueriesOperationWithoutRepeatingMutation() async throws {
        let server = AnonymousDisplayRecoveryServer(mode: .operation(dropAcceptance: true))
        defer { server.stop() }
        let response = try await clientConnected(to: server, timeout: .milliseconds(50)).send(.init(command: .prepareVirtual))
        #expect(response.operationStatus == .completed)
        #expect(server.mutationCount == 1)
        #expect(Set(server.operationIDs).count == 1)
    }

    @Test func commandTimeoutsMatchTheOperationCost() {
        #expect(DisplayRecoveryClient.timeout(for: .status) == .seconds(4))
        #expect(DisplayRecoveryClient.timeout(for: .heartbeat) == .seconds(4))
        #expect(DisplayRecoveryClient.timeout(for: .disable) == .seconds(15))
        #expect(DisplayRecoveryClient.timeout(for: .prepareVirtual) == .seconds(30))
        #expect(DisplayRecoveryClient.timeout(for: .restore) == .seconds(60))
    }

    private func missingServiceClient() -> DisplayRecoveryClient {
        let serviceName = "\(DisplayRecoveryService.serviceName).test.\(UUID().uuidString)"
        return DisplayRecoveryClient(machServiceName: serviceName, timeout: .seconds(1))
    }

    private func clientConnected(
        to server: AnonymousDisplayRecoveryServer,
        timeout: Duration
    ) -> DisplayRecoveryClient {
        DisplayRecoveryClient(
            connectionFactory: { NSXPCConnection(listenerEndpoint: server.endpoint) },
            timeout: timeout
        )
    }

    private func isUnavailable(_ error: Error) -> Bool {
        guard let error = error as? DisplayRecoveryClientError else { return false }
        return switch error {
        case .unavailable: true
        case .invalidResponse, .timeout: false
        }
    }

    private func isTimeout(_ error: Error) -> Bool {
        guard let error = error as? DisplayRecoveryClientError else { return false }
        return switch error {
        case .timeout: true
        case .unavailable, .invalidResponse: false
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return predicate()
    }
}

/// A real Foundation listener used only through an anonymous endpoint. It does
/// not register a launch agent, start the production helper, or touch displays.
private final class AnonymousDisplayRecoveryServer: NSObject, NSXPCListenerDelegate, DisplayRecoveryXPC, @unchecked Sendable {
    enum Mode {
        case reply(delay: TimeInterval)
        case replyAndInvalidate(delay: TimeInterval)
        case hold
        case operation(dropAcceptance: Bool)
    }

    private let listener: NSXPCListener
    private let mode: Mode
    private let responseData: Data
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    private var receivedRequests: [DisplayControlRequest] = []
    private var requestsReceived = 0
    private var repliesSent = 0
    private var heldReply: (@Sendable (Data) -> Void)?

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    var operationIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.compactMap(\.operationID)
    }
    var mutationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.filter(\.isMutation).count
    }

    var replyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return repliesSent
    }

    private var hasReceivedRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestsReceived > 0
    }

    init(mode: Mode) {
        self.listener = NSXPCListener.anonymous()
        self.mode = mode
        self.responseData = (try? JSONEncoder().encode(
            DisplayControlResponse(displays: [], state: .idle, helperReady: true)
        )) ?? Data()
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func stop() {
        listener.invalidate()
        lock.lock()
        let activeConnections = connections
        connections.removeAll()
        lock.unlock()
        activeConnections.forEach { $0.invalidate() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DisplayRecoveryXPC.self)
        connection.exportedObject = self
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.resume()
        return true
    }

    func execute(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        requestsReceived += 1
        let request = try? JSONDecoder().decode(DisplayControlRequest.self, from: data)
        if let request { receivedRequests.append(request) }
        lock.unlock()

        switch mode {
        case let .operation(dropAcceptance):
            guard let request, let id = request.operationID else { reply(responseData); return }
            if request.isMutation && dropAcceptance { return }
            let response = DisplayControlResponse(displays: [], state: request.isMutation ? .managing : .active,
                helperReady: true, operationID: id, operationStatus: request.isMutation ? .accepted : .completed)
            let encoded = (try? JSONEncoder().encode(response)) ?? Data()
            DispatchQueue.global().async {
                self.recordReply()
                reply(encoded)
            }

        case let .reply(delay):
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [responseData, weak self] in
                self?.recordReply()
                reply(responseData)
            }
        case let .replyAndInvalidate(delay):
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [responseData, weak self] in
                self?.recordReply()
                reply(responseData)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                self.invalidateLastConnection()
            }
        case .hold:
            lock.lock()
            heldReply = reply
            lock.unlock()
        }
    }

    func waitForRequest(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if hasReceivedRequest { return true }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return false
    }

    private func recordReply() {
        lock.lock()
        repliesSent += 1
        lock.unlock()
    }

    func releaseHeldReply() -> Bool {
        lock.lock()
        let reply = heldReply
        heldReply = nil
        if reply != nil {
            repliesSent += 1
        }
        lock.unlock()

        guard let reply else { return false }
        DispatchQueue.global(qos: .userInitiated).async { [responseData] in
            reply(responseData)
        }
        return true
    }

    private func invalidateLastConnection() {
        lock.lock()
        let connection = connections.last
        lock.unlock()
        connection?.invalidate()
    }
}
