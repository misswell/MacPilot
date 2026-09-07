import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct FinderSyncRegistrationTests {
    @Test func enabledExtensionRestoresUseElectionAfterReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                restoreEnabledElection: true
            ) == [
                ["-a", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
            ]
        )
    }

    @Test func disabledExtensionIsNotSilentlyReenabled() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                restoreEnabledElection: false
            ) == [
                ["-a", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"]
            ]
        )
    }

    @Test func onlyEnabledMatchingExtensionIsRestored() {
        #expect(
            FinderSyncRegistration.isElectedForUse(
                in: "     com.apple.FinderSync(1.0)\n+    com.misswell.macpilot.finder-sync(1.1.263)"
            )
        )
        #expect(
            !FinderSyncRegistration.isElectedForUse(
                in: "     com.misswell.macpilot.finder-sync(1.1.263)"
            )
        )
    }
}
