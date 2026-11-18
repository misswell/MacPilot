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
}
