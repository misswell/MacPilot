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

    /// Where the failure happened.
    ///
    /// A `protection` failure means the MacBook may still sleep with the lid
    /// closed. A `retirement` failure means a power service the feature no
    /// longer needs was not released; sleep protection is not missing at all.
    /// The menu-bar icon flags both (something needs attention either way), so
    /// the Home page has to describe them differently instead of labelling an
    /// unfinished release as "closed-lid sleep prevention failed".
    enum Stage: String, Sendable {
        case protection
        case retirement
    }

    let kind: Kind
    let message: String
    var stage = Stage.protection

    var errorDescription: String? { message }

    /// Re-labels a failure raised while retiring an unused power service.
    func duringRetirement() -> ClosedLidSleepFailure {
        ClosedLidSleepFailure(kind: kind, message: message, stage: .retirement)
    }

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
    func prepareRegistrationForUse() async throws
    func cleanupUnusedLegacyRegistration() async throws
    func openSystemSettings()
    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure>
    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure>
    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure>
    /// Best-effort synchronous release used while the app terminates.
    func releaseSynchronously()
    /// Drops the cached privileged connection once the feature is off, so an
    /// idle XPC connection does not stay open for the rest of the session.
    func invalidate() async
}

extension PowerHelperServicing {
    func prepareRegistrationForUse() async throws {}
    func cleanupUnusedLegacyRegistration() async throws {}
    /// Test doubles and fakes need no implementation.
    func invalidate() async {}
}

/// Real helper: `SMAppService` LaunchDaemon registration plus an XPC client.
@MainActor
final class PrivilegedPowerHelper: PowerHelperServicing {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.ClosedLid")
    private let plistName: String
    private let service: SMAppService?
    private let client: PowerHelperClient
    private let lifecycle = PowerHelperLifecycleBarrier.shared
    // Advance only when the launchd job/lifecycle contract changes, not for
    // ordinary app releases. Registration must survive routine Beta upgrades.
    private let definitionStamp = "power-on-demand-v1"
    private var stampKey: String { "powerHelper.definition." + Bundle.main.bundleURL.standardizedFileURL.path }
    private var hasCurrentDefinition: Bool { UserDefaults.standard.string(forKey: stampKey) == definitionStamp }

    init(plistName: String = MacPilotPowerService.daemonPlistName) {
        // `SMAppService.daemon` returns a service even when the plist is
        // missing from the bundle; `status` then reports `.notFound`.
        self.plistName = plistName
        self.service = SMAppService.daemon(plistName: plistName)
        self.client = PowerHelperClient(machServiceName: MacPilotPowerService.machServiceName)
    }

    var registrationState: ClosedLidSleepServiceState {
        guard let service else { return .unavailable }
        return Self.mapRegistrationState(
            status: service.status,
            plistPresentInBundle: Self.isDaemonPlistPresent(
                plistName: plistName,
                bundleURL: Bundle.main.bundleURL
            )
        )
    }

    /// On current macOS an **unregistered** daemon reports `.notFound`, not
    /// `.notRegistered` — verified with a probe on macOS 26 and 27. So the plist
    /// still shipping in the running bundle is what separates "the registration
    /// record was lost (OS upgrade, BTM reset) and `register()` can restore it"
    /// from "this is not a real app bundle at all (bare `swift run` binary),
    /// where registration is genuinely impossible".
    nonisolated static func mapRegistrationState(
        status: SMAppService.Status,
        plistPresentInBundle: Bool
    ) -> ClosedLidSleepServiceState {
        switch status {
        case .enabled:
            return .ready
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return plistPresentInBundle ? .notRegistered : .unavailable
        @unknown default:
            return .unavailable
        }
    }

    nonisolated static func isDaemonPlistPresent(plistName: String, bundleURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons")
                .appendingPathComponent(plistName)
                .path
        )
    }

    func register() throws {
        guard let service else {
            throw ClosedLidSleepFailure.helperUnavailable()
        }
        do {
            try service.register()
            UserDefaults.standard.set(definitionStamp, forKey: stampKey)
            logger.notice("Registered background power service")
        } catch {
            logger.error("Background power service registration failed: \(error.localizedDescription, privacy: .public)")
            throw ClosedLidSleepFailure.registrationFailed(error.localizedDescription)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func prepareRegistrationForUse() async throws {
        try await lifecycle.run { [self] in try await prepareRegistrationUnserialized() }
    }

    private func prepareRegistrationUnserialized() async throws {
        guard Self.isDaemonPlistPresent(plistName: plistName, bundleURL: Bundle.main.bundleURL) else {
            throw ClosedLidSleepFailure.helperUnavailable()
        }
        guard let service else { throw ClosedLidSleepFailure.helperUnavailable() }
        if service.status == .enabled, !hasCurrentDefinition {
            try await retireLegacyJob(service)
            guard service.status != .enabled else {
                throw ClosedLidSleepFailure.registrationFailed("The old power service did not unload.")
            }
        }
        if service.status != .enabled, service.status != .requiresApproval { try register() }
    }

    private func retireLegacyJob(_ service: SMAppService) async throws {
        try await PowerHelperJobRetirement.run(
            release: { [client] in await client.setSleepDisabled(false) },
            read: { [client] in await client.sleepDisabled() },
            invalidate: { [client] in await client.invalidate() },
            unregister: { try await service.unregister() }
        )
    }

    func cleanupUnusedLegacyRegistration() async throws {
        guard Self.isDaemonPlistPresent(plistName: plistName, bundleURL: Bundle.main.bundleURL) else { return }
        try await lifecycle.run { [self] in
            guard let service, service.status == .enabled, !hasCurrentDefinition else { return }
            try await retireLegacyJob(service)
            // No registration stamp until the next successful registration.
        }
    }

    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure> {
        do {
            return try await lifecycle.run { [self] in
                if disabled { try await prepareRegistrationUnserialized() }
                return await client.setSleepDisabled(disabled)
            }
        } catch {
            return .failure(error as? ClosedLidSleepFailure ?? .registrationFailed(error.localizedDescription))
        }
    }

    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure> {
        do { return try await lifecycle.run { [self] in await client.sleepDisabled() } }
        catch { return .failure(.requestFailed(error.localizedDescription)) }
    }

    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure> {
        do { return try await lifecycle.run { [self] in await client.heartbeat() } }
        catch { return .failure(.requestFailed(error.localizedDescription)) }
    }

    func releaseSynchronously() { client.releaseSynchronously() }

    func invalidate() async {
        _ = try? await lifecycle.run { [self] in await client.invalidate() }
    }

}

/// Serialized XPC access. Lives in an actor so the non-`Sendable`
/// `NSXPCConnection` never crosses an isolation boundary.
actor PowerHelperClient {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.ClosedLid")
    private let machServiceName: String
    private var activeConnections: [UUID: NSXPCConnection] = [:]

    init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    func setSleepDisabled(_ disabled: Bool) async -> Result<Bool, ClosedLidSleepFailure> {
        let result = await perform { proxy, reply in
            proxy.setSleepDisabled(disabled) { success, message in
                reply(success ? .success(true) : .failure(.requestFailed(message ?? "The power service rejected the request.")))
            }
        }
        return result
    }

    func sleepDisabled() async -> Result<Bool, ClosedLidSleepFailure> {
        let result = await perform { proxy, reply in
            proxy.getSleepDisabled { disabled, message in
                if let message {
                    reply(.failure(.requestFailed(message)))
                } else {
                    reply(.success(disabled))
                }
            }
        }
        return result
    }

    func heartbeat() async -> Result<Bool, ClosedLidSleepFailure> {
        await perform { proxy, reply in
            proxy.heartbeat { owned in
                reply(.success(owned))
            }
        }
    }

    func invalidate() {
        for connection in activeConnections.values { connection.invalidate() }
        activeConnections.removeAll()
    }

    /// Each request owns a short-lived connection. An idle client must not
    /// pin the helper process between uses.
    private func liveConnection() -> NSXPCConnection {
        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MacPilotPowerHelperProtocol.self)
        return newConnection
    }

    private func perform(
        _ body: @escaping @Sendable (MacPilotPowerHelperProtocol, @escaping @Sendable (Result<Bool, ClosedLidSleepFailure>) -> Void) -> Void
    ) async -> Result<Bool, ClosedLidSleepFailure> {
        let connection = liveConnection()
        let requestID = UUID()
        activeConnections[requestID] = connection
        defer {
            activeConnections.removeValue(forKey: requestID)
            connection.invalidate()
        }
        var timeout: Task<Void, Never>?
        let result: Result<Bool, ClosedLidSleepFailure> = await withCheckedContinuation { continuation in
            let box = SingleShot(continuation)
            timeout = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                box.resume(.failure(.requestFailed("The power service request timed out.")))
            }
            connection.invalidationHandler = {
                box.resume(.failure(.requestFailed("The power service connection ended.")))
            }
            connection.interruptionHandler = {
                box.resume(.failure(.requestFailed("The power service connection was interrupted.")))
            }
            connection.resume()
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
        timeout?.cancel()
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
