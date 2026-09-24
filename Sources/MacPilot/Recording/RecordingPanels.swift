//
//  RecordingPanels.swift
//  MacPilot
//
//  Floating panels for the recording flow: the pre-record countdown and the
//  always-on-top controller bar (stop / pause / timer / device picker).
//  A finished recording is reported by the media QuickAccess card
//  (`SmartMediaQuickAccessWindowController` in SmartScreenshot.swift).
//

import AppKit
import SwiftUI

/// A click-through outline of the actual display crop. Window sharing is
/// disabled so the guide cannot become part of the recorded video.
@MainActor
final class ScreenRecordingRangeBorder {
    static let shared = ScreenRecordingRangeBorder()
    private var panel: NSPanel?

    func show(rect: CGRect) {
        close()
        guard !rect.isNull, !rect.isEmpty else { return }
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Range Border"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = ScreenRecordingRangeBorderView(frame: CGRect(origin: .zero, size: rect.size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private final class ScreenRecordingRangeBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.systemRed.setStroke()
        border.stroke()
    }
}

// MARK: - Countdown panel

/// Centered countdown shown before a recording starts.
///
/// The disc is drawn, not sampled: this floats in a borderless panel over
/// whatever the user's desktop happens to be, and a `Material` there goes pale
/// on a white page — the digits would disappear exactly when they matter.
struct CountdownPanelView: View {
    @State var remainingSeconds: Int
    var atEnd: () -> Void

    private static let cornerRadius: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(RecordingChromeStyle.fillOpacity))
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(RecordingChromeStyle.strokeOpacity),
                    lineWidth: 1
                )
            Text("\(remainingSeconds)")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundStyle(RecordingChromeStyle.glyph)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.25), value: remainingSeconds)
        }
        .task {
            while remainingSeconds > 1 {
                try? await Task.sleep(for: .seconds(1))
                remainingSeconds -= 1
            }
            try? await Task.sleep(for: .seconds(1))
            atEnd()
        }
    }
}

@MainActor
final class ScreenRecordingCountdownPanel {
    static let shared = ScreenRecordingCountdownPanel()

    private var panel: NSWindow?

    func show(seconds: Int, atEnd: @escaping () -> Void) {
        close()
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Countdown Panel"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(
            rootView: CountdownPanelView(remainingSeconds: max(1, seconds)) { [weak panel] in
                panel?.close()
                atEnd()
            }
        )
        panel.center()
        if let screen = NSScreen.screenWithMouse {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - 60,
                y: screen.frame.midY - 60
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - Floating controller bar

/// The bar shown at the top of the screen while recording: stop,
/// pause/resume, the elapsed timer, the live microphone meter, and the
/// camera/device picker button. The cancel button uses a two-step arm so a
/// stray click cannot discard a long recording.
struct FloatingControllerBarView: View {
    @ObservedObject var model: ScreenRecordingModel
    @State private var showsDevicePicker = false
    @State private var isCancelArmed = false
    @State private var cancelArmResetTask: Task<Void, Never>?

    private typealias Chrome = RecordingChromeStyle

    var body: some View {
        HStack(spacing: Chrome.controlSpacing) {
            Button(action: { model.stop() }, label: {
                Chrome.CircleAction(
                    color: Chrome.recordRed,
                    systemImage: "stop.fill",
                    side: 24,
                    glyphSize: 9
                )
            })
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingStop", language: model.language))

            Button(action: { model.togglePause() }, label: {
                Image(systemName: model.state == .paused ? "play.fill" : "pause.fill")
                    .offset(x: model.state == .paused ? 1 : 0)
            })
            .buttonStyle(Chrome.ControlButtonStyle(
                emphasis: model.state == .paused ? .inverted : .resting
            ))
            .help(AppText.value(
                model.state == .paused ? "scRecordingResume" : "scRecordingPause",
                language: model.language
            ))

            Text(Self.timerText(model.elapsedTime))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Chrome.glyph)
                .fixedSize()
                .layoutPriority(1)

            if model.settings.capturesMicrophone {
                MicrophoneLevelMeter(level: model.microphoneLevel)
                    .frame(width: 22, height: 16)
                    .accessibilityLabel(Text(AppText.value("scRecordingMicLevel", language: model.language)))
                    .help(AppText.value("scRecordingMicLevel", language: model.language))
            }

            Button(action: { showsDevicePicker = true }, label: {
                Image(systemName: model.selectedCameraName.isEmpty ? "video.slash.fill" : "video.fill")
            })
            .buttonStyle(Chrome.ControlButtonStyle(
                emphasis: model.selectedCameraName.isEmpty ? .dimmed : .tinted
            ))
            .help(AppText.value("scRecordingCamera", language: model.language))
            .popover(isPresented: $showsDevicePicker, arrowEdge: .bottom) {
                CaptureDeviceMenuView(model: model)
            }

            Button(action: { handleCancelPressed() }, label: {
                Image(systemName: isCancelArmed ? "trash.fill" : "xmark")
            })
            .buttonStyle(Chrome.ControlButtonStyle(
                emphasis: isCancelArmed ? .destructive : .resting
            ))
            .help(AppText.value(
                isCancelArmed ? "scRecordingCancelArmed" : "scRecordingCancel",
                language: model.language
            ))
        }
        .padding(.horizontal, Chrome.capsulePadding)
        .frame(height: Chrome.stripHeight)
        // The bar lays out at its own width and the panel measures that width;
        // a narrower panel used to spend the shortfall on the timer ("00…"),
        // the one compressible item.
        .fixedSize(horizontal: true, vertical: false)
        .recordingHUDCapsule(height: Chrome.stripHeight)
    }

    /// First press arms the cancel button, a second press within three
    /// seconds actually discards the recording; arming expires on its own.
    private func handleCancelPressed() {
        guard isCancelArmed else {
            isCancelArmed = true
            cancelArmResetTask?.cancel()
            cancelArmResetTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                isCancelArmed = false
            }
            return
        }
        cancelArmResetTask?.cancel()
        isCancelArmed = false
        model.cancel()
    }

    static func timerText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Tiny 4-bar live microphone level indicator used inside the floating
/// controller. Purely decorative; the accessibility label carries meaning.
struct MicrophoneLevelMeter: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                let threshold = Double(index + 1) / 4.0
                Capsule()
                    .fill(level >= threshold * 0.85
                        ? RecordingChromeStyle.glyph
                        : RecordingChromeStyle.glyphDimmed)
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Camera / iPhone menu shown from the floating controller: cameras toggle
/// the floating camera overlay, mobile devices toggle the floating preview.
struct CaptureDeviceMenuView: View {
    @ObservedObject var model: ScreenRecordingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.availableCameras.isEmpty {
                Label(AppText.value("scRecordingNoCameras", language: .english), systemImage: "video.slash.fill")
                    .padding(10)
            }
            ForEach(model.availableCameras, id: \.uniqueID) { camera in
                menuRow(
                    title: camera.localizedName,
                    systemImage: "video.fill",
                    isSelected: model.selectedCameraName == camera.localizedName
                ) {
                    model.toggleCameraOverlay(named: camera.localizedName)
                }
            }
            if !model.availableCaptureDevices.isEmpty {
                Divider().padding(.vertical, 4)
            }
            ForEach(model.availableCaptureDevices, id: \.uniqueID) { device in
                menuRow(
                    title: device.localizedName,
                    systemImage: "apple.logo",
                    isSelected: model.selectedDeviceName == device.localizedName
                ) {
                    model.toggleDevicePreview(named: device.localizedName)
                }
            }
        }
        .padding(5)
        .frame(width: 220)
    }

    private func menuRow(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action, label: {
            HStack {
                ZStack {
                    Circle()
                        .frame(width: 26)
                        .foregroundStyle(isSelected ? .blue : .primary)
                        .opacity(isSelected ? 1.0 : 0.2)
                    Image(systemName: systemImage)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .font(.system(size: 12))
                }
                Text(title)
                    .lineLimit(1)
                    .padding(.vertical, 8)
                Spacer()
            }
        })
        .buttonStyle(.plain)
    }
}

@MainActor
final class ScreenRecordingFloatingController {
    static let shared = ScreenRecordingFloatingController()

    private var panel: NSPanel?
    private weak var model: ScreenRecordingModel?

    func show(model: ScreenRecordingModel) {
        close()
        self.model = model
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Controller"
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: FloatingControllerBarView(model: model))
        panel.contentView = host
        // Width measured off the bar, not the 262 that predated the mic meter.
        // Keep the default `sizingOptions`: clearing them zeroes `fittingSize`.
        host.layoutSubtreeIfNeeded()
        let size = RecordingChromeStyle.panelSize(barFitting: host.fittingSize)
        panel.setContentSize(size)
        if let screen = NSScreen.screenWithMouse {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height
            ))
        } else {
            panel.center()
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
        model = nil
    }
}

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
