import Foundation
import Testing
@testable import MacPilot

/// Two fast-switched accounts each running MacPilot left bluetoothd delivering
/// advertisements to neither process (September 2026 wedge). Detection pins
/// the conflict so the UI can name it instead of proximity unlock silently
/// dying.
struct DuplicateInstanceDetectorTests {
    private let appPath = "/Applications/MacPilot.app/Contents/MacOS/MacPilot"

    private func process(_ pid: pid_t, _ path: String?) -> DuplicateInstanceDetector.ProcessSnapshot {
        DuplicateInstanceDetector.ProcessSnapshot(pid: pid, executablePath: path)
    }

    @Test func findsOtherProcessesRunningTheSameExecutable() {
        let processes = [
            process(100, appPath),       // another session, same bundle
            process(101, appPath),       // a second one
            process(102, "/Applications/Other.app/Contents/MacOS/Other"),
            process(103, nil),           // exited before its path resolved
        ]

        #expect(DuplicateInstanceDetector.conflictingPIDs(
            in: processes,
            executablePath: appPath,
            currentPID: 100  // 100 is this process; 101 is the conflict
        ) == [101])
    }

    @Test func excludesTheCurrentProcessAndNeverMatchesItself() {
        let processes = [process(7, appPath)]
        #expect(DuplicateInstanceDetector.conflictingPIDs(
            in: processes,
            executablePath: appPath,
            currentPID: 7
        ).isEmpty)
    }

    @Test func anUnknownExecutablePathMatchesNothing() {
        let processes = [process(7, appPath)]
        #expect(DuplicateInstanceDetector.conflictingPIDs(
            in: processes,
            executablePath: "",
            currentPID: 1
        ).isEmpty)
    }

    @Test func resultsAreSortedByPIDForStableLogging() {
        let processes = [process(30, appPath), process(20, appPath), process(10, appPath)]
        #expect(DuplicateInstanceDetector.conflictingPIDs(
            in: processes,
            executablePath: appPath,
            currentPID: 10
        ) == [20, 30])
    }

    @Test func theLiveProcessTableNeverFlagsThisTestProcess() {
        // Sanity check on the real sysctl path: this test's own executable is
        // running right now, and the detector must exclude it by PID.
        #expect(DuplicateInstanceDetector.conflictingInstanceCount(
            executablePath: CommandLine.arguments.first ?? "",
            currentPID: ProcessInfo.processInfo.processIdentifier,
            processes: DuplicateInstanceDetector.snapshotRunningProcesses()
        ) == 0)
    }
}
