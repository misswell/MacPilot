import Foundation
import SwiftUI

@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var apps: [AppMemoryUsage] = []
    @Published private(set) var systemMemory: SystemMemorySnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    func beginRefresh() { isRefreshing = true }

    func publish(apps: [AppMemoryUsage], snapshot: SystemMemorySnapshot?) {
        self.apps = apps
        systemMemory = snapshot
        lastUpdated = Date()
        isRefreshing = false
    }

    func clear() {
        apps = []
        systemMemory = nil
        lastUpdated = nil
        isRefreshing = false
    }
}
