import Foundation
import SwiftUI

/// 内存监控的运行时状态：定时采样进程与系统内存，供监控页展示。
@MainActor
final class MemoryMonitorModel: ObservableObject {
    /// 自动刷新间隔：足够跟随变化，又不会带来可感知的开销。
    static let refreshInterval: TimeInterval = 3

    /// 菜单栏缓存的采样有效期：菜单开合触发的多次求值共享同一次采样。
    private static var cachedMenuSample: (date: Date, apps: [AppMemoryUsage], system: SystemMemorySnapshot?)?

    @Published private(set) var apps: [AppMemoryUsage] = []
    @Published private(set) var systemMemory: SystemMemorySnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private var refreshLoop: Task<Void, Never>?

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
        guard refreshLoop == nil else { return }
        refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let samples = ProcessMemorySampler.sample()
            let snapshot = SystemMemoryReader.snapshot()
            let apps = AppMemoryGrouper.group(samples)
            await self?.apply(apps: apps, snapshot: snapshot)
        }
    }

    private func apply(apps: [AppMemoryUsage], snapshot: SystemMemorySnapshot?) {
        self.apps = apps
        systemMemory = snapshot
        lastUpdated = Date()
        isRefreshing = false
    }
}
