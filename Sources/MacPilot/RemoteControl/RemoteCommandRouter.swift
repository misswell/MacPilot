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
    /// Dock groups on this Mac. `nil` leaves the three Dock group commands
    /// answering `unsupportedCommand`, which is how a host without the feature
    /// (and every test that does not care) keeps compiling.
    private let dockGroups: (any RemoteDockGroupsHosting)?

    private let logHandler: (String) -> Void
    private let mediaControl: (RemoteCommand) -> RemoteErrorCode?

    init(
        service: MacScreenControlService,
        dockGroups: (any RemoteDockGroupsHosting)? = nil,
        mediaControl: @escaping (RemoteCommand) -> RemoteErrorCode? = { RemoteMediaControl.send($0) },
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.service = service
        self.dockGroups = dockGroups
        self.mediaControl = mediaControl
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

        case .setBrightness, .setVolume:
            return respondToLevel(request, started: started)

        case .mediaPrevious, .mediaPlayPause, .mediaNext:
            if let error = mediaControl(request.command) {
                return failure(for: request, code: error)
            }
            return payloadResponse(request, started: started, payload: nil)

        case .getDockGroups:
            return await respondToDockGroups(request, started: started)

        case .launchDockGroup, .launchDockGroupApp:
            return await respondToDockGroupLaunch(request, started: started)

        case .beginRealtimeInput, .endRealtimeInput,
             .beginTextInput, .textInput, .endTextInput,
             .beginRemoteVideo, .endRemoteVideo, .remotePointer, .remoteKey:
            // Intercepted by `RemoteConnection` before the router: they arm
            // per-connection session state, which the router never sees.
            return failure(for: request, code: .unsupportedCommand)
        }
    }

    /// A Dock group listing. `nil` from the host means the feature is switched
    /// off, which the phone treats the same as an old Mac: no section.
    private func respondToDockGroups(_ request: RemoteRequest, started: Date) async -> RemoteResponse {
        guard let dockGroups, let snapshot = await dockGroups.remoteSnapshot() else {
            return failure(for: request, code: .unsupportedCommand)
        }
        return payloadResponse(request, started: started, payload: try? snapshot.encoded())
    }

    private func respondToDockGroupLaunch(_ request: RemoteRequest, started: Date) async -> RemoteResponse {
        guard let dockGroups else {
            return failure(for: request, code: .unsupportedCommand)
        }
        guard let launch = RemoteDockGroupLaunchRequest.decoded(from: request.payload) else {
            log("command refused reason=missingDockGroup command=\(request.command.rawValue)")
            return failure(for: request, code: .invalidMessage)
        }
        guard case let .snapshot(snapshot) = await dockGroups.remoteLaunch(
            groupID: launch.groupID,
            appID: launch.appID
        ) else {
            log("command refused reason=dockGroupNotFound command=\(request.command.rawValue)")
            return failure(for: request, code: .invalidMessage)
        }
        return payloadResponse(request, started: started, payload: try? snapshot.encoded())
    }

    /// The Dock group commands answer with the group snapshot instead of state
    /// changes; `state` still rides along so the panel stays fresh for free.
    private func payloadResponse(_ request: RemoteRequest, started: Date, payload: Data?) -> RemoteResponse {
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        log("command completed command=\(request.command.rawValue) latency=\(latency)ms")
        return RemoteResponse(
            requestID: request.requestID,
            success: true,
            state: service.currentState(),
            payload: payload
        )
    }

    /// Brightness and volume share one shape: decode the payload, clamp it, apply
    /// it, then answer with the level the machine actually reports. A missing or
    /// unreadable payload is refused rather than guessed at, because guessing
    /// would move a control the user did not ask to move.
    private func respondToLevel(_ request: RemoteRequest, started: Date) -> RemoteResponse {
        guard let level = RemoteLevelRequest.decoded(from: request.payload) else {
            log("command refused reason=missingLevel command=\(request.command.rawValue)")
            return failure(for: request, code: .invalidMessage)
        }

        let result: ScreenControlResult
        switch request.command {
        case .setBrightness:
            result = service.setBrightness(level.clampedValue)
        case .setVolume:
            result = service.setVolume(level.clampedValue, muted: level.muted)
        default:
            return failure(for: request, code: .unsupportedCommand)
        }
        return respond(request, result, started: started)
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
