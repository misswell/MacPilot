import Foundation

/// Finds other running copies of this exact executable.
///
/// Two accounts fast-user-switched on one Mac each run their own MacPilot, so
/// two same-bundle processes hold independent CoreBluetooth sessions at once.
/// That combination left bluetoothd delivering advertisements to neither
/// process — the September 2026 proximity-unlock wedge — and the state
/// outlived both the app relaunch and a machine reboot while the second
/// session kept coming back. Detection is the cheap half of the fix: surface
/// the conflict instead of letting proximity unlock fail silently.
enum DuplicateInstanceDetector {
    struct ProcessSnapshot: Equatable {
        let pid: pid_t
        let executablePath: String?
    }

    /// One-shot snapshot of every process this user can see. Processes from
    /// other sessions are visible too; their `executablePath` is what ties a
    /// foreign-UID instance back to this bundle.
    static func snapshotRunningProcesses() -> [ProcessSnapshot] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        // The process table can grow between the size probe and the read;
        // retry with the new size instead of failing the check entirely.
        for _ in 0..<3 {
            let elementCount = size / MemoryLayout<kinfo_proc>.stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: elementCount)
            var resultSize = size
            guard sysctl(&name, u_int(name.count), &buffer, &resultSize, nil, 0) == 0 else {
                guard errno == ENOMEM else { return [] }
                size = resultSize * 2
                continue
            }
            return buffer.prefix(resultSize / MemoryLayout<kinfo_proc>.stride).map { proc in
                ProcessSnapshot(
                    pid: proc.kp_proc.p_pid,
                    executablePath: executablePath(for: proc.kp_proc.p_pid)
                )
            }
        }
        return []
    }

    /// Resolves a PID to its executable path through proc_pidinfo; PIDs that
    /// exited between the table read and this call yield nil and never match.
    /// The buffer size mirrors PROC_PIDPATHINFO_MAXSIZE from libproc.h (4096),
    /// which Swift does not re-export.
    private static func executablePath(for pid: pid_t) -> String? {
        let pathInfoMaxSize = 4096
        var pathBuffer = [CChar](repeating: 0, count: pathInfoMaxSize)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathInfoMaxSize))
        guard length > 0 else { return nil }
        let bytes = pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func conflictingPIDs(
        in processes: [ProcessSnapshot],
        executablePath: String,
        currentPID: pid_t
    ) -> [pid_t] {
        guard !executablePath.isEmpty else { return [] }
        return processes
            .filter { $0.pid != currentPID && $0.executablePath == executablePath }
            .map(\.pid)
            .sorted()
    }

    static func conflictingInstanceCount(
        executablePath: String = Bundle.main.executableURL?.path ?? "",
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        processes: [ProcessSnapshot] = snapshotRunningProcesses()
    ) -> Int {
        conflictingPIDs(in: processes, executablePath: executablePath, currentPID: currentPID).count
    }
}
