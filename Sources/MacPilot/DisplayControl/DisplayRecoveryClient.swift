import Foundation
import MacPilotDisplayControlCore

@MainActor
protocol DisplayRecoverySending: AnyObject {
    func send(_ request: DisplayControlRequest) async throws -> DisplayControlResponse
}

enum DisplayRecoveryClientError: Error { case unavailable, invalidResponse, timeout }

@MainActor
final class DisplayRecoveryClient: DisplayRecoverySending {
    private let connectionFactory: @MainActor () -> NSXPCConnection
    private let timeout: Duration

    init(machServiceName: String = DisplayRecoveryService.serviceName, timeout: Duration = .seconds(4)) {
        connectionFactory = { NSXPCConnection(machServiceName: machServiceName, options: []) }
        self.timeout = timeout
    }

    init(connectionFactory: @escaping @MainActor () -> NSXPCConnection, timeout: Duration = .seconds(4)) {
        self.connectionFactory = connectionFactory
        self.timeout = timeout
    }

    func send(_ request: DisplayControlRequest) async throws -> DisplayControlResponse {
        let data = try JSONEncoder().encode(request)
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let connection = connectionFactory()
            connection.remoteObjectInterface = NSXPCInterface(with: DisplayRecoveryXPC.self)
            let call = PendingCall(connection: connection, continuation: continuation)
            connection.interruptionHandler = Self.unavailableHandler(for: call)
            connection.invalidationHandler = Self.unavailableHandler(for: call)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler(Self.errorHandler(for: call)) as? DisplayRecoveryXPC
            guard let proxy else { call.finish(.failure(DisplayRecoveryClientError.unavailable)); return }
            proxy.execute(data, reply: Self.replyHandler(for: call))
            call.timeout = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                call.finish(.failure(DisplayRecoveryClientError.timeout))
            }
        }
    }

    // Foundation invokes all of these on its own XPC queue. Creating the
    // closures outside MainActor prevents an inherited executor assertion at
    // callback entry; hopping in the body alone is too late to prevent a trap.
    private nonisolated static func unavailableHandler(for call: PendingCall) -> @Sendable () -> Void {
        { Task { @MainActor in call.finish(.failure(DisplayRecoveryClientError.unavailable)) } }
    }

    private nonisolated static func errorHandler(for call: PendingCall) -> @Sendable (any Error) -> Void {
        { _ in Task { @MainActor in call.finish(.failure(DisplayRecoveryClientError.unavailable)) } }
    }

    private nonisolated static func replyHandler(for call: PendingCall) -> @Sendable (Data) -> Void {
        { reply in
            Task { @MainActor in
                guard reply.count <= 1_048_576,
                      let response = try? JSONDecoder().decode(DisplayControlResponse.self, from: reply) else {
                    call.finish(.failure(DisplayRecoveryClientError.invalidResponse))
                    return
                }
                call.finish(.success(response))
            }
        }
    }

    @MainActor
    private final class PendingCall {
        let connection: NSXPCConnection
        var continuation: CheckedContinuation<DisplayControlResponse, Error>?
        var timeout: Task<Void, Never>?

        init(connection: NSXPCConnection, continuation: CheckedContinuation<DisplayControlResponse, Error>) {
            self.connection = connection
            self.continuation = continuation
        }

        func finish(_ result: Result<DisplayControlResponse, Error>) {
            guard let pending = continuation else { return }
            continuation = nil
            timeout?.cancel()
            timeout = nil
            connection.interruptionHandler = nil
            connection.invalidationHandler = nil
            connection.invalidate()
            pending.resume(with: result)
        }
    }
}
