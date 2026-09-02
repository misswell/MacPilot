//
//  RecordingCameraOverlay.swift
//  MacPilot
//
//  The floating camera preview window. The window is an ordinary on-screen
//  window that the recording stream captures, so whatever it shows lands
//  in the video; its fixed title keeps it out of the recorder's
//  self-exclusion list.
//

import AVFoundation
import AppKit
import OSLog

@MainActor
final class ScreenRecordingCameraOverlay: NSObject {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingCameraOverlay")

    static let windowTitle = "Camera Overlayer"

    private var session: AVCaptureSession?
    private var window: NSPanel?
    private var mirrored = false

    /// Shows the floating preview for the given camera, replacing any
    /// existing preview.
    func show(device: AVCaptureDevice) {
        close()
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            Self.logger.error("Failed to set up camera preview")
            return
        }
        session.addInput(input)
        session.startRunning()
        self.session = session

        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 200),
            styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.windowTitle
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let container = CameraPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        container.configure(session: session, mirrored: true, showPlaceholder: false)
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.masksToBounds = true
        let flipButton = NSButton(title: "", target: self, action: #selector(flipPreview))
        flipButton.bezelStyle = .circular
        flipButton.image = NSImage(systemSymbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill", accessibilityDescription: "Flip")
        flipButton.frame = NSRect(x: 168, y: 8, width: 24, height: 24)
        flipButton.isBordered = false
        container.addSubview(flipButton)
        panel.contentView = container
        panel.center()
        panel.orderFront(nil)
        window = panel
    }

    @objc private func flipPreview() {
        mirrored.toggle()
        window?.contentView?.subviews
            .compactMap { $0 as? CameraPreviewContainerView }
            .first?.setMirrored(mirrored)
    }

    func close() {
        if let panel = window { panel.close() }
        window = nil
        if let session {
            if session.isRunning { session.stopRunning() }
            self.session = nil
        }
        mirrored = false
    }
}

/// NSView hosting an AVCaptureVideoPreviewLayer, used by the camera
/// overlay and the mobile-device preview windows.
final class CameraPreviewContainerView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var placeholderLabel: NSTextView?

    func configure(session: AVCaptureSession, mirrored: Bool, showPlaceholder: Bool) {
        wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = bounds
        if showPlaceholder {
            layer.videoGravity = .resizeAspect
        } else {
            layer.videoGravity = .resizeAspectFill
            layer.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
        }
        self.layer?.addSublayer(layer)
        previewLayer = layer
        if showPlaceholder {
            let label = NSTextView(frame: NSRect(x: 0, y: bounds.height / 2 - 12, width: bounds.width, height: 24))
            label.isEditable = false
            label.drawsBackground = false
            label.alignment = .center
            label.string = AppText.value("scRecordingDeviceLocked", language: .english)
            label.textColor = .white
            addSubview(label)
            placeholderLabel = label
        }
    }

    func setMirrored(_ mirrored: Bool) {
        previewLayer?.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        placeholderLabel?.frame = NSRect(x: 0, y: bounds.height / 2 - 12, width: bounds.width, height: 24)
    }
}
