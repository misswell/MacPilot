import Darwin
import Foundation

struct CPUTimeCounters: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64
}

struct SystemCPUSnapshot: Equatable, Sendable {
    let userPercent: Double
    let systemPercent: Double
    let nicePercent: Double
    let idlePercent: Double
    let totalPercent: Double
    let logicalCoreCount: Int
    let loadAverage: [Double]
}

/// `proc_taskinfo` 的 CPU 计数单位是 mach absolute time，而不是纳秒。
/// Apple Silicon 的 timebase 是 125/3（一个 tick ≈ 41.67 ns），把它当成纳秒会按同样的
/// 倍数低估每个应用的占用：系统显示 25%、列表却全是 0.1% 就是这么来的。
/// Intel 机器的 timebase 是 1/1，所以这个换算在那边是恒等变换。
enum MachCPUTime {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            return (1, 1)
        }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let timebase = timebase
        return nanoseconds(fromMachTicks: ticks, numer: timebase.numer, denom: timebase.denom)
    }

    /// 先整除再乘，避免长时间运行进程累计的 tick 在乘法里溢出 UInt64。
    static func nanoseconds(fromMachTicks ticks: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        guard numer > 0, denom > 0 else { return ticks }
        let quotient = ticks / denom
        let remainder = ticks % denom
        let (high, highOverflow) = quotient.multipliedReportingOverflow(by: numer)
        let (low, lowOverflow) = remainder.multipliedReportingOverflow(by: numer)
        guard !highOverflow, !lowOverflow else { return UInt64.max }
        let (total, overflow) = high.addingReportingOverflow(low / denom)
        return overflow ? UInt64.max : total
    }
}

enum CPUUsageCalculator {
    /// Converts process CPU nanoseconds to a percentage of the whole machine.
    /// One fully busy logical core therefore contributes 100 / coreCount percent.
    static func processPercent(
        deltaCPUTime: UInt64,
        elapsed: TimeInterval,
        logicalCoreCount: Int
    ) -> Double {
        guard deltaCPUTime > 0, elapsed > 0 else { return 0 }
        let coreCount = Double(max(1, logicalCoreCount))
        let capacity = elapsed * 1_000_000_000 * coreCount
        guard capacity > 0 else { return 0 }
        return min(100, max(0, Double(deltaCPUTime) / capacity * 100))
    }

    static func systemSnapshot(
        previous: CPUTimeCounters,
        current: CPUTimeCounters,
        logicalCoreCount: Int,
        loadAverage: [Double]
    ) -> SystemCPUSnapshot {
        let user = delta(current.user, previous.user)
        let system = delta(current.system, previous.system)
        let nice = delta(current.nice, previous.nice)
        let idle = delta(current.idle, previous.idle)
        let total = user + system + nice + idle

        guard total > 0 else {
            return SystemCPUSnapshot(
                userPercent: 0,
                systemPercent: 0,
                nicePercent: 0,
                idlePercent: 0,
                totalPercent: 0,
                logicalCoreCount: max(1, logicalCoreCount),
                loadAverage: loadAverage
            )
        }

        let totalValue = Double(total)
        let userPercent = Double(user) / totalValue * 100
        let systemPercent = Double(system) / totalValue * 100
        let nicePercent = Double(nice) / totalValue * 100
        let idlePercent = Double(idle) / totalValue * 100
        return SystemCPUSnapshot(
            userPercent: userPercent,
            systemPercent: systemPercent,
            nicePercent: nicePercent,
            idlePercent: idlePercent,
            totalPercent: min(100, max(0, userPercent + systemPercent + nicePercent)),
            logicalCoreCount: max(1, logicalCoreCount),
            loadAverage: loadAverage
        )
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

struct CPUUsageSampleResult: Sendable {
    let apps: [AppCPUUsage]
    let system: SystemCPUSnapshot?
}

/// Samples cumulative process and host CPU counters and turns them into an
/// interval-based usage snapshot. The lock keeps menu-bar and page refreshes
/// from corrupting the previous-counter baseline when they overlap.
final class CPUUsageSampler: @unchecked Sendable {
    private struct ProcessCounter {
        let cpuTime: UInt64
        let startedAt: Date?
    }

    private let lock = NSLock()
    private var previousProcessCounters: [pid_t: ProcessCounter] = [:]
    private var previousSystemCounters: CPUTimeCounters?

    func reset() {
        lock.lock()
        previousProcessCounters.removeAll(keepingCapacity: true)
        previousSystemCounters = nil
        previousSampleUptime = nil
        lock.unlock()
    }

    func sample() -> CPUUsageSampleResult {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed: TimeInterval
        if let previous = previousSampleUptime {
            elapsed = max(0, now - previous)
        } else {
            elapsed = 0
        }

        let logicalCoreCount = max(1, ProcessInfo.processInfo.processorCount)
        let processInfos = ProcessCollector.shared.sample()
        var currentProcessCounters: [pid_t: ProcessCounter] = [:]
        currentProcessCounters.reserveCapacity(processInfos.count)
        var processSamples: [ProcessCPUSample] = []
        processSamples.reserveCapacity(processInfos.count)

        for process in processInfos {
            guard let cpuTime = Self.cpuTime(of: process.pid) else { continue }
            currentProcessCounters[process.pid] = ProcessCounter(
                cpuTime: cpuTime,
                startedAt: process.startedAt
            )
            let delta: UInt64
            if let previous = previousProcessCounters[process.pid], previous.startedAt == process.startedAt {
                delta = cpuTime >= previous.cpuTime ? cpuTime - previous.cpuTime : 0
            } else {
                delta = 0
            }
            processSamples.append(
                ProcessCPUSample(
                    pid: process.pid,
                    name: process.name,
                    executablePath: process.executablePath,
                    cpuPercent: CPUUsageCalculator.processPercent(
                        deltaCPUTime: MachCPUTime.nanoseconds(fromMachTicks: delta),
                        elapsed: elapsed,
                        logicalCoreCount: logicalCoreCount
                    ),
                    startedAt: process.startedAt
                )
            )
        }

        let currentSystemCounters = Self.systemCounters()
        let system: SystemCPUSnapshot?
        if let currentSystemCounters {
            if let previousSystemCounters {
                system = CPUUsageCalculator.systemSnapshot(
                    previous: previousSystemCounters,
                    current: currentSystemCounters,
                    logicalCoreCount: logicalCoreCount,
                    loadAverage: Self.loadAverage()
                )
            } else {
                system = SystemCPUSnapshot(
                    userPercent: 0,
                    systemPercent: 0,
                    nicePercent: 0,
                    idlePercent: 0,
                    totalPercent: 0,
                    logicalCoreCount: logicalCoreCount,
                    loadAverage: Self.loadAverage()
                )
            }
        } else {
            system = nil
        }

        previousProcessCounters = currentProcessCounters
        previousSystemCounters = currentSystemCounters
        previousSampleUptime = now
        return CPUUsageSampleResult(
            apps: AppCPUGrouper.group(processSamples),
            system: system
        )
    }

    private var previousSampleUptime: TimeInterval?

    /// 返回累计 CPU 时间，单位是 mach absolute time（不是纳秒），
    /// 需要经 MachCPUTime 换算后才能和纳秒口径的 elapsed 一起做百分比。
    private static func cpuTime(of pid: pid_t) -> UInt64? {
        var taskInfo = proc_taskinfo()
        let result = proc_pidinfo(
            pid,
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            Int32(MemoryLayout<proc_taskinfo>.stride)
        )
        guard result == Int32(MemoryLayout<proc_taskinfo>.stride) else { return nil }
        let (total, overflow) = taskInfo.pti_total_user.addingReportingOverflow(taskInfo.pti_total_system)
        return overflow ? UInt64.max : total
    }

    private static func systemCounters() -> CPUTimeCounters? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTimeCounters(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
    }

    private static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = values.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return getloadavg(baseAddress, 3)
        }
        guard count > 0 else { return [] }
        return Array(values.prefix(Int(min(count, 3))))
    }
}
