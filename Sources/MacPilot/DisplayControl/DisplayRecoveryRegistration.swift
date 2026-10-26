import MacPilotDisplayControlCore
import ServiceManagement

@MainActor
protocol DisplayRecoveryRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
final class DisplayRecoveryRegistration: DisplayRecoveryRegistering {
    private let service = SMAppService.agent(plistName: DisplayRecoveryService.serviceName + ".plist")

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}
