import Foundation
import SwiftUI

/// Only the CPU page observes this state. Sampling and task ownership stay in
/// CPUMonitorModel so the page can be released without retaining process data.
@MainActor
final class CPUStore: ObservableObject {
    let icons = ProcessIconStore()
    @Published private(set) var apps: [AppCPUUsage] = []
    @Published private(set) var systemCPU: SystemCPUSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    func beginRefresh() { isRefreshing = true }

    func publish(_ result: CPUUsageSampleResult) {
        apps = result.apps
        icons.request(paths: result.apps.compactMap(\.bundlePath))
        systemCPU = result.system
        lastUpdated = Date()
        isRefreshing = false
    }

    func clear() {
        icons.clear()
        apps = []
        systemCPU = nil
        lastUpdated = nil
        isRefreshing = false
    }
}
