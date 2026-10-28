import Combine
import Foundation
import MacPilotDisplayControlCore
import Testing
@testable import MacPilot

struct DisplayControlSettingsTests {
    @Test func newInstallsAndUnknownPoliciesNeverOptIntoControl() throws {
        let empty = try JSONDecoder().decode(DisplayControlSettings.self, from: Data("{}".utf8))
        #expect(!empty.isEnabled)
        #expect(empty.uuPolicy == .none)
        let future = try JSONDecoder().decode(DisplayControlSettings.self,
            from: Data(#"{"uuPolicy":"futureMode","targetUUID":"keep-me","virtualWidth":2400}"#.utf8))
        #expect(future.uuPolicy == .none)
        #expect(future.targetUUID == "keep-me")
        #expect(future.virtualWidth == 2400)
    }

    @Test func invalidVirtualDimensionsCannotBeApplied() {
        var settings = DisplayControlSettings()
        #expect(settings.hasValidVirtualSize)
        settings.virtualWidth = 1921
        #expect(!settings.hasValidVirtualSize)
        settings.virtualWidth = 8194
        #expect(!settings.hasValidVirtualSize)
        settings.virtualWidth = 1920
        settings.virtualHeight = 0
        #expect(!settings.hasValidVirtualSize)
    }

    @Test func uncertainEvidenceDoesNotInventANewConnectionAndBypassOverride() {
        var gate = UUSessionGate()
        let now = Date(timeIntervalSince1970: 1_000)
        gate.update(.init(status: .connected, controllers: ["tablet"]), now: now)
        let first = gate.sessionID
        gate.update(.init(status: .unknown), now: now.addingTimeInterval(1))
        gate.update(.init(status: .connected, controllers: ["tablet"]), now: now.addingTimeInterval(2))
        #expect(gate.sessionID == first)
        gate.update(.init(status: .disconnected), now: now.addingTimeInterval(3))
        #expect(gate.sessionID == first)
        gate.update(.init(status: .disconnected), now: now.addingTimeInterval(5))
        #expect(gate.sessionID == nil)
        gate.update(.init(status: .connected, controllers: ["tablet"]), now: now.addingTimeInterval(6))
        #expect(gate.sessionID != first)
    }

    @Test func anotherControllerChangesSessionIdentity() {
        var gate = UUSessionGate()
        gate.update(.init(status: .connected, controllers: ["tablet"]), now: Date())
        let first = gate.sessionID
        gate.update(.init(status: .connected, controllers: ["phone"]), now: Date())
        #expect(gate.sessionID != first)
        gate.update(.init(status: .ambiguous, controllers: ["phone", "tablet"]), now: Date())
        #expect(gate.observation.status == .ambiguous)
    }
}

@MainActor
struct DisplayControlIntegrationTests {
    @Test func legacyConfigurationCannotEnableNewScreenControl() throws {
        let legacy = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data("{}".utf8))
        #expect(!legacy.enabledFeatures.contains(MainSection.displayControl.rawValue))
        #expect(!legacy.displayControl.isEnabled)
    }

    @Test func homeSwitchAlignsScreenControlWithoutStartingHardware() throws {
        let config = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self,
            from: Data(#"{"enabledFeatures":["displayControl"],"displayControl":{"isEnabled":false}}"#.utf8))
        #expect(config.aligningHomeControlledSwitches().displayControl.isEnabled)
        let disabled = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self,
            from: Data(#"{"enabledFeatures":[],"displayControl":{"isEnabled":true}}"#.utf8))
        #expect(!disabled.aligningHomeControlledSwitches().displayControl.isEnabled)
    }

    @Test func displayControlTranslationsHaveMatchingKeys() {
        #expect(Set(AppText.displayControlChinese.keys) == Set(AppText.displayControlEnglish.keys))
        for key in AppText.displayControlChinese.keys {
            #expect(AppText.value(key, language: .simplifiedChinese) != key)
            #expect(AppText.value(key, language: .english) != key)
        }
    }

    @Test func emergencyRecoveryCombinationCannotBeAssignedToAnotherFeature() {
        let reserved = SmartCaptureShortcutBinding(keyCode: 25, modifiers: [.control, .option, .command])
        #expect(reserved.validationError == .reservedKey)
    }

    @Test func missingRecoveryHelperPreventsCommands() async {
        let client = MockDisplayClient(ready: false)
        let model = makeModel(client)
        var settings = DisplayControlSettings()
        settings.isEnabled = true
        model.applyLoadedSettings(settings)
        model.start()
        defer { model.stop() }
        await model.refresh()
        model.disable(client.display)
        model.keepOnly(client.display)
        #expect(client.requests.allSatisfy { $0.command == .status })
        #expect(!model.canChange)
    }

    @Test func restoreRemainsReachableWhenFeatureIsOff() async {
        let client = MockDisplayClient(ready: true)
        let model = makeModel(client)
        #expect(!model.isRunning)
        model.restore()
        for _ in 0..<30 where model.isBusy { await Task.yield() }
        #expect(client.requests.contains { $0.command == .restore })
    }

    @Test func pendingRecoveryRetriesRestoreWithoutRenewingControl() async {
        let client = MockDisplayClient(ready: true)
        client.state = .recoveryRequired
        let model = makeModel(client)
        await model.refresh()
        #expect(model.hasRecoveryObligation)
        #expect(!model.holdsControl)
        var settings = DisplayControlSettings()
        settings.isEnabled = true
        model.applyLoadedSettings(settings)
        model.start()
        defer { model.stop() }
        for _ in 0..<100 where !client.requests.contains(where: { $0.command == .restore }) {
            await Task.yield()
        }
        #expect(client.requests.contains { $0.command == .restore })
        #expect(!client.requests.contains { $0.command == .heartbeat })
    }

    @Test func activeControlAndRecoveryHaveSeparateOwnershipStates() async {
        let client = MockDisplayClient(ready: true)
        let model = makeModel(client)
        for state in [DisplayControlState.active, .awaitingVirtualConfirmation, .awaitingKeepConfirmation] {
            client.state = state
            await model.refresh()
            #expect(model.holdsControl)
            #expect(!model.hasRecoveryObligation)
        }
        for state in [DisplayControlState.recovering, .recoveryRequired, .failed] {
            client.state = state
            await model.refresh()
            #expect(!model.holdsControl)
            #expect(model.hasRecoveryObligation)
        }
        client.state = .idle
        await model.refresh()
        #expect(!model.holdsControl)
        #expect(!model.hasRecoveryObligation)
    }

    @Test func idleStatusChecksBackOffButActiveAndRecoveryLeasesStayFast() async {
        let client = MockDisplayClient(ready: true)
        let model = makeModel(client)
        #expect(model.pollInterval == .seconds(1))
        await model.refresh()
        #expect(model.pollInterval == .seconds(15))
        for state in [DisplayControlState.active, .awaitingVirtualConfirmation,
                      .awaitingKeepConfirmation, .recovering, .recoveryRequired, .failed] {
            client.state = state
            await model.refresh()
            #expect(model.pollInterval == .seconds(1))
        }
        client.state = .idle
        await model.refresh()
        #expect(model.pollInterval == .seconds(15))
    }

    @Test func idleLoopSleepsThroughTheOldOneSecondPollingInterval() async throws {
        let client = MockDisplayClient(ready: true)
        let model = makeModel(client)
        var settings = DisplayControlSettings()
        settings.isEnabled = true
        model.applyLoadedSettings(settings)
        model.start()
        defer { model.stop() }
        for _ in 0..<200 where client.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(client.requests.count == 1)
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(client.requests.count == 1)
    }

    @Test func acquiringControlWakesTheIdleLoopToRenewItsLease() async throws {
        let client = MockDisplayClient(ready: true)
        let model = makeModel(client)
        var settings = DisplayControlSettings()
        settings.isEnabled = true
        model.applyLoadedSettings(settings)
        model.start()
        defer { model.stop() }
        for _ in 0..<200 where !model.canChange {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.state = .active
        model.keepOnly(client.display)
        for _ in 0..<200 where !client.requests.contains(where: { $0.command == .heartbeat }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(client.requests.contains { $0.command == .keepOnly })
        #expect(client.requests.contains { $0.command == .heartbeat })
    }

    @Test func rejectedCommandClearsOptimisticControlEvenWhenTheReplyIsUnchanged() async throws {
        let client = MockDisplayClient(ready: true)
        var controlMarks: [Bool] = []
        let model = DisplayControlModel(client: client,
            monitor: UUSessionMonitor(read: { .init(status: .disconnected) }),
            showsConfirmation: false, prepareVisibleOutputs: { true },
            controlStateChanged: { controlMarks.append($0) })
        var settings = DisplayControlSettings()
        settings.isEnabled = true
        model.applyLoadedSettings(settings)
        model.start()
        defer { model.stop() }
        for _ in 0..<200 where !model.canChange {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.keepOnly(client.display)
        for _ in 0..<200 where model.isBusy {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controlMarks.contains(true))
        #expect(controlMarks.last == false)
    }

    @Test func unchangedStatusDoesNotInvalidateMenusAndSettings() async {
        let client = MockDisplayClient(ready: true)
        let model = makeModel(client)
        await model.refresh()
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<100 { await model.refresh() }
        #expect(publications == 0)
        client.state = .active
        await model.refresh()
        #expect(publications > 0)
    }

    private func makeModel(_ client: MockDisplayClient) -> DisplayControlModel {
        DisplayControlModel(client: client,
            monitor: UUSessionMonitor(read: { .init(status: .disconnected) }),
            showsConfirmation: false, prepareVisibleOutputs: { true }, controlStateChanged: { _ in })
    }

    private final class MockDisplayClient: DisplayRecoverySending {
        var requests: [DisplayControlRequest] = []
        var state: DisplayControlState = .idle
        let ready: Bool
        let display = DisplayControlDisplay(uuid: "test-physical", displayID: 1, name: "Test display",
            isBuiltIn: true, isVirtual: false, isOnline: true, isActive: true,
            isMain: true, width: 1920, height: 1080)

        init(ready: Bool) { self.ready = ready }

        func send(_ request: DisplayControlRequest) async throws -> DisplayControlResponse {
            requests.append(request)
            return .init(displays: [display], state: state, helperReady: ready)
        }
    }
}
