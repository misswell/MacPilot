//
//  RecordingPrepareBar.swift
//  MacPilot
//
//  浮光-style "ready to record" bar: after the area/window selection for a
//  recording commits, the recording does not start immediately. A floating
//  bar pinned to the selection lets the user toggle the microphone and
//  system audio, snap the region to a 16:9 / 9:16 framing, cancel, or
//  confirm. Pressing confirm hands the (possibly reframed) rect back to the
//  recording model, which still honors the configured countdown.
//

import AppKit
import SwiftUI
import CoreGraphics
import Foundation

/// Pure geometry for the H/V framing buttons: grow or shrink `rect` into
/// `aspect`, keep its center, and clamp the result into `bounds`.
nonisolated enum RecordingRegionFraming {
    static func rectFitting(_ rect: CGRect, aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0, aspect > 0, bounds.width > 0, bounds.height > 0 else {
            return rect
        }
        var width = rect.width
        var height = width / aspect
        if height > rect.height {
            height = rect.height
            width = height * aspect
        }
        width = min(width, bounds.width)
        height = min(height, bounds.height)
        var fitted = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        ).integral
        fitted.origin.x = min(max(bounds.minX, fitted.minX), bounds.maxX - fitted.width)
        fitted.origin.y = min(max(bounds.minY, fitted.minY), bounds.maxY - fitted.height)
        return fitted
    }
}

/// View model + presentation controller for the prepare bar. Observable so
/// the H/V reframing updates the dimension badge live.
@MainActor
final class ScreenRecordingPrepareBarController: ObservableObject {
    static let shared = ScreenRecordingPrepareBarController()

    @Published private(set) var regionRect: CGRect = .zero
    @Published private(set) var activeAspect: CGFloat?

    private var panel: NSPanel?
    private(set) weak var model: ScreenRecordingModel?
    private var onStart: ((CGRect) -> Void)?
    private var onCancel: (() -> Void)?

    var isShowing: Bool { panel != nil }

    func show(captureRect: CGRect, model: ScreenRecordingModel, onStart: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        close()
        self.model = model
        self.onStart = onStart
        self.onCancel = onCancel
        regionRect = captureRect
        activeAspect = nil

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 344, height: 44),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Prepare Bar"
        panel.level = .statusBar
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingPrepareBarView(controller: self))
        panel.setFrameOrigin(Self.barOrigin(for: captureRect, barSize: NSSize(width: 344, height: 44)))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
        model = nil
        onStart = nil
        onCancel = nil
        activeAspect = nil
    }

    // MARK: - Bar actions (invoked by the view)

    func toggleMicrophone() {
        guard let model else { return }
        model.setCapturesMicrophone(!model.settings.capturesMicrophone)
    }

    func toggleSystemAudio() {
        guard let model else { return }
        model.setCapturesSystemAudio(!model.settings.capturesSystemAudio)
    }

    /// Snaps the region to 16:9 (`aspect` = 16/9) or 9:16, keeping the
    /// region's center and staying inside the display that contains it.
    func reframe(toAspect aspect: CGFloat) {
        guard let displayBounds = Self.quartzDisplayFrame(containing: regionRect) else { return }
        regionRect = RecordingRegionFraming.rectFitting(regionRect, aspect: aspect, in: displayBounds)
        activeAspect = aspect
    }

    func confirm() {
        let rect = regionRect
        let callback = onStart
        close()
        callback?(rect)
    }

    func cancel() {
        let callback = onCancel
        close()
        callback?()
    }

    // MARK: - Placement helpers

    /// Places the bar just below the region (AppKit coordinates); flips
    /// above it when there is no room and clamps into the region's screen.
    static func barOrigin(for quartzRect: CGRect, barSize: NSSize) -> NSPoint {
        let region = SmartCaptureCoordinateConversion.appKitRect(fromQuartzRect: quartzRect) ?? CGRect(
            x: quartzRect.minX, y: quartzRect.minY, width: quartzRect.width, height: quartzRect.height
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(region) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? CGRect(
            x: region.minX, y: region.minY, width: region.width, height: region.height
        )
        var origin = NSPoint(
            x: region.midX - barSize.width / 2,
            y: region.minY - barSize.height - 12
        )
        if origin.y < frame.minY + 8 {
            origin.y = region.maxY + 12
        }
        origin.x = min(max(frame.minX + 8, origin.x), frame.maxX - barSize.width - 8)
        return origin
    }

    private static func quartzDisplayFrame(containing rect: CGRect) -> CGRect? {
        for screen in NSScreen.screens {
            guard let frame = SmartCaptureCoordinateConversion.quartzRect(fromAppKitRect: screen.frame) else {
                continue
            }
            if frame.intersects(rect) || frame.contains(rect.origin) {
                return frame
            }
        }
        return nil
    }
}

/// The bar itself: dark pill with 准备录制 + live dimension badge on the
/// left, audio toggles and H/V framing in the middle, cancel/confirm on the
/// right (浮光's 准备录制 layout).
struct RecordingPrepareBarView: View {
    @ObservedObject var controller: ScreenRecordingPrepareBarController
    @ObservedObject private var model: ScreenRecordingModel

    init(controller: ScreenRecordingPrepareBarController) {
        self.controller = controller
        self.model = controller.model ?? ScreenRecordingModel()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(AppText.value("scRecordingPrepare", language: model.language))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Text("\(Int(controller.regionRect.width)) × \(Int(controller.regionRect.height))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))

            Button(action: { controller.toggleMicrophone() }, label: {
                Image(systemName: model.settings.capturesMicrophone ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(model.settings.capturesMicrophone ? Color.white : Color.white.opacity(0.4))
            })
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingMicrophone", language: model.language))

            Button(action: { controller.toggleSystemAudio() }, label: {
                Image(systemName: model.settings.capturesSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(model.settings.capturesSystemAudio ? Color.white : Color.white.opacity(0.4))
            })
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingSystemAudio", language: model.language))

            aspectButton(label: "16:9", aspect: 16.0 / 9.0)
            aspectButton(label: "9:16", aspect: 9.0 / 16.0)

            Button(action: { controller.cancel() }, label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.85))
            })
            .buttonStyle(.plain)
            .help(AppText.value("cancel", language: model.language))

            Button(action: { controller.confirm() }, label: {
                ZStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 18, height: 18)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                }
            })
            .buttonStyle(.plain)
            .help(AppText.value("scRecordingStart", language: model.language))
        }
        .padding(.horizontal, 12)
        .frame(width: 344, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
    }

    private func aspectButton(label: String, aspect: CGFloat) -> some View {
        let isActive = controller.activeAspect == aspect
        return Button(action: { controller.reframe(toAspect: aspect) }, label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.white : Color.white.opacity(0.14))
                )
        })
        .buttonStyle(.plain)
        .help(AppText.value(
            aspect > 1 ? "scRecordingAspectHorizontal" : "scRecordingAspectVertical",
            language: model.language
        ))
    }
}
