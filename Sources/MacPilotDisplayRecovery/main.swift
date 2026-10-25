import AppKit
import Foundation
import MacPilotDisplayControlCore

if CommandLine.arguments.dropFirst().contains("--restore") {
    let connection = NSXPCConnection(machServiceName: DisplayRecoveryService.serviceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: DisplayRecoveryXPC.self)
    connection.resume()
    defer { connection.invalidate() }
    let semaphore = DispatchSemaphore(value: 0)
    var didRestore = false
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in semaphore.signal() } as? DisplayRecoveryXPC
    let request = DisplayControlRequest(command: .restore)
    if let proxy, let data = try? JSONEncoder.displayControlEncoder.encode(request) {
        proxy.execute(data) { payload in
            if let response = try? JSONDecoder.displayControlDecoder.decode(DisplayControlResponse.self, from: payload) {
                didRestore = response.state == .idle
                    && response.message != DisplayControlMessageCode.recoveryIncomplete.rawValue
                    && response.virtualDisplayUUID == nil
            }
            semaphore.signal()
        }
    }
    _ = semaphore.wait(timeout: .now() + 30)
    exit(didRestore ? 0 : 1)
}

DisplayRecoveryAgent.shared.run()
