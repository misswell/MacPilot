import Foundation

/// Spaces repeated L2CAP-open failures so a broken or unavailable channel does
/// not drive the central into a tight discover/read/open loop.
struct RemoteBLEChannelOpenRetryPolicy {
    private(set) var failureCount = 0

    private let baseDelay: TimeInterval
    private let maximumDelay: TimeInterval

    init(baseDelay: TimeInterval = 2, maximumDelay: TimeInterval = 30) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
    }

    mutating func recordOpenFailure() -> TimeInterval {
        failureCount += 1
        let exponent = min(failureCount - 1, 8)
        return min(baseDelay * pow(2.0, Double(exponent)), maximumDelay)
    }

    mutating func recordOpenSuccess() {
        failureCount = 0
    }
}
