import Combine
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol
import OSLog
import SwiftUI

/// Orchestrates the trackpad page: touch callbacks in, binary input batches
/// out.
///
/// The pipeline is the plan's stack, one stage per type:
/// `TouchProcessor` → `GestureEngine` → `VelocityCalculator` →
/// `AccelerationCurve` → `InputEvent` → `InputEncoder` → connection.
///
/// This type knows nothing about which transport carries the session — it
/// hands batches to the app model and reacts to connection state changes,
/// which is what lets the trackpad survive a Wi-Fi↔Bluetooth handoff without
/// caring that one happened.
@MainActor
final class RemoteTrackpadModel: ObservableObject {
    @Published private(set) var phase: TrackpadPhase = .idle
    /// Text key of the failure that stopped the session from arming
    /// (accessibility missing, Mac too old, …). `nil` once armed.
    @Published private(set) var beginErrorKey: String?
    @Published private(set) var orientation: TrackpadOrientation {
        didSet { store.orientation = orientation }
    }
    @Published var settings: TrackpadSettings {
        didSet {
            store.settings = settings
            engine.tapToClick = settings.tapToClick
            engine.naturalScrolling = settings.naturalScrolling
            acceleration.trackingSpeed = settings.trackingSpeed
        }
    }

    private weak var appModel: RemoteAppModel?
    private var store = TrackpadSettingsStore()
    /// True when the Mac injects through its own virtual HID device: macOS
    /// applies its pointer curve, so raw finger deltas leave this side and the
    /// local acceleration is bypassed. Refreshed on every (re)begin.
    private var usesSystemAcceleration = false

    /// Switches the finger→cursor mapping. Only the mapping changes: the page
    /// never rotates itself with the device.
    func setOrientation(_ orientation: TrackpadOrientation) {
        self.orientation = orientation
    }

    private var engine = GestureEngine()
    private var velocity = VelocityCalculator()
    private var acceleration = AccelerationCurve()
    private var inertia = InertiaProcessor()
    private var scrollVelocity = VelocityCalculator()

    /// Accumulated raw finger travel, feeding the velocity estimate.
    private var cursorTravel = CGPoint.zero
    private var scrollTravel = CGPoint.zero
    /// Sub-pixel remainders so quantizing to integer deltas never drifts.
    private var cursorRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero

    /// Events waiting for the next flush. Moves merge; clicks wait in order.
    private var pending: [InputEvent] = []
    private var flushTask: Task<Void, Never>?
    private var beginTask: Task<Void, Never>?

    /// The flush cadence: 120 Hz, matching the touch sample rate.
    static let flushInterval: TimeInterval = 1.0 / 120.0
    /// When the queue runs long, pointer motion is the one stream where
    /// freshness beats completeness: keep the newest move, keep every click.
    private static let maximumPendingEvents = 24

    /// End-to-end diagnostics, sampled every couple of seconds — never per
    /// event, the flush loop is too hot for that.
    private let logger = Logger(subsystem: "com.misswell.macpilot.remote", category: "Trackpad")
    private var batchesSent = 0
    private var eventsSent = 0
    private var lastSendLogAt = Date()
    private var didLogFirstBatch = false

    init() {
        let stored = store
        orientation = stored.orientation
        settings = stored.settings
        engine.tapToClick = settings.tapToClick
        engine.naturalScrolling = settings.naturalScrolling
        acceleration.trackingSpeed = settings.trackingSpeed
    }

    // MARK: - Lifecycle

    func open(appModel: RemoteAppModel) {
        guard phase == .idle else { return }
        self.appModel = appModel
        // Defense in depth for a Mac that does not advertise the realtime
        // channel: sending `beginRealtimeInput` anyway would make an older
        // Mac fail to decode the command and drop the whole session. Say so
        // and stop instead.
        guard appModel.supportsRealtimeInput else {
            beginErrorKey = "trackpadNeedsMacUpdate"
            phase = .disconnected
            return
        }
        phase = .entering
        beginErrorKey = nil
        engine.reset()
        startFlushLoop()
        beginTask = Task { await beginSession() }
    }

    func close() {
        guard phase != .idle, phase != .exiting else { return }
        phase = .exiting
        beginTask?.cancel()
        beginTask = nil
        pending.removeAll()
        inertia.stop()
        let appModel = self.appModel
        Task {
            await appModel?.endRealtimeInput()
            self.phase = .idle
        }
    }

    private func beginSession() async {
        defer { beginTask = nil }
        guard let appModel else { return }
        guard appModel.connectionState.isConnected else {
            // The page opened while the supervisor was still dialling; the
            // state observer re-begins the moment the link is up.
            phase = .reconnecting
            return
        }
        switch await appModel.beginRealtimeInput() {
        case .failure(let error):
            beginErrorKey = error.messageKey
            phase = .disconnected
        case .success(let session):
            beginErrorKey = nil
            usesSystemAcceleration = session.usesSystemAcceleration
            phase = .active
            batchesSent = 0
            eventsSent = 0
            lastSendLogAt = Date()
            didLogFirstBatch = false
            logger.info("realtime session armed systemAcceleration=\(session.usesSystemAcceleration)")
            // The flush loop stops whenever the page leaves the active states,
            // so every re-entry after a reconnect restarts it here.
            startFlushLoop()
        }
    }

    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.phase.isActiveLike {
                self.tickGestures()
                self.flushIfNeeded()
                try? await Task.sleep(for: .seconds(Self.flushInterval))
            }
        }
    }

    /// Called from the view whenever the app model's connection state moves.
    func connectionStateChanged(_ state: RemoteConnectionState) {
        switch state {
        case .connected:
            guard phase == .reconnecting, beginTask == nil else { return }
            beginTask = Task { await beginSession() }
        case .reconnecting:
            guard phase.isActiveLike else { return }
            phase = .reconnecting
            dropMotion()
        case .failed, .idle, .discovering:
            guard phase.isActiveLike else { return }
            phase = .disconnected
            dropMotion()
        case .connecting, .pairing, .authenticating:
            break
        }
    }

    private func dropMotion() {
        pending.removeAll()
        inertia.stop()
        engine.reset()
        velocity.reset()
        scrollVelocity.reset()
        cursorTravel = .zero
        scrollTravel = .zero
    }

    // MARK: - Touch ingestion

    func handleTouchEvent(
        phase touchPhase: TouchPhase,
        samples: [TouchSample],
        centroid: CGPoint?,
        touchCount: Int
    ) {
        guard self.phase.isActiveLike else { return }
        let time = touchTime(of: samples)
        let outputs: [GestureOutput]
        switch touchPhase {
        case .began:
            outputs = engine.handleBegan(samples: samples, touchCount: touchCount, centroid: centroid, time: time)
        case .moved:
            outputs = engine.handleMoved(samples: samples, touchCount: touchCount, centroid: centroid, time: time)
        case .ended:
            outputs = engine.handleEnded(samples: samples, remaining: touchCount, time: time)
        case .cancelled:
            outputs = engine.handleCancelled(remaining: touchCount)
        }
        apply(outputs)
    }

    private func touchTime(of samples: [TouchSample]) -> TimeInterval {
        if let last = samples.last { return last.time }
        return ProcessInfo.processInfo.systemUptime
    }

    private func apply(_ outputs: [GestureOutput]) {
        for output in outputs {
            switch output {
            case let .cursor(dx, dy, dragging, time):
                let (mdx, mdy) = mapped(dx: dx, dy: dy)
                if usesSystemAcceleration {
                    // The Mac's virtual HID device rides macOS's own pointer
                    // curve; adding ours would double it.
                    append(.move(
                        dx: quantized(mdx, into: &cursorRemainder.x),
                        dy: quantized(mdy, into: &cursorRemainder.y),
                        dragging: dragging
                    ))
                } else {
                    cursorTravel.x += mdx
                    cursorTravel.y += mdy
                    let velocity = velocity.record(position: cursorTravel, time: time)
                    let speed = hypot(velocity.x, velocity.y)
                    let scaled = acceleration.apply(dx: mdx, dy: mdy, fingerSpeed: speed)
                    append(.move(
                        dx: quantized(scaled.x, into: &cursorRemainder.x),
                        dy: quantized(scaled.y, into: &cursorRemainder.y),
                        dragging: dragging
                    ))
                }

            case let .scroll(dx, dy, time):
                scrollTravel.x += dx
                scrollTravel.y += dy
                scrollVelocity.record(position: scrollTravel, time: time)
                let gain = GestureEngine.scrollGain
                append(.scroll(
                    dx: quantized(dx * gain, into: &scrollRemainder.x),
                    dy: quantized(dy * gain, into: &scrollRemainder.y)
                ))

            case let .scrollEnd(velocityX, velocityY):
                guard settings.scrollInertia else { continue }
                let (vx, vy) = mapped(dx: velocityX, dy: velocityY)
                inertia.start(velocity: CGPoint(x: vx, y: vy))

            case let .click(button, action):
                append(.click(button: button, action: action))
                if action == .down { Haptics.impact() }
            }
        }
    }

    /// Runs each flush cycle so gestures can complete without waiting for a
    /// touch callback (drag arming) and so the glide keeps scrolling.
    private func tickGestures() {
        let now = ProcessInfo.processInfo.systemUptime
        apply(engine.tick(time: now))
        if let delta = inertia.tick(dt: Self.flushInterval) {
            let gain = GestureEngine.scrollGain
            append(.scroll(
                dx: quantized(delta.x * gain, into: &scrollRemainder.x),
                dy: quantized(delta.y * gain, into: &scrollRemainder.y)
            ))
        }
    }

    // MARK: - Motion helpers

    /// Rotates finger deltas for the orientation the user is holding. Landscape
    /// assumes the phone's top points to the user's left.
    private func mapped(dx: Double, dy: Double) -> (Double, Double) {
        switch orientation {
        case .portrait:
            return (dx, dy)
        case .landscape:
            return (-dy, dx)
        }
    }

    private func quantized(_ value: Double, into remainder: inout CGFloat) -> Double {
        let total = value + Double(remainder)
        let rounded = total.rounded()
        remainder = CGFloat(total - rounded)
        return rounded
    }

    private func append(_ event: InputEvent) {
        // Consecutive moves with the same button state merge into one: same
        // total travel, fewer packets. A button state change always stays its
        // own event — the Mac must see the press as an ordered step.
        if case .move(let dx, let dy, let dragging) = event,
           let last = pending.last,
           case .move(let lastDx, let lastDy, let lastDragging) = last,
           lastDragging == dragging {
            pending[pending.count - 1] = .move(dx: lastDx + dx, dy: lastDy + dy, dragging: dragging)
            return
        }
        if case .scroll(let dx, let dy) = event,
           let last = pending.last,
           case .scroll(let lastDx, let lastDy) = last {
            pending[pending.count - 1] = .scroll(dx: lastDx + dx, dy: lastDy + dy)
            return
        }
        pending.append(event)
    }

    // MARK: - Flush

    private func flushIfNeeded() {
        guard !pending.isEmpty else { return }
        guard let appModel, appModel.connectionState.isConnected, phase == .active else {
            // No link, no queue: the state observer already flipped the page
            // into reconnecting, and stale deltas would only jerk the cursor.
            pending.removeAll()
            return
        }
        coalescePending()
        let batch = InputEncoder.encode(pending)
        pending.removeAll()
        batchesSent += 1
        eventsSent += batch.events.count
        if !didLogFirstBatch {
            didLogFirstBatch = true
            logger.info("first batch sent events=\(batch.events.count)")
        }
        let sinceLog = Date().timeIntervalSince(lastSendLogAt)
        if sinceLog >= 2 {
            logger.info("input sent batches=\(self.batchesSent) events/s=\(Int(Double(self.eventsSent) / sinceLog))")
            batchesSent = 0
            eventsSent = 0
            lastSendLogAt = Date()
        }
        appModel.sendRealtimeInput(batch)
    }

    private func coalescePending() {
        guard pending.count > Self.maximumPendingEvents else { return }
        var kept: [InputEvent] = []
        var lastMoveIndex: Int?
        for (index, event) in pending.enumerated() {
            if case .move = event {
                lastMoveIndex = index
            }
        }
        for (index, event) in pending.enumerated() {
            switch event {
            case .move:
                if index == lastMoveIndex {
                    kept.append(event)
                }
            default:
                kept.append(event)
            }
        }
        pending = kept
    }
}
