import Foundation
import MacPilotRemoteProtocol
import Testing
@testable import MacPilot

/// Test doubles for the injection surfaces, so coordinator behavior is
/// verified without posting real HID events. Also used by the connection
/// watchdog tests, whose host needs a `RemoteInputCoordinator`.
@MainActor
final class FakeMouseInjector: MouseInjecting {
    struct Click: Equatable {
        let button: RemoteInputButton
        let action: RemoteInputAction
    }

    var canPostEvents: Bool
    private(set) var moves: [(dx: Double, dy: Double, buttons: RemoteInputButtons)] = []
    private(set) var clicks: [Click] = []

    init(canPostEvents: Bool = true) {
        self.canPostEvents = canPostEvents
    }

    func moveCursor(dx: Double, dy: Double, buttons: RemoteInputButtons) {
        moves.append((dx, dy, buttons))
    }

    func click(button: RemoteInputButton, action: RemoteInputAction) {
        clicks.append(Click(button: button, action: action))
    }
}

@MainActor
final class FakeScrollInjector: ScrollInjecting {
    private(set) var scrolls: [(dx: Double, dy: Double)] = []

    func scroll(dx: Double, dy: Double) {
        scrolls.append((dx, dy))
    }
}

@Suite("Remote input coordinator")
@MainActor
struct RemoteInputCoordinatorTests {
    private func makeCoordinator() -> (RemoteInputCoordinator, FakeMouseInjector, FakeScrollInjector) {
        let mouse = FakeMouseInjector()
        let scroll = FakeScrollInjector()
        var logs: [String] = []
        let coordinator = RemoteInputCoordinator(mouse: mouse, scroll: scroll, log: { logs.append($0) })
        return (coordinator, mouse, scroll)
    }

    private let connectionID = UUID()

    @Test("batches are dropped while unarmed")
    func unarmedDrops() {
        let (coordinator, mouse, _) = makeCoordinator()
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 10, dy: 0, buttons: [])]),
            connectionID: connectionID
        )
        #expect(mouse.moves.isEmpty)
    }

    @Test("armed sessions apply events in order")
    func armedAppliesInOrder() {
        let (coordinator, mouse, scroll) = makeCoordinator()
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        coordinator.handle(
            RemoteInputBatch(
                timestampMilliseconds: 1,
                events: [
                    .move(dx: 1, dy: 2, buttons: []),
                    .click(button: .left, action: .down),
                    .move(dx: 3, dy: 4, buttons: [.left]),
                    .scroll(dx: 5, dy: 6),
                    .click(button: .left, action: .up),
                ]
            ),
            connectionID: connectionID
        )
        #expect(mouse.moves.map { $0.dx } == [1, 3])
        #expect(mouse.moves.map { $0.buttons == RemoteInputButtons.left } == [false, true])
        #expect(mouse.clicks == [.init(button: .left, action: .down), .init(button: .left, action: .up)])
        #expect(scroll.scrolls.count == 1)
        #expect(scroll.scrolls[0].dy == 6)
    }

    @Test("ending the session stops injection")
    func endStops() {
        let (coordinator, mouse, _) = makeCoordinator()
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        #expect(coordinator.hasActiveSession)
        coordinator.endSession(connectionID: connectionID)
        #expect(!coordinator.hasActiveSession)
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 1, dy: 1, buttons: [])]),
            connectionID: connectionID
        )
        #expect(mouse.moves.isEmpty)
    }

    @Test("closing the connection disarms it")
    func closeDisarms() {
        let (coordinator, mouse, _) = makeCoordinator()
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        coordinator.connectionDidClose(connectionID: connectionID)
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 1, dy: 1, buttons: [])]),
            connectionID: connectionID
        )
        #expect(mouse.moves.isEmpty)
    }

    @Test("a second begin on the same connection is idempotent")
    func beginTwice() {
        let (coordinator, _, _) = makeCoordinator()
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        #expect(coordinator.hasActiveSession)
        coordinator.endSession(connectionID: connectionID)
        #expect(!coordinator.hasActiveSession)
    }

    @Test("arming is refused without Accessibility trust")
    func accessibilityGate() {
        let mouse = FakeMouseInjector(canPostEvents: false)
        let scroll = FakeScrollInjector()
        let coordinator = RemoteInputCoordinator(mouse: mouse, scroll: scroll, log: { _ in })
        #expect(coordinator.beginSession(connectionID: connectionID) == .accessibilityRequired)
        #expect(!coordinator.hasActiveSession)
    }

    @Test("an unknown connection's batches are dropped even while another is armed")
    func otherConnectionDrops() {
        let (coordinator, mouse, _) = makeCoordinator()
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 1, dy: 1, buttons: [])]),
            connectionID: UUID()
        )
        #expect(mouse.moves.isEmpty)
    }
}
