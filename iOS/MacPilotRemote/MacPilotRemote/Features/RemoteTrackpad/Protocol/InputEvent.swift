import Foundation
import MacPilotRemoteProtocol

/// A pointer action ready to leave the trackpad module.
///
/// The engine and the motion pipeline speak this type; `InputEncoder` is the
/// only place it meets the wire format, which is what keeps the trackpad
/// ignorant of both the transport and the packet layout.
enum InputEvent: Equatable {
    case move(dx: Double, dy: Double, dragging: Bool)
    case click(button: RemoteInputButton, action: RemoteInputAction)
    case scroll(dx: Double, dy: Double)
}

/// Turns engine output into the binary batch the connection layer sends.
enum InputEncoder {
    static func encode(_ events: [InputEvent]) -> RemoteInputBatch {
        RemoteInputBatch(
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            events: events.map { event in
                switch event {
                case let .move(dx, dy, dragging):
                    var buttons: RemoteInputButtons = []
                    if dragging { buttons.insert(.left) }
                    return .move(dx: dx, dy: dy, buttons: buttons)
                case let .click(button, action):
                    return .click(button: button, action: action)
                case let .scroll(dx, dy):
                    return .scroll(dx: dx, dy: dy)
                }
            }
        )
    }
}
