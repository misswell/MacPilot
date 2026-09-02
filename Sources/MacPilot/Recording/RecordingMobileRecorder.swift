//
//  RecordingMobileRecorder.swift
//  MacPilot
//
//  iPhone/iPad screen recording: a floating preview window plus an
//  AVCaptureSession with an AVCaptureMovieFileOutput whose encoder and
//  container come from the recording settings. The device's audio
//  connection is removed so only the screen content is written.
//

import AVFoundation
import AppKit
import OSLog

@MainActor
final class ScreenRecordingMobileRecorder: NSObject {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingMobileRecorder")

    static let previewWindowTitle = "iDevice Overlayer"

    private var captureSession: AVCaptureSession?
    private var previewSession: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var previewWindow: NSPanel?
    private var completion: ((URL) -> Void)?
    private var previewClosedHandler: (() -> Void)?

    private lazy var recordingDelegate = MobileRecordingDelegate { [weak self] url, error in
        Task { @MainActor in
            self?.handleRecordingFinished(url: url, error: error)
        }
    }

    // MARK: - Floating preview

    /// Shows a floating preview of the attached device. `onClosed` fires
    /// when the preview is dismissed so the model can clear its selection.
    func showPreview(named deviceName: String, onClosed: @escaping () -> Void) {
        closePreview()
        guard let device = ScreenRecordingDeviceDiscovery.availableMobileDevices().first(where: { $0.localizedName == deviceName }) else {
            Self.logger.error("Device preview failed: \(deviceName, privacy: .public) not found")
            onClosed()
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            Self.logger.error("Failed to set up device preview")
            onClosed()
            return
        }
        session.addInput(input)
        session.startRunning()
        previewSession = session

        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 500),
            styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.previewWindowTitle
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let container = CameraPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        container.configure(session: session, mirrored: false, showPlaceholder: true)
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.masksToBounds = true
        let closeButton = NSButton(title: "", target: self, action: #selector(closePreviewWindow))
        closeButton.bezelStyle = .circular
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.frame = NSRect(x: 264, y: 8, width: 24, height: 24)
        container.addSubview(closeButton)
        panel.contentView = container
        panel.center()
        panel.orderFront(nil)
        previewWindow = panel
        previewClosedHandler = onClosed
    }

    @objc private func closePreviewWindow() {
        closePreview()
    }

    func closePreview() {
        let hadWindow = previewWindow != nil
        if let panel = previewWindow { panel.close() }
        previewWindow = nil
        if let session = previewSession {
            if session.isRunning { session.stopRunning() }
            previewSession = nil
        }
        if hadWindow {
            let handler = previewClosedHandler
            previewClosedHandler = nil
            handler?()
        } else {
            previewClosedHandler = nil
        }
    }

    // MARK: - Recording

    /// Records the device screen into a video file. Returns false when the
    /// device cannot be opened; the completion receives the finished file.
    func startRecording(
        named deviceName: String,
        settings: ScreenRecordingSettings,
        onCompleted: @escaping (URL) -> Void
    ) -> Bool {
        guard let device = ScreenRecordingDeviceDiscovery.availableMobileDevices().first(where: { $0.localizedName == deviceName }) else {
            return false
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        let preview = AVCaptureSession()
        preview.sessionPreset = .high

        guard let input = try? AVCaptureDeviceInput(device: device),
              let previewInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              preview.canAddInput(previewInput) else {
            Self.logger.error("Failed to set up device recording")
            return false
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        preview.addInput(previewInput)

        // Mobile devices expose a muxed track; drop the audio connection so
        // only the screen content is written.
        if let audioConnection = output.connection(with: .audio) {
            session.removeConnection(audioConnection)
        }
        if let videoConnection = output.connection(with: .video) {
            output.setOutputSettings(
                [AVVideoCodecKey: settings.effectiveEncoder == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264],
                for: videoConnection
            )
        }

        let folder = ScreenRecordingOutput.folder(for: settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("MacPilot-\(timestamp).\(settings.effectiveFormat.fileExtension)")

        session.startRunning()
        output.startRecording(to: url, recordingDelegate: recordingDelegate)

        captureSession = session
        movieOutput = output
        completion = onCompleted

        // Keep the floating preview available while recording.
        showPreview(named: deviceName) {}
        return true
    }

    func stopRecording() {
        guard let output = movieOutput else { return }
        if captureSession?.isRunning == true {
            output.stopRecording()
        }
    }

    private func handleRecordingFinished(url: URL, error: Error?) {
        if captureSession?.isRunning == true { captureSession?.stopRunning() }
        if previewSession?.isRunning == true { previewSession?.stopRunning() }
        captureSession = nil
        movieOutput = nil
        closePreview()
        if let error {
            Self.logger.error("Device recording failed: \(error.localizedDescription, privacy: .public)")
            ScreenRecordingNotifications.show(
                titleKey: "scRecordingSaveFailedTitle",
                bodyKey: "scRecordingSaveFailedBody",
                arguments: [error.localizedDescription]
            )
        } else {
            ScreenRecordingNotifications.show(
                titleKey: "scRecordingCompletedTitle",
                bodyKey: "scRecordingCompletedBody",
                arguments: [url.lastPathComponent]
            )
            completion?(url)
        }
        completion = nil
    }
}

/// Non-isolated shim that forwards AVCaptureFileOutputRecordingDelegate
/// callbacks onto the main actor (the recorder owns AppKit windows).
final class MobileRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let handler: @Sendable (URL, Error?) -> Void

    init(handler: @escaping @Sendable (URL, Error?) -> Void) {
        self.handler = handler
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        handler(outputFileURL, error)
    }
}
