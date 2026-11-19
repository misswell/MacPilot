import AppKit
import Testing
@testable import MacPilot

@MainActor
struct ImageViewerFileRouterTests {
    @Test func buffersOnlyFileDocumentsUntilTheConfiguredReceiverAttaches() throws {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        let photo = URL(fileURLWithPath: "/tmp/sample.jpg")
        let pdf = URL(fileURLWithPath: "/tmp/pages.pdf")
        let settings = try #require(URL(string: "macpilot://settings"))
        let capture = try #require(URL(string: "snapzy://capture"))
        delegate.application(app, open: [photo, photo, pdf, settings, capture])
        #expect(delegate.takePendingDeepLinks() == [settings, capture])
        var batches: [[URL]] = []
        delegate.imageViewerFileRouter.attach { batches.append($0) }
        delegate.imageViewerFileRouter.attach { _ in Issue.record("A second consumer must not replace the configured one") }
        #expect(batches == [[photo, pdf]])
        delegate.application(app, open: [photo, settings])
        #expect(batches == [[photo, pdf], [photo]])
        #expect(delegate.takePendingDeepLinks().isEmpty)
    }

    @Test func bundleRegistersAnAlternateViewerWithoutChangingSchemes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let viewer = try #require((info["CFBundleDocumentTypes"] as? [[String: Any]])?.first)
        #expect(viewer["LSHandlerRank"] as? String == "Alternate")
        #expect(viewer["CFBundleTypeRole"] as? String == "Viewer")
        let types = try #require(viewer["LSItemContentTypes"] as? [String])
        #expect(types.contains("public.image"))
        #expect(types.contains("com.adobe.pdf"))
        let urlTypes = try #require((info["CFBundleURLTypes"] as? [[String: Any]])?.first)
        #expect(urlTypes["CFBundleURLSchemes"] as? [String] == ["snapzy", "macpilot"])
    }

    @Test func finderLaunchBuffersFiveDocumentsButDoesNotRequestSettings() throws {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        let photos = ["jpg", "png", "heic", "webp", "pdf"].enumerated().map {
            URL(fileURLWithPath: "/tmp/cold-launch-\($0.offset).\($0.element)")
        }
        #expect(!delegate.imageViewerFileRouter.hasPendingDocuments)
        delegate.application(app, open: photos)
        #expect(delegate.imageViewerFileRouter.hasPendingDocuments)
        #expect(!delegate.applicationShouldOpenUntitledFile(app))
        #expect(!delegate.applicationOpenUntitledFile(app))
        #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        #expect(delegate.takePendingDeepLinks().isEmpty)
        var received: [[URL]] = []
        delegate.imageViewerFileRouter.attach { received.append($0) }
        #expect(received == [photos])
        #expect(!delegate.imageViewerFileRouter.hasPendingDocuments)
    }

    @Test(arguments: [false, true])
    func finderDeliverySuppressesReopenEvenAfterTheStartupBufferHasDrained(lateArrival: Bool) {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        let photo = URL(fileURLWithPath: "/tmp/finder-photo.jpg")
        var scheduled: [@MainActor () -> Void] = []
        var received: [URL] = []
        if !lateArrival { delegate.application(app, open: [photo]) }
        delegate.imageViewerFileRouter.attach(schedule: { scheduled.append($0) }) { urls in
            #expect(!delegate.applicationOpenUntitledFile(app))
            #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            received.append(contentsOf: urls)
        }
        if lateArrival { delegate.application(app, open: [photo]) }
        #expect(!delegate.imageViewerFileRouter.hasPendingDocuments)
        #expect(delegate.imageViewerFileRouter.hasOutstandingDocuments)
        #expect(!delegate.applicationShouldOpenUntitledFile(app))
        #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        for delivery in scheduled { delivery() }
        #expect(received == [photo])
        #expect(!delegate.imageViewerFileRouter.hasOutstandingDocuments)
    }

    @Test func aDocumentEventWinsOverAnActivationQueuedInTheSameTurn() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        var scheduled: [@MainActor () -> Void] = []
        delegate.scheduleActivation = { scheduled.append($0) }
        var opens = 0
        let opener = MainWindowOpener(loadContent: { opens += 1 }, activate: {}, schedule: { _ in }, record: { _ in })
        withExtendedLifetime(opener) {
            #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            #expect(scheduled.count == 1)
            delegate.application(app, open: [URL(fileURLWithPath: "/tmp/late-image.jpg")])
            for action in scheduled { action() }
            #expect(opens == 0)

            delegate.imageViewerFileRouter.attach { _ in }
            scheduled.removeAll()
            #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            for action in scheduled { action() }
            #expect(opens == 1)
        }
    }

    @Test func rejectsOrdinaryFoldersEvenWhenNamedLikeAnImage() throws {
        try ImageViewerFixture.withFolder { folder in
            let misleading = folder.appendingPathComponent("album.jpg", isDirectory: true)
            try FileManager.default.createDirectory(at: misleading, withIntermediateDirectories: false)
            let unmarked = URL(filePath: misleading.path, directoryHint: .notDirectory)
            let sketch = folder.appendingPathComponent("document.sketch", isDirectory: true)
            try FileManager.default.createDirectory(at: sketch, withIntermediateDirectories: false)
            let router = ImageViewerFileRouter()
            #expect(!router.receive([folder, unmarked]))
            #expect(!router.hasPendingDocuments)
            #expect(router.receive([sketch]))
        }
    }
}
