import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct FinderSyncRegistrationTests {
    @Test func refreshRemovesTheExistingExtensionBeforeAddingTheReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let extensionPath = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                registeredExtensionPaths: [extensionPath],
                restoreEnabledElection: true
            ) == [
                ["-r", extensionPath],
                ["-a", extensionPath],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
            ]
        )
    }

    @Test func enabledExtensionRestoresUseElectionAfterReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                restoreEnabledElection: true
            ) == [
                ["-r", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"],
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
                ["-r", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"],
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

    @Test func registeredPathsExtractAllDuplicateExtensionRecords() {
        let output = """
        +    com.misswell.macpilot.finder-sync(1.1.278)\tOLD-UUID\t/Applications/OctoPilot.app/Contents/PlugIns/FinderSync.appex
             com.misswell.macpilot.finder-sync(1.1.279)\tNEW-UUID\t/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex
        """

        #expect(
            FinderSyncRegistration.registeredExtensionPaths(in: output) == [
                "/Applications/OctoPilot.app/Contents/PlugIns/FinderSync.appex",
                "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
            ]
        )
    }
}
