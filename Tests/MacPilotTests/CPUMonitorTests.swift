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
