//
//  SnapzyCaptureSupport.swift
//  MacPilot integration seams for the Snapzy capture sources.
//
//  The capture algorithms in this directory are copied from Snapzy and kept
//  deliberately close to the upstream types.  This file only supplies the
//  small application-specific seams that Snapzy normally gets from its
//  localization and capture coordinator layers.
//

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// ScreenCaptureKit's shareable-content objects are Objective-C reference
/// types without a Sendable annotation.  Snapzy keeps the prefetch task as a
/// value passed between main-actor capture stages; this unchecked box is the
/// same seam, scoped to the task's lifetime and never mutated after creation.
struct ShareableContentBox: @unchecked Sendable {
    let value: SCShareableContent
}

struct ShareableContentPrefetchTask: @unchecked Sendable {
    let task: Task<ShareableContentBox, Error>

    var value: Task<ShareableContentBox, Error> { task }

    init(_ task: Task<ShareableContentBox, Error>) {
        self.task = task
    }
}

typealias SnapzyCaptureError = ScreenCaptureError

enum SelectionMode {
    case screenshot
    case recording
    case scrollingCapture
}

enum DiagnosticLogLevel { case debug, info, warning, error }
enum DiagnosticLogCategory {
    case capture, ui, action, cloud, history, preferences, fileAccess, clipboard, recording, lifecycle
}

/// Snapzy's capture sources log through a richer diagnostics service.  MacPilot
/// keeps that seam intentionally cheap; the app's existing os.Logger handles
/// user-visible failures while these high-frequency overlay diagnostics stay
/// allocation-free.
struct DiagnosticLogger {
    static let shared = DiagnosticLogger()

    func log(
        _ level: DiagnosticLogLevel,
        _ category: DiagnosticLogCategory,
        _ message: String,
        context: [String: String] = [:]
    ) {
        _ = (level, category, message, context)
    }

    func logError(
        _ category: DiagnosticLogCategory,
        _ error: Error,
        _ message: String,
        context: [String: String] = [:]
    ) {
        _ = (category, error, message, context)
    }
}

enum PreferencesKeys {
    static let screenshotShowSelectionAreaOverlay = "MacPilot.screenshotShowSelectionAreaOverlay"
    static let screenshotReverseMagnifierZoomDirection = "MacPilot.screenshotReverseMagnifierZoomDirection"
    static let screenshotShowMagnifierByDefault = "MacPilot.screenshotShowMagnifierByDefault"
    static let screenshotShowMagnifierColorPanel = "MacPilot.screenshotShowMagnifierColorPanel"
    static let screenshotLastAreaRect = "MacPilot.screenshotLastAreaRect"
}

struct CaptureOverlayShortcut: Equatable {
    let displayString: String
    let isIndependent: Bool
}

enum CaptureOverlayShortcutSettings {
    static let applicationCaptureShortcut: CaptureOverlayShortcut? = nil
    static let recordingApplicationCaptureShortcut: CaptureOverlayShortcut? = nil
}

@MainActor
enum ScreenshotLastAreaStore {
    static func save(_ rect: CGRect) {
        UserDefaults.standard.set(
            ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height],
            forKey: PreferencesKeys.screenshotLastAreaRect
        )
    }

    static func load() -> CGRect? {
        guard let values = UserDefaults.standard.dictionary(forKey: PreferencesKeys.screenshotLastAreaRect),
              let x = values["x"] as? CGFloat,
              let y = values["y"] as? CGFloat,
              let width = values["width"] as? CGFloat,
              let height = values["height"] as? CGFloat
        else { return nil }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        return NSScreen.screens.contains { $0.frame.intersects(rect) } ? rect : nil
    }
}

enum L10n {
    enum ScreenCapture {
        static let magnifierCopyColorHintPrefix = "Copy color"
        static let magnifierCopyColorHintSuffix = "⌘C"
        static let magnifierColorCopiedFeedback = "Copied"

        static func applicationModeHint(_ shortcut: String) -> String {
            "Application window · (shortcut)"
        }

        static func manualModeHint(_ shortcut: String) -> String {
            "Area selection · (shortcut)"
        }
    }
}

// Kept under Snapzy's original property name so the migrated window/query
// sources can be used without a second coordinate-conversion layer.
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
