import Foundation
import CoreServices
import Testing
@testable import MacPilot

private enum MonitoringTestError: Error {
    case timedOut
}

private func firstBatch(
    from stream: AsyncStream<FileCompressionChangeBatch>
) async throws -> FileCompressionChangeBatch {
    try await withThrowingTaskGroup(of: FileCompressionChangeBatch.self) { group in
        group.addTask {
            for await batch in stream {
                return batch
            }
            throw MonitoringTestError.timedOut
        }
        group.addTask {
            try await Task.sleep(for: .seconds(8))
            throw MonitoringTestError.timedOut
        }
        let result = try await group.next() ?? FileCompressionChangeBatch(
            changedPaths: [],
            rootsRequiringFullScan: []
        )
        group.cancelAll()
        return result
    }
}

private func firstDelivery(
    from stream: AsyncStream<FileCompressionChangeDelivery>
) async throws -> FileCompressionChangeDelivery {
    try await withThrowingTaskGroup(of: FileCompressionChangeDelivery.self) { group in
        group.addTask {
            for await delivery in stream {
                return delivery
            }
            throw MonitoringTestError.timedOut
        }
        group.addTask {
            try await Task.sleep(for: .seconds(8))
            throw MonitoringTestError.timedOut
        }
        guard let result = try await group.next() else {
            throw MonitoringTestError.timedOut
        }
        group.cancelAll()
        return result
    }
}

struct FileCompressionMonitoringTests {
    @Test func retryBackoffStopsAfterSixAttemptsUntilANewEventResetsIt() {
        var backoff = FileCompressionRetryBackoff()

        #expect((0..<6).compactMap { _ in backoff.consumeDelay() } == [5, 10, 20, 40, 80, 160])
        #expect(backoff.consumeDelay() == nil)
        backoff.reset()
        #expect(backoff.consumeDelay() == 5)
    }

    @Test func changedFilesWaitUntilStableAndRepeatedEventsResetTheirDeadline() {
        let filePath = "/tmp/monitored/new.log"
        var pending = FileCompressionPendingChanges()

        pending.record(
            FileCompressionChangeBatch(changedPaths: [filePath], rootsRequiringFullScan: []),
            now: Date(timeIntervalSince1970: 100),
            stableSeconds: 600
        )
        pending.record(
            FileCompressionChangeBatch(changedPaths: [filePath], rootsRequiringFullScan: []),
            now: Date(timeIntervalSince1970: 200),
            stableSeconds: 600
        )

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 799)).changedPaths.isEmpty)
        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 800)).changedPaths == [filePath])
    }

    @Test func fullScanRecoverySupersedesPendingChangesInsideThatRoot() {
        let root = "/tmp/monitored"
        var pending = FileCompressionPendingChanges()
        pending.record(
            FileCompressionChangeBatch(changedPaths: [root + "/new.log"], rootsRequiringFullScan: []),
            now: Date(timeIntervalSince1970: 100),
            stableSeconds: 0
        )

        pending.record(
            FileCompressionChangeBatch(changedPaths: [], rootsRequiringFullScan: [root]),
            now: Date(timeIntervalSince1970: 101),
            stableSeconds: 0
        )

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 102)).isEmpty)
        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 103)) == FileCompressionDueChanges(
            rootsRequiringFullScan: [root]
        ))
    }

    @Test func droppedFSEventsRequestRecoveryScansForEveryMonitoredRoot() {
        let roots: Set<String> = ["/tmp/first", "/tmp/second"]
        let batch = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: "/",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            )],
            monitoredRoots: roots
        )

        #expect(batch.changedPaths.isEmpty)
        #expect(batch.rootsRequiringFullScan == Set(roots.map(FileCompressionPath.canonical)))
    }

    @Test func mustScanSubdirectoriesRequestsRecoveryInsteadOfBeingFilteredAsDirectoryNoise() {
        let roots: Set<String> = ["/tmp/first", "/tmp/second"]
        let batch = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: "/tmp/first",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            )],
            monitoredRoots: roots
        )

        #expect(batch.changedPaths == [FileCompressionPath.canonical("/tmp/first")])
        #expect(batch.rootsRequiringFullScan.isEmpty)
    }

    @Test func failedDueChangesCanBeRequeuedWithABoundedDelay() {
        let path = "/tmp/monitored/new.log"
        var pending = FileCompressionPendingChanges()
        pending.requeue(
            FileCompressionDueChanges(changedPaths: [path]),
            now: Date(timeIntervalSince1970: 100),
            delaySeconds: 5
        )

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 104)).isEmpty)
        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 105)).changedPaths == [path])
    }

    @Test func retryNeverShortensADeadlineResetByANewerFileEvent() {
        let path = "/tmp/monitored/new.log"
        var pending = FileCompressionPendingChanges()
        pending.record(
            FileCompressionChangeBatch(changedPaths: [path], rootsRequiringFullScan: []),
            now: Date(timeIntervalSince1970: 200),
            stableSeconds: 600
        )
        pending.requeue(
            FileCompressionDueChanges(changedPaths: [path]),
            now: Date(timeIntervalSince1970: 201),
            delaySeconds: 5
        )

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 799)).isEmpty)
        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 800)).changedPaths == [path])
    }

    @Test func changingTheStabilityWindowReschedulesAlreadyPendingPaths() {
        let path = "/tmp/monitored/new.log"
        var pending = FileCompressionPendingChanges()
        pending.record(
            FileCompressionChangeBatch(changedPaths: [path], rootsRequiringFullScan: []),
            now: Date(timeIntervalSince1970: 100),
            stableSeconds: 600
        )
        pending.rescheduleAll(
            now: Date(timeIntervalSince1970: 200),
            stableSeconds: 3_600
        )

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 700)).isEmpty)
        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 3_800)).changedPaths == [path])
    }

    @Test func folderReconfigurationRetainsPendingPathsOnlyInsideRemainingRoots() {
        var pending = FileCompressionPendingChanges()
        pending.record(
            FileCompressionChangeBatch(
                changedPaths: ["/tmp/kept/new.log", "/tmp/removed/old.log"],
                rootsRequiringFullScan: []
            ),
            now: Date(timeIntervalSince1970: 100),
            stableSeconds: 600
        )

        pending.retainPaths(inside: ["/tmp/kept", "/tmp/added"])

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 700)).changedPaths == ["/tmp/kept/new.log"])
    }

    @Test func mountEventsRequestRecoveryOnlyForTheAffectedRoot() {
        let roots: Set<String> = ["/tmp/first", "/tmp/second"]
        let batch = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: "/tmp/first/mounted-volume",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMount)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
            )],
            monitoredRoots: roots
        )

        #expect(batch.rootsRequiringFullScan == [FileCompressionPath.canonical("/tmp/first")])
    }

    @Test func eventsOutsideMonitoredRootsAreIgnored() {
        let batch = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: "/tmp/elsewhere/new.log",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            )],
            monitoredRoots: ["/tmp/monitored"]
        )

        #expect(batch.changedPaths.isEmpty)
        #expect(batch.rootsRequiringFullScan.isEmpty)
    }

    @Test func internalCompressionTemporaryFilesNeverResetTheExternalChangeQueue() {
        let root = "/tmp/monitored"
        let batch = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: root + "/.macpilot-compression-1234",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            )],
            monitoredRoots: [root]
        )

        #expect(batch.changedPaths.isEmpty)
        #expect(batch.rootsRequiringFullScan.isEmpty)
    }

    @Test func directoryMetadataNoiseIsIgnoredButNewDirectoriesAreInspected() {
        let root = "/tmp/monitored"
        let metadataOnly = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: root + "/nested",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            )],
            monitoredRoots: [root]
        )
        let created = FileCompressionChangeBatch.from(
            events: [FileCompressionFileEvent(
                path: root + "/new-directory",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            )],
            monitoredRoots: [root]
        )

        #expect(metadataOnly.changedPaths.isEmpty)
        #expect(created.changedPaths == [FileCompressionPath.canonical(root + "/new-directory")])
    }

    @Test func dueParentDirectorySupersedesChangedChildren() {
        let root = "/tmp/monitored"
        var pending = FileCompressionPendingChanges()
        pending.record(
            FileCompressionChangeBatch(
                changedPaths: [root + "/nested", root + "/nested/first.log", root + "/nested/second.log"],
                rootsRequiringFullScan: []
            ),
            now: Date(timeIntervalSince1970: 100),
            stableSeconds: 0
        )

        #expect(pending.takeDue(at: Date(timeIntervalSince1970: 102)).changedPaths == [root + "/nested"])
    }

    @Test func fseventsMonitorReportsANewFileWithoutScanningTheWholeRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotMonitoringTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expectedPath = root.appendingPathComponent("new.log")
            .path
        let canonicalExpectedPath = FileCompressionPath.canonical(expectedPath)
        let events = AsyncStream<FileCompressionChangeBatch>.makeStream()
        let monitor = FileCompressionEventMonitor()
        defer { monitor.stop() }
        for _ in 0..<10 {
            #expect(monitor.start(paths: [root.path]) { _ in })
            monitor.stop()
        }
        #expect(monitor.start(paths: [root.path]) { events.continuation.yield($0.batch) })
        try await Task.sleep(for: .milliseconds(500))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [expectedPath]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let batch = try await firstBatch(from: events.stream)

        #expect(batch.changedPaths == [canonicalExpectedPath])
        #expect(batch.rootsRequiringFullScan.isEmpty)
    }

    @Test func restartingFromTheLastDeliveredEventIDReplaysChangesMadeWhileStopped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotMonitoringResumeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expectedPath = root.appendingPathComponent("during-restart.log").path
        let monitor = FileCompressionEventMonitor()
        defer { monitor.stop() }
        #expect(monitor.start(paths: [root.path]) { _ in })
        let resumeEventID = try #require(monitor.resumeEventID)
        monitor.stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [expectedPath]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let events = AsyncStream<FileCompressionChangeBatch>.makeStream()
        #expect(monitor.start(
            paths: [root.path],
            sinceWhen: resumeEventID
        ) { events.continuation.yield($0.batch) })
        let batch = try await firstBatch(from: events.stream)

        #expect(batch.changedPaths.contains(FileCompressionPath.canonical(expectedPath)))
    }

    @Test func anUnacknowledgedCallbackBatchIsReplayedAfterReconfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotMonitoringAckTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expectedPath = root.appendingPathComponent("not-yet-accepted.log").path
        let monitor = FileCompressionEventMonitor()
        defer { monitor.stop() }
        let firstDeliveries = AsyncStream<FileCompressionChangeDelivery>.makeStream()
        #expect(monitor.start(paths: [root.path]) { firstDeliveries.continuation.yield($0) })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [expectedPath]
        try process.run()
        process.waitUntilExit()
        let first = try await firstDelivery(from: firstDeliveries.stream)
        let resumeEventID = try #require(monitor.resumeEventID)
        #expect(resumeEventID < first.eventID)
        monitor.stop()

        let replayedDeliveries = AsyncStream<FileCompressionChangeDelivery>.makeStream()
        #expect(monitor.start(
            paths: [root.path],
            sinceWhen: resumeEventID
        ) { replayedDeliveries.continuation.yield($0) })
        let replayed = try await firstDelivery(from: replayedDeliveries.stream)
        monitor.acknowledge(replayed)

        #expect(replayed.batch.changedPaths.contains(FileCompressionPath.canonical(expectedPath)))
    }

    @Test func acknowledgementsAdvanceOnlyAfterEveryEarlierBatchIsAccepted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotMonitoringOrderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let monitor = FileCompressionEventMonitor()
        defer { monitor.stop() }
        let deliveries = AsyncStream<FileCompressionChangeDelivery>.makeStream()
        #expect(monitor.start(paths: [root.path]) { deliveries.continuation.yield($0) })
        _ = try #require(monitor.resumeEventID)

        func touch(_ name: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            process.arguments = [root.appendingPathComponent(name).path]
            try process.run()
            process.waitUntilExit()
        }

        try touch("first.log")
        let first = try await firstDelivery(from: deliveries.stream)
        try touch("second.log")
        let second = try await firstDelivery(from: deliveries.stream)
        #expect(first.eventID < second.eventID)
        let resumeBeforeOutOfOrderAcknowledgement = monitor.resumeEventID

        monitor.acknowledge(second)
        #expect(monitor.resumeEventID == resumeBeforeOutOfOrderAcknowledgement)
        monitor.acknowledge(first)
        #expect(monitor.resumeEventID == second.eventID)
    }
}
