//
//  RecordingMouseAids.swift
//  MacPilot
//
//  Cursor-anchored recording aids: the highlight ring that visualizes
//  mouse activity and the 3x screen magnifier. Both are frameless windows
//  driven by one global mouse monitor while a recording runs, and both are
//  excluded from the recorder's self-exclusion list so they appear in the
//  captured video.
//

import AppKit
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// The highlight ring that follows the cursor while recording. Rings are
/// color-coded per button (left blue, right purple, other orange) and fade
/// between pressed (0.8) and idle (0.3) opacity. When cursor capture is
/// disabled the ring additionally draws a filled dot, because the real
/// pointer is not part of the video.
struct MouseHighlightRingView: View {
    var event: NSEvent
    var showsCursor: Bool

    private var isPressed: Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseDragged,
             .leftMouseDown, .leftMouseDragged,
             .otherMouseDown, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private var opacity: Double { isPressed ? 0.8 : 0.3 }

    private var color: Color {
        switch event.type {
        case .rightMouseDown, .rightMouseDragged: return .purple
        case .leftMouseDown, .leftMouseDragged: return .blue
        case .otherMouseDown, .otherMouseDragged: return .orange
        default: return .gray
        }
    }

    private var strokeColor: Color {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved: return .black
        default: return .clear
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .overlay(
                    ZStack {
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 4))
                            .foregroundColor(strokeColor.opacity(0.3))
                            .padding(4)
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 4))
                            .foregroundColor(color.opacity(opacity))
                            .padding(8)
                        Circle()
                            .stroke(style: StrokeStyle(lineWidth: 1))
                            .foregroundColor(.gray)
                            .opacity(isPressed ? 0.3 : 0.0)
                            .padding(10)
                    }
                )
            if !showsCursor {
                Circle()
                    .fill(color.opacity(opacity))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// Drives the mouse highlight ring window with a global event monitor and
/// forwards the same events to the magnifier.
@MainActor
final class ScreenRecordingMouseHighlighter {
    static let shared = ScreenRecordingMouseHighlighter()

    private var ringWindow: NSWindow?
    private var monitor: Any?
    private var showsCursor = true

    /// Registers the global mouse monitor that moves the highlight (and
    /// the magnifier, when enabled) during a recording.
    func startMonitoring(showsCursor: Bool = true) {
        self.showsCursor = showsCursor
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .mouseMoved, .rightMouseUp, .rightMouseDown, .rightMouseDragged,
                       .leftMouseUp, .leftMouseDown, .leftMouseDragged, .otherMouseUp, .otherMouseDown, .otherMouseDragged]
        ) { [weak self] event in
            Task { @MainActor in
                self?.route(event: event)
            }
        }
    }

    func stopMonitoring() {
        ringWindow?.orderOut(nil)
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        ScreenRecordingMagnifier.shared.stop()
    }

    private func route(event: NSEvent) {
        moveRing(for: event)
        ScreenRecordingMagnifier.shared.follow(event: event)
    }

    private func moveRing(for event: NSEvent) {
        if ringWindow == nil {
            ringWindow = makeRingWindow()
        }
        guard let ringWindow else { return }
        if event.type == .scrollWheel {
            ringWindow.orderOut(nil)
            return
        }
        let location = event.locationInWindow
        var frame = ringWindow.frame
        frame.origin = NSPoint(x: location.x - frame.width / 2, y: location.y - frame.height / 2)
        ringWindow.contentView = NSHostingView(
            rootView: MouseHighlightRingView(event: event, showsCursor: showsCursor)
        )
        ringWindow.setFrameOrigin(frame.origin)
        ringWindow.orderFront(nil)
    }

    private func makeRingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -70, y: -70, width: 70, height: 70),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Mouse Pointer"
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        return window
    }
}

/// The 3x magnifier window that trails the cursor during a recording,
/// toggled by hotkey. The snapshot comes from ScreenCaptureKit with this
/// app's windows excluded.
struct MagnifierContentView: View {
    var snapshot: NSImage

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .padding(1)
                        .foregroundColor(.blue.opacity(0.5))
                )
                .background(
                    Image(nsImage: snapshot)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: snapshot.size.width * 3, height: snapshot.size.height * 3)
                )
        }
    }
}

@MainActor
final class ScreenRecordingMagnifier {
    static let shared = ScreenRecordingMagnifier()

    private var magnifierWindow: NSWindow?
    private var isEnabled = false
    private var isCapturing = false
    /// ScreenCaptureKit content cached per display; re-queried only when
    /// the cursor moves to another display. The magnifier refreshes many
    /// times per second, and a full content query per refresh is the
    /// expensive part.
    private var cachedContent: SCShareableContent?
    private var cachedDisplayID: CGDirectDisplayID?

    func toggle() {
        isEnabled.toggle()
        if !isEnabled {
            magnifierWindow?.orderOut(nil)
        }
    }

    func stop() {
        isEnabled = false
        magnifierWindow?.orderOut(nil)
    }

    /// Moves the magnifier to the event location and refreshes its zoomed
    /// snapshot. Only the 134×116 pt region around the cursor is captured
    /// (rendered at 3× into a 402×348 image), and snapshot refreshes are
    /// throttled: while one capture is in flight the window just follows
    /// the cursor.
    func follow(event: NSEvent) {
        guard isEnabled, event.type != .scrollWheel else { return }
        if magnifierWindow == nil {
            magnifierWindow = makeWindow()
        }
        guard !isCapturing else { return }
        isCapturing = true
        Task { @MainActor [weak self] in
            defer { self?.isCapturing = false }
            guard let self, self.isEnabled, let window = self.magnifierWindow else { return }
            let location = NSEvent.mouseLocation
            guard let image = await self.zoomedSnapshot(around: location) else { return }
            var frame = window.frame
            frame.origin = NSPoint(x: location.x - frame.width / 2, y: location.y - frame.height / 2)
            window.contentView = NSHostingView(
                rootView: MagnifierContentView(snapshot: image)
            )
            window.setFrameOrigin(frame.origin)
            window.orderFront(nil)
        }
    }

    /// Captures the region around `location` at 3× magnification, using the
    /// cached ScreenCaptureKit content when the cursor stays on the same
    /// display.
    private func zoomedSnapshot(around location: NSPoint) async -> NSImage? {
        guard let display = await displayUnderCursor(at: location) else { return nil }
        let localOrigin = CGPoint(
            x: location.x - display.frame.minX,
            y: location.y - display.frame.minY
        )
        let cropRect = CGRect(origin: localOrigin, size: .zero)
            .insetBy(dx: -67, dy: -58)
            .intersection(CGRect(origin: .zero, size: display.frame.size))
        guard !cropRect.isNull, !cropRect.isEmpty else { return nil }

        let ownApplications = cachedContent?.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        } ?? []
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = cropRect
        configuration.width = max(2, Int(cropRect.width) * 3)
        configuration.height = max(2, Int(cropRect.height) * 3)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: cropRect.size)
    }

    /// The SCDisplay under `location`, refreshing the cached shareable
    /// content only when the cursor switches displays.
    private func displayUnderCursor(at location: NSPoint) async -> SCDisplay? {
        if let content = cachedContent,
           let display = content.displays.first(where: { $0.frame.contains(location) }),
           let id = NSScreen.screenWithMouse?.displayID,
           id == cachedDisplayID {
            return display
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        cachedContent = content
        cachedDisplayID = NSScreen.screenWithMouse?.displayID
        return content.displays.first(where: { $0.frame.contains(location) }) ?? content.displays.first
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -402, y: -402, width: 402, height: 348),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Screen Magnifier"
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        return window
    }
}
