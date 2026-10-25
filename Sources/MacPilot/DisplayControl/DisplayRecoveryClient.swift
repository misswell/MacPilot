import Foundation
import MacPilotDisplayControlCore

@MainActor
protocol DisplayRecoverySending: AnyObject {
    func send(_ request: DisplayControlRequest) async throws -> DisplayControlResponse
}

enum DisplayRecoveryClientError: Error { case unavailable, invalidResponse, timeout }

@MainActor
final class DisplayRecoveryClient: DisplayRecoverySending {
    func send(_ request: DisplayControlRequest) async throws -> DisplayControlResponse {
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: DisplayRecoveryService.serviceName, options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: DisplayRecoveryXPC.self)
            let call = PendingCall(connection: connection, continuation: continuation)
            connection.interruptionHandler = {
                Task { @MainActor in call.finish(.failure(DisplayRecoveryClientError.unavailable)) }
            }
            connection.invalidationHandler = {
                Task { @MainActor in call.finish(.failure(DisplayRecoveryClientError.unavailable)) }
            }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                Task { @MainActor in call.finish(.failure(DisplayRecoveryClientError.unavailable)) }
            } as? DisplayRecoveryXPC
            guard let proxy else { call.finish(.failure(DisplayRecoveryClientError.unavailable)); return }
            proxy.execute(data) { reply in
                Task { @MainActor in
                    guard reply.count <= 1_048_576,
                          let response = try? JSONDecoder().decode(DisplayControlResponse.self, from: reply) else {
                        call.finish(.failure(DisplayRecoveryClientError.invalidResponse))
                        return
                    }
                    call.finish(.success(response))
                }
            }
            call.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                call.finish(.failure(DisplayRecoveryClientError.timeout))
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
