import AppKit
import Testing
@testable import MacPilot

@MainActor
struct ImageViewerWindowTests {
    private final class CanvasProbe: ImageViewerCanvas {
        var requestedRedraw = false

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            super.setNeedsDisplay(invalidRect)
            requestedRedraw = true
        }
    }

    @Test func actualPixelsUseTheWindowScaleAndRotationChangesFitWithoutStretching() {
        let original = CGSize(width: 1000, height: 500)
        let viewport = CGSize(width: 250, height: 200)
        var geometry = ImageViewerGeometry()
        #expect(geometry.fitScale(original, in: viewport) == 0.25)
        geometry.actualSize()
        #expect(geometry.pointScale(original, in: viewport, backing: 1) == 1)
        #expect(geometry.pointScale(original, in: viewport, backing: 2) == 0.5)
        geometry.move(CGPoint(x: 999, y: 999), original: original, viewport: viewport, backing: 2)
        #expect(geometry.pan == CGPoint(x: 125, y: 25))
        geometry.rotate(1)
        geometry.fit()
        #expect(geometry.fitScale(original, in: viewport) == 0.2)
        #expect(geometry.pan == .zero)
    }

    @Test func documentWindowsOwnIndependentViewportState() throws {
        _ = NSApplication.shared
        let session = ImageViewerSession(observePressure: false)
        let first = ImageViewerWindowController(url: URL(fileURLWithPath: "/one.pdf"), session: session, language: .english)
        let second = ImageViewerWindowController(url: URL(fileURLWithPath: "/two.pdf"), session: session, language: .english)
        defer { first.dispose(); second.dispose(); session.close() }
        first.perform(.actual)
        first.perform(.right)
        #expect(first.geometry.absoluteZoom == 1)
        #expect(first.geometry.turn == 1)
        #expect(second.geometry.absoluteZoom == nil)
        #expect(second.geometry.turn == 0)
        first.dispose()
        #expect(first.window?.contentView == nil)
        #expect(!second.isClosed)
    }

    @Test func animationPauseRemovesItsTimerWithoutResettingItsLoop() async {
        let animation = ImageViewerAnimationController()
        animation.displayed(0)
        animation.schedule(after: 0.01) { Issue.record("A paused animation fired") }
        #expect(animation.hasTimer)
        animation.pause()
        #expect(!animation.hasTimer)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(animation.completedLoops == 1)
        animation.reset()
        #expect(animation.completedLoops == 0)
    }

    @Test func decodedPhotoAndRotationInvalidateTheNativeCanvas() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = ImageViewerSession(observePressure: false)
        let file = try ImageViewerFixture.image(in: folder, named: "image.png")
        let document = ImageViewerWindowController(url: file, session: session, language: .english)
        defer {
            document.dispose()
            session.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let canvas = CanvasProbe(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        canvas.controller = document
        document.begin(show: false)
        // Observe the AppKit invalidation request without showing a window.
        canvas.requestedRedraw = false

        let deadline = ContinuousClock.now + .seconds(5)
        while document.loading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rendered = try #require(document.frame)
        #expect(rendered.originalSize == CGSize(width: 1200, height: 800))
        #expect(canvas.requestedRedraw)

        canvas.requestedRedraw = false
        document.perform(.right)
        #expect(canvas.requestedRedraw)
    }
}
