//
//  RecordingDevices.swift
//  MacPilot
//
//  Camera overlay, iPhone/iPad capture, device discovery, and the
//  recording notifications. The camera preview lives in a floating,
//  always-capturable window; iOS devices record through AVCaptureSession
//  with an AVCaptureMovieFileOutput.
//

import AVFoundation
import AppKit
import CoreAudio
import CoreMedia
import CoreMediaIO
import OSLog
import UserNotifications

/// Completion/failure notifications for the recording feature.
enum ScreenRecordingNotifications {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingNotifications")

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                logger.error("Notification authorization denied: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func show(titleKey: String, bodyKey: String, arguments: [CVarArg] = []) {
        let content = UNMutableNotificationContent()
        content.title = AppText.value(titleKey, language: .english)
        let bodyTemplate = AppText.value(bodyKey, language: .english)
        content.body = arguments.isEmpty ? bodyTemplate : String(format: bodyTemplate, arguments: arguments)
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(
            identifier: "com.misswell.macpilot.recording.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Owns the floating camera overlay window and the iPhone/iPad capture
/// session. Window titles are fixed, non-localized strings because the
/// capture planner keeps these windows out of the self-exclusion list by
/// title.
@MainActor
final class ScreenRecordingDeviceController: NSObject {
    static let shared = ScreenRecordingDeviceController()

    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecordingDevices")

    static let cameraWindowTitle = "Camera Overlayer"
    static let deviceWindowTitle = "iDevice Overlayer"

    private var cameraSession: AVCaptureSession?
    private var cameraWindow: NSPanel?
    private var cameraMirrored = false

    private var deviceCaptureSession: AVCaptureSession?
    private var devicePreviewSession: AVCaptureSession?
    private var deviceMovieOutput: AVCaptureMovieFileOutput?
    private var deviceWindow: NSPanel?
    private var deviceCompletion: ((URL) -> Void)?
    private var deviceWindowClosedHandler: (() -> Void)?

    // MARK: - Device discovery

    nonisolated static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    nonisolated static func availableMicrophones() -> [AVCaptureDevice] {
        // .builtInMicrophone is deprecated (renamed .microphone) on macOS 15;
        // construct the legacy identifier from its raw value so the macOS 14
        // discovery path stays warning-free.
        let builtInMicrophone = AVCaptureDevice.DeviceType(rawValue: "builtinMicrophone")
        let discovery: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [builtInMicrophone, .microphone],
                mediaType: .audio,
                position: .unspecified
            )
        } else {
            discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [builtInMicrophone, .external],
                mediaType: .audio,
                position: .unspecified
            )
        }
        return discovery.devices.filter { !$0.localizedName.contains("CADefaultDeviceAggregate") }
    }

    nonisolated static func availableMobileDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
    }

    /// Active format sample rate of the named microphone, or of the system
    /// default input device when "default" is selected.
    nonisolated static func selectedMicrophoneSampleRate(deviceName: String) -> Int {
        if deviceName != "default",
           let device = availableMicrophones().first(where: { $0.localizedName == deviceName }),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee {
            return Int(asbd.mSampleRate)
        }
        return defaultInputSampleRate() ?? 48_000
    }

    private nonisolated static func defaultInputSampleRate() -> Int? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        guard status == noErr else { return nil }
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout<Double>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rateStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &sampleRate)
        guard rateStatus == noErr else { return nil }
        return Int(sampleRate)
    }

    /// Allows screen capture of attached mobile devices (the CoreMediaIO
    /// flag that must be on before iPhone screens can be recorded).
    nonisolated static func enableMobileDeviceScreenCapture() {
        var allow: UInt32 = 1
        let dataSize: UInt32 = 4
        let zero: UInt32 = 0
        var property = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &property,
            zero,
            nil,
            dataSize,
            &allow
        )
    }

    // MARK: - Camera overlay

    /// Shows the floating camera preview. The preview window is captured by
    /// the recording stream like any other on-screen window, so whatever it
    /// shows lands in the video.
    func showCameraOverlay(device: AVCaptureDevice) {
        closeCameraOverlay()
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            Self.logger.error("Failed to set up camera preview")
            return
        }
        session.addInput(input)
        session.startRunning()
        cameraSession = session

        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 200),
            styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.cameraWindowTitle
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
        let flipButton = NSButton(title: "", target: self, action: #selector(flipCameraPreview))
        flipButton.bezelStyle = .circular
        flipButton.image = NSImage(systemSymbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill", accessibilityDescription: "Flip")
        flipButton.frame = NSRect(x: 168, y: 8, width: 24, height: 24)
        flipButton.isBordered = false
        container.addSubview(flipButton)
        panel.contentView = container
        panel.center()
        panel.orderFront(nil)
        cameraWindow = panel
    }

    @objc private func flipCameraPreview() {
        cameraMirrored.toggle()
        cameraWindow?.contentView?.subviews
            .compactMap { $0 as? CameraPreviewContainerView }
            .first?.setMirrored(cameraMirrored)
    }

    func closeCameraOverlay() {
        if let panel = cameraWindow { panel.close() }
        cameraWindow = nil
        if let session = cameraSession {
            if session.isRunning { session.stopRunning() }
            cameraSession = nil
        }
        cameraMirrored = false
    }

    // MARK: - iPhone / iPad preview

    /// Shows a floating preview of the attached device. `onClosed` fires
    /// when the preview is dismissed so the model can clear its selection.
    func showDevicePreview(named deviceName: String, onClosed: @escaping () -> Void) {
        closeDeviceOverlay()
        guard let device = Self.availableMobileDevices().first(where: { $0.localizedName == deviceName }) else {
            onClosed()
            return
        }
        let previewSession = AVCaptureSession()
        previewSession.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: device), previewSession.canAddInput(input) else {
            Self.logger.error("Failed to set up device preview")
            onClosed()
            return
        }
        previewSession.addInput(input)
        previewSession.startRunning()
        devicePreviewSession = previewSession

        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 500),
            styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.deviceWindowTitle
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let container = CameraPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        container.configure(session: previewSession, mirrored: false, showPlaceholder: true)
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.masksToBounds = true
        let closeButton = NSButton(title: "", target: self, action: #selector(closeDevicePreview))
        closeButton.bezelStyle = .circular
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.frame = NSRect(x: 264, y: 8, width: 24, height: 24)
        container.addSubview(closeButton)
        panel.contentView = container
        panel.center()
        panel.orderFront(nil)
        deviceWindow = panel
        deviceWindowClosedHandler = onClosed
    }

    @objc private func closeDevicePreview() {
        closeDeviceOverlay()
    }

    func closeDeviceOverlay() {
        let hadWindow = deviceWindow != nil
        if let panel = deviceWindow { panel.close() }
        deviceWindow = nil
        if let session = devicePreviewSession {
            if session.isRunning { session.stopRunning() }
            devicePreviewSession = nil
        }
        if hadWindow {
            let handler = deviceWindowClosedHandler
            deviceWindowClosedHandler = nil
            handler?()
        } else {
            deviceWindowClosedHandler = nil
        }
    }

    // MARK: - iPhone / iPad recording

    /// Records the device screen into a video file through
    /// AVCaptureMovieFileOutput with the encoder and container from the
    /// recording settings; the audio connection is removed because mobile
    /// devices expose a muxed track. Returns false when the device cannot
    /// be opened.
    func startDeviceRecording(
        named deviceName: String,
        settings: ScreenRecordingSettings,
        onCompleted: @escaping (URL) -> Void
    ) -> Bool {
        guard let device = Self.availableMobileDevices().first(where: { $0.localizedName == deviceName }) else {
            return false
        }
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        let previewSession = AVCaptureSession()
        previewSession.sessionPreset = .high

        guard let input = try? AVCaptureDeviceInput(device: device),
              let previewInput = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input),
              previewSession.canAddInput(previewInput) else {
            Self.logger.error("Failed to set up device recording")
            return false
        }

        let output = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(output) else { return false }
        captureSession.addInput(input)
        captureSession.addOutput(output)
        previewSession.addInput(previewInput)

        if let audioConnection = output.connection(with: .audio) {
            captureSession.removeConnection(audioConnection)
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

        captureSession.startRunning()
        output.startRecording(to: url, recordingDelegate: deviceRecordingDelegate)

        deviceCaptureSession = captureSession
        deviceMovieOutput = output
        deviceCompletion = onCompleted

        // Keep the floating preview available while recording.
        showDevicePreview(named: deviceName) {}
        return true
    }

    private lazy var deviceRecordingDelegate = DeviceRecordingDelegate { [weak self] url, error in
        Task { @MainActor in
            self?.handleDeviceRecordingFinished(url: url, error: error)
        }
    }

    private func handleDeviceRecordingFinished(url: URL, error: Error?) {
        if deviceCaptureSession?.isRunning == true { deviceCaptureSession?.stopRunning() }
        if devicePreviewSession?.isRunning == true { devicePreviewSession?.stopRunning() }
        deviceCaptureSession = nil
        deviceMovieOutput = nil
        closeDeviceOverlay()
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
            deviceCompletion?(url)
        }
        deviceCompletion = nil
    }

    func stopDeviceRecording() {
        guard let output = deviceMovieOutput else { return }
        if deviceCaptureSession?.isRunning == true {
            output.stopRecording()
        }
    }
}

/// Non-isolated shim that forwards AVCaptureFileOutputRecordingDelegate
/// callbacks onto the main actor (the controller owns AppKit windows).
final class DeviceRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
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

// MARK: - Preview layer container

/// NSView hosting an AVCaptureVideoPreviewLayer, used by both the camera
/// overlay window and the device preview window.
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

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
