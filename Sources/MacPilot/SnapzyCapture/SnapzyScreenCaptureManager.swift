//
//  SnapzyScreenCaptureManager.swift
//  MacPilot integration of Snapzy's capture core.
//
//  The display snapshot, ScreenCaptureKit compatibility, and crop flow below
//  are intentionally based on Snapzy's
//  Services/Capture/ScreenCaptureManager.swift.  MacPilot only needs the
//  image-producing vertical slice, so app-specific persistence, recording,
//  and output naming stay in ScreenCaptureModel.
//
//  Upstream: https://github.com/duongductrong/Snapzy
//  Copyright (c) Trong Duong Duc. BSD 3-Clause License.
//

import AppKit
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Snapzy's source-level capture manager reduced to the screenshot vertical
/// slice used by MacPilot.  It owns only a short-lived shareable-content cache;
/// image history and persistence remain outside the capture engine.
@MainActor
final class SnapzyScreenCaptureManager {
    static let shared = SnapzyScreenCaptureManager()

    private init() {}

    func prefetchShareableContent() -> ShareableContentPrefetchTask {
        // Keep the task owned by the selection session only.  Retaining a
        // completed SCShareableContent object in a process-wide cache keeps
        // every visible window/application alive and raises steady-state
        // memory after a capture.
        return ShareableContentPrefetchTask(Task(priority: .userInitiated) {
            ShareableContentBox(value: try await SCShareableContent.current)
        })
    }

    /// Captures frozen display snapshots using Snapzy's parallel display path.
    /// The resulting value is consumed by `FrozenAreaCaptureSession`, whose
    /// crop/composite implementation is copied from Snapzy verbatim apart from
    /// MacPilot's error/localization seam.
    func captureDisplaySnapshots(
        displayIDs: Set<CGDirectDisplayID>? = nil,
        showCursor: Bool = false,
        excludeDesktopIcons: Bool = false,
        excludeDesktopWidgets: Bool = false,
        excludeOwnApplication: Bool = false,
        prefetchedContentTask: ShareableContentPrefetchTask? = nil
    ) async throws -> [CGDirectDisplayID: FrozenDisplaySnapshot] {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionRequired
        }

        let content = try await loadShareableContent(prefetchedContentTask: prefetchedContentTask)
        let screens = NSScreen.screens.filter { screen in
            guard let displayID = screen.snapzyDisplayID else { return false }
            return displayIDs?.contains(displayID) ?? true
        }
        guard !screens.isEmpty else { throw ScreenCaptureError.noDisplayFound }

        return try await withThrowingTaskGroup(
            of: (CGDirectDisplayID, FrozenDisplaySnapshot).self,
            returning: [CGDirectDisplayID: FrozenDisplaySnapshot].self
        ) { group in
            for screen in screens {
                guard let displayID = screen.snapzyDisplayID,
                      let display = content.displays.first(where: { $0.displayID == Int(displayID) })
                else { continue }

                let filter = makeFilter(
                    display: display,
                    content: content,
                    excludeOwnApplication: excludeOwnApplication
                )
                let scaleFactor = displayScaleFactor(for: screen, display: display, filter: filter)
                let configuration = makeDisplayConfiguration(
                    for: screen,
                    scaleFactor: scaleFactor,
                    showsCursor: showCursor
                )
                let screenFrame = screen.frame
                let colorSpaceName = configuration.colorSpaceName

                group.addTask {
                    let image = try await Self.captureImageCompat(
                        contentFilter: filter,
                        configuration: configuration
                    )
                    let imageScale = Self.imageScaleFactor(
                        for: image,
                        screenFrame: screenFrame,
                        fallback: scaleFactor
                    )
                    return (
                        displayID,
                        FrozenDisplaySnapshot(
                            displayID: displayID,
                            screenFrame: screenFrame,
                            scaleFactor: imageScale,
                            colorSpaceName: colorSpaceName,
                            image: image
                        )
                    )
                }
            }

            var result: [CGDirectDisplayID: FrozenDisplaySnapshot] = [:]
            for try await (displayID, snapshot) in group {
                result[displayID] = snapshot
            }
            guard !result.isEmpty else { throw ScreenCaptureError.noDisplayFound }
            return result
        }
    }

    /// Captures an AppKit-space region through Snapzy's frozen snapshot and
    /// crop/composite pipeline.  This is the single entry point used by the
    /// interactive screenshot controller, replacing the former hand-written
    /// region crop path.
    func captureAreaAsImage(
        rect: CGRect,
        showCursor: Bool = false,
        excludeOwnApplication: Bool = false,
        prefetchedContentTask: ShareableContentPrefetchTask? = nil
    ) async throws -> CGImage? {
        let intersectingIDs = Set(
            NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
                guard let displayID = screen.snapzyDisplayID,
                      screen.frame.intersects(rect)
                else { return nil }
                return displayID
            }
        )
        guard !intersectingIDs.isEmpty else { throw ScreenCaptureError.noDisplayFound }

        let snapshots = try await captureDisplaySnapshots(
            displayIDs: intersectingIDs,
            showCursor: showCursor,
            excludeDesktopIcons: false,
            excludeDesktopWidgets: false,
            excludeOwnApplication: excludeOwnApplication,
            prefetchedContentTask: prefetchedContentTask
        )
        let primaryDisplayID = snapshots.keys.first {
            snapshots[$0]?.screenFrame.intersects(rect) == true
        } ?? intersectingIDs.first!
        let selection = AreaSelectionResult(
            target: .rect(rect),
            displayID: primaryDisplayID,
            mode: .screenshot,
            displayIDs: intersectingIDs
        )
        let session = FrozenAreaCaptureSession.fromSnapshots(Array(snapshots.values))
        let crop: FrozenAreaCropResult
        if intersectingIDs.count > 1 {
            crop = try session.cropCompositeImage(for: selection)
        } else {
            crop = try session.cropImage(for: selection)
        }
        return crop.image
    }

    // MARK: - Snapzy capture-core helpers

    private func loadShareableContent(
        prefetchedContentTask: ShareableContentPrefetchTask?
    ) async throws -> SCShareableContent {
        if let prefetchedContentTask {
            do {
                let box = try await prefetchedContentTask.task.value
                return box.value
            }
            catch { /* Fall through to a fresh query. */ }
        }
        return try await SCShareableContent.current
    }

    private func makeFilter(
        display: SCDisplay,
        content: SCShareableContent,
        excludeOwnApplication: Bool
    ) -> SCContentFilter {
        if excludeOwnApplication,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           let app = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private func displayScaleFactor(
        for screen: NSScreen,
        display: SCDisplay,
        filter: SCContentFilter
    ) -> CGFloat {
        if #available(macOS 14.0, *) {
            let pointPixelScale = CGFloat(filter.pointPixelScale)
            if pointPixelScale.isFinite, pointPixelScale > 0 { return pointPixelScale }
        }
        let widthScale = CGFloat(display.width) / max(screen.frame.width, 1)
        let heightScale = CGFloat(display.height) / max(screen.frame.height, 1)
        return max(widthScale, heightScale, screen.backingScaleFactor, 1)
    }

    private func makeDisplayConfiguration(
        for screen: NSScreen,
        scaleFactor: CGFloat,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((screen.frame.width * scaleFactor).rounded()))
        configuration.height = max(1, Int((screen.frame.height * scaleFactor).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        if #available(macOS 14.2, *) { configuration.captureResolution = .best }
        if let colorSpaceName = preferredCaptureColorSpaceName(for: screen) {
            configuration.colorSpaceName = colorSpaceName
        }
        return configuration
    }

    private func preferredCaptureColorSpaceName(for screen: NSScreen) -> CFString? {
        guard let name = screen.colorSpace?.cgColorSpace?.name else { return nil }
        if CFEqual(name, CGColorSpace.displayP3) { return CGColorSpace.displayP3 }
        if CFEqual(name, CGColorSpace.sRGB) { return CGColorSpace.sRGB }
        return nil
    }

    private nonisolated static func imageScaleFactor(
        for image: CGImage,
        screenFrame: CGRect,
        fallback: CGFloat
    ) -> CGFloat {
        let widthScale = screenFrame.width > 0 ? CGFloat(image.width) / screenFrame.width : 0
        let heightScale = screenFrame.height > 0 ? CGFloat(image.height) / screenFrame.height : 0
        return max(widthScale, heightScale, fallback, 1)
    }

    /// Compatibility wrapper copied from Snapzy's ScreenCaptureManager:
    /// SCScreenshotManager on macOS 14+, SingleFrameStreamCaptureSession on
    /// older systems.
    private nonisolated static func captureImageCompat(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            )
        }
        return try await SingleFrameStreamCaptureSession.capture(
            contentFilter: contentFilter,
            configuration: configuration
        )
    }
}

private extension NSScreen {
    var snapzyDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
