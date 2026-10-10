import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct UpdaterLaunchPlanTests {
    @Test func relaunchPlanRunsTheReplacedBundleExecutable() {
        let application = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            UpdaterLaunchPlan.directExecutableURL(for: application).path
                == "/Applications/MacPilot.app/Contents/MacOS/MacPilot"
        )
        #expect(
            UpdaterLaunchPlan.directExecutableURL(
                for: URL(fileURLWithPath: "/Applications/OctoPilot.app"),
                executableName: "OctoPilot"
            ).path == "/Applications/OctoPilot.app/Contents/MacOS/OctoPilot"
        )
    }
}

struct FinderSyncRegistrationTests {
    @Test func enabledExtensionIsPausedBeforeReplacementAndResumedAfterRegistration() throws {
        try withTemporaryJournal { journal in
            var elected = true
            var events: [String] = []
            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                journal: journal,
                execute: { arguments in
                    events.append(arguments.joined(separator: " "))
                    if arguments.contains("ignore") { elected = false }
                    if arguments.contains("use") { elected = true }
                },
                query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                operation: {
                    events.append("replace bundle")
                    events.append("refresh registration")
                }
            )
            #expect(events == [
                "-e ignore -i com.misswell.macpilot.finder-sync",
                "replace bundle",
                "refresh registration",
                "-e use -i com.misswell.macpilot.finder-sync"
            ])
        }
    }

    @Test func failedReplacementRestoresElectionAndPreservesTheOriginalError() {
        enum Failure: Error { case replacement }
        do {
            try withTemporaryJournal { journal in
                var elected = true
                var events: [String] = []
                do {
                    try FinderSyncRegistration.withSuspendedElection(
                        applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                        journal: journal,
                        execute: { arguments in
                            events.append(arguments.joined(separator: " "))
                            if arguments.contains("ignore") { elected = false }
                            if arguments.contains("use") { elected = true }
                        },
                        query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                        operation: { throw Failure.replacement }
                    )
                    Issue.record("Replacement failure must propagate")
                } catch {
                    #expect(error is Failure)
                }
                #expect(events == [
                    "-e ignore -i com.misswell.macpilot.finder-sync",
                    "-e use -i com.misswell.macpilot.finder-sync"
                ])
            }
        } catch {
            Issue.record("Temporary journal setup failed: \(error)")
        }
    }

    @Test func disabledElectionIsLeftDisabledThroughoutReplacement() throws {
        try withTemporaryJournal { journal in
            var replaced = false
            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                journal: journal,
                execute: { _ in Issue.record("A disabled extension must not be elected") },
                query: { _ in finderSyncOutput(enabled: false, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                operation: { replaced = true }
            )
            #expect(replaced)
        }
    }

    @Test func failedSuspensionPreventsBundleReplacement() {
        enum Failure: Error { case suspension }
        do {
            try withTemporaryJournal { journal in
                var elected = true
                var replaced = false
                #expect(throws: Failure.self) {
                    try FinderSyncRegistration.withSuspendedElection(
                        applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                        journal: journal,
                        execute: { arguments in
                            if arguments.contains("ignore") {
                                elected = false
                                throw Failure.suspension
                            }
                            if arguments.contains("use") { elected = true }
                        },
                        query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                        operation: { replaced = true }
                    )
                }
                #expect(!replaced)
            }
        } catch {
            Issue.record("Temporary journal setup failed: \(error)")
        }
    }

    @Test func restorationFailureIsReportedWithoutMaskingReplacementFailure() {
        enum Failure: Error, Equatable { case replacement, restoration }
        do {
            try withTemporaryJournal { journal in
                var elected = true
                var reported: Failure?
                do {
                    try FinderSyncRegistration.withSuspendedElection(
                        applicationURL: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                        journal: journal,
                        execute: { arguments in
                            if arguments.contains("ignore") { elected = false }
                            if arguments.contains("use") { throw Failure.restoration }
                        },
                        query: { _ in finderSyncOutput(enabled: elected, at: URL(fileURLWithPath: "/Applications/MacPilot.app")) },
                        restorationFailed: { reported = $0 as? Failure },
                        operation: { throw Failure.replacement }
                    )
                    Issue.record("Replacement failure must propagate")
                } catch {
                    #expect((error as? Failure) == .replacement)
                }
                #expect(reported == .restoration)
            }
        } catch {
            Issue.record("Temporary journal setup failed: \(error)")
        }
    }

    @Test func startupRecoveryDoesNotOverrideADisabledSystemExtension() throws {
        try withTemporaryJournal { journal in
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: URL(fileURLWithPath: "/Applications/MacPilot.app"),
                journal: journal,
                execute: {
                    commands.append($0)
                    return "-    com.misswell.macpilot.finder-sync(1.1.501)"
                }
            )
            #expect(!recovered)
            #expect(commands == [FinderSyncRegistration.queryArguments()])
        }
    }

    @Test func startupRecoveryRemovesStaleVersionsWhileLaunchesAreSuspended() throws {
        let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let current = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
        let stale = "/Users/developer/Code/MacPilot.app/Contents/PlugIns/FinderSync.appex"
        try withTemporaryJournal { journal in
            var commands: [[String]] = []
            var elected = true
            let recovered = try FinderSyncRegistration.recoverIfEnabled(at: app, journal: journal, execute: {
                commands.append($0)
                if $0 == FinderSyncRegistration.queryArguments() {
                    return finderSyncOutput(enabled: elected, at: app)
                }
                if $0 == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                    return """
                    + com.misswell.macpilot.finder-sync(1.1.469)\tOLD\t\(stale)
                    + com.misswell.macpilot.finder-sync(1.1.501)\tNEW\t\(current)
                    """
                }
                if $0.contains("ignore") { elected = false }
                if $0.contains("use") { elected = true }
                return ""
            })
            #expect(recovered)
            #expect(commands == [
                FinderSyncRegistration.queryArguments(),
                FinderSyncRegistration.queryArguments(includeAllVersions: true),
                ["-e", "ignore", "-i", FinderSyncRegistration.extensionBundleIdentifier],
                ["-r", stale], ["-r", current], ["-a", current],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier],
                FinderSyncRegistration.queryArguments()
            ])
        }
    }

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

    private func withTemporaryJournal<T>(_ body: (FinderSyncRecoveryJournal) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderSyncRegistrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(FinderSyncRecoveryJournal(fileURL: directory.appendingPathComponent("journal.json")))
    }
}

private func finderSyncOutput(enabled: Bool, at applicationURL: URL) -> String {
    let status = enabled ? "+" : "-"
    let extensionPath = applicationURL
        .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
        .path
    return "\(status)\tcom.misswell.macpilot.finder-sync(1.1.501)\tTEST-UUID\t\(extensionPath)"
}
