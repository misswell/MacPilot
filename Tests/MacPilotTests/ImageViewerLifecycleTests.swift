import AppKit
import Testing
@testable import MacPilot

@MainActor
struct ImageViewerLifecycleTests {
    @Test func prefetchSkipsDocumentsAndAnimatedImageFormats() {
        #expect(ImageViewerSession.canPrefetch(URL(fileURLWithPath: "/test/image.png")))
        #expect(!ImageViewerSession.canPrefetch(URL(fileURLWithPath: "/test/document.pdf")))
        #expect(!ImageViewerSession.canPrefetch(URL(fileURLWithPath: "/test/animation.gif")))
        #expect(!ImageViewerSession.canPrefetch(URL(fileURLWithPath: "/test/animation.webp")))
    }

    @Test func openingWhileDisabledUsesOneRuntimeForTheBatchAndReleasesItAfterTheLastWindow() throws {
        _ = NSApplication.shared
        let registry = FeatureLifecycleManager()
        let feature = ImageViewerFeature { ImageViewerRuntime(language: $0, presentWindows: false) }
        registry.register(feature)
        try ImageViewerFixture.withFolder { folder in
            let photos = try (1...5).map { try ImageViewerFixture.image(in: folder, named: "\($0).png") }
            feature.openDocuments([folder])
            #expect(!feature.isRunning)
            feature.openDocuments(photos + [photos[0]])
            let runtime = try #require(feature.runtime)
            let windows = runtime.windows.all
            #expect(windows.count == 5)
            #expect(Set(windows.map(\.browser.url)) == Set(photos))
            let session = try #require(runtime.session)
            for window in windows.dropLast() { window.window?.close() }
            #expect(feature.runtime === runtime)
            #expect(runtime.session === session)
            windows.last?.window?.close()
            #expect(feature.runtime == nil)
            #expect(runtime.isClosed)
            #expect(session.isClosed)
            #expect(registry.diagnostics().first?.taskCount == 0)
            #expect(registry.diagnostics().first?.observerCount == 0)
            #expect(registry.diagnostics().first?.cacheBytes == 0)
        }
    }

    @Test(arguments: [false, true])
    func enabledViewerKeepsTheRuntimeWhetherEnabledBeforeOrDuringExternalOpen(enableDuringOpen: Bool) throws {
        _ = NSApplication.shared
        let feature = ImageViewerFeature { ImageViewerRuntime(language: $0, presentWindows: false) }
        let registry = FeatureLifecycleManager()
        registry.register(feature)
        defer { registry.stopAll() }
        try ImageViewerFixture.withFolder { folder in
            let photo = try ImageViewerFixture.image(in: folder, named: "image.png")
            if !enableDuringOpen { registry.start(feature.identifier) }
            feature.openDocuments([photo])
            let runtime = try #require(feature.runtime)
            if enableDuringOpen {
                feature.keepRuntimeWhenIdle()
                registry.start(feature.identifier)
            }
            runtime.windows.all.first?.window?.close()
            #expect(feature.runtime === runtime)
            #expect(runtime.session == nil)
            registry.stopAll()
            #expect(feature.runtime == nil)
        }
    }

    @Test func registeringAndCyclingTheFeatureDoesNotAllocateSessionResources() throws {
        let registry = FeatureLifecycleManager()
        let feature = ImageViewerFeature()
        registry.register(feature)
        #expect(feature.runtime == nil)
        for _ in 0..<100 {
            registry.start(feature.identifier)
            weak var runtime = try #require(feature.runtime)
            registry.start(feature.identifier)
            #expect(feature.runtime === runtime)
            #expect(runtime?.session == nil)
            #expect(registry.diagnostics().first?.taskCount == 0)
            #expect(registry.diagnostics().first?.cacheBytes == 0)
            #expect(registry.diagnostics().first?.observerCount == 0)
            registry.stopAll()
            #expect(runtime == nil)
            #expect(!feature.isRunning)
        }
    }

    @Test func lastWindowClosesSessionWhileRuntimeRemainsAvailable() throws {
        _ = NSApplication.shared
        let runtime = ImageViewerRuntime(language: .english, presentWindows: false)
        try ImageViewerFixture.withFolder { folder in
            let first = try ImageViewerFixture.image(in: folder, named: "1.png")
            let second = try ImageViewerFixture.image(in: folder, named: "2.png")
            runtime.open([first, second])
            let documents = runtime.windows.all
            let session = try #require(runtime.session)
            try #require(documents.count == 2)
            #expect(session.folderCount == 1)
            #expect(session.observerCount == 1)
            documents[0].window?.close()
            #expect(runtime.session === session)
            #expect(!documents[1].isClosed)
            #expect(session.folderCount == 1)
            documents[1].window?.close()
            #expect(runtime.session == nil)
            #expect(session.isClosed)
            #expect(session.taskCount == 0)
            #expect(session.cacheBytes == 0)
            #expect(session.folderCount == 0)
            #expect(session.observerCount == 0)
            #expect(!runtime.isClosed)
            runtime.close()
        }
    }

    @Test func closingSessionInvalidatesCallbacksAlreadyEnqueuedForDelivery() async throws {
        let session = ImageViewerSession()
        let url = URL(fileURLWithPath: "/missing.png")
        let job = session.render(.init(url: url, pixels: 512)) { _ in
            Issue.record("The callback must not reach a closed session")
        }
        #expect(job != nil)
        session.close()
        await Task.yield()
        #expect(session.taskCount == 0)
        #expect(session.observerCount == 0)
        #expect(session.render(.init(url: url, pixels: 512)) { _ in } == nil)
    }

    @Test func closingRuntimeDisposesAllWindowsBeforeDiscardingTheirSession() throws {
        _ = NSApplication.shared
        let runtime = ImageViewerRuntime(language: .english, presentWindows: false)
        try ImageViewerFixture.withFolder { folder in
            let file = try ImageViewerFixture.image(in: folder, named: "image.png")
            runtime.open([file])
            let document = try #require(runtime.windows.all.first)
            runtime.close()
            runtime.open([file])
            #expect(runtime.windows.isEmpty)
            #expect(runtime.session == nil)
            #expect(document.isClosed)
            #expect(document.frame == nil)
            #expect(document.animationTimerCount == 0)
            #expect(runtime.taskCount == 0)
        }
    }
}
