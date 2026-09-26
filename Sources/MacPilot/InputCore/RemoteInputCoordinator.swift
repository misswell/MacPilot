import AppKit
import Foundation
import MacPilotRemoteProtocol

enum RemoteInputArmResult: Equatable {
    case armed
    case accessibilityRequired
}

/// The Mac side of the realtime input channel — the trackpad.
///
/// A session is armed explicitly by the `beginRealtimeInput` command (which is
/// also the Accessibility gate: synthesizing mouse events requires trust) and
/// disarmed by `endRealtimeInput`, the connection closing, or the feature
/// stopping. Batches arriving over an unarmed or unknown connection are
/// dropped, never injected.
///
/// Events are applied in arrival order on the main actor. CGEvent posting is
/// microseconds, so the 120 Hz drain loop that feeds this runs comfortably
/// inside the connection's serial frame budget.
@MainActor
final class RemoteInputCoordinator {
    private let mouse: MouseInjecting
    private let scroll: ScrollInjecting
    private let logHandler: (String) -> Void
    private var armedConnections = Set<UUID>()

    init(
        mouse: MouseInjecting = MouseInjector(),
        scroll: ScrollInjecting = ScrollInjector(),
        log: @escaping (String) -> Void = { remoteControlLog($0) }
    ) {
        self.mouse = mouse
        self.scroll = scroll
        self.logHandler = log
    }

    var hasActiveSession: Bool { !armedConnections.isEmpty }

    /// Arms a connection. Fails when mouse event synthesis is not permitted;
    /// the phone surfaces that as the Accessibility error it already knows.
    func beginSession(connectionID: UUID) -> RemoteInputArmResult {
        guard mouse.canPostEvents else {
            logHandler("realtime input refused reason=accessibilityPermissionRequired")
            return .accessibilityRequired
        }
        let inserted = armedConnections.insert(connectionID).inserted
        if inserted {
            logHandler("realtime input session began")
        }
        return .armed
    }

    func endSession(connectionID: UUID) {
        guard armedConnections.remove(connectionID) != nil else { return }
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
                mouse.moveCursor(dx: dx, dy: dy, buttons: buttons)
            case let .click(button, action):
                mouse.click(button: button, action: action)
            case let .scroll(dx, dy):
                scroll.scroll(dx: dx, dy: dy)
            }
        }
    }
}
