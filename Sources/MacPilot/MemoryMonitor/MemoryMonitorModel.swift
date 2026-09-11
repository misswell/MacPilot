import Foundation
import SwiftUI

/// 内存监控的运行时状态：定时采样进程与系统内存，供监控页展示。
@MainActor
final class MemoryMonitorModel: ObservableObject {
    /// 自动刷新间隔：足够跟随变化，又不会带来可感知的开销。
    static let refreshInterval: TimeInterval = 3

    @Published private(set) var apps: [AppMemoryUsage] = []
    @Published private(set) var systemMemory: SystemMemorySnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private var refreshLoop: Task<Void, Never>?

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
