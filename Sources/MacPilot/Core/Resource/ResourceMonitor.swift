import Darwin
import Foundation

struct ResourceSnapshot: Equatable {
    let memoryBytes: UInt64?
    let cpuPercent: Double?
    let activeFeatures: [String]
    let managedTasks: Int
    let trackedObservers: Int
}

/// Diagnostics are sampled only while the user opens the menu. There is no
/// permanent CPU/memory timer attached to the menu-bar process.
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var snapshot = ResourceSnapshot(
        memoryBytes: nil, cpuPercent: nil, activeFeatures: [],
        managedTasks: 0, trackedObservers: 0
    )

    private var previousCPU: (uptime: TimeInterval, seconds: Double)?
    private var sampleTask: Task<Void, Never>?

    func startSampling(lifecycle: FeatureLifecycleManager, trackedObservers: @escaping @MainActor () -> Int) {
        stopSampling()
        previousCPU = nil
        refresh(lifecycle: lifecycle, trackedObservers: trackedObservers())
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                self.refresh(lifecycle: lifecycle, trackedObservers: trackedObservers())
            }
        }
    }

    func stopSampling() {
        sampleTask?.cancel()
        sampleTask = nil
    }

    func refresh(lifecycle: FeatureLifecycleManager, trackedObservers: Int) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let cpuSeconds = Self.cumulativeCPUSeconds()
        let percent: Double?
        if let previousCPU, let cpuSeconds, uptime > previousCPU.uptime {
            percent = max(0, (cpuSeconds - previousCPU.seconds) / (uptime - previousCPU.uptime) * 100)
        } else {
            percent = nil
        }
        if let cpuSeconds { previousCPU = (uptime, cpuSeconds) }
        snapshot = ResourceSnapshot(
            memoryBytes: ProcessMemorySampler.ownFootprint(),
            cpuPercent: percent,
            activeFeatures: lifecycle.activeIdentifiers,
            managedTasks: BackgroundTask.activeCount,
            trackedObservers: trackedObservers
        )
    }

    private static func cumulativeCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
