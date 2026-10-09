import Foundation

/// The four non-text navigation keys exposed on the phone's home page.
/// Their command payload is exactly one byte; unknown values and oversized
/// payloads are rejected rather than interpreted as arbitrary key codes.
public enum RemoteNavigationKey: UInt8, Codable, Sendable, CaseIterable, Equatable {
    case pageUp = 1
    case pageDown = 2
    case home = 3
    case end = 4

    public func encoded() -> Data { Data([rawValue]) }

    public static func decoded(from payload: Data?) -> Self? {
        guard let payload, payload.count == 1 else { return nil }
        return Self(rawValue: payload[payload.startIndex])
    }
}
