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
import ScreenCaptureKit
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
    /// snapshot. Snapshot refreshes are throttled: while one capture is in
    /// flight the window just follows the cursor.
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
            guard let image = await NSImage.snapshotOfActiveDisplay() else { return }
            let location = NSEvent.mouseLocation
            var frame = window.frame
            frame.origin = NSPoint(x: location.x - frame.width / 2, y: location.y - frame.height / 2)
            let cropRect = NSRect(x: location.x - 67, y: location.y - 58, width: 134, height: 116)
            window.contentView = NSHostingView(
                rootView: MagnifierContentView(snapshot: image.cropped(to: cropRect))
            )
            window.setFrameOrigin(frame.origin)
            window.orderFront(nil)
        }
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

private extension NSImage {
    /// Screen capture of the display under the cursor with this app's
    /// windows excluded. Main-actor isolated because it reads the mouse
    /// location and returns a non-sendable `NSImage`.
    @MainActor
    static func snapshotOfActiveDisplay() async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let mouseLocation = NSEvent.mouseLocation
        guard let display = content.displays.first(where: { $0.frame.contains(mouseLocation) }) ?? content.displays.first else {
            return nil
        }
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(display.frame.width))
        configuration.height = max(2, Int(display.frame.height))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: display.frame.size)
    }

    func cropped(to rect: CGRect) -> NSImage {
        let result = NSImage(size: rect.size)
        result.lockFocus()
        result.draw(in: CGRect(origin: .zero, size: result.size), from: rect, operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}
