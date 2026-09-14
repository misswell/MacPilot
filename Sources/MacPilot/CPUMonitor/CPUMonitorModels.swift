import Foundation

struct ProcessCPUSample: ProcessMonitorSample {
    let pid: pid_t
    let name: String
    let executablePath: String?
    let cpuPercent: Double
    let startedAt: Date?

    var id: Int32 { pid }

    var runningDurationInterval: TimeInterval? {
        startedAt.map { max(0, Date().timeIntervalSince($0)) }
    }
}

struct AppCPUUsage: Identifiable, Equatable, Sendable {
    let familyKey: String
    let name: String
    let bundlePath: String?
    let cpuPercent: Double
    let processes: [ProcessCPUSample]
    let earliestStartedAt: Date?

    var id: String { familyKey }
    var processCount: Int { processes.count }

    var runningDurationInterval: TimeInterval? {
        earliestStartedAt.map { max(0, Date().timeIntervalSince($0)) }
    }
}

enum AppCPUGrouper {
    static func group(_ samples: [ProcessCPUSample]) -> [AppCPUUsage] {
        AppProcessFamilyGrouper.group(samples)
            .map { family in
                AppCPUUsage(
                    familyKey: family.familyKey,
                    name: family.name,
                    bundlePath: family.bundlePath,
                    cpuPercent: family.processes.reduce(0) { $0 + $1.cpuPercent },
                    processes: family.processes.sorted { $0.cpuPercent > $1.cpuPercent },
                    earliestStartedAt: family.earliestStartedAt
                )
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    static func appBundlePath(ofExecutable path: String) -> String? {
        AppProcessFamilyGrouper.appBundlePath(ofExecutable: path)
    }

    static func pathContainsAppName(_ path: String, appName: String) -> Bool {
        AppProcessFamilyGrouper.pathContainsAppName(path, appName: appName)
    }
}

enum CPUPercentFormatter {
    static func string(from percent: Double) -> String {
        String(format: "%.1f%%", min(100, max(0, percent)))
    }
}
