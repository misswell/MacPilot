import Foundation
import IOKit.pwr_mgt
import Testing
@testable import MacPilot

@MainActor
struct AwakeAssertionControllerTests {
    private let systemOnly = DesiredAwakeState(
        preventSystemSleep: true, preventDisplaySleep: false, preventClosedLidSleep: false
    )
    private let both = DesiredAwakeState(
        preventSystemSleep: true, preventDisplaySleep: true, preventClosedLidSleep: false
    )

    @Test func nilPropertiesRequireConfirmedAbsenceBeforeRecreation() {
        for code in [kIOReturnError, kIOReturnNotPrivileged] {
            let api = IOKitAwakePowerAssertionAPI(copyProperties: { _ in nil }, setLevelOn: { _ in code })
            #expect(api.ensureActive(42) == .failed(code))
        }
        for code in [kIOReturnNotFound, kIOReturnBadArgument] {
            let missing = IOKitAwakePowerAssertionAPI(copyProperties: { _ in nil }, setLevelOn: { _ in code })
            #expect(missing.ensureActive(42) == .missing)
        }
        let recovered = IOKitAwakePowerAssertionAPI(copyProperties: { _ in nil }, setLevelOn: { _ in kIOReturnSuccess })
        #expect(recovered.ensureActive(42) == .active)
    }

    @Test func existingInactiveAssertionIsReenabledAndHealthyAssertionsAreLeftAlone() {
        var writes = 0
        let healthy = IOKitAwakePowerAssertionAPI(
            copyProperties: { _ in [kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOn)] },
            setLevelOn: { _ in writes += 1; return kIOReturnSuccess })
        #expect(healthy.ensureActive(42) == .active)
        #expect(writes == 0)
        let inactive = IOKitAwakePowerAssertionAPI(
            copyProperties: { _ in [kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOff)] },
            setLevelOn: { _ in writes += 1; return kIOReturnSuccess })
        #expect(inactive.ensureActive(42) == .active)
        #expect(writes == 1)
        let malformed = IOKitAwakePowerAssertionAPI(copyProperties: { _ in [:] },
            setLevelOn: { _ in writes += 1; return kIOReturnSuccess })
        #expect(malformed.ensureActive(42) == .failed(kIOReturnError))
        #expect(writes == 1)
    }

    @Test func repeatedApplicationsKeepOneAssertionPerKind() {
        let api = FakeAwakePowerAssertionAPI()
        let controller = AwakeAssertionController(api: api)
        controller.apply(systemOnly)
        controller.apply(systemOnly)
        #expect(api.createdTypes == [kIOPMAssertionTypePreventUserIdleSystemSleep])
        #expect(controller.isSystemAssertionActive)
        #expect(!controller.isDisplayAssertionActive)
        controller.apply(both)
        #expect(api.createdTypes.count == 2)
        #expect(controller.isDisplayAssertionActive)
        controller.releaseAll()
        #expect(api.releasedIDs == [1, 2])
        #expect(!controller.isSystemAssertionActive)
        #expect(!controller.isDisplayAssertionActive)
    }

    @Test func confirmedMissingAssertionIsRecreatedWithoutDuplicatingItsPeer() {
        let api = FakeAwakePowerAssertionAPI()
        let controller = AwakeAssertionController(api: api)
        controller.apply(both)
        api.liveIDs.remove(1)
        controller.apply(both)
        #expect(api.createdTypes.count == 3)
        #expect(api.liveIDs == [2, 3])
        #expect(controller.isSystemAssertionActive)
        #expect(controller.isDisplayAssertionActive)
        controller.releaseAll()
        #expect(api.releasedIDs == [3, 2])
    }

    @Test func queryFailureRetainsTheIDUntilHealthRecovers() {
        let api = FakeAwakePowerAssertionAPI()
        let controller = AwakeAssertionController(api: api)
        controller.apply(systemOnly)
        api.healthError = kIOReturnError
        guard case .failure(let failure) = controller.apply(systemOnly) else {
            Issue.record("Expected health failure")
            return
        }
        #expect(failure.kind == .systemSleep)
        #expect(!controller.isSystemAssertionActive)
        #expect(api.createdTypes.count == 1)
        api.healthError = nil
        controller.apply(systemOnly)
        #expect(controller.isSystemAssertionActive)
        #expect(api.createdTypes.count == 1)
        controller.releaseAll()
        #expect(api.releasedIDs == [1])
    }

    @Test func createFailureRetriesAndDoesNotPreventTheOtherKindFromStarting() {
        let api = FakeAwakePowerAssertionAPI()
        api.createErrorType = kIOPMAssertionTypePreventUserIdleSystemSleep
        let controller = AwakeAssertionController(api: api)
        guard case .failure(let failure) = controller.apply(both) else {
            Issue.record("Expected create failure")
            return
        }
        #expect(failure.kind == .systemSleep)
        #expect(!controller.isSystemAssertionActive)
        #expect(controller.isDisplayAssertionActive)
        api.createErrorType = nil
        controller.apply(both)
        #expect(api.createdTypes.count == 3)
        #expect(api.liveIDs.count == 2)
        #expect(controller.isSystemAssertionActive)
    }

    @Test func failedReleaseKeepsItsIDForTheNextRetry() {
        let api = FakeAwakePowerAssertionAPI()
        let controller = AwakeAssertionController(api: api)
        controller.apply(both)
        api.releaseError = kIOReturnError
        guard case .failure = controller.releaseAll() else {
            Issue.record("Expected release failure")
            return
        }
        #expect(api.liveIDs == [1, 2])
        #expect(!controller.isSystemAssertionActive)
        #expect(!controller.isDisplayAssertionActive)
        api.releaseError = nil
        controller.releaseAll()
        #expect(api.liveIDs.isEmpty)
        #expect(api.releasedIDs == [1, 2, 1, 2])
    }

    @Test func releasingAnAlreadyMissingAssertionClearsTheLocalID() {
        let api = FakeAwakePowerAssertionAPI()
        let controller = AwakeAssertionController(api: api)
        controller.apply(systemOnly)
        api.liveIDs.remove(1)
        guard case .success = controller.releaseAll() else {
            Issue.record("An absent ID on release must count as already released")
            return
        }
        controller.apply(systemOnly)
        #expect(api.createdTypes.count == 2)
        #expect(controller.isSystemAssertionActive)
    }

    @Test func unlimitedSessionRepairsAConfirmedMissingAssertionOnMaintenance() async throws {
        let api = FakeAwakePowerAssertionAPI()
        let manager = makeManager(api)
        defer { manager.shutdown() }
        manager.startManualSession()
        // Allow the initial maintenance iteration to finish, then lose its ID.
        await Task.yield()
        api.liveIDs.removeAll()
        try await waitUntil { api.createdTypes.count >= 2 }
        #expect(manager.isSystemAssertionActive)
        #expect(api.liveIDs.count == 1)
    }

    @Test func maintenanceRetriesReleaseAfterTheLastSessionEndsThenStops() async throws {
        let api = FakeAwakePowerAssertionAPI()
        let manager = makeManager(api)
        defer { manager.shutdown() }
        let id = manager.startManualSession()
        api.releaseError = kIOReturnError
        manager.endSession(id)
        #expect(!manager.isActive)
        #expect(manager.lastAssertionFailure != nil)
        api.releaseError = nil
        try await waitUntil { api.liveIDs.isEmpty && manager.lastAssertionFailure == nil }
        let releases = api.releasedIDs.count
        try await Task.sleep(for: .milliseconds(550))
        #expect(api.releasedIDs.count == releases)
    }

    @Test func failedCreationDoesNotAdvertiseKeepingAwakeAndLaterRecovers() async throws {
        let api = FakeAwakePowerAssertionAPI()
        api.createErrorType = kIOPMAssertionTypePreventUserIdleSystemSleep
        let manager = makeManager(api)
        defer { manager.shutdown() }
        manager.startManualSession()
        #expect(manager.isActive)
        #expect(!manager.isKeepingAwake)
        #expect(MenuBarIcon.systemImage(awakeActive: manager.isKeepingAwake, enforcing: false,
            awakeFailed: manager.hasAttentionIssue) == "exclamationmark.triangle")
        // The warning icon must have a matching row on the Home page.
        #expect(manager.attentionIssues == [.assertion(manager.lastAssertionFailure!)])
        api.createErrorType = nil
        try await waitUntil { manager.isKeepingAwake }
        #expect(manager.lastAssertionFailure == nil)
        #expect(manager.attentionIssues.isEmpty)
    }

    @Test func displayOffPolicyKeepsTheSessionWithoutAdvertisingAnActiveAssertion() {
        let api = FakeAwakePowerAssertionAPI()
        let manager = makeManager(api)
        defer { manager.shutdown() }
        manager.updateSettings { $0.defaultPolicy.allowSystemSleepWhenDisplayOff = true }
        manager.startManualSession()
        manager.handleDisplaysDidSleep()
        #expect(manager.isActive)
        #expect(!manager.isKeepingAwake)
        manager.handleDisplaysDidWake()
        #expect(manager.isKeepingAwake)
    }

    @Test func shutdownCancelsFurtherHealthChecks() async throws {
        let api = FakeAwakePowerAssertionAPI()
        let manager = makeManager(api)
        manager.startManualSession()
        await Task.yield()
        manager.shutdown()
        let checks = api.healthChecks
        try await Task.sleep(for: .milliseconds(550))
        #expect(api.healthChecks == checks)
        #expect(api.liveIDs.isEmpty)
        #expect(!manager.isKeepingAwake)
    }

    private func makeManager(_ api: FakeAwakePowerAssertionAPI) -> AwakeSessionManager {
        AwakeSessionManager(assertionController: AwakeAssertionController(api: api),
            powerStateProvider: AssertionTestPowerStateProvider(), maintenanceInterval: 0.25)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Maintenance did not reconcile within two seconds")
    }
}

@MainActor
private final class FakeAwakePowerAssertionAPI: AwakePowerAssertionAPI {
    var liveIDs: Set<IOPMAssertionID> = []
    var createdTypes: [String] = []
    var releasedIDs: [IOPMAssertionID] = []
    var createErrorType: String?
    var healthError: IOReturn?
    var releaseError: IOReturn?
    var healthChecks = 0
    private var nextID: IOPMAssertionID = 1

    func create(type: String, reason: String) -> (code: IOReturn, id: IOPMAssertionID) {
        createdTypes.append(type)
        if createErrorType == type { return (kIOReturnError, 0) }
        let id = nextID
        nextID += 1
        liveIDs.insert(id)
        return (kIOReturnSuccess, id)
    }

    func ensureActive(_ id: IOPMAssertionID) -> AwakeAssertionHealth {
        healthChecks += 1
        if let healthError { return .failed(healthError) }
        return liveIDs.contains(id) ? .active : .missing
    }

    func release(_ id: IOPMAssertionID) -> IOReturn {
        releasedIDs.append(id)
        if let releaseError { return releaseError }
        return liveIDs.remove(id) == nil ? kIOReturnBadArgument : kIOReturnSuccess
    }
}

private final class AssertionTestPowerStateProvider: AwakePowerStateProviding {
    func currentPowerState() -> PowerState {
        PowerState(batteryLevel: 80, charging: true, onExternalPower: true)
    }
}
