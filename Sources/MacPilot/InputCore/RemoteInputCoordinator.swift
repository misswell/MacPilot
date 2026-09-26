import AppKit
import Foundation
import MacPilotRemoteProtocol

enum RemoteInputArmResult: Equatable {
    case armed
    case accessibilityRequired
}

/// The Mac side of the realtime input channel — the trackpad.
///
/// Motion and clicks go through the virtual HID device when it can be created
/// (device-level input: system pointer acceleration, no Accessibility grant
/// needed); otherwise they fall back to posted CGEvents, which do require the
/// grant. Scrolling always rides the continuous-event `ScrollInjector`, whose
/// glide quality a stepped wheel cannot match.
///
/// A session is armed explicitly by the `beginRealtimeInput` command and
/// disarmed by `endRealtimeInput`, the connection closing, or the feature
/// stopping. Batches from an unarmed or unknown connection are dropped,
/// never injected.
///
/// Events are applied in arrival order on the main actor. Report posting is
/// microseconds, so the 120 Hz drain loop that feeds this runs comfortably
/// inside the connection's serial frame budget.
@MainActor
final class RemoteInputCoordinator {
    private let mouse: MouseInjecting
    private let scroll: ScrollInjecting
    private let virtualDevice: VirtualHIDDevice
    private let logHandler: (String) -> Void
    private var armedConnections = Set<UUID>()
    /// Button bits currently held in the virtual device, so a mid-session
    /// device failure can release them instead of leaving a stuck drag.
    private var virtualButtonBits: UInt8 = 0
    /// Logged once per session, not per dropped scroll event.
    private var didWarnScrollWithoutAccessibility = false

    init(
        mouse: MouseInjecting = MouseInjector(),
        scroll: ScrollInjecting = ScrollInjector(),
        virtualDevice: VirtualHIDDevice = VirtualHIDDevice(),
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.mouse = mouse
        self.scroll = scroll
        self.virtualDevice = virtualDevice
        self.logHandler = log
    }

    var hasActiveSession: Bool { !armedConnections.isEmpty }

    /// True while pointer motion rides the virtual HID device. The begin
    /// response carries this to the phone, which then sends raw finger deltas
    /// instead of pre-accelerated ones — macOS applies its own curve.
    var usesVirtualDevice: Bool { virtualDevice.isAvailable }

    /// Arms a connection. Fails only when neither injection path is available:
    /// no virtual device and no Accessibility grant for posting events.
    func beginSession(connectionID: UUID) -> RemoteInputArmResult {
        let virtualReady = virtualDevice.activate()
        guard virtualReady || mouse.canPostEvents else {
            logHandler("realtime input refused reason=accessibilityPermissionRequired")
            return .accessibilityRequired
        }
        let inserted = armedConnections.insert(connectionID).inserted
        if inserted {
            logHandler("realtime input session began path=\(virtualReady ? "virtualHID" : "cgEvent")")
            didWarnScrollWithoutAccessibility = false
        }
        return .armed
    }

    func endSession(connectionID: UUID) {
        guard armedConnections.remove(connectionID) != nil else { return }
        releaseVirtualButtons()
        logHandler("realtime input session ended")
    }

    func connectionDidClose(connectionID: UUID) {
        endSession(connectionID: connectionID)
    }

    /// Applies one decoded batch. Motion that arrives without a session is
    /// discarded: an armed channel is what makes the trackpad a feature
    /// instead of a hole.
    func handle(_ batch: RemoteInputBatch, connectionID: UUID) {
        guard armedConnections.contains(connectionID) else { return }
        for event in batch.events {
            switch event {
            case let .move(dx, dy, buttons):
                moveCursor(dx: dx, dy: dy, buttons: buttons)
            case let .click(button, action):
                click(button: button, action: action)
            case let .scroll(dx, dy):
                handleScroll(dx: dx, dy: dy)
            }
        }
    }

    private func moveCursor(dx: Double, dy: Double, buttons: RemoteInputButtons) {
        if virtualDevice.isAvailable {
            let bits = buttonBits(buttons)
            virtualDevice.handle(dx: clamped(dx), dy: clamped(dy), buttons: bits)
            virtualButtonBits = bits
            recoverFromVirtualFailureIfNeeded()
        } else {
            mouse.moveCursor(dx: dx, dy: dy, buttons: buttons)
        }
    }

    private func click(button: RemoteInputButton, action: RemoteInputAction) {
        if virtualDevice.isAvailable {
            let mask: UInt8 = button == .left ? 0b001 : 0b010
            if action == .down {
                virtualButtonBits |= mask
            } else {
                virtualButtonBits &= ~mask
            }
            virtualDevice.handle(dx: 0, dy: 0, buttons: virtualButtonBits)
            recoverFromVirtualFailureIfNeeded()
        } else {
            mouse.click(button: button, action: action)
        }
    }

    private func handleScroll(dx: Double, dy: Double) {
        if mouse.canPostEvents {
            scroll.scroll(dx: dx, dy: dy)
        } else if !didWarnScrollWithoutAccessibility {
            // Smooth scrolling is the one event-posted path left; without the
            // grant the system ignores it. Say so once instead of silently
            // eating every scroll event.
            didWarnScrollWithoutAccessibility = true
            logHandler("scroll dropped reason=accessibilityPermissionRequired")
        }
    }

    /// A failed report means the device is gone; release any held button
    /// through the event path and drop to CGEvent injection.
    private func recoverFromVirtualFailureIfNeeded() {
        guard !virtualDevice.isAvailable else { return }
        logHandler("virtual HID device failed; falling back to CGEvent injection")
        if virtualButtonBits & 0b001 != 0 {
            mouse.click(button: .left, action: .up)
        }
        virtualButtonBits = 0
    }

    private func releaseVirtualButtons() {
        guard virtualDevice.isAvailable, virtualButtonBits != 0 else { return }
        virtualDevice.handle(dx: 0, dy: 0, buttons: 0)
        virtualButtonBits = 0
    }

    private func buttonBits(_ buttons: RemoteInputButtons) -> UInt8 {
        var bits: UInt8 = 0
        if buttons.contains(.left) { bits |= 0b001 }
        if buttons.contains(.right) { bits |= 0b010 }
        return bits
    }

    private func clamped(_ value: Double) -> Int16 {
        Int16(clamping: Int(value.rounded()))
    }
}
