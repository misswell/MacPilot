import Foundation
import MacPilotRemoteProtocol

/// Turns an authenticated `RemoteRequest` into a `RemoteResponse` by calling the
/// shared `MacScreenControlService`.
///
/// Every state changing command waits for the machine to actually reach the
/// requested state before reporting success.
@MainActor
struct RemoteCommandRouter {
    let service: MacScreenControlService

    private let logHandler: (String) -> Void

    init(
        service: MacScreenControlService,
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.service = service
        self.logHandler = log
    }

    private func log(_ message: @autoclosure () -> String) {
        logHandler(message())
    }

    func response(for request: RemoteRequest, isAuthenticated: Bool) async -> RemoteResponse {
        guard request.version == RemoteProtocolVersion.current else {
            return failure(for: request, code: .unsupportedProtocol)
        }
        if request.command.requiresAuthentication, !isAuthenticated {
            log("command refused reason=unauthenticated command=\(request.command.rawValue)")
            return failure(for: request, code: .unauthenticated)
        }

        let started = Date()
        switch request.command {
        case .ping:
            return RemoteResponse(requestID: request.requestID, success: true, state: service.currentState())

        case .getState:
            return RemoteResponse(requestID: request.requestID, success: true, state: service.currentState())

        case .lockScreen:
            return respond(request, await service.lockScreen(source: .remoteExplicit), started: started)

        case .displayOff:
            return respond(request, await service.sleepDisplay(), started: started)

        case .wakeDisplay:
            return respond(request, await service.wakeDisplay(), started: started)

        case .unlock:
            return respond(request, await service.unlock(source: .remoteExplicit), started: started)

        case .wakeAndUnlock:
            return respond(request, await service.wakeAndUnlock(source: .remoteExplicit), started: started)
        }
    }

    private func respond(
        _ request: RemoteRequest,
        _ result: ScreenControlResult,
        started: Date
    ) -> RemoteResponse {
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        if result.success {
            log("command completed command=\(request.command.rawValue) latency=\(latency)ms")
            return RemoteResponse(requestID: request.requestID, success: true, state: result.state)
        }
        let code = result.failure?.remoteErrorCode ?? .internalError
        log("command failed command=\(request.command.rawValue) code=\(code.rawValue) latency=\(latency)ms")
        return failure(for: request, code: code)
    }

    private func failure(for request: RemoteRequest, code: RemoteErrorCode) -> RemoteResponse {
        RemoteResponse(
            requestID: request.requestID,
            success: false,
            error: RemoteError(code: code),
            state: service.currentState()
        )
    }
}
