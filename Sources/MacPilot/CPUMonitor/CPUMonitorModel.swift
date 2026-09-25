import Foundation

/// CPU 监控的运行时状态：定时采样进程与系统 CPU，供监控页和菜单栏使用。
@MainActor
final class CPUMonitorModel: ManagedFeature {
    let identifier = "cpuMonitor"
    var isRunning: Bool { refreshLoop.isRunning }
    static let refreshInterval: TimeInterval = 3

    private static let menuSampler = CPUUsageSampler()
    private static var cachedMenuSample: (date: Date, apps: [AppCPUUsage], system: SystemCPUSnapshot?)?

    let store = CPUStore()

    private let sampler = CPUUsageSampler()
    private let refreshLoop = BackgroundTask()
    private var samplingTask: Task<Void, Never>?
    private var sampleRevision = 0

    static func menuSnapshot(maxAge: TimeInterval = 2) -> (
        apps: [AppCPUUsage],
        system: SystemCPUSnapshot?
    ) {
        if let cached = cachedMenuSample, Date().timeIntervalSince(cached.date) < maxAge {
            return (cached.apps, cached.system)
        }
        let result = menuSampler.sample()
        cachedMenuSample = (Date(), result.apps, result.system)
        return (result.apps, result.system)
    }

    func startAutoRefresh() {
        guard !refreshLoop.isRunning else { return }
        sampler.reset()
        refresh()
        refreshLoop.start(interval: .seconds(Self.refreshInterval)) { [weak self] in
            self?.refresh()
        }
    }

    func stopAutoRefresh() {
        refreshLoop.stop()
        sampleRevision += 1
        samplingTask?.cancel()
        samplingTask = nil
        sampler.reset()
        store.clear()
        ProcessCollector.shared.clear()
    }

    func start() { startAutoRefresh() }
    func stop() { stopAutoRefresh() }

    static func clearMenuCache() {
        cachedMenuSample = nil
        menuSampler.reset()
    }

    func refresh() {
        guard !store.isRefreshing else { return }
        store.beginRefresh()
        sampleRevision += 1
        let revision = sampleRevision
        let sampler = self.sampler
        samplingTask = Task.detached(priority: .utility) { [weak self, sampler] in
            let result = sampler.sample()
            guard !Task.isCancelled else { return }
            await self?.apply(result, revision: revision)
        }
    }

    private func apply(_ result: CPUUsageSampleResult, revision: Int) {
        guard revision == sampleRevision else { return }
        samplingTask = nil
        store.publish(result)
    }
}
