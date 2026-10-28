import Foundation
import MacPilotPowerIPC
import Testing

struct PowerHelperIdleStateTests {
    @Test func ownedStateSurvivesClientLossUntilRecoveryFinishes() {
        var state = PowerHelperIdleState()
        let client = UUID()
        let outcome1 = state.admit(client)
        #expect(outcome1)
        state.remove(client)
        let outcome2 = state.commitIdleExit(ownsPowerState: true)
        #expect(!outcome2)
        let outcome3 = state.commitIdleExit(ownsPowerState: false)
        #expect(outcome3)
        let outcome4 = state.admit(UUID())
        #expect(!outcome4)
    }
    @Test func newlyAcceptedConnectionPreventsAnIdleExit() {
        var state = PowerHelperIdleState()
        let client = UUID()
        let outcome5 = state.admit(client)
        #expect(outcome5)
        let outcome6 = state.commitIdleExit(ownsPowerState: false)
        #expect(!outcome6)
        state.remove(client)
        let outcome7 = state.commitIdleExit(ownsPowerState: false)
        #expect(outcome7)
    }
    @Test func launchdKeepsOnlyOwnedRecoveryAliveRatherThanStartingAtLogin() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/" + MacPilotPowerService.daemonPlistName))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["RunAtLoad"] as? Bool == false)
        let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
        let paths = try #require(keepAlive["PathState"] as? [String: Bool])
        let marker = URL(fileURLWithPath: MacPilotPowerService.stateDirectoryPath)
            .appendingPathComponent(MacPilotPowerService.ownershipMarkerName).path
        #expect(paths == [marker: true])
    }

}
