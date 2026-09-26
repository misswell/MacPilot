import Foundation

/// 内存监控的运行时状态：定时采样进程与系统内存，供监控页展示。
@MainActor
final class MemoryMonitorModel: ManagedFeature, FeatureResourceReporting {
    let identifier = "memoryMonitor"
    var isRunning: Bool { refreshLoop.isRunning }
    var diagnosticTaskCount: Int { (refreshLoop.isRunning ? 1 : 0) + (samplingTask == nil ? 0 : 1) }
    var diagnosticObserverCount: Int { 0 }
    /// 自动刷新间隔：足够跟随变化，又不会带来可感知的开销。
    static let refreshInterval: TimeInterval = 3

    /// 菜单栏缓存的采样有效期：菜单开合触发的多次求值共享同一次采样。
    private static var cachedMenuSample: (date: Date, apps: [AppMemoryUsage], system: SystemMemorySnapshot?)?

    let store = MemoryStore()

    private let refreshLoop = BackgroundTask()
    private var samplingTask: Task<Void, Never>?
    private var sampleRevision = 0

    /// 菜单栏「内存监控」子菜单使用：同步采样一次（毫秒级），
    /// 短时间内重复调用（如菜单反复开合）共享缓存结果。
    static func menuSnapshot(maxAge: TimeInterval = 2) -> (apps: [AppMemoryUsage], system: SystemMemorySnapshot?) {
        if let cached = cachedMenuSample, Date().timeIntervalSince(cached.date) < maxAge {
            return (cached.apps, cached.system)
        }
        let samples = ProcessMemorySampler.sample()
        let system = SystemMemoryReader.snapshot()
        let apps = AppMemoryGrouper.group(samples)
        cachedMenuSample = (Date(), apps, system)
        return (apps, system)
    }

    func startAutoRefresh() {
        guard !refreshLoop.isRunning else { return }
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
        store.clear()
        ProcessCollector.shared.clear()
    }

    func start() { startAutoRefresh() }
    func stop() { stopAutoRefresh() }

    /// Drops the process-wide menu snapshot so a terminated app does not keep
    /// the cached `[AppMemoryUsage]` array alive.
    static func clearMenuCache() {
        cachedMenuSample = nil
    }

    func refresh() {
        guard !store.isRefreshing else { return }
        store.beginRefresh()
        sampleRevision += 1
        let revision = sampleRevision
        samplingTask = Task.detached(priority: .utility) { [weak self] in
            let samples = ProcessMemorySampler.sample()
            let snapshot = SystemMemoryReader.snapshot()
            let apps = AppMemoryGrouper.group(samples)
            guard !Task.isCancelled else { return }
            await self?.apply(apps: apps, snapshot: snapshot, revision: revision)
        }
    }

    private func apply(apps: [AppMemoryUsage], snapshot: SystemMemorySnapshot?, revision: Int) {
        guard revision == sampleRevision else { return }
        samplingTask = nil
        store.publish(apps: apps, snapshot: snapshot)
    }
}
