//
//  DelayedCaptureCountdown.swift
//  MacPilot
//
//  Pre-capture countdown for the delayed screenshot entry point: a small
//  non-activating panel with the remaining seconds and an explicit cancel
//  button, so a misfired hotkey can always be stopped before the selection
//  overlay takes over the screen.
//

import AppKit
import SwiftUI
import Foundation

/// Pure countdown arithmetic kept value-typed so the tick schedule is unit
/// testable without AppKit.
nonisolated struct DelayedCaptureCountdown: Equatable, Sendable {
    let totalSeconds: Int
    /// Seconds elapsed since the countdown began, as reported by ticks.
    private let elapsedSeconds: Int

    init(totalSeconds: Int, elapsedSeconds: Int = 0) {
        self.totalSeconds = max(1, totalSeconds)
        self.elapsedSeconds = max(0, elapsedSeconds)
    }

    func advanced(by seconds: Int = 1) -> DelayedCaptureCountdown {
        DelayedCaptureCountdown(totalSeconds: totalSeconds, elapsedSeconds: elapsedSeconds + max(0, seconds))
    }

    var remainingSeconds: Int {
        max(0, totalSeconds - elapsedSeconds)
    }

    var isFinished: Bool { remainingSeconds == 0 }

    /// Progress in 0...1 for the ring indicator.
    var progress: Double {
        guard totalSeconds > 0 else { return 1 }
        return min(1, max(0, Double(elapsedSeconds) / Double(totalSeconds)))
    }
}

/// Centered countdown panel shown between the delayed-capture hotkey and the
/// selection overlay. `cancel` is invoked by the button; the completion only
/// fires when the countdown runs to the end.
struct DelayedCapturePanelView: View {
    @State var countdown: DelayedCaptureCountdown
    var cancelLabel: String
    var onCancel: () -> Void
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: countdown.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(countdown.remainingSeconds)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .frame(width: 76, height: 76)

            Button(cancelLabel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: countdown.totalSeconds) {
            while !countdown.isFinished {
                try? await Task.sleep(for: .seconds(1))
                countdown = countdown.advanced()
            }
            onFinish()
        }
    }
}

@MainActor
final class DelayedCaptureCountdownController {
    static let shared = DelayedCaptureCountdownController()

    private var panel: NSPanel?
    private var isFinished = false

    var isShowing: Bool { panel != nil }

    /// Shows the countdown and invokes `onFinish` when it completes. Any
    /// previous countdown is replaced; the replaced one neither finishes nor
    /// cancels its completion.
    func show(seconds: Int, language: AppLanguage, onFinish: @escaping () -> Void) {
        close()
        isFinished = false
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 150),
            styleMask: [.fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Delayed Capture Countdown"
        panel.level = .statusBar
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: DelayedCapturePanelView(
                countdown: DelayedCaptureCountdown(totalSeconds: max(1, seconds)),
                cancelLabel: AppText.value("scDelayedCaptureCancel", language: language),
                onCancel: { [weak self] in self?.close() },
                onFinish: { [weak self] in
                    guard let self, !self.isFinished else { return }
                    self.isFinished = true
                    self.close()
                    onFinish()
                }
            )
        )
        panel.center()
        if let screen = NSScreen.screenWithMouse {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - 60,
                y: screen.visibleFrame.midY - 75
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
