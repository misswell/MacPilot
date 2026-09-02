//
//  RecordingCapturePlanning.swift
//  MacPilot
//
//  Resolves what a recording will capture: which on-screen window a
//  selection or the frontmost application points at, how the mode maps
//  onto a ScreenCaptureKit filter and output geometry, which windows and
//  applications the filter excludes, and the fill color used where the
//  captured content is transparent.
//

import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// A plain-data description of a capturable window, kept separate from
/// ScreenCaptureKit types so the selection rules can be unit-tested.
struct ScreenRecordingWindowProbe: Equatable, Sendable {
    var frame: CGRect
    var windowLayer: Int
    var isOnScreen: Bool
    var bundleID: String?
}

/// Resolves which on-screen window a recording should target.
enum ScreenRecordingWindowPicker {
    /// Picks the recorded window for application-window mode: the on-screen
    /// layer-0 window with the largest overlap on the selection, excluding
    /// the recorder's own application. Windows covering less than half of
    /// the selection are ignored so a sloppy drag falls back to a crop of
    /// the display instead of an accidental window recording.
    static func largestOverlap(
        in probes: [ScreenRecordingWindowProbe],
        selection: CGRect,
        excludingOwnBundleID ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.misswell.macpilot"
    ) -> ScreenRecordingWindowProbe? {
        guard selection.width > 0.5, selection.height > 0.5 else { return nil }
        let selectionArea = selection.width * selection.height
        var winner: ScreenRecordingWindowProbe?
        var winnerOverlap: CGFloat = 0
        for probe in probes
        where probe.windowLayer == 0 && probe.isOnScreen && probe.bundleID != ownBundleID {
            let overlap = probe.frame.intersection(selection)
            guard !overlap.isNull else { continue }
            let overlapArea = overlap.width * overlap.height
            guard overlapArea / selectionArea >= 0.5 else { continue }
            if winner == nil || overlapArea > winnerOverlap {
                winner = probe
                winnerOverlap = overlapArea
            }
        }
        return winner
    }

    /// Picks the largest on-screen window of the frontmost application —
    /// the target of the "record topmost window" hot-key path.
    static func frontmost(in content: SCShareableContent) -> SCWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = content.windows.filter { window in
            guard let owning = window.owningApplication else { return false }
            return owning.processID == app.processIdentifier
                && window.isOnScreen
                && window.windowLayer == 0
                && !(window.title ?? "").isEmpty
                && window.frame.width > 40
                && window.frame.height > 40
        }
        return candidates.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
    }
}

/// Turns the requested capture mode into a concrete stream filter and
/// output geometry.
enum ScreenRecordingCapturePlanner {
    /// The capture decision for one recording session.
    struct Blueprint {
        /// ScreenCaptureKit filter producing the frames.
        let filter: SCContentFilter
        /// Display-local point rectangle when the recording crops a region
        /// of the display; nil when the filter frames the content itself.
        let cropRect: CGRect?
        /// Point size that maps onto the output pixel dimensions.
        let renderSize: CGSize
    }

    /// Builds the blueprint for the requested mode: a display crop, the
    /// full display, or a desktop-independent window that follows its
    /// window if the user moves it mid-recording. The recorder's own
    /// windows are hidden in every display-wide mode except the capture
    /// overlays (camera, mouse ring, magnifier, device preview).
    static func blueprint(
        content: SCShareableContent,
        display: SCDisplay,
        mode: ScreenRecordingCaptureMode,
        selection: CGRect?,
        frontmostOnly: Bool,
        settings: ScreenRecordingSettings
    ) -> Blueprint {
        let excludableOwnWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier else { return false }
            return !ScreenRecordingModel.capturableOverlayWindowTitles.contains(window.title ?? "")
        }

        func croppedDisplay(_ quartzRect: CGRect?) -> Blueprint {
            let localRect = quartzRect
                .map { $0.intersection(display.frame) }
                .flatMap { $0.isNull || $0.isEmpty ? nil : $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
            return Blueprint(
                filter: displayFilter(
                    content: content,
                    display: display,
                    excludableOwnWindows: excludableOwnWindows,
                    settings: settings
                ),
                cropRect: localRect,
                renderSize: localRect?.size ?? display.frame.size
            )
        }

        switch mode {
        case .fullscreen:
            return Blueprint(
                filter: displayFilter(
                    content: content,
                    display: display,
                    excludableOwnWindows: excludableOwnWindows,
                    settings: settings
                ),
                cropRect: nil,
                renderSize: display.frame.size
            )
        case .application:
            if frontmostOnly, let window = ScreenRecordingWindowPicker.frontmost(in: content) {
                return Blueprint(
                    filter: SCContentFilter(desktopIndependentWindow: window),
                    cropRect: nil,
                    renderSize: window.frame.size
                )
            }
            guard let selection else { return croppedDisplay(nil) }
            let probes = content.windows.map { window in
                ScreenRecordingWindowProbe(
                    frame: window.frame,
                    windowLayer: window.windowLayer,
                    isOnScreen: window.isOnScreen,
                    bundleID: window.owningApplication?.bundleIdentifier
                )
            }
            guard let probe = ScreenRecordingWindowPicker.largestOverlap(in: probes, selection: selection),
                  let window = matchingWindow(in: content, probe: probe) else {
                return croppedDisplay(selection)
            }
            return Blueprint(
                filter: SCContentFilter(desktopIndependentWindow: window),
                cropRect: nil,
                renderSize: window.frame.size
            )
        case .area, .audio:
            return croppedDisplay(selection)
        }
    }

    /// Fill color for transparent captured content. `wallpaper` returns nil
    /// so the real desktop wallpaper stays in the frame.
    static func backgroundFill(for settings: ScreenRecordingSettings) -> CGColor? {
        switch settings.background {
        case .wallpaper: return nil
        case .clear: return CGColor.clear
        case .black: return CGColor.black
        case .white: return CGColor.white
        case .gray: return NSColor.systemGray.cgColor
        case .yellow: return NSColor.systemYellow.cgColor
        case .orange: return NSColor.systemOrange.cgColor
        case .green: return NSColor.systemGreen.cgColor
        case .blue: return NSColor.systemBlue.cgColor
        case .red: return NSColor.systemRed.cgColor
        case .custom: return CGColor.parse(hexString: settings.customBackgroundHex) ?? CGColor.black
        }
    }

    /// Builds the display-wide filter: the application blocklist and
    /// Control Center are excluded at the application level; the recorder's
    /// own windows, wallpaper/desktop windows (when a fill color replaces
    /// the wallpaper), and Finder desktop-icon windows are excluded at the
    /// window level. The menu bar stays in frame when requested.
    private static func displayFilter(
        content: SCShareableContent,
        display: SCDisplay,
        excludableOwnWindows: [SCWindow],
        settings: ScreenRecordingSettings
    ) -> SCContentFilter {
        var excludedApplications = [SCRunningApplication]()
        var exceptingWindows = excludableOwnWindows

        if !settings.blocklist.isEmpty {
            excludedApplications += content.applications.filter {
                settings.blocklist.contains($0.bundleIdentifier)
            }
        }
        if settings.hideControlCenter {
            excludedApplications += content.applications.filter {
                $0.bundleIdentifier == "com.apple.controlcenter"
            }
        }
        if settings.background != .wallpaper {
            // Replacing the wallpaper with a fill color also removes the
            // Dock's wallpaper and desktop windows so no wallpaper bleeds
            // through around the fill.
            exceptingWindows += content.windows.filter { window in
                guard let title = window.title else { return false }
                return window.owningApplication?.bundleIdentifier == "com.apple.dock"
                    && title != "LPSpringboard" && title != "Dock"
            }
            exceptingWindows += content.windows.filter { window in
                guard let title = window.title else { return false }
                return (window.owningApplication?.bundleIdentifier ?? "").isEmpty && title == "Desktop"
            }
        }
        if settings.hideDesktopFiles {
            // Desktop icons are Finder windows sized to the display with no
            // title; excluding them hides the files from the recording.
            exceptingWindows += content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == "com.apple.finder"
                    && (window.title ?? "").isEmpty
                    && window.frame == display.frame
            }
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: exceptingWindows
        )
        if #available(macOS 14.2, *), settings.includeMenuBar {
            filter.includeMenuBar = true
        }
        return filter
    }

    /// Finds the capture window whose identity matches the selected probe
    /// (same owning application and the same frame within a point).
    private static func matchingWindow(in content: SCShareableContent, probe: ScreenRecordingWindowProbe) -> SCWindow? {
        let probeFrame = probe.frame
        let probeBundleID = probe.bundleID
        return content.windows.first { window in
            guard window.owningApplication?.bundleIdentifier == probeBundleID else { return false }
            let frame = window.frame
            return abs(frame.minX - probeFrame.minX) < 1
                && abs(frame.minY - probeFrame.minY) < 1
                && abs(frame.width - probeFrame.width) < 1
                && abs(frame.height - probeFrame.height) < 1
        }
    }
}
