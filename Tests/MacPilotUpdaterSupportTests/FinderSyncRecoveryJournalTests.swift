import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct FinderSyncRecoveryJournalTests {
    private let applicationURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
    private let extensionIdentifier = "com.misswell.macpilot.finder-sync"

    @Test func disabledWithoutJournalDoesNotRegisterOrEnable() throws {
        try withTemporaryJournal { journal, _ in
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL,
                journal: journal,
                execute: { arguments in
                    commands.append(arguments)
                    return "-    \(extensionIdentifier)(1.1.501)"
                }
            )

            #expect(!recovered)
            #expect(commands == [FinderSyncRegistration.queryArguments()])
        }
    }

    @Test func emptyPlugInKitQueryDoesNotCauseUnconditionalRegistration() throws {
        try withTemporaryJournal { journal, _ in
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL,
                journal: journal,
                execute: { arguments in
                    commands.append(arguments)
                    return ""
                }
            )

            #expect(!recovered)
            #expect(commands == [FinderSyncRegistration.queryArguments()])
        }
    }

    @Test func queryFailureDoesNotWriteJournalOrRunRegistrationCommands() throws {
        enum Failure: Error { case query }

        try withTemporaryJournal { journal, markerURL in
            var executionCount = 0
            #expect(throws: Failure.self) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { _ in executionCount += 1 },
                    query: { _ in throw Failure.query },
                    operation: {}
                )
            }

            #expect(executionCount == 0)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func markerIsWrittenBeforeIgnoreAndClearedOnlyAfterEnabledQuery() throws {
        try withTemporaryJournal { journal, markerURL in
            var elected = true
            var events: [String] = []
            try FinderSyncRegistration.withSuspendedElection(
                applicationURL: applicationURL,
                journal: journal,
                execute: { arguments in
                    events.append(arguments.joined(separator: " "))
                    if arguments.contains("ignore") {
                        #expect(FileManager.default.fileExists(atPath: markerURL.path))
                        elected = false
                    }
                    if arguments.contains("use") { elected = true }
                },
                query: { _ in
                    if events.contains("-e use -i \(extensionIdentifier)") {
                        #expect(FileManager.default.fileExists(atPath: markerURL.path))
                    }
                    events.append("query \(elected ? "+" : "-")")
                    return plugInOutput(enabled: elected, at: applicationURL)
                },
                operation: {
                    #expect(FileManager.default.fileExists(atPath: markerURL.path))
                    events.append("replace bundle")
                }
            )

            #expect(events == [
                "query +",
                "-e ignore -i \(extensionIdentifier)",
                "replace bundle",
                "-e use -i \(extensionIdentifier)",
                "query +"
            ])
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func cancelledOperationStillRunsUncancelledRestoration() throws {
        try withTemporaryJournal { journal, markerURL in
            var elected = true
            var commands: [[String]] = []

            #expect(throws: CancellationError.self) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        if arguments.contains("ignore") { elected = false }
                        if arguments.contains("use") { elected = true }
                    },
                    query: { _ in plugInOutput(enabled: elected, at: applicationURL) },
                    operation: { throw CancellationError() }
                )
            }

            #expect(commands.last == ["-e", "use", "-i", extensionIdentifier])
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func successfulUseCommandWithoutEnabledReadbackRetainsMarker() throws {
        try withTemporaryJournal { journal, markerURL in
            var events: [String] = []
            var queryCount = 0
            #expect(throws: FinderSyncRegistrationError.restorationNotConfirmed) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { events.append($0.joined(separator: " ")) },
                    query: { _ in
                        queryCount += 1
                        let election = queryCount == 1 ? "+" : "-"
                        events.append("query \(election)")
                        return plugInOutput(enabled: election == "+", at: applicationURL)
                    },
                    operation: {}
                )
            }

            #expect(events == [
                "query +",
                "-e ignore -i \(extensionIdentifier)",
                "-e use -i \(extensionIdentifier)",
                "query -"
            ])
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func crashedSuspensionCanBeRecoveredByAnotherJournalInstance() throws {
        enum Failure: Error { case simulatedCrash }

        try withTemporaryJournal { journal, markerURL in
            var elected = true
            #expect(throws: Failure.self) {
                try FinderSyncRegistration.withSuspendedElection(
                    applicationURL: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        if arguments.contains("ignore") { elected = false }
                        if arguments.contains("use") { throw FinderSyncRegistrationError.restorationNotConfirmed }
                    },
                    query: { _ in plugInOutput(enabled: elected, at: applicationURL) },
                    operation: { throw Failure.simulatedCrash }
                )
            }
            #expect(FileManager.default.fileExists(atPath: markerURL.path))

            let restartedJournal = FinderSyncRecoveryJournal(fileURL: markerURL)
            var commands: [[String]] = []
            let recovered = try FinderSyncRegistration.recoverIfEnabled(
                at: applicationURL,
                journal: restartedJournal,
                execute: { arguments in
                    commands.append(arguments)
                    if arguments.contains("use") { elected = true }
                    if arguments == FinderSyncRegistration.queryArguments() {
                        return plugInOutput(enabled: elected, at: applicationURL)
                    }
                    if arguments == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                        return "+    \(extensionIdentifier)(1.1.501)\tAPP\t/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
                    }
                    return ""
                }
            )

            #expect(recovered)
            #expect(commands.contains(["-e", "use", "-i", extensionIdentifier]))
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func enabledStalePathDoesNotClearMarkerWhenUseReadbackStillNamesOldBundle() throws {
        try withTemporaryJournal { journal, markerURL in
            try journal.withExclusiveLock { access in
                try access.writeIntent(for: applicationURL)
            }
            let oldApplication = URL(fileURLWithPath: "/Applications/OldMacPilot.app")
            var elected = true
            var commands: [[String]] = []

            #expect(throws: FinderSyncRegistrationError.restorationNotConfirmed) {
                _ = try FinderSyncRegistration.recoverIfEnabled(
                    at: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        if arguments.contains("ignore") { elected = false }
                        if arguments.contains("use") { elected = true }
                        if arguments == FinderSyncRegistration.queryArguments() {
                            return plugInOutput(enabled: elected, at: oldApplication)
                        }
                        if arguments == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                            return plugInOutput(enabled: true, at: oldApplication)
                        }
                        return ""
                    }
                )
            }

            #expect(FileManager.default.fileExists(atPath: markerURL.path))
            #expect(commands.contains(["-e", "use", "-i", extensionIdentifier]))
        }
    }

    @Test func corruptedMarkerNeverAuthorizesAutomaticReenable() throws {
        try withTemporaryJournal { journal, markerURL in
            try Data(#"{"schemaVersion":999,"bundleIdentifier":"com.misswell.macpilot.finder-sync"}"#.utf8)
                .write(to: markerURL, options: .atomic)
            var commands: [[String]] = []

            #expect(throws: FinderSyncRecoveryJournalError.invalidMarker) {
                _ = try FinderSyncRegistration.recoverIfEnabled(
                    at: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        return "-    \(extensionIdentifier)(1.1.501)"
                    }
                )
            }

            #expect(commands == [FinderSyncRegistration.queryArguments()])
            #expect(try Data(contentsOf: markerURL) == Data(#"{"schemaVersion":999,"bundleIdentifier":"com.misswell.macpilot.finder-sync"}"#.utf8))
        }
    }

    @Test func validMarkerForAnotherApplicationCannotAuthorizeRecovery() throws {
        try withTemporaryJournal { journal, markerURL in
            let otherApplication = URL(fileURLWithPath: "/Applications/Other.app")
            try journal.withExclusiveLock { access in
                try access.writeIntent(for: otherApplication)
            }
            var commands: [[String]] = []

            #expect(throws: FinderSyncRegistrationError.journalTargetMismatch) {
                _ = try FinderSyncRegistration.recoverIfEnabled(
                    at: applicationURL,
                    journal: journal,
                    execute: { arguments in
                        commands.append(arguments)
                        return "-    \(extensionIdentifier)(1.1.501)"
                    }
                )
            }

            #expect(commands == [FinderSyncRegistration.queryArguments()])
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
    }

    @Test func lockContentionFailsPromptlyInsteadOfWaitingIndefinitely() throws {
        try withTemporaryJournal { journal, _ in
            try journal.withExclusiveLock { _ in
                #expect(throws: FinderSyncRecoveryJournalError.lockBusy) {
                    try journal.withExclusiveLock { _ in }
                }
            }
        }
    }

    @Test func lookalikeBundleIdentifierDoesNotCountAsEnabled() {
        #expect(
            !FinderSyncRegistration.isElectedForUse(
                in: "+ com.misswell.macpilot.finder-sync-copy(1.1.501)"
            )
        )
    }

    private func withTemporaryJournal<T>(
        _ body: (FinderSyncRecoveryJournal, URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderSyncRecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent("finder-sync-recovery.json")
        return try body(FinderSyncRecoveryJournal(fileURL: markerURL), markerURL)
    }

    private func plugInOutput(enabled: Bool, at applicationURL: URL) -> String {
        let status = enabled ? "+" : "-"
        let extensionPath = applicationURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path
        return "\(status)\t\(extensionIdentifier)(1.1.501)\tTEST-UUID\t\(extensionPath)"
    }
}
