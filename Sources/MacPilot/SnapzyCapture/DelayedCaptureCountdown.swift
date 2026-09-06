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

/// Observable state the controller ticks so the panel is purely a renderer:
/// driving the countdown from SwiftUI `.task` proved unreliable inside an
/// NSHostingView hosted by a non-activating NSPanel (the panel never closed).
@MainActor
final class DelayedCaptureCountdownState: ObservableObject {
    @Published var countdown: DelayedCaptureCountdown

    init(countdown: DelayedCaptureCountdown) {
        self.countdown = countdown
    }
}

/// Centered countdown panel shown between the delayed-capture hotkey and the
/// selection overlay. `onCancel` fires for the cancel button, `onFinish` when
/// the countdown reaches zero; either fires exactly once.
struct DelayedCapturePanelView: View {
    @ObservedObject var state: DelayedCaptureCountdownState
    var cancelLabel: String
    var onCancel: () -> Void
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: state.countdown.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(state.countdown.remainingSeconds)")
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
    }
}

@MainActor
final class DelayedCaptureCountdownController {
    static let shared = DelayedCaptureCountdownController()

    private var panel: NSPanel?
    private var state: DelayedCaptureCountdownState?
    private var tickTask: Task<Void, Never>?
    private var isFinished = false
    private var pendingCancel: (() -> Void)?
    private var pendingFinish: (() -> Void)?

    var isShowing: Bool { panel != nil }

    /// Shows the countdown and invokes `onFinish` when it completes. The
    /// cancel button invokes `onCancel` first, so the caller can release the
    /// "counting" state; either callback fires exactly once. Any previous
    /// countdown is replaced; the replaced one fires neither callback.
    func show(
        seconds: Int,
        language: AppLanguage,
        onCancel: @escaping () -> Void = {},
        onFinish: @escaping () -> Void
    ) {
        close()
        isFinished = false
        pendingCancel = onCancel
        pendingFinish = onFinish
        let countdownState = DelayedCaptureCountdownState(
            countdown: DelayedCaptureCountdown(totalSeconds: max(1, seconds))
        )
        state = countdownState
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
                state: countdownState,
                cancelLabel: AppText.value("scDelayedCaptureCancel", language: language),
                onCancel: { [weak self] in self?.terminate(isCancel: true) },
                onFinish: { [weak self] in self?.terminate(isCancel: false) }
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
        startTicking()
    }

    /// Ticks once a second on the main actor and closes the panel at zero.
    /// The panel view only renders `state`; the controller owns the clock so
    /// termination cannot depend on SwiftUI lifecycle callbacks.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.isFinished, let state = self.state else { return }
                let advanced = state.countdown.advanced()
                state.countdown = advanced
                if advanced.isFinished {
                    self.terminate(isCancel: false)
                }
            }
        }
    }

    private func terminate(isCancel: Bool) {
        guard !isFinished else { return }
        isFinished = true
        tickTask?.cancel()
        tickTask = nil
        let callback = isCancel ? pendingCancel : pendingFinish
        close()
        callback?()
    }

    func close() {
        tickTask?.cancel()
        tickTask = nil
        panel?.close()
        panel = nil
        state = nil
        pendingCancel = nil
        pendingFinish = nil
    }
}
