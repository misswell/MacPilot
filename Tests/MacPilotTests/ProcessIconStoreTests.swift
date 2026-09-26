import AppKit
import Testing
@testable import MacPilot

struct ProcessIconStoreTests {
    @Test @MainActor func processIconIsLoadedOutsideTheView() async throws {
        let app = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let store = ProcessIconStore()
        store.request(paths: [app.path])
        for _ in 0 ..< 100 where store.image(for: app.path) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.image(for: app.path) != nil)
        store.clear()
    }

    @Test @MainActor func clearingTheMonitorReleasesPendingIcons() async throws {
        let app = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        let store = ProcessIconStore()
        store.request(paths: [app.path])
        store.clear()

        try await Task.sleep(for: .milliseconds(150))
        #expect(store.count == 0)
    }
}
