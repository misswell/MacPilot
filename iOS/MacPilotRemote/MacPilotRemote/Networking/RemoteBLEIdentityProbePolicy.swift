import Foundation

/// Bounds the foreground-only BLE proof used to learn a paired iPhone's
/// peripheral identity. It never determines whether the device is nearby; BLE
/// Unlock still applies its own signal policy on the Mac.
enum RemoteBLEIdentityProbePolicy {
    static let windowDuration: TimeInterval = 12

    static func shouldStart(
        isForeground: Bool,
        alreadyAttemptedThisForeground: Bool,
        hasAuthenticatedNetworkSession: Bool,
        serverSupportsLearning: Bool
    ) -> Bool {
        isForeground
            && !alreadyAttemptedThisForeground
            && hasAuthenticatedNetworkSession
            && serverSupportsLearning
    }

    static func shouldAcceptChannel(
        isForeground: Bool,
        isProbeWindowActive: Bool,
        hasAuthenticatedNetworkSession: Bool,
        serverSupportsLearning: Bool
    ) -> Bool {
        isForeground
            && isProbeWindowActive
            && hasAuthenticatedNetworkSession
            && serverSupportsLearning
    }
}
