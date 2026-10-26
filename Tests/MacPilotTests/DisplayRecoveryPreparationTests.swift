import Foundation
import MacPilotDisplayControlCore
import ServiceManagement
import Testing
@testable import MacPilot

@MainActor
struct DisplayRecoveryPreparationTests {
    @Test func enabledButMissingServiceIsRegisteredAgainAtTheCurrentBundlePath() async {
        let service = Registration(status: .enabled)
        let client = Client(service: service, reachable: false)
        let model = model(client, service)
        await model.prepareHelperAndRefresh()
        #expect(service.events == ["unregister", "register"])
        #expect(model.helperReady)
        #expect(model.errorKey == nil)
        #expect(client.commands == [.status, .status])
    }

    @Test func reachableButUnreadyHelperIsNeverRestarted() async {
        let service = Registration(status: .enabled)
        let client = Client(service: service, reachable: true, ready: false)
        let model = model(client, service)
        await model.prepareHelperAndRefresh()
        #expect(service.events.isEmpty)
        #expect(!model.helperReady)
        #expect(client.commands == [.status])
    }

    @Test func approvalPendingIsPreservedWithoutReregisteringOrProbing() async {
        let service = Registration(status: .requiresApproval)
        let client = Client(service: service, reachable: false)
        let model = model(client, service)
        await model.prepareHelperAndRefresh()
        #expect(service.events.isEmpty)
        #expect(client.commands.isEmpty)
        #expect(model.errorKey == "displayHelperApproval")
    }

    @Test func unregisterFailureDoesNotReportSuccessOrRegisterAgain() async {
        let service = Registration(status: .enabled)
        service.unregisterFails = true
        let model = model(Client(service: service, reachable: false), service)
        await model.prepareHelperAndRefresh()
        #expect(service.events == ["unregister"])
        #expect(model.errorKey == "displayHelperInstallFailed")
        #expect(!model.helperReady)
    }

    @Test func firstPreparationRegistersBeforeRequestingStatus() async {
        let service = Registration(status: .notRegistered)
        let client = Client(service: service, reachable: false)
        let model = model(client, service)
        await model.prepareHelperAndRefresh()
        #expect(service.events == ["register"])
        #expect(client.commands == [.status])
        #expect(model.helperReady)
    }

    private func model(_ client: Client, _ service: Registration) -> DisplayControlModel {
        DisplayControlModel(client: client,
            monitor: UUSessionMonitor(read: { .init(status: .disconnected) }),
            showsConfirmation: false, prepareVisibleOutputs: { true },
            controlStateChanged: { _ in }, recoveryService: service)
    }

    private final class Registration: DisplayRecoveryRegistering {
        var status: SMAppService.Status
        var events: [String] = []
        var unregisterFails = false
        init(status: SMAppService.Status) { self.status = status }
        func register() throws { events.append("register"); status = .enabled }
        func unregister() async throws {
            events.append("unregister")
            if unregisterFails { throw DisplayRecoveryClientError.unavailable }
            status = .notRegistered
        }
    }

    private final class Client: DisplayRecoverySending {
        let service: Registration
        let reachable: Bool
        let ready: Bool
        var commands: [DisplayControlCommand] = []
        init(service: Registration, reachable: Bool, ready: Bool = true) {
            self.service = service; self.reachable = reachable; self.ready = ready
        }
        func send(_ request: DisplayControlRequest) async throws -> DisplayControlResponse {
            commands.append(request.command)
            guard reachable || service.events.last == "register" else {
                throw DisplayRecoveryClientError.unavailable
            }
            return .init(displays: [], state: .idle, helperReady: ready)
        }
    }
}
