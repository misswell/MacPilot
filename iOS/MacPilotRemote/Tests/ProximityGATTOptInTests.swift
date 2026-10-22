import Foundation
import Testing
@testable import PilotNest

@MainActor
struct ProximityGATTOptInTests {
    @Test func aFreshInstallDoesNotStartBluetoothAndStoppingClearsOnlyTheTestIntent() throws {
        let name = "ReverseGATT-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("untouched", forKey: "remoteControlSentinel")
        let central = ProximityBLECentral(defaults: defaults)
        central.resumeIfEnabled()
        #expect(!central.isRunning)
        #expect(central.status == .idle)
        // Stopping before start must be safe and idempotent, without a radio.
        defaults.set(true, forKey: ProximityBLECentral.enabledKey)
        central.stop()
        central.stop()
        #expect(!defaults.bool(forKey: ProximityBLECentral.enabledKey))
        #expect(defaults.string(forKey: "remoteControlSentinel") == "untouched")
        #expect(!central.isConnected)
        #expect(!central.isSubscribed)
        central.applicationStateChanged(isActive: true)
        central.sendEcho()
        #expect(central.probe.sentBytes == 0)
        central.clearLog()
        #expect(central.logLines.isEmpty)
    }
}
