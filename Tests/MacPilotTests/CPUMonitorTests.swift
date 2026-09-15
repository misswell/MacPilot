import Foundation
import Testing
@testable import MacPilot

struct CPUMonitorTests {
    private func sample(
        _ pid: Int32,
        _ name: String,
        path: String? = nil,
        _ cpuPercent: Double
    ) -> ProcessCPUSample {
        ProcessCPUSample(
            pid: pid,
            name: name,
            executablePath: path,
            cpuPercent: cpuPercent,
            startedAt: nil
        )
    }

    @Test func cpuPercentUsesWholeMachineCapacity() {
        let percent = CPUUsageCalculator.processPercent(
            deltaCPUTime: 2_000_000_000,
            elapsed: 1,
            logicalCoreCount: 4
        )

        #expect(abs(percent - 50) < 0.001)
    }

    /// proc_taskinfo 的计数单位是 mach absolute time；Apple Silicon 的 timebase 是
    /// 125/3。直接把它当纳秒会让每个应用的占用低 41.67 倍。
    @Test func machTicksAreConvertedToNanoseconds() {
        #expect(MachCPUTime.nanoseconds(fromMachTicks: 3, numer: 125, denom: 3) == 125)
        #expect(MachCPUTime.nanoseconds(fromMachTicks: 24_000_000, numer: 125, denom: 3) == 1_000_000_000)
        #expect(MachCPUTime.nanoseconds(fromMachTicks: 1_000_000, numer: 1, denom: 1) == 1_000_000)
    }

    @Test func machTickConversionDoesNotOverflowOnLongLivedProcesses() {
        // 运行 30 天的进程累计约 30 * 86_400 * 24_000_000 ticks。
        let ticks: UInt64 = 30 * 86_400 * 24_000_000
        let nanoseconds = MachCPUTime.nanoseconds(fromMachTicks: ticks, numer: 125, denom: 3)
        let expected = Double(ticks) * 125 / 3

        #expect(abs(Double(nanoseconds) - expected) < 1_000_000)
    }

    /// 一个占满单核的进程必须报出接近 100 / 核数 的百分比增量。
    /// 单位混用时这里是红的最大信号（Apple Silicon 上会低约 41.67 倍）。
    /// 用「空闲区间 vs 满载区间」的差值来隔离并行测试套件本身的 CPU 占用。
    @Test func samplerReportsAFullyBusyCoreAtItsRealShare() {
        let sampler = CPUUsageSampler()
        _ = sampler.sample()

        Thread.sleep(forTimeInterval: 1.2)
        let idle = sampler.sample()

        let stop = ManagedAtomicFlag()
        let burn = Thread {
            var accumulator = 0.0
            while !stop.isSet {
                for _ in 0..<50_000 { accumulator += Double.random(in: 0...1) }
            }
        }
        burn.stackSize = 512 * 1024
        burn.start()

        Thread.sleep(forTimeInterval: 1.2)
        let busy = sampler.sample()
        stop.set()

        let expected = 100.0 / Double(max(1, ProcessInfo.processInfo.processorCount))
        let increase = ownPercent(in: busy) - ownPercent(in: idle)

        #expect(increase > expected * 0.25, "increase=\(increase) expected≈\(expected)")
        #expect(increase < expected * 2.5, "increase=\(increase) expected≈\(expected)")
    }

    private func ownPercent(in result: CPUUsageSampleResult) -> Double {
        result.apps
            .flatMap(\.processes)
            .filter { $0.pid == getpid() }
            .reduce(0) { $0 + $1.cpuPercent }
    }

    private final class ManagedAtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    @Test func systemSnapshotSeparatesCpuStates() {
        let snapshot = CPUUsageCalculator.systemSnapshot(
            previous: CPUTimeCounters(user: 100, system: 100, nice: 100, idle: 700),
            current: CPUTimeCounters(user: 120, system: 110, nice: 100, idle: 770),
            logicalCoreCount: 4,
            loadAverage: [1.25, 1.10, 0.95]
        )

        #expect(abs(snapshot.userPercent - 20) < 0.001)
        #expect(abs(snapshot.systemPercent - 10) < 0.001)
        #expect(abs(snapshot.nicePercent) < 0.001)
        #expect(abs(snapshot.idlePercent - 70) < 0.001)
        #expect(abs(snapshot.totalPercent - 30) < 0.001)
        #expect(snapshot.logicalCoreCount == 4)
        #expect(snapshot.loadAverage == [1.25, 1.10, 0.95])
    }

    @Test func appProcessesAreGroupedAndSortedByCpuUsage() {
        let grouped = AppCPUGrouper.group([
            sample(1, "ZCode", path: "/Applications/ZCode.app/Contents/MacOS/ZCode", 12.5),
            sample(
                2,
                "ZCode Helper",
                path: "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper",
                7.5
            ),
            sample(3, "zcode-cli", path: "/Users/dev/.zcode/cli/zcode-cli", 5),
            sample(4, "Safari", path: "/System/Applications/Safari.app/Contents/MacOS/Safari", 20)
        ])

        #expect(grouped.map(\.name) == ["ZCode", "Safari"])
        #expect(grouped.first?.cpuPercent == 25)
        #expect(grouped.last?.processCount == 1)
        #expect(grouped.last?.cpuPercent == 20)
        #expect(grouped.first?.processes.map(\.cpuPercent) == [12.5, 7.5, 5])
    }

    @Test func samplerReadsLiveProcessesAndSystemCpu() {
        let sampler = CPUUsageSampler()
        let first = sampler.sample()
        let second = sampler.sample()

        #expect(first.system != nil)
        #expect(!first.apps.isEmpty)
        #expect(second.system?.logicalCoreCount ?? 0 > 0)
        #expect(second.apps.contains { $0.processes.contains { $0.pid == getpid() } })
        #expect(zip(second.apps, second.apps.dropFirst()).allSatisfy {
            $0.cpuPercent >= $1.cpuPercent
        })
        #expect(second.apps.allSatisfy { $0.cpuPercent >= 0 && $0.cpuPercent <= 100 })
    }

    @Test @MainActor func menuSnapshotReusesCpuSampleWithinTtl() {
        let first = CPUMonitorModel.menuSnapshot(maxAge: 60)
        let second = CPUMonitorModel.menuSnapshot(maxAge: 60)

        #expect(first.apps == second.apps)
        #expect(first.system == second.system)
    }
}
