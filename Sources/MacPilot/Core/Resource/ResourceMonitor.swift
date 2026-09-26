import Darwin
import Foundation

struct ResourceSnapshot: Equatable {
    let memoryBytes: UInt64?
    let cpuPercent: Double?
    let activeFeatures: [String]
    let managedTasks: Int
    let trackedObservers: Int
    let eventTaps: Int
    let activeCaptures: Int
    let iconCacheEntries: Int
    let windowCacheEntries: Int
}

struct ResourceRuntimeCounts {
    let eventTaps: Int
    let activeCaptures: Int
    let externalObservers: Int
    let processIconEntries: Int
    let windowCacheEntries: Int
}

/// Diagnostics are sampled only while the user opens the menu. There is no
/// permanent CPU/memory timer attached to the menu-bar process.
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var snapshot = ResourceSnapshot(
        memoryBytes: nil, cpuPercent: nil, activeFeatures: [],
        managedTasks: 0, trackedObservers: 0,
        eventTaps: 0, activeCaptures: 0, iconCacheEntries: 0, windowCacheEntries: 0
    )

    private var previousCPU: (uptime: TimeInterval, seconds: Double)?
    private let sampleTask = BackgroundTask()

    func startSampling(
        lifecycle: FeatureLifecycleManager,
        runtimeCounts: @escaping @MainActor () -> ResourceRuntimeCounts
    ) {
        stopSampling()
        previousCPU = nil
        refresh(lifecycle: lifecycle, runtimeCounts: runtimeCounts())
        sampleTask.start(interval: .seconds(1)) { [weak self] in
            self?.refresh(lifecycle: lifecycle, runtimeCounts: runtimeCounts())
        }
    }

    func stopSampling() {
        sampleTask.stop()
    }

    func refresh(lifecycle: FeatureLifecycleManager, runtimeCounts: ResourceRuntimeCounts) {
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
            trackedObservers: ObserverBag.activeCount + runtimeCounts.externalObservers,
            eventTaps: runtimeCounts.eventTaps,
            activeCaptures: runtimeCounts.activeCaptures,
            iconCacheEntries: AppIconCache.shared.count + runtimeCounts.processIconEntries,
            windowCacheEntries: runtimeCounts.windowCacheEntries
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
