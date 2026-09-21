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
    private typealias Chrome = RecordingChromeStyle

    static let preferredSize = CGSize(
        width: 500,
        height: RecordingChromeStyle.stripHeight
    )

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
        HStack(spacing: Chrome.controlSpacing) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Chrome.recordRed)
                    .frame(width: 7, height: 7)
                Text(AppText.value("scRecordingPrepare", language: configuration.language))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.glyph)
            }
            // Without this the label is the one compressible item, and a strip
            // sized for 准备录制 clips "Ready to Record" down to an ellipsis.
            .fixedSize()

            Divider()
                .frame(height: 20)
                .overlay(Color.white.opacity(Chrome.strokeOpacity))

            glyphButton(
                systemImage: capturesMicrophone ? "mic.fill" : "mic.slash.fill",
                emphasis: capturesMicrophone ? .tinted : .dimmed,
                helpKey: "scRecordingMicrophone"
            ) {
                capturesMicrophone.toggle()
                onAction(.recordingToggleMicrophone)
            }

            glyphButton(
                systemImage: capturesSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                emphasis: capturesSystemAudio ? .tinted : .dimmed,
                helpKey: "scRecordingSystemAudio"
            ) {
                capturesSystemAudio.toggle()
                onAction(.recordingToggleSystemAudio)
            }

            pillButton(
                label: videoQuality == .high ? "HD" : "SD",
                isSelected: videoQuality == .high,
                helpKey: videoQuality == .high
                    ? "scRecordingQualityHighHint"
                    : "scRecordingQualityLowHint"
            ) {
                videoQuality = videoQuality == .high ? .low : .high
                onAction(.recordingToggleQuality)
            }

            glyphButton(
                systemImage: cameraEnabled ? "video.fill" : "video.slash.fill",
                emphasis: cameraEnabled ? .tinted : .dimmed,
                helpKey: "scRecordingCameraToggle"
            ) {
                cameraEnabled.toggle()
                onAction(.recordingToggleCamera)
            }

            pillButton(
                label: "16:9",
                isSelected: activeAspect == 16.0 / 9.0,
                helpKey: "scRecordingAspectHorizontal"
            ) {
                activeAspect = 16.0 / 9.0
                onAction(.recordingAspectLandscape)
            }

            pillButton(
                label: "9:16",
                isSelected: activeAspect == 9.0 / 16.0,
                helpKey: "scRecordingAspectVertical"
            ) {
                activeAspect = 9.0 / 16.0
                onAction(.recordingAspectPortrait)
            }

            Spacer(minLength: 0)

            glyphButton(
                systemImage: "slider.horizontal.3",
                emphasis: .resting,
                helpKey: "scRecordingPrepareSettings"
            ) {
                onAction(.recordingSettings)
            }

            glyphButton(systemImage: "xmark", emphasis: .resting, helpKey: "cancel") {
                onAction(.cancel)
            }

            Button {
                onAction(.recordingStart)
            } label: {
                Chrome.CircleAction(
                    color: Chrome.startGreen,
                    systemImage: "play.fill",
                    glyphOffset: CGSize(width: 1, height: 0)
                )
            }
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingStart", language: configuration.language))
        }
        .padding(.horizontal, Chrome.capsulePadding)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .recordingHUDCapsule(height: Self.preferredSize.height)
    }

    /// A square glyph control: a plain action (`resting`) or a switch
    /// (`.tinted` / `.dimmed`).
    private func glyphButton(
        systemImage: String,
        emphasis: Chrome.ControlEmphasis,
        helpKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(Chrome.ControlButtonStyle(emphasis: emphasis))
        .help(AppText.value(helpKey, language: configuration.language))
    }

    /// A text pill — the framing and quality choices, where the active one
    /// inverts to a white pill with a dark label.
    private func pillButton(
        label: String,
        isSelected: Bool,
        helpKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7)
        }
        .buttonStyle(Chrome.ControlButtonStyle(
            emphasis: isSelected ? .inverted : .tinted,
            width: nil
        ))
        .help(AppText.value(helpKey, language: configuration.language))
    }
}

/// Pure placement for the recording pill. It follows the same below/above
/// convention as the screenshot HUD and clamps the full control to the
/// display even for very small selections near an edge. When the selection
/// is fullscreen (or close to it) the pill cannot fit outside on either
/// vertical side, so it is placed deliberately inside the selection near its
/// bottom edge — centered, with a comfortable inset — instead of being
/// clamped across the selection border and resize handles.
nonisolated enum RecordingSelectionBarLayout {
    /// 与截图选区操作栏共用同一套算术：单栏、优先贴选区下/上方、夹回屏幕，
    /// 近全屏时收进选区内侧。两个入口的 HUD 位置因此保持一致。
    static let gap: CGFloat = AreaSelectionBarLayout.gap
    static let edgeMargin: CGFloat = AreaSelectionBarLayout.edgeMargin
    /// 全屏/近全屏时操作栏收进选区内侧的底边距。
    static let insideInset: CGFloat = AreaSelectionBarLayout.insideInset

    static func resolve(selectionRect: CGRect, barSize: CGSize, bounds: CGSize) -> CGRect {
        AreaSelectionBarLayout.resolve(
            selectionRect: selectionRect,
            barSize: barSize,
            bounds: bounds
        )
    }
}
