import AppKit
import Foundation
import MacPilotDisplayControlCore

/// XPC callbacks run independently of the command-line entry thread. Keep the
/// result and error/late-reply race behind one lock, not a captured local var.
private final class DisplayRestoreCLIResult: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var completed = false
    private var restored = false

    func finish(restored: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        self.restored = restored
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> Bool {
        guard semaphore.wait(timeout: .now() + 30) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return restored
    }
}

if CommandLine.arguments.dropFirst().contains("--restore") {
    let connection = NSXPCConnection(machServiceName: DisplayRecoveryService.serviceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: DisplayRecoveryXPC.self)
    connection.resume()
    defer { connection.invalidate() }
    let result = DisplayRestoreCLIResult()
    let errorHandler: @Sendable (any Error) -> Void = { _ in result.finish(restored: false) }
    let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler) as? DisplayRecoveryXPC
    let request = DisplayControlRequest(command: .restore)
    if let proxy, let data = try? JSONEncoder.displayControlEncoder.encode(request) {
        proxy.execute(data) { payload in
            if let response = try? JSONDecoder.displayControlDecoder.decode(DisplayControlResponse.self, from: payload) {
                let restored = response.state == .idle
                    && response.message != DisplayControlMessageCode.recoveryIncomplete.rawValue
                    && response.virtualDisplayUUID == nil
                result.finish(restored: restored)
            } else { result.finish(restored: false) }
        }
    } else { result.finish(restored: false) }
    exit(result.wait() ? 0 : 1)
}

DisplayRecoveryAgent.shared.run()
