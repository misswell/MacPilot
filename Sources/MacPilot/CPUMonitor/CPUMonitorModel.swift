import Foundation
import SwiftUI

/// CPU 监控的运行时状态：定时采样进程与系统 CPU，供监控页和菜单栏使用。
@MainActor
final class CPUMonitorModel: ObservableObject, ManagedFeature {
    let identifier = "cpuMonitor"
    var isRunning: Bool { refreshLoop.isRunning }
    static let refreshInterval: TimeInterval = 3

    private static let menuSampler = CPUUsageSampler()
    private static var cachedMenuSample: (date: Date, apps: [AppCPUUsage], system: SystemCPUSnapshot?)?

    @Published private(set) var apps: [AppCPUUsage] = []
    @Published private(set) var systemCPU: SystemCPUSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private let sampler = CPUUsageSampler()
    private let refreshLoop = BackgroundTask()

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
    }

    func start() { startAutoRefresh() }
    func stop() { stopAutoRefresh() }

    static func clearMenuCache() {
        cachedMenuSample = nil
        menuSampler.reset()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let sampler = self.sampler
        Task.detached(priority: .utility) { [weak self, sampler] in
            let result = sampler.sample()
            await self?.apply(result)
        }
    }

    private func apply(_ result: CPUUsageSampleResult) {
        apps = result.apps
        systemCPU = result.system
        lastUpdated = Date()
        isRefreshing = false
    }
}
