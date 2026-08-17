import CoreGraphics
import Foundation
import AppKit
import Testing
@testable import MacPilot

/// Geometry coverage for the source-migrated Snapzy frozen-display pipeline.
struct SnapzyCaptureTests {
    private final class InitialTargetResolverRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var observedMainThread: Bool?

        func record() {
            lock.lock()
            observedMainThread = Thread.isMainThread
            lock.unlock()
        }

        var result: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return observedMainThread
        }
    }

    private func image(width: Int, height: Int, color: CGColor = CGColor(gray: 0.5, alpha: 1)) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func frozenSnapshotCropUsesNativePixelScaleAndScreenCoordinates() throws {
        let snapshot = FrozenDisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 2,
            colorSpaceName: nil,
            image: image(width: 200, height: 200)
        )
        let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 10, y: 20, width: 30, height: 25)),
            displayID: 1,
            mode: .screenshot
        )

        let result = try session.cropImage(for: selection)
        #expect(result.image.width == 60)
        #expect(result.image.height == 50)
        #expect(result.screenRect == CGRect(x: 10, y: 20, width: 30, height: 25))
    }

    @Test func frozenSnapshotCompositeCropsAcrossDisplays() throws {
        let left = FrozenDisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scaleFactor: 1,
            colorSpaceName: nil,
            image: image(width: 100, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        )
        let right = FrozenDisplaySnapshot(
            displayID: 2,
            screenFrame: CGRect(x: 100, y: 0, width: 100, height: 100),
            scaleFactor: 1,
            colorSpaceName: nil,
            image: image(width: 100, height: 100, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        )
        let session = FrozenAreaCaptureSession.fromSnapshots([left, right])
        let selection = AreaSelectionResult(
            target: .rect(CGRect(x: 50, y: 10, width: 100, height: 20)),
            displayID: 1,
            mode: .screenshot,
            displayIDs: [1, 2]
        )

        let result = try session.cropCompositeImage(for: selection)
        #expect(result.image.width == 100)
        #expect(result.image.height == 20)
        #expect(result.screenRect == CGRect(x: 50, y: 10, width: 100, height: 20))
    }

    @Test @MainActor func areaSelectionWindowIsPresentedBeforeFrozenBackdropCompletes() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }

        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true }
        )
        let delayedImage = image(width: 1, height: 1)
        let delayedPreparation: @MainActor () async throws -> FrozenAreaCaptureSession = {
            try await Task.sleep(for: .milliseconds(150))
            return FrozenAreaCaptureSession.fromSnapshot(
                FrozenDisplaySnapshot(
                    displayID: NSScreen.main?.displayID ?? 1,
                    screenFrame: NSScreen.main?.frame ?? .zero,
                    scaleFactor: 1,
                    colorSpaceName: nil,
                    image: delayedImage
                )
            )
        }

        defer {
            controller.cancelSelection()
            controller.stop()
        }

        let startedAt = Date()
        controller.startSnapzySelection(mode: .manualArea, preparation: delayedPreparation)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 0.1)
        #expect(SnapzyAreaSelectionController.shared.isPresenting)
    }

    @Test @MainActor func initialSmartTargetResolutionRunsOnMainActor() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }

        let recorder = InitialTargetResolverRecorder()
        let controller = SmartScreenshotController(
            language: { .simplifiedChinese },
            onCapture: { _ in },
            onError: { _ in },
            screenCaptureAccessProvider: { true },
            initialTargetResolver: { _, _ in
                recorder.record()
                return nil
            }
        )

        defer {
            controller.stop()
        }

        controller.startSelection(mode: .smartElement)
        for _ in 0..<50 {
            if recorder.result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.result == true)
    }
}
