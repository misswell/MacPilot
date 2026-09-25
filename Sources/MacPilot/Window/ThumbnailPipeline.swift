import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct WindowSwitcherCapturedPreview: @unchecked Sendable {
    let windowID: CGWindowID
    let image: CGImage
}

enum WindowSwitcherPreviewCapture {
    static func captureBatch(
        windowIDs: [CGWindowID],
        maximumPixelSize: CGSize
    ) async -> [WindowSwitcherCapturedPreview] {
        guard !windowIDs.isEmpty, !Task.isCancelled else { return [] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else {
            return []
        }

        let windowsByID = Dictionary(
            uniqueKeysWithValues: content.windows
                .filter { $0.windowID != 0 }
                .map { ($0.windowID, $0) }
        )
        var result: [WindowSwitcherCapturedPreview] = []
        result.reserveCapacity(windowIDs.count)

        for windowID in windowIDs {
            guard !Task.isCancelled, let window = windowsByID[windowID] else { continue }
            let outputSize = WindowSwitcherThumbnailCapturePolicy.outputPixelSize(
                windowSize: window.frame.size,
                maximumPixelSize: maximumPixelSize
            )
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(outputSize.width))
            configuration.height = max(1, Int(outputSize.height))
            configuration.queueDepth = 1
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .nominal

            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ), !Task.isCancelled else {
                return []
            }
            result.append(WindowSwitcherCapturedPreview(windowID: windowID, image: image))
        }
        return result
    }
}

/// Keep one thumbnail batch serialized. ScreenCaptureKit is configured to
/// produce the final 256x160-class image, so WindowServer never has to send a
/// native-resolution window image to this process for downscaling.
actor WindowSwitcherPreviewCaptureQueue {
    private var lastBatch: Task<Void, Never>?

    func capture(
        windowIDs: [CGWindowID],
        maximumPixelSize: CGSize
    ) async -> [WindowSwitcherCapturedPreview] {
        let previousBatch = lastBatch
        let batch: Task<[WindowSwitcherCapturedPreview], Never> = Task.detached(priority: .utility) {
            _ = await previousBatch?.value
            guard !Task.isCancelled else { return [] }
            return await WindowSwitcherPreviewCapture.captureBatch(
                windowIDs: windowIDs,
                maximumPixelSize: maximumPixelSize
            )
        }
        lastBatch = Task {
            _ = await batch.value
        }
        return await withTaskCancellationHandler {
            await batch.value
        } onCancel: {
            batch.cancel()
        }
    }
}

