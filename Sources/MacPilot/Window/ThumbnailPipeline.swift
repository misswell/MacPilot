import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct WindowSwitcherCapturedPreview: @unchecked Sendable {
    let windowID: CGWindowID
    let image: CGImage
}

private struct WindowCaptureRequest: @unchecked Sendable {
    let index: Int
    let window: SCWindow
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
        let requests = windowIDs.enumerated().compactMap { index, windowID -> WindowCaptureRequest? in
            guard let window = windowsByID[windowID] else { return nil }
            return WindowCaptureRequest(index: index, window: window)
        }
        return await withTaskGroup(of: (Int, WindowSwitcherCapturedPreview?).self) { group in
            var next = 0
            var completed: [(Int, WindowSwitcherCapturedPreview)] = []

            func enqueue() {
                guard next < requests.count, !Task.isCancelled else { return }
                let request = requests[next]
                next += 1
                group.addTask {
                    (request.index, await capture(request.window, maximumPixelSize: maximumPixelSize))
                }
            }

            enqueue()
            enqueue()
            while let (index, preview) = await group.next() {
                if let preview { completed.append((index, preview)) }
                enqueue()
            }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func capture(
        _ window: SCWindow,
        maximumPixelSize: CGSize
    ) async -> WindowSwitcherCapturedPreview? {
        guard !Task.isCancelled else { return nil }
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
        ), !Task.isCancelled else { return nil }
        return WindowSwitcherCapturedPreview(windowID: window.windowID, image: image)
    }
}

/// Keep batches serialized and capture at most two windows per batch.
/// ScreenCaptureKit is configured to
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
