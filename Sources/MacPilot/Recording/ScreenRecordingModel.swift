//
//  ScreenRecordingModel.swift
//  MacPilot
//
//  Main-actor state machine for the recording feature: owns the settings,
//  the recording session, the capture-device controllers, the secondary
//  hot keys, the countdown/auto-stop timers, and post-recording hand-off
//  (preview panel, notifications, GIF conversion).
//

import AVFoundation
import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import CoreMedia
import OSLog

enum ScreenRecordingState: String, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
}

enum ScreenRecordingError: Error, Equatable, Sendable {
    case permissionRequired
    case microphonePermissionRequired
    case cameraPermissionRequired
    case noDisplayFound
    case alreadyRecording
    case notRecording
    case writerCreationFailed
    case noVideoFrames
    case noAudioCaptured
    case deviceNotFound
    case streamFailed(String)

    var messageKey: String {
        switch self {
        case .permissionRequired: return "scRecordingPermissionRequired"
        case .microphonePermissionRequired: return "scRecordingMicPermissionRequired"
        case .cameraPermissionRequired: return "scRecordingCameraPermissionRequired"
        case .noDisplayFound: return "scRecordingNoDisplay"
        case .alreadyRecording: return "scRecordingAlreadyRunning"
        case .notRecording: return "scRecordingNotRunning"
        case .writerCreationFailed: return "scRecordingWriterFailed"
        case .noVideoFrames: return "scRecordingNoVideoFrames"
        case .noAudioCaptured: return "scRecordingNoAudio"
        case .deviceNotFound: return "scRecordingDeviceNotFound"
        case .streamFailed: return "scRecordingStreamFailed"
        }
    }

}

enum ScreenRecordingOutput {
    static func folder(for settings: ScreenRecordingSettings) -> URL {
        let trimmed = settings.outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("MacPilot Recordings", isDirectory: true)
    }
}

/// App-level hooks attached to every recording session: persisting the
/// H.264→HEVC hardware fallback and hiding the floating camera window while
/// the system Presenter Overlay takes over.
struct ScreenRecordingSessionHooks: @unchecked Sendable {
    var onEncoderFallback: (@MainActor (ScreenRecordingVideoEncoder) -> Void)?
    var onPresenterOverlayChanged: (@MainActor (Bool) -> Void)?
}

@MainActor
final class ScreenRecordingModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "ScreenRecording")

    @Published private(set) var settings = ScreenRecordingSettings()
    @Published private(set) var state: ScreenRecordingState = .idle
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isConvertingGIF = false
    @Published private(set) var isDeviceRecording = false
    @Published private(set) var selectedCameraName = ""
    @Published private(set) var selectedDeviceName = ""
    @Published private(set) var availableCameras: [AVCaptureDevice] = []
    @Published private(set) var availableCaptureDevices: [AVCaptureDevice] = []
    @Published private(set) var availableMicrophones: [AVCaptureDevice] = []

    var language: AppLanguage = .system
    var persist: (() -> Void)?
    /// Injected by the app model so the recording shortcut cannot shadow a
    /// screenshot entry point. Standalone model tests and previews can leave
    /// this unset.
    var isShortcutInUse: ((SmartCaptureShortcutBinding) -> Bool)?
    var onCompleted: ((URL) -> Void)?
    /// Requests the shared screenshot selection overlay for area/application
    /// recording. The callback is intentionally injected so the recording
    /// model remains independent from the overlay controller.
    var onRequestSelection: ((ScreenRecordingCaptureMode) -> Void)?
    var sessionConfigurationHooks: ScreenRecordingSessionHooks?

    /// Floating camera overlay window controller (owned, not shared).
    let cameraOverlay = ScreenRecordingCameraOverlay()
    /// iPhone/iPad capture recorder.
    let mobileRecorder = ScreenRecordingMobileRecorder()

    private var session: ScreenRecordingEngine?
    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pauseStartedAt: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var shortcutContext: ScreenRecordingShortcutContext?
    private var isCountingDown = false
    /// Registered Carbon hot keys in registration order. Index 0 is always
    /// the primary toggle shortcut.
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyEventHandler: EventHandlerRef?

    /// Windows belonging to this app that must remain capturable while
    /// `excludeSelf` is on (the camera/iDevice/mouse/magnifier overlays).
    nonisolated static let capturableOverlayWindowTitles: Set<String> = [
        "Camera Overlayer",
        "iDevice Overlayer",
        "Mouse Pointer",
        "Screen Magnifier"
    ]

    deinit {
        timerTask?.cancel()
    }

    func applyLoadedSettings(_ settings: ScreenRecordingSettings) {
        self.settings = settings
        refreshCaptureDeviceLists()
    }

    func activateFromConfiguration() {
        registerAllHotKeys()
        refreshCaptureDeviceLists()
    }

    func suspendShortcut() {
        unregisterAllHotKeys()
    }

    func resumeShortcut() {
        _ = registerAllHotKeys()
    }

    // MARK: - Settings mutation

    func setOutputFolder(_ url: URL) {
        updateSettings { $0.outputFolder = url.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    func setFormat(_ format: ScreenRecordingFormat) {
        updateSettings { $0.format = format }
    }

    func setCaptureMode(_ mode: ScreenRecordingCaptureMode) {
        updateSettings { $0.captureMode = mode }
    }

    func setFramesPerSecond(_ value: Int) {
        updateSettings { $0.framesPerSecond = min(60, max(5, value)) }
    }

    func setShowsCursor(_ value: Bool) {
        updateSettings { $0.showsCursor = value }
    }

    func setCapturesSystemAudio(_ value: Bool) {
        updateSettings { $0.capturesSystemAudio = value }
    }

    func setCapturesMicrophone(_ value: Bool) {
        updateSettings { $0.capturesMicrophone = value }
    }

    func setMicrophoneEchoCancellation(_ value: Bool) {
        updateSettings { $0.microphoneEchoCancellation = value }
    }

    func setEncoder(_ encoder: ScreenRecordingVideoEncoder) {
        updateSettings { $0.encoder = encoder }
    }

    func setAudioFormat(_ format: ScreenRecordingAudioFormat) {
        updateSettings { $0.audioFormat = format }
    }

    func setAudioQuality(_ quality: ScreenRecordingAudioQuality) {
        updateSettings { $0.audioQuality = quality }
    }

    /// Enabling alpha forces HEVC + MOV; turning it off restores the
    /// wallpaper background from a transparent one.
    func setWithAlpha(_ value: Bool) {
        updateSettings {
            $0.withAlpha = value
            if value {
                $0.encoder = .hevc
                $0.format = .mov
            } else if $0.background == .clear {
                $0.background = .wallpaper
            }
        }
    }

    func setRecordHDR(_ value: Bool) {
        updateSettings { $0.recordHDR = value }
    }

    func setHighRes(_ value: Bool) {
        updateSettings { $0.highRes = value }
    }

    func setPixelFormat(_ format: ScreenRecordingPixelFormat) {
        updateSettings { $0.pixelFormat = format }
    }

    func setBackground(_ background: ScreenRecordingBackground) {
        updateSettings { $0.background = background }
    }

    func setCustomBackgroundHex(_ hex: String) {
        updateSettings { $0.customBackgroundHex = hex }
    }

    func setVideoQuality(_ quality: ScreenRecordingVideoQuality) {
        updateSettings { $0.videoQuality = quality }
    }

    func setCountdownSeconds(_ seconds: Int) {
        updateSettings { $0.countdownSeconds = min(99, max(0, seconds)) }
    }

    func setAutoStopMinutes(_ minutes: Int) {
        updateSettings { $0.autoStopMinutes = min(99 * 24 * 60, max(0, minutes)) }
    }

    func setRemuxAudio(_ value: Bool) {
        updateSettings { $0.remuxAudio = value }
    }

    func setMicrophoneDeviceName(_ name: String) {
        updateSettings { $0.microphoneDeviceName = name }
    }

    func setAudioDuckingLevel(_ level: ScreenRecordingAudioDuckingLevel) {
        updateSettings { $0.audioDuckingLevel = level }
    }

    func setHighlightMouse(_ value: Bool) {
        updateSettings { $0.highlightMouse = value }
    }

    func setHideDesktopFiles(_ value: Bool) {
        updateSettings { $0.hideDesktopFiles = value }
    }

    func setHideControlCenter(_ value: Bool) {
        updateSettings { $0.hideControlCenter = value }
    }

    func setIncludeMenuBar(_ value: Bool) {
        updateSettings { $0.includeMenuBar = value }
    }

    func setExcludeSelf(_ value: Bool) {
        updateSettings { $0.excludeSelf = value }
    }

    func setPreventSleep(_ value: Bool) {
        updateSettings { $0.preventSleep = value }
    }

    func setShowPreviewAfterRecord(_ value: Bool) {
        updateSettings { $0.showPreviewAfterRecord = value }
    }

    func setShowRecordingController(_ value: Bool) {
        updateSettings { $0.showRecordingController = value }
    }

    func setPresenterOverlaySafeDelay(_ seconds: Int) {
        updateSettings { $0.presenterOverlaySafeDelay = min(99, max(0, seconds)) }
    }

    func setBlocklist(_ bundleIDs: [String]) {
        updateSettings { $0.blocklist = bundleIDs }
    }

    func setHotKey(_ purpose: ScreenRecordingHotKeyPurpose, _ binding: SmartCaptureShortcutBinding?) {
        updateSettings {
            if let binding, binding.isValid {
                $0.hotkeys[purpose.rawValue] = binding
            } else {
                $0.hotkeys.removeValue(forKey: purpose.rawValue)
            }
        }
        _ = registerAllHotKeys()
    }

    func hotKey(for purpose: ScreenRecordingHotKeyPurpose) -> SmartCaptureShortcutBinding? {
        settings.hotkeys[purpose.rawValue]
    }

    @discardableResult
    func setShortcut(_ binding: SmartCaptureShortcutBinding) -> Bool {
        guard binding.isValid else {
            errorMessage = AppText.value(
                binding.validationError?.messageKey ?? "scShortcutRegistrationFailed",
                language: language
            )
            return false
        }
        guard binding != settings.shortcut else { return true }
        guard !(isShortcutInUse?(binding) ?? false) else {
            errorMessage = AppText.value("scShortcutUsedByScreenshot", language: language)
            return false
        }
        let previous = settings.shortcut
        settings.shortcut = binding
        guard registerAllHotKeys() else {
            settings.shortcut = previous
            _ = registerAllHotKeys()
            errorMessage = AppText.value("scShortcutRegistrationFailed", language: language)
            return false
        }
        persist?()
        errorMessage = nil
        return true
    }

    // MARK: - Capture devices

    func refreshCaptureDeviceLists() {
        availableCameras = ScreenRecordingDeviceDiscovery.availableCameras()
        availableCaptureDevices = ScreenRecordingDeviceDiscovery.availableMobileDevices()
        availableMicrophones = ScreenRecordingDeviceDiscovery.availableMicrophones()
    }

    /// Toggles the floating camera preview window. The preview window is
    /// an on-screen window that the recording stream captures, so whatever
    /// it shows lands in the video.
    func toggleCameraOverlay(named deviceName: String) {
        if selectedCameraName == deviceName {
            selectedCameraName = ""
            cameraOverlay.close()
            return
        }
        guard let device = availableCameras.first(where: { $0.localizedName == deviceName }) else { return }
        selectedCameraName = deviceName
        cameraOverlay.show(device: device)
    }

    /// Toggles the floating iPhone/iPad preview. Starting an actual device
    /// recording goes through `startDeviceRecording(named:)`.
    func toggleDevicePreview(named deviceName: String) {
        if selectedDeviceName == deviceName {
            selectedDeviceName = ""
            mobileRecorder.closePreview()
            return
        }
        selectedDeviceName = deviceName
        mobileRecorder.showPreview(named: deviceName) { [weak self] in
            self?.selectedDeviceName = ""
        }
    }

    /// Records an iPhone/iPad screen via AVCaptureSession. The macOS
    /// screen is not captured; the device feed goes straight into a video
    /// file.
    func startDeviceRecording(named deviceName: String) {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        errorMessage = nil
        let settings = self.settings
        Task { [weak self] in
            guard let self else { return }
            var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                || AVCaptureDevice.authorizationStatus(for: .muxed) == .authorized
            if !cameraAuthorized {
                cameraAuthorized = await Self.requestCameraAccess()
            }
            guard cameraAuthorized else {
                self.errorMessage = self.localized(ScreenRecordingError.cameraPermissionRequired)
                return
            }
            let started = mobileRecorder.startRecording(
                named: deviceName,
                settings: settings
            ) { [weak self] url in
                guard let self else { return }
                self.isDeviceRecording = false
                self.selectedDeviceName = ""
                self.lastRecordingURL = url
                self.onCompleted?(url)
            }
            if started {
                self.isDeviceRecording = true
                self.selectedDeviceName = deviceName
            } else {
                self.errorMessage = self.localized(ScreenRecordingError.deviceNotFound)
            }
        }
    }

    func stopDeviceRecording() {
        guard isDeviceRecording else { return }
        mobileRecorder.stopRecording()
        isDeviceRecording = false
        selectedDeviceName = ""
    }

    // MARK: - Start / stop

    func start() {
        start(captureRect: nil)
    }

    /// Starts a recording immediately when a selection has already been made.
    /// Passing `nil` from the public `start()` path requests the pre-record
    /// area selector for the configured area/application modes.
    func start(captureRect: CGRect?) {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        if captureRect == nil, settings.captureMode != .fullscreen {
            guard let onRequestSelection else {
                errorMessage = localized(ScreenRecordingError.noDisplayFound)
                return
            }
            onRequestSelection(settings.captureMode)
            return
        }
        if settings.captureMode == .audio {
            startAudioRecording()
            return
        }
        let countdown = settings.countdownSeconds
        if countdown > 0 {
            isCountingDown = true
            ScreenRecordingCountdownPanel.shared.show(seconds: countdown) { [weak self] in
                guard let self else { return }
                self.isCountingDown = false
                self.beginStart(captureRect: captureRect, directWindow: false)
            }
        } else {
            beginStart(captureRect: captureRect, directWindow: false)
        }
    }

    /// Starts a recording of the current screen without the selection
    /// overlay, regardless of the configured capture mode (the "record
    /// current screen" hotkey path).
    func startScreenRecording() {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        beginCountdownOr { [weak self] in
            self?.beginStart(captureRect: nil, directWindow: false, overrideCaptureMode: .fullscreen)
        }
    }

    private func beginCountdownOr(_ action: @escaping () -> Void) {
        let countdown = settings.countdownSeconds
        if countdown > 0 {
            isCountingDown = true
            ScreenRecordingCountdownPanel.shared.show(seconds: countdown) { [weak self] in
                guard let self else { return }
                self.isCountingDown = false
                action()
            }
        } else {
            action()
        }
    }

    /// Starts a recording of the frontmost application's on-screen window
    /// without showing the selection overlay (the "record topmost window"
    /// hotkey path).
    func startFrontmostWindowRecording() {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        beginCountdownOr { [weak self] in
            self?.beginStart(captureRect: nil, directWindow: true, overrideCaptureMode: .application)
        }
    }

    /// Starts a system-audio (optionally microphone) recording with no video.
    func startAudioRecording() {
        guard state == .idle, !isDeviceRecording else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard !isCountingDown else { return }
        beginCountdownOr { [weak self] in
            self?.beginStart(captureRect: nil, directWindow: false, overrideCaptureMode: .audio)
        }
    }

    private func beginStart(captureRect: CGRect?, directWindow: Bool, overrideCaptureMode: ScreenRecordingCaptureMode? = nil) {
        guard state == .idle else {
            errorMessage = localized(ScreenRecordingError.alreadyRecording)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            errorMessage = localized(ScreenRecordingError.permissionRequired)
            return
        }
        state = .preparing
        errorMessage = nil
        var snapshot = settings
        if let overrideCaptureMode {
            snapshot.captureMode = overrideCaptureMode
        }
        Task { @MainActor [weak self] in
            await self?.performStart(
                snapshot: snapshot,
                captureRect: captureRect,
                frontmostWindowOnly: directWindow
            )
        }
    }

    /// Resolves microphone permission, builds the engine session, and moves
    /// the model into the recording state. Runs off the synchronous start
    /// path so the UI never blocks on session construction.
    private func performStart(
        snapshot: ScreenRecordingSettings,
        captureRect: CGRect?,
        frontmostWindowOnly: Bool
    ) async {
        do {
            if snapshot.capturesMicrophone {
                let granted = await Self.ensureMicrophonePermission()
                guard granted else {
                    state = .idle
                    errorMessage = localized(ScreenRecordingError.microphonePermissionRequired)
                    return
                }
            }
            let session = try await ScreenRecordingEngine.makeSession(
                settings: snapshot,
                captureRect: captureRect,
                frontmostWindowOnly: frontmostWindowOnly
            )
            try await session.start()
            session.encoderFallbackHandler = sessionConfigurationHooks?.onEncoderFallback
            session.presenterOverlayActivityHandler = sessionConfigurationHooks?.onPresenterOverlayChanged
            self.session = session
            startedAt = Date()
            pauseStartedAt = nil
            accumulatedPauseDuration = 0
            elapsedTime = 0
            state = .recording
            startTimer()
            recordingSessionBegan()
        } catch {
            state = .idle
            errorMessage = localized(error)
            Self.logger.error("Could not start recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called once the engine is streaming: raises the floating controller,
    /// enables the mouse highlight and magnifier monitors, and asks for
    /// notification permission so the completion notice can be delivered.
    private func recordingSessionBegan() {
        ScreenRecordingNotifications.requestAuthorization()
        if settings.showRecordingController {
            ScreenRecordingFloatingController.shared.show(model: self)
        }
        if settings.highlightMouse {
            ScreenRecordingMouseHighlighter.shared.startMonitoring(showsCursor: settings.showsCursor)
        }
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: - Hot key dispatch

    /// Called from the Carbon event handler with the registered hot key
    /// index (0 = primary toggle).
    func handleHotKey(index: Int) {
        // Index 0 is reserved for the primary toggle shortcut.
        if index == 0 {
            toggleFromShortcut()
            return
        }
        let order = hotKeyOrder
        guard index - 1 < order.count else { return }
        switch order[index - 1] {
        case .stop:
            if state == .recording || state == .paused { stop() }
        case .pauseResume:
            if state == .recording || state == .paused { togglePause() }
        case .startAudio:
            if state == .idle { startAudioRecording() }
        case .startScreen:
            if state == .idle { startScreenRecording() }
        case .startWindow:
            if state == .idle { startFrontmostWindowRecording() }
        case .startArea:
            if state == .idle { start() }
        case .saveFrame:
            saveFrame()
        case .toggleMagnifier:
            ScreenRecordingMagnifier.shared.toggle()
        }
    }

    func saveFrame() {
        guard state == .recording, let session else { return }
        session.requestFrameSave { url in
            guard let url else { return }
            ScreenRecordingNotifications.show(
                titleKey: "scRecordingFrameSaved",
                bodyKey: "scRecordingFrameSavedBody",
                arguments: [url.lastPathComponent]
            )
        }
    }

    func toggleFromShortcut() {
        switch state {
        case .idle:
            start()
        case .recording:
            stop()
        case .paused:
            stop()
        case .preparing, .stopping:
            break
        }
    }

    func pause() {
        guard state == .recording, let session else { return }
        session.pause()
        pauseStartedAt = Date()
        elapsedTime = elapsedDuration(at: Date())
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused, let session else { return }
        session.resume()
        if let pauseStartedAt {
            accumulatedPauseDuration += max(0, Date().timeIntervalSince(pauseStartedAt))
        }
        self.pauseStartedAt = nil
        state = .recording
        startTimer()
    }

    func togglePause() {
        switch state {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    func stop() {
        guard (state == .recording || state == .paused), let session else {
            if state == .idle { errorMessage = localized(ScreenRecordingError.notRecording) }
            return
        }
        state = .stopping
        stopTimer()
        let previewImage = session.initialFrameImage
        self.session = nil
        ScreenRecordingFloatingController.shared.close()
        ScreenRecordingMouseHighlighter.shared.stopMonitoring()
        ScreenRecordingMagnifier.shared.stop()
        Task { [weak self] in
            do {
                let url = try await session.stop()
                guard let self else { return }
                self.finishRecording(url: url, previewImage: previewImage)
            } catch {
                guard let self else { return }
                self.state = .idle
                self.startedAt = nil
                self.errorMessage = self.localized(error)
                Self.logger.error("Could not finish recording: \(error.localizedDescription, privacy: .public)")
                ScreenRecordingNotifications.show(
                    titleKey: "scRecordingSaveFailedTitle",
                    bodyKey: "scRecordingSaveFailedBody",
                    arguments: [self.errorMessage ?? ""]
                )
            }
        }
    }

    private func finishRecording(url: URL, previewImage: NSImage?) {
        lastRecordingURL = url
        elapsedTime = elapsedDuration(at: Date())
        startedAt = nil
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        state = .idle
        errorMessage = nil
        if settings.showPreviewAfterRecord, let image = previewImage ?? lastFrameThumbnail(for: url) {
            ScreenRecordingCompletionPreview.shared.show(image: image, fileURL: url)
        }
        ScreenRecordingNotifications.show(
            titleKey: "scRecordingCompletedTitle",
            bodyKey: "scRecordingCompletedBody",
            arguments: [url.lastPathComponent]
        )
        onCompleted?(url)
    }

    private func lastFrameThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 500, height: 500)
        guard let cgImage = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 10), actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func cancel() {
        guard let session else {
            state = .idle
            stopTimer()
            return
        }
        self.session = nil
        state = .idle
        startedAt = nil
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        stopTimer()
        ScreenRecordingFloatingController.shared.close()
        ScreenRecordingMouseHighlighter.shared.stopMonitoring()
        ScreenRecordingMagnifier.shared.stop()
        Task { await session.cancel() }
    }

    func openOutputFolder() {
        let folder = ScreenRecordingOutput.folder(for: settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func convertLastRecordingToGIF() {
        guard !isConvertingGIF, state == .idle, let source = lastRecordingURL else { return }
        guard source.pathExtension.lowercased() != "gif" else { return }
        isConvertingGIF = true
        errorMessage = nil
        let output = source.deletingPathExtension().appendingPathExtension("gif")
        Task { [weak self] in
            do {
                let gif = try await ScreenRecordingGIFConverter.convert(
                    videoURL: source,
                    outputURL: output
                )
                guard let self else { return }
                self.lastRecordingURL = gif
                self.isConvertingGIF = false
                self.onCompleted?(gif)
            } catch {
                guard let self else { return }
                self.isConvertingGIF = false
                self.errorMessage = self.localized(error)
            }
        }
    }

    func shutdown() {
        timerTask?.cancel()
        timerTask = nil
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        if isDeviceRecording {
            mobileRecorder.stopRecording()
            isDeviceRecording = false
        }
        state = .idle
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        unregisterAllHotKeys()
    }

    // MARK: - Timer / auto stop

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .recording else { return }
                let elapsed = self.elapsedDuration(at: Date())
                self.elapsedTime = elapsed
                // Timed auto stop: the configured minute value ends the
                // recording when the elapsed time passes it.
                let limit = self.settings.autoStopMinutes
                if limit > 0, elapsed / 60 >= Double(limit) {
                    self.stop()
                    return
                }
            }
        }
    }

    private func elapsedDuration(at date: Date) -> TimeInterval {
        guard let startedAt else { return elapsedTime }
        let activePause = pauseStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return max(0, date.timeIntervalSince(startedAt) - accumulatedPauseDuration - activePause)
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func updateSettings(_ mutate: (inout ScreenRecordingSettings) -> Void) {
        mutate(&settings)
        persist?()
    }

    // MARK: - Hot key registration

    /// Hot key registration order: index 0 = primary toggle, then the
    /// secondary purposes in `ScreenRecordingHotKeyPurpose.allCases` order
    /// for every purpose with an assigned binding.
    private var hotKeyOrder: [ScreenRecordingHotKeyPurpose] {
        ScreenRecordingHotKeyPurpose.allCases.filter { settings.hotkeys[$0.rawValue] != nil }
    }

    @discardableResult
    private func registerAllHotKeys() -> Bool {
        unregisterAllHotKeys()
        guard settings.shortcut.validationError == nil,
              SmartCaptureSystemShortcutDetector.conflicts(for: settings.shortcut).isEmpty else {
            return false
        }
        var bindings: [SmartCaptureShortcutBinding] = [settings.shortcut]
        for purpose in hotKeyOrder {
            if let binding = settings.hotkeys[purpose.rawValue] {
                bindings.append(binding)
            }
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = ScreenRecordingShortcutContext(model: self)
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            screenRecordingCarbonEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(context).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr, let handler else { return false }

        var registered: [EventHotKeyRef?] = []
        for (index, binding) in bindings.enumerated() {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                ScreenRecordingCarbonHotKey.modifiers(for: binding),
                ScreenRecordingCarbonHotKey.id(for: UInt32(index)),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyNoOptions),
                &hotKey
            )
            if status == noErr, let hotKey {
                registered.append(hotKey)
            } else if index == 0 {
                // The primary shortcut must register or nothing works.
                RemoveEventHandler(handler)
                self.hotKeyEventHandler = nil
                return false
            }
        }
        shortcutContext = context
        hotKeyEventHandler = handler
        hotKeyRefs = registered
        errorMessage = nil
        return true
    }

    private func unregisterAllHotKeys() {
        for hotKey in hotKeyRefs {
            if let hotKey { UnregisterEventHotKey(hotKey) }
        }
        hotKeyRefs = []
        if let hotKeyEventHandler { RemoveEventHandler(hotKeyEventHandler) }
        hotKeyEventHandler = nil
        shortcutContext = nil
    }

    private func localized(_ error: Error) -> String {
        if let recordingError = error as? ScreenRecordingError {
            if case .streamFailed(let detail) = recordingError {
                return AppText.value(recordingError.messageKey, language: language, arguments: [detail])
            }
            return AppText.value(recordingError.messageKey, language: language)
        }
        if let conversionError = error as? ScreenRecordingGIFConverter.ConversionError {
            return AppText.value(conversionError.messageKey, language: language)
        }
        return AppText.value("scRecordingUnknownError", language: language)
    }
}
