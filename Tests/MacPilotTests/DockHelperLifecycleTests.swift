import Foundation
import MacPilotDockGroupsCore
import Testing

struct DockHelperLifecycleTests {
    @Test func shutdownIntentIsBoundToRootGenerationAndExistingProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date.distantPast
        var generation = ""
        var notifiedRoot = ""
        try DockHelperLifecycle.publish(enabled: false, root: root) { generation = $0; notifiedRoot = $1 }
        #expect(notifiedRoot == root.standardizedFileURL.path)
        #expect(!DockHelperLifecycle.permitsLaunch(root: root))
        #expect(DockHelperLifecycle.acceptsShutdown(generation: generation, root: root, startedAt: started))
        #expect(!DockHelperLifecycle.acceptsShutdown(generation: generation, root: root, startedAt: .distantFuture))
        #expect(!DockHelperLifecycle.acceptsShutdown(generation: "stale", root: root, startedAt: started))
        #expect(!DockHelperLifecycle.acceptsShutdown(generation: generation,
            root: root.appendingPathComponent("other"), startedAt: started))
        try DockHelperLifecycle.publish(enabled: true, root: root)
        #expect(DockHelperLifecycle.permitsLaunch(root: root))
        #expect(!DockHelperLifecycle.acceptsShutdown(generation: generation, root: root, startedAt: started))
    }
}
