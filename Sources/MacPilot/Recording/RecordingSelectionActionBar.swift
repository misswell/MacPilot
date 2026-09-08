//
//  RecordingSelectionActionBar.swift
//  MacPilot
//
//  The in-selection recording controls shown after an area/window is chosen.
//  Keeping this bar inside the frozen selection overlay makes recording feel
//  like the screenshot flow: the selected frame stays visible while the user
//  chooses audio, quality, camera, framing, or the final start action.
//

import AppKit
import SwiftUI

struct RecordingSelectionBarConfiguration {
    let language: AppLanguage
    let capturesMicrophone: Bool
    let capturesSystemAudio: Bool
    let videoQuality: ScreenRecordingVideoQuality
    let cameraEnabled: Bool
}

struct RecordingSelectionActionBarView: View {
    static let preferredSize = CGSize(width: 474, height: 48)

    private let configuration: RecordingSelectionBarConfiguration
    private let onAction: (AreaSelectionAction) -> Void
    @State private var capturesMicrophone: Bool
    @State private var capturesSystemAudio: Bool
    @State private var videoQuality: ScreenRecordingVideoQuality
    @State private var cameraEnabled: Bool
    @State private var activeAspect: CGFloat?

    init(
        configuration: RecordingSelectionBarConfiguration,
        onAction: @escaping (AreaSelectionAction) -> Void
    ) {
        self.configuration = configuration
        self.onAction = onAction
        _capturesMicrophone = State(initialValue: configuration.capturesMicrophone)
        _capturesSystemAudio = State(initialValue: configuration.capturesSystemAudio)
        _videoQuality = State(initialValue: configuration.videoQuality)
        _cameraEnabled = State(initialValue: configuration.cameraEnabled)
        _activeAspect = State(initialValue: nil)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 7, height: 7)
                Text(AppText.value("scRecordingPrepare", language: configuration.language))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Divider()
                .frame(height: 20)
                .overlay(Color.white.opacity(0.22))

            toggleButton(
                systemImage: capturesMicrophone ? "mic.fill" : "mic.slash.fill",
                isOn: capturesMicrophone,
                helpKey: "scRecordingMicrophone"
            ) {
                capturesMicrophone.toggle()
                onAction(.recordingToggleMicrophone)
            }

            toggleButton(
                systemImage: capturesSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                isOn: capturesSystemAudio,
                helpKey: "scRecordingSystemAudio"
            ) {
                capturesSystemAudio.toggle()
                onAction(.recordingToggleSystemAudio)
            }

            Button {
                videoQuality = videoQuality == .high ? .low : .high
                onAction(.recordingToggleQuality)
            } label: {
                Text(videoQuality == .high ? "HD" : "SD")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(videoQuality == .high ? .white : .white.opacity(0.72))
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(videoQuality == .high ? Color.blue.opacity(0.78) : Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)
            .help(AppText.value(
                videoQuality == .high ? "scRecordingQualityHighHint" : "scRecordingQualityLowHint",
                language: configuration.language
            ))

            toggleButton(
                systemImage: cameraEnabled ? "video.fill" : "video.slash.fill",
                isOn: cameraEnabled,
                helpKey: "scRecordingCameraToggle"
            ) {
                cameraEnabled.toggle()
                onAction(.recordingToggleCamera)
            }

            aspectButton(label: "16:9", aspect: 16.0 / 9.0, action: .recordingAspectLandscape)
            aspectButton(label: "9:16", aspect: 9.0 / 16.0, action: .recordingAspectPortrait)

            Spacer(minLength: 0)

            Button {
                onAction(.recordingSettings)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingPrepareSettings", language: configuration.language))

            Button {
                onAction(.cancel)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.red.opacity(0.92))
            }
            .buttonStyle(.plain)
            .help(AppText.value("cancel", language: configuration.language))

            Button {
                onAction(.recordingStart)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 22, height: 22)
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
            }
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingStart", language: configuration.language))
        }
        .padding(.horizontal, 12)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(
            RoundedRectangle(cornerRadius: Self.preferredSize.height / 2, style: .continuous)
                .fill(Color.black.opacity(0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.preferredSize.height / 2, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
    }

    private func toggleButton(
        systemImage: String,
        isOn: Bool,
        helpKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? .white : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.white.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(AppText.value(helpKey, language: configuration.language))
    }

    private func aspectButton(
        label: String,
        aspect: CGFloat,
        action: AreaSelectionAction
    ) -> some View {
        let isActive = activeAspect == aspect
        return Button {
            activeAspect = aspect
            onAction(action)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.76))
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.white : Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .help(AppText.value(
            aspect > 1 ? "scRecordingAspectHorizontal" : "scRecordingAspectVertical",
            language: configuration.language
        ))
    }
}

/// Pure placement for the recording pill. It follows the same below/above
/// convention as the screenshot HUD and clamps the full control to the
/// display even for very small selections near an edge.
nonisolated enum RecordingSelectionBarLayout {
    static let gap: CGFloat = 16
    static let edgeMargin: CGFloat = 8

    static func resolve(selectionRect: CGRect, barSize: CGSize, bounds: CGSize) -> CGRect {
        let maxX = max(edgeMargin, bounds.width - barSize.width - edgeMargin)
        let maxY = max(edgeMargin, bounds.height - barSize.height - edgeMargin)
        let spaceBelow = selectionRect.minY - edgeMargin
        let spaceAbove = bounds.height - edgeMargin - selectionRect.maxY
        let preferBelow = spaceBelow >= barSize.height || spaceBelow >= spaceAbove
        let proposedY = preferBelow
            ? selectionRect.minY - gap - barSize.height
            : selectionRect.maxY + gap
        return CGRect(
            x: min(maxX, max(edgeMargin, selectionRect.midX - barSize.width / 2)),
            y: min(maxY, max(edgeMargin, proposedY)),
            width: barSize.width,
            height: barSize.height
        )
    }
}
