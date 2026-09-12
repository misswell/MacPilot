import Foundation
import MacPilotPowerIPC
import OSLog
import ServiceManagement

/// A privileged-helper failure that the Awake UI can surface. Deliberately a
/// different type from `AwakeAssertionFailure`: IOKit assertions and
/// privileged power operations fail for very different reasons.
struct ClosedLidSleepFailure: Error, Equatable, LocalizedError, Sendable {
    enum Kind: String, Sendable {
        case helperUnavailable
        case notRegistered
        case requiresApproval
        case registrationFailed
        case requestFailed
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }

    static func helperUnavailable() -> ClosedLidSleepFailure {
        ClosedLidSleepFailure(kind: .helperUnavailable, message: "The background power service is unavailable.")
    }

    static func registrationFailed(_ message: String) -> ClosedLidSleepFailure {
        ClosedLidSleepFailure(kind: .registrationFailed, message: message)
    }

    static func requestFailed(_ message: String) -> ClosedLidSleepFailure {
        ClosedLidSleepFailure(kind: .requestFailed, message: message)
    }
}

/// Everything the Awake UI needs to describe the closed-lid service.
enum ClosedLidSleepServiceState: Equatable, Sendable {
    case unavailable
    case notRegistered
    case requiresApproval
    case ready
    case enabling
    case enabled
    case error(String)
}

/// Abstracts the privileged helper so the session manager and tests never talk
/// to `SMAppService` or XPC directly.
@MainActor
protocol PowerHelperServicing: AnyObject {
    var registrationState: ClosedLidSleepServiceState { get }

    func register() throws
    func openSystemSettings()
    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure>
    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure>
    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure>
    /// Best-effort synchronous release used while the app terminates.
    func releaseSynchronously()
}

/// Real helper: `SMAppService` LaunchDaemon registration plus an XPC client.
@MainActor
final class PrivilegedPowerHelper: PowerHelperServicing {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.ClosedLid")
    private let service: SMAppService?
    private let client: PowerHelperClient

    init(plistName: String = MacPilotPowerService.daemonPlistName) {
        // `SMAppService.daemon` returns a service even when the plist is
        // missing; `status` then reports `.notFound`, which we surface as
        // `.unavailable`.
        self.service = SMAppService.daemon(plistName: plistName)
        self.client = PowerHelperClient(machServiceName: MacPilotPowerService.machServiceName)
    }

    var registrationState: ClosedLidSleepServiceState {
        guard let service else { return .unavailable }
        switch service.status {
        case .enabled:
            return .ready
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        guard let service else {
            throw ClosedLidSleepFailure.helperUnavailable()
        }
        do {
            try service.register()
            logger.notice("Registered background power service")
        } catch {
            logger.error("Background power service registration failed: \(error.localizedDescription, privacy: .public)")
            throw ClosedLidSleepFailure.registrationFailed(error.localizedDescription)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure> {
        await client.setSleepDisabled(disabled)
    }

    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure> {
        await client.sleepDisabled()
    }

    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure> {
        await client.heartbeat()
    }

    func releaseSynchronously() {
        client.releaseSynchronously()
    }
}

/// Serialized XPC access. Lives in an actor so the non-`Sendable`
/// `NSXPCConnection` never crosses an isolation boundary.
actor PowerHelperClient {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.ClosedLid")
    private let machServiceName: String
    private var connection: NSXPCConnection?

    init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure> {
        await perform { proxy, reply in
            proxy.setSleepDisabled(disabled) { success, message in
                reply(success ? .success(true) : .failure(.requestFailed(message ?? "The power service rejected the request.")))
            }
        }
    }

    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure> {
        await perform { proxy, reply in
            proxy.getSleepDisabled { disabled, message in
                if let message {
                    reply(.failure(.requestFailed(message)))
                } else {
                    reply(.success(disabled))
                }
            }
        }
    }

    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure> {
        await perform { proxy, reply in
            proxy.heartbeat { owned in
                reply(.success(owned))
            }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// Drops a broken connection so the next request recreates it.
    private func liveConnection() -> NSXPCConnection {
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MacPilotPowerHelperProtocol.self)
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func perform(
        _ body: @escaping @Sendable (MacPilotPowerHelperProtocol, @escaping @Sendable (Result<Bool, ClosedLidSleepFailure>) -> Void) -> Void
    ) async -> Result<Bool, ClosedLidSleepFailure> {
        let connection = liveConnection()
        let result: Result<Bool, ClosedLidSleepFailure> = await withCheckedContinuation { continuation in
            let box = SingleShot(continuation)
            let errorHandler: @Sendable (any Error) -> Void = { error in
                box.resume(.failure(.requestFailed(error.localizedDescription)))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler) as? MacPilotPowerHelperProtocol else {
                box.resume(.failure(.helperUnavailable()))
                return
            }
            body(proxy) { result in
                box.resume(result)
            }
        }
        if case .failure = result {
            invalidate()
        }
        return result
    }

    /// Best-effort synchronous release on a throwaway connection so app
    /// termination can hand the setting back before the process exits.
    nonisolated func releaseSynchronously() {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MacPilotPowerHelperProtocol.self)
        connection.resume()
        let semaphore = DispatchSemaphore(value: 0)
        let reply: @Sendable (Bool, String?) -> Void = { _, _ in semaphore.signal() }
        if let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler({ _ in
            semaphore.signal()
        }) as? MacPilotPowerHelperProtocol {
            proxy.setSleepDisabled(false, reply: reply)
        } else {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        connection.invalidate()
    }
}

/// Guards a continuation so a reply block and an error handler can never
/// resume it twice.
private final class SingleShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return }
        isResumed = true
        continuation.resume(returning: value)
    }
}
