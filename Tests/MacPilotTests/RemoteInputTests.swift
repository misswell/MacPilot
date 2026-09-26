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
    private func makeCoordinator(
        canPostEvents: Bool = true,
        virtualDevice: VirtualHIDDevice = VirtualHIDDevice(creationOverride: false)
    ) -> (RemoteInputCoordinator, FakeMouseInjector, FakeScrollInjector) {
        let mouse = FakeMouseInjector(canPostEvents: canPostEvents)
        let scroll = FakeScrollInjector()
        var logs: [String] = []
        let coordinator = RemoteInputCoordinator(mouse: mouse, scroll: scroll, virtualDevice: virtualDevice, log: { logs.append($0) })
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

    @Test("arming is refused without Accessibility trust when no virtual device exists")
    func accessibilityGate() {
        let (coordinator, mouse, _) = makeCoordinator(canPostEvents: false)
        #expect(coordinator.beginSession(connectionID: connectionID) == .accessibilityRequired)
        #expect(!coordinator.hasActiveSession)
        #expect(mouse.clicks.isEmpty)
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

@Suite("Remote input coordinator over virtual HID")
@MainActor
struct RemoteInputVirtualHIDTests {
    private let connectionID = UUID()

    @Test("the virtual device arms a session without Accessibility")
    func armsWithoutAccessibility() {
        let device = VirtualHIDDevice(creationOverride: true)
        let (coordinator, mouse, _) = makeCoordinator(virtualDevice: device, canPostEvents: false)
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        #expect(coordinator.usesVirtualDevice)
        #expect(mouse.clicks.isEmpty)
    }

    @Test("motion and clicks ride the virtual device as reports")
    func reportsOverVirtualDevice() {
        let device = VirtualHIDDevice(creationOverride: true)
        let (coordinator, mouse, _) = makeCoordinator(virtualDevice: device)
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        coordinator.handle(
            RemoteInputBatch(
                timestampMilliseconds: 1,
                events: [
                    .move(dx: 12, dy: -3, buttons: []),
                    .click(button: .left, action: .down),
                    .move(dx: 4, dy: 5, buttons: [.left]),
                    .click(button: .left, action: .up),
                ]
            ),
            connectionID: connectionID
        )
        #expect(mouse.moves.isEmpty && mouse.clicks.isEmpty)
        // The batch ends with the release, so the final report carries no buttons.
        #expect(device.lastReport == VirtualHIDReportBuilder.report(dx: 0, dy: 0, buttons: 0))
    }

    @Test("a report failure releases the held button through the fallback")
    func failureReleasesButton() {
        let device = VirtualHIDDevice(creationOverride: true)
        let (coordinator, mouse, _) = makeCoordinator(virtualDevice: device)
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        device.failReports = true
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.click(button: .left, action: .down)]),
            connectionID: connectionID
        )
        #expect(!device.isAvailable)
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 2, events: [.move(dx: 1, dy: 1, buttons: [])]),
            connectionID: connectionID
        )
        // The stuck press is released through CGEvent, then motion falls back.
        #expect(mouse.clicks.map(\.action) == [.up])
        #expect(mouse.moves.count == 1)
    }

    @Test("ending the session releases held virtual buttons")
    func endReleasesButtons() {
        let device = VirtualHIDDevice(creationOverride: true)
        let (coordinator, _, _) = makeCoordinator(virtualDevice: device)
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.click(button: .left, action: .down)]),
            connectionID: connectionID
        )
        coordinator.endSession(connectionID: connectionID)
        #expect(device.lastReport == VirtualHIDReportBuilder.report(dx: 0, dy: 0, buttons: 0))
    }

    @Test("deltas clamp to the 16-bit report range")
    func deltaClamping() {
        let device = VirtualHIDDevice(creationOverride: true)
        let (coordinator, _, _) = makeCoordinator(virtualDevice: device)
        #expect(coordinator.beginSession(connectionID: connectionID) == .armed)
        coordinator.handle(
            RemoteInputBatch(timestampMilliseconds: 1, events: [.move(dx: 99_999, dy: -99_999, buttons: [])]),
            connectionID: connectionID
        )
        #expect(device.lastReport == VirtualHIDReportBuilder.report(dx: Int16.max, dy: Int16.min, buttons: 0))
    }

    private func makeCoordinator(
        virtualDevice: VirtualHIDDevice,
        canPostEvents: Bool = true
    ) -> (RemoteInputCoordinator, FakeMouseInjector, FakeScrollInjector) {
        let mouse = FakeMouseInjector(canPostEvents: canPostEvents)
        let scroll = FakeScrollInjector()
        let coordinator = RemoteInputCoordinator(mouse: mouse, scroll: scroll, virtualDevice: virtualDevice, log: { _ in })
        return (coordinator, mouse, scroll)
    }
}
