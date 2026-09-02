//
//  ScreenRecordingPage.swift
//  MacPilot
//
//  Dedicated settings page for screen recording. Layout follows
//  docs/UI_DESIGN.md: 30pt page header, frosted-glass `SettingsCard`
//  groups with 24pt spacing, label-left/control-right rows.
//

import SwiftUI

struct ScreenRecordingPageView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var recording: ScreenRecordingModel
    @State private var editingShortcut = false
    @State private var editingHotKey: ScreenRecordingHotKeyPurpose?
    @State private var blocklistApps: [ScreenBlocklistApp] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("scRecording"))
                        .font(.system(size: 30, weight: .bold))
                    Text(t("scRecordingSubtitle"))
                        .foregroundStyle(.secondary)
                }

                statusCard
                devicesCard
                videoCard
                audioCard
                behaviorCard
                outputCard
                hotKeysCard
                blocklistCard
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .sheet(isPresented: $editingShortcut) {
            ScreenRecordingShortcutEditor(recording: recording)
        }
        .sheet(item: $editingHotKey) { purpose in
            ScreenRecordingHotKeyEditorSheet(recording: recording, purpose: purpose)
        }
        .onAppear {
            recording.refreshCaptureDeviceLists()
            blocklistApps = ScreenBlocklistApp.runningApps()
        }
    }

    private func t(_ key: String, _ args: CVarArg...) -> String {
        AppText.value(key, language: model.language, arguments: args)
    }

    // MARK: - Rows

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            content()
        }
    }

    private func flag(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
    }

    // MARK: - Status

    private var statusCard: some View {
        SettingsCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(Color.red.opacity(0.13))
                    Image(systemName: recording.state == .recording || recording.state == .paused ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(t("scRecording")).font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(recording.state == .recording ? .red : recording.state == .paused ? .orange : .secondary)
                }
                Spacer()
                Text(recording.settings.shortcut.displayName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(t("scChangeShortcut")) { editingShortcut = true }
                    .buttonStyle(.bordered)
            }

            Divider()

            HStack(spacing: 14) {
                if recording.state == .recording || recording.state == .paused || recording.state == .stopping {
                    if recording.state == .recording {
                        Button(t("scRecordingPause")) { recording.pause() }
                            .buttonStyle(.bordered)
                    } else if recording.state == .paused {
                        Button(t("scRecordingResume")) { recording.resume() }
                            .buttonStyle(.bordered)
                    }
                    Button(t("scRecordingStop")) { recording.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(recording.state == .stopping)
                    Text(formattedDuration)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(recording.state == .paused ? .orange : .red)
                } else if recording.state == .preparing {
                    Button(t("scRecordingCancel")) { recording.cancel() }
                        .buttonStyle(.bordered)
                    Text(t("scRecordingPreparing"))
                        .foregroundStyle(.secondary)
                } else {
                    Button(t("scRecordingStart")) { recording.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    if recording.isDeviceRecording {
                        Button(t("scRecordingStopDeviceRecording")) { recording.stopDeviceRecording() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                }
                Spacer()
            }

            if let error = recording.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.orange.opacity(0.35))
                    )
            }
        }
    }

    private var statusText: String {
        switch recording.state {
        case .idle: return t("scRecordingIdle")
        case .preparing: return t("scRecordingPreparing")
        case .recording: return t("scRecordingActive", formattedDuration)
        case .paused: return t("scRecordingPaused", formattedDuration)
        case .stopping: return t("scRecordingStopping")
        }
    }

    private var formattedDuration: String {
        let totalSeconds = max(0, Int(recording.elapsedTime.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // MARK: - Devices

    private var devicesCard: some View {
        SettingsCard {
            Text(t("scRecordingCamera")).font(.headline)
            row(t("scRecordingCameraRow")) {
                Menu {
                    if recording.availableCameras.isEmpty {
                        Text(t("scRecordingNoCameras"))
                    }
                    ForEach(recording.availableCameras, id: \.uniqueID) { camera in
                        Button(camera.localizedName) {
                            recording.toggleCameraOverlay(named: camera.localizedName)
                        }
                    }
                } label: {
                    Label(
                        recording.selectedCameraName.isEmpty ? t("scRecordingHotKeyOff") : recording.selectedCameraName,
                        systemImage: "video"
                    )
                }
                .frame(width: 240)
            }
            row(t("scRecordingDeviceRow")) {
                Menu {
                    if recording.availableCaptureDevices.isEmpty {
                        Text(t("scRecordingDeviceNotFound"))
                    }
                    ForEach(recording.availableCaptureDevices, id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            recording.toggleDevicePreview(named: device.localizedName)
                        }
                    }
                } label: {
                    Label(
                        recording.selectedDeviceName.isEmpty ? t("scRecordingHotKeyOff") : recording.selectedDeviceName,
                        systemImage: "apple.logo"
                    )
                }
                .frame(width: 240)
            }
            HStack(spacing: 12) {
                if recording.isDeviceRecording {
                    Button(t("scRecordingStopDeviceRecording")) { recording.stopDeviceRecording() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else if !recording.selectedDeviceName.isEmpty {
                    Button(t("scRecordingStartDeviceRecording")) {
                        recording.startDeviceRecording(named: recording.selectedDeviceName)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            Text(t("scRecordingCameraHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Video

    private var videoCard: some View {
        SettingsCard {
            Text(t("scRecordingVideoGroup")).font(.headline)
            row(t("scRecordingCaptureMode")) {
                Picker("", selection: Binding(
                    get: { recording.settings.captureMode },
                    set: { recording.setCaptureMode($0) }
                )) {
                    ForEach(ScreenRecordingCaptureMode.allCases) { mode in
                        Text(t(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if recording.settings.captureMode == .audio {
                Text(t("scRecordingAudioOnlyHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            row(t("scRecordingFormat")) {
                Picker("", selection: Binding(
                    get: { recording.settings.format },
                    set: { recording.setFormat($0) }
                )) {
                    ForEach(ScreenRecordingFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(recording.settings.withAlpha)
            }
            row(t("scRecordingFPS")) {
                Picker("", selection: Binding(
                    get: { recording.settings.framesPerSecond },
                    set: { recording.setFramesPerSecond($0) }
                )) {
                    ForEach([15, 24, 30, 60], id: \.self) { fps in
                        Text(t("scRecordingFPSValue", fps)).tag(fps)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row(t("scRecordingEncoder")) {
                Picker("", selection: Binding(
                    get: { recording.settings.encoder },
                    set: { recording.setEncoder($0) }
                )) {
                    ForEach(ScreenRecordingVideoEncoder.allCases) { encoder in
                        Text(t(encoder.titleKey)).tag(encoder)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .disabled(recording.settings.withAlpha)
            }
            row(t("scRecordingVideoQuality")) {
                Picker("", selection: Binding(
                    get: { recording.settings.videoQuality },
                    set: { recording.setVideoQuality($0) }
                )) {
                    ForEach(ScreenRecordingVideoQuality.allCases) { quality in
                        Text(t(quality.titleKey)).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row(t("scRecordingPixelFormat")) {
                Picker("", selection: Binding(
                    get: { recording.settings.pixelFormat },
                    set: { recording.setPixelFormat($0) }
                )) {
                    ForEach(ScreenRecordingPixelFormat.allCases) { format in
                        Text(t(format.titleKey)).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            row(t("scRecordingBackground")) {
                Picker("", selection: Binding(
                    get: { recording.settings.background },
                    set: { recording.setBackground($0) }
                )) {
                    ForEach(ScreenRecordingBackground.allCases) { background in
                        Text(t(background.titleKey)).tag(background)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if recording.settings.background == .custom {
                row(t("scRecordingCustomBackground")) {
                    TextField(
                        "#RRGGBB",
                        text: Binding(
                            get: { recording.settings.customBackgroundHex },
                            set: { recording.setCustomBackgroundHex($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                }
            }
            Divider()
            flag(t("scRecordingWithAlpha"), isOn: Binding(get: { recording.settings.withAlpha }, set: { recording.setWithAlpha($0) }))
            flag(t("scRecordingHDR"), isOn: Binding(get: { recording.settings.recordHDR }, set: { recording.setRecordHDR($0) }))
            flag(t("scRecordingHighRes"), isOn: Binding(get: { recording.settings.highRes }, set: { recording.setHighRes($0) }))
            flag(t("scRecordingCursor"), isOn: Binding(get: { recording.settings.showsCursor }, set: { recording.setShowsCursor($0) }))
            Text(t("scRecordingAlphaHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Audio

    private var audioCard: some View {
        SettingsCard {
            Text(t("scRecordingAudioGroup")).font(.headline)
            flag(t("scRecordingSystemAudio"), isOn: Binding(get: { recording.settings.capturesSystemAudio }, set: { recording.setCapturesSystemAudio($0) }))
            flag(t("scRecordingMicrophone"), isOn: Binding(get: { recording.settings.capturesMicrophone }, set: { recording.setCapturesMicrophone($0) }))
            if recording.settings.capturesMicrophone {
                row(t("scRecordingMicDevice")) {
                    Picker("", selection: Binding(
                        get: { recording.settings.microphoneDeviceName },
                        set: { recording.setMicrophoneDeviceName($0) }
                    )) {
                        Text("default").tag("default")
                        ForEach(recording.availableMicrophones, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.localizedName)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                flag(t("scRecordingEchoCancellation"), isOn: Binding(get: { recording.settings.microphoneEchoCancellation }, set: { recording.setMicrophoneEchoCancellation($0) }))
                row(t("scRecordingDucking")) {
                    Picker("", selection: Binding(
                        get: { recording.settings.audioDuckingLevel },
                        set: { recording.setAudioDuckingLevel($0) }
                    )) {
                        ForEach(ScreenRecordingAudioDuckingLevel.allCases) { level in
                            Text(t(level.titleKey)).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(!recording.settings.microphoneEchoCancellation)
                }
                flag(t("scRecordingRemuxAudio"), isOn: Binding(get: { recording.settings.remuxAudio }, set: { recording.setRemuxAudio($0) }))
                Text(recording.settings.remuxAudio ? t("scRecordingMicTrackHint") : t("scRecordingRemuxHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            row(t("scRecordingAudioFormat")) {
                Picker("", selection: Binding(
                    get: { recording.settings.audioFormat },
                    set: { recording.setAudioFormat($0) }
                )) {
                    ForEach(ScreenRecordingAudioFormat.allCases) { format in
                        Text(t(format.titleKey)).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row(t("scRecordingAudioQuality")) {
                Picker("", selection: Binding(
                    get: { recording.settings.audioQuality },
                    set: { recording.setAudioQuality($0) }
                )) {
                    ForEach(ScreenRecordingAudioQuality.allCases) { quality in
                        Text(t(quality.titleKey)).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }

    // MARK: - Behavior

    private var behaviorCard: some View {
        SettingsCard {
            Text(t("scRecordingBehaviorGroup")).font(.headline)
            row(t("scRecordingCountdown")) {
                Stepper(value: Binding(
                    get: { recording.settings.countdownSeconds },
                    set: { recording.setCountdownSeconds($0) }
                ), in: 0...99) {
                    Text(t("scSecondsValue", recording.settings.countdownSeconds))
                        .frame(width: 80, alignment: .leading)
                }
                .frame(width: 200)
            }
            row(t("scRecordingAutoStopMinutes")) {
                Stepper(value: Binding(
                    get: { recording.settings.autoStopMinutes },
                    set: { recording.setAutoStopMinutes($0) }
                ), in: 0...99 * 24 * 60) {
                    Text(t("scMinutesValue", recording.settings.autoStopMinutes))
                        .frame(width: 80, alignment: .leading)
                }
                .frame(width: 200)
            }
            row(t("scRecordingPresenterOverlayDelay")) {
                Stepper(value: Binding(
                    get: { recording.settings.presenterOverlaySafeDelay },
                    set: { recording.setPresenterOverlaySafeDelay($0) }
                ), in: 0...99) {
                    Text(t("scSecondsValue", recording.settings.presenterOverlaySafeDelay))
                        .frame(width: 80, alignment: .leading)
                }
                .frame(width: 200)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                flag(t("scRecordingHighlightMouse"), isOn: Binding(get: { recording.settings.highlightMouse }, set: { recording.setHighlightMouse($0) }))
                flag(t("scRecordingHideDesktopFiles"), isOn: Binding(get: { recording.settings.hideDesktopFiles }, set: { recording.setHideDesktopFiles($0) }))
                flag(t("scRecordingHideControlCenter"), isOn: Binding(get: { recording.settings.hideControlCenter }, set: { recording.setHideControlCenter($0) }))
                flag(t("scRecordingIncludeMenuBar"), isOn: Binding(get: { recording.settings.includeMenuBar }, set: { recording.setIncludeMenuBar($0) }))
                flag(t("scRecordingExcludeSelf"), isOn: Binding(get: { recording.settings.excludeSelf }, set: { recording.setExcludeSelf($0) }))
                flag(t("scRecordingPreventSleep"), isOn: Binding(get: { recording.settings.preventSleep }, set: { recording.setPreventSleep($0) }))
                flag(t("scRecordingShowController"), isOn: Binding(get: { recording.settings.showRecordingController }, set: { recording.setShowRecordingController($0) }))
                flag(t("scRecordingShowPreview"), isOn: Binding(get: { recording.settings.showPreviewAfterRecord }, set: { recording.setShowPreviewAfterRecord($0) }))
            }
        }
    }

    // MARK: - Output

    private var outputCard: some View {
        SettingsCard {
            Text(t("scRecordingOutputGroup")).font(.headline)
            HStack {
                Button(t("scRecordingOpenFolder")) { recording.openOutputFolder() }
                    .buttonStyle(.bordered)
                if let url = recording.lastRecordingURL {
                    Text(t("scRecordingLastFile", url.lastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(recording.isConvertingGIF ? t("scRecordingConvertingGIF") : t("scRecordingExportGIF")) {
                        recording.convertLastRecordingToGIF()
                    }
                    .buttonStyle(.bordered)
                    .disabled(recording.isConvertingGIF || recording.state != .idle)
                }
                Spacer()
            }
        }
    }

    // MARK: - Hot keys

    private var hotKeysCard: some View {
        SettingsCard {
            Text(t("scRecordingHotKeys")).font(.headline)
            row(t("scRecordingToggleShortcut")) {
                HStack {
                    Text(recording.settings.shortcut.displayName)
                        .font(.system(.body, design: .monospaced))
                    Button(t("scRecordingEditHotKey")) { editingShortcut = true }
                        .buttonStyle(.bordered)
                }
            }
            ForEach(ScreenRecordingHotKeyPurpose.allCases) { purpose in
                row(t(purpose.titleKey)) {
                    HStack {
                        Text(recording.hotKey(for: purpose)?.displayName ?? t("scRecordingHotKeyOff"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(recording.hotKey(for: purpose) == nil ? .secondary : .primary)
                        Button(t("scRecordingEditHotKey")) { editingHotKey = purpose }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Blocklist

    private var blocklistCard: some View {
        SettingsCard {
            Text(t("scRecordingBlocklist")).font(.headline)
            Text(t("scRecordingBlocklistHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if blocklistApps.isEmpty {
                Text(t("scRecordingBlocklistEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                ForEach(blocklistApps) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { recording.settings.blocklist.contains(app.bundleID) },
                        set: { included in
                            var ids = recording.settings.blocklist
                            if included {
                                if !ids.contains(app.bundleID) { ids.append(app.bundleID) }
                            } else {
                                ids.removeAll { $0 == app.bundleID }
                            }
                            recording.setBlocklist(ids)
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

/// A regular GUI application offered in the recording blocklist editor.
struct ScreenBlocklistApp: Identifiable, Equatable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    static func runningApps() -> [ScreenBlocklistApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.localizedName != nil }
            .map { ScreenBlocklistApp(bundleID: $0.bundleIdentifier!, name: $0.localizedName!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Editor sheet for the primary recording shortcut.
struct ScreenRecordingShortcutEditor: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recording: ScreenRecordingModel
    @State private var recordedKeyCode: UInt16?
    @State private var recordedModifiers: InputSourceShortcutModifiers
    @State private var validationMessage: String?

    init(recording: ScreenRecordingModel) {
        self.recording = recording
        let binding = recording.settings.shortcut
        _recordedKeyCode = State(initialValue: binding.keyCode)
        _recordedModifiers = State(initialValue: binding.modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppText.value("scRecording", language: appModel.language))
                .font(.title2.bold())
            Text(AppText.value("scShortcutHint", language: appModel.language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SmartCaptureShortcutRecorder(
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                placeholder: AppText.value("scRecordShortcut", language: appModel.language),
                onRejected: { error in
                    validationMessage = AppText.value(error.messageKey, language: appModel.language)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            if let conflict = candidateConflicts.first {
                Label(AppText.value(conflict.titleKey, language: appModel.language), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let duplicateKind {
                Label(
                    AppText.value(
                        "scShortcutDuplicate",
                        language: appModel.language,
                        arguments: [AppText.value(duplicateKind.titleKey, language: appModel.language)]
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button(AppText.value("scResetShortcut", language: appModel.language, arguments: [
                    ScreenRecordingSettings.defaultShortcut.displayName
                ])) {
                    let binding = ScreenRecordingSettings.defaultShortcut
                    recordedKeyCode = binding.keyCode
                    recordedModifiers = binding.modifiers
                }
                Spacer()
                Button(AppText.value("cancel", language: appModel.language), role: .cancel) { dismiss() }
                Button(AppText.value("save", language: appModel.language)) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        recordedKeyCode == nil
                            || candidateBinding.validationError != nil
                            || !candidateConflicts.isEmpty
                            || duplicateKind != nil
                    )
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: recordedKeyCode) { _, _ in validationMessage = nil }
        .onChange(of: recordedModifiers) { _, _ in validationMessage = nil }
        .onAppear { recording.suspendShortcut() }
        .onDisappear { recording.resumeShortcut() }
    }

    private var candidateBinding: SmartCaptureShortcutBinding {
        SmartCaptureShortcutBinding(
            keyCode: recordedKeyCode ?? recording.settings.shortcut.keyCode,
            modifiers: recordedModifiers
        )
    }

    private var candidateConflicts: [SmartCaptureSystemShortcutConflict] {
        SmartCaptureSystemShortcutDetector.conflicts(for: candidateBinding)
    }

    private var duplicateKind: ScreenCaptureShortcutKind? {
        ScreenCaptureShortcutKind.allCases.first { captureKind in
            // The screenshot model is owned by the shared app model, so this
            // editor only blocks a duplicate when it can observe that model.
            appModel.screenCapture.shortcutBinding(for: captureKind) == candidateBinding
        }
    }

    private func save() {
        guard recordedKeyCode != nil else { return }
        if recording.setShortcut(candidateBinding) {
            dismiss()
        } else {
            validationMessage = recording.errorMessage
        }
    }
}

/// Editor sheet for the secondary recording hot keys (stop, pause, mode
/// starts, save frame, magnifier). Reuses the shared key recorder.
struct ScreenRecordingHotKeyEditorSheet: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recording: ScreenRecordingModel
    let purpose: ScreenRecordingHotKeyPurpose
    @State private var recordedKeyCode: UInt16?
    @State private var recordedModifiers: InputSourceShortcutModifiers = []
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppText.value(purpose.titleKey, language: appModel.language))
                .font(.title2.bold())
            Text(AppText.value("scShortcutHint", language: appModel.language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SmartCaptureShortcutRecorder(
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                placeholder: AppText.value("scRecordShortcut", language: appModel.language),
                onRejected: { error in
                    validationMessage = AppText.value(error.messageKey, language: appModel.language)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                if recording.hotKey(for: purpose) != nil {
                    Button(AppText.value("scRecordingClearHotKey", language: appModel.language), role: .destructive) {
                        recording.setHotKey(purpose, nil)
                        dismiss()
                    }
                }
                Spacer()
                Button(AppText.value("cancel", language: appModel.language), role: .cancel) { dismiss() }
                Button(AppText.value("save", language: appModel.language)) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(recordedKeyCode == nil || candidateBinding?.validationError != nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { recording.suspendShortcut() }
        .onDisappear { recording.resumeShortcut() }
    }

    private var candidateBinding: SmartCaptureShortcutBinding? {
        guard let recordedKeyCode else { return nil }
        return SmartCaptureShortcutBinding(keyCode: recordedKeyCode, modifiers: recordedModifiers)
    }

    private func save() {
        guard let binding = candidateBinding else { return }
        recording.setHotKey(purpose, binding)
        dismiss()
    }
}
