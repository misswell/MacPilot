//
//  RecordingPanels.swift
//  MacPilot
//
//  Floating panels for the recording flow: the pre-record countdown, the
//  always-on-top controller bar (stop / pause / timer / device picker),
//  and the completion preview that appears in the corner of the screen
//  when a recording finishes.
//

import AppKit
import SwiftUI

// MARK: - Countdown panel

/// Centered countdown shown before a recording starts.
struct CountdownPanelView: View {
    @State var remainingSeconds: Int
    var atEnd: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThickMaterial)
            Text("\(remainingSeconds)")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
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

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { model.stop() }, label: {
                ZStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            })
            .buttonStyle(.plain)

            Button(action: { model.togglePause() }, label: {
                Image(systemName: model.state == .paused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            })
            .buttonStyle(.plain)

            Text(Self.timerText(model.elapsedTime))
                .foregroundStyle(.white)
                .font(.system(size: 15).monospaced())

            if model.settings.capturesMicrophone {
                MicrophoneLevelMeter(level: model.microphoneLevel)
                    .frame(width: 22, height: 14)
                    .accessibilityLabel(Text(AppText.value("scRecordingMicLevel", language: model.language)))
                    .help(AppText.value("scRecordingMicLevel", language: model.language))
            }

            Button(action: { showsDevicePicker = true }, label: {
                ZStack {
                    Rectangle()
                        .fill(model.selectedCameraName.isEmpty ? Color.gray : Color.green)
                        .cornerRadius(4)
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.white)
                }
                .frame(width: 26)
            })
            .buttonStyle(.plain)
            .popover(isPresented: $showsDevicePicker, arrowEdge: .bottom) {
                CaptureDeviceMenuView(model: model)
            }

            Button(action: { handleCancelPressed() }, label: {
                Image(systemName: isCancelArmed ? "trash.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isCancelArmed ? .red : .white.opacity(0.85))
            })
            .buttonStyle(.plain)
            .help(AppText.value(
                isCancelArmed ? "scRecordingCancelArmed" : "scRecordingCancel",
                language: model.language
            ))
        }
        .padding([.leading, .trailing], 4)
        .frame(height: 24)
        .background(Color.purple.cornerRadius(4).shadow(color: .black.opacity(0.3), radius: 4))
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
                    .fill(level >= threshold * 0.85 ? Color.white : Color.white.opacity(0.3))
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
        panel.contentView = NSHostingView(rootView: FloatingControllerBarView(model: model))
        panel.setContentSize(NSSize(width: 262, height: 24))
        panel.center()
        if let screen = NSScreen.screenWithMouse {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - 95,
                y: screen.visibleFrame.maxY - 24
            ))
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

// MARK: - Completion preview

/// Corner preview shown when a recording completes: hover the thumbnail to
/// reveal the play button, click to open, hover the panel for the close
/// button, context menu with Finder/copy/delete actions, auto-dismiss
/// after six idle seconds.
struct CompletionPreviewContentView: View {
    let image: NSImage
    let fileURL: URL
    var language: AppLanguage = .system
    var onClose: () -> Void
    @State private var opacity: Double = 0.0
    @State private var isHovered = false
    @State private var showsPlayButton = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Color.clear
                    .background(.ultraThickMaterial)
                    .cornerRadius(6)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
                    if showsPlayButton {
                        Button(action: {
                            if NSWorkspace.shared.open(fileURL) {
                                onClose()
                            }
                        }, label: {
                            ZStack {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 49))
                                    .foregroundStyle(.black)
                                    .opacity(0.5)
                                Image(systemName: "play.circle")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                        })
                        .buttonStyle(.plain)
                    }
                }
                .onHover { hovering in showsPlayButton = hovering }
                .padding(8)
            }
            if isHovered {
                Button(action: onClose, label: {
                    ZStack {
                        Image(systemName: "circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.black)
                    }
                })
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .opacity(opacity)
        .onHover { hovering in isHovered = hovering }
        .contextMenu {
            Button(AppText.value("scRecordingRevealInFinder", language: language)) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                onClose()
            }
            Button(AppText.value("scRecordingDeleteFile", language: language)) {
                try? FileManager.default.removeItem(at: fileURL)
                onClose()
            }
            Divider()
            Button(AppText.value("scRecordingCopyFile", language: language)) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([fileURL as NSURL])
                onClose()
            }
            Divider()
            Button(AppText.value("scRecordingClosePreview", language: language)) { onClose() }
        }
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { opacity = 1.0 }
            scheduleAutoClose()
        }
        .onChange(of: isHovered) { _, newValue in
            if !newValue { scheduleAutoClose() }
        }
    }

    private func scheduleAutoClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if !isHovered { onClose() }
        }
    }
}

@MainActor
final class ScreenRecordingCompletionPreview {
    static let shared = ScreenRecordingCompletionPreview()

    private var panel: NSWindow?

    func show(image: NSImage, fileURL: URL, language: AppLanguage = .system) {
        close()
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 266, height: 156),
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(
            rootView: CompletionPreviewContentView(image: image, fileURL: fileURL, language: language) { [weak self] in
                self?.close()
            }
        )
        if let screen = NSScreen.screenWithMouse {
            panel.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
