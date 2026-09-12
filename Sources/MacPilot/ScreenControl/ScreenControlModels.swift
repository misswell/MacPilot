import Foundation
import MacPilotRemoteProtocol

/// Who asked for a screen control action. The distinction matters because a
/// remote lock must suppress the BLE proximity auto-unlock while a remote
/// explicit unlock must still be allowed to run.
enum ScreenControlSource: String, Codable, Equatable, Sendable {
    case localManual
    case bleAutomatic
    case remoteExplicit

    /// Screen lock history label recorded for this source.
    var historySource: ScreenLockHistorySource {
        switch self {
        case .localManual: return .manual
        case .bleAutomatic: return .automatic
        case .remoteExplicit: return .remote
        }
    }
}

/// Machine readable failure reason for a screen control action. The remote
/// server maps these onto the wire level `RemoteErrorCode`; nothing else leaks.
enum ScreenControlFailure: String, Equatable, Sendable {
    case accessibilityPermissionRequired
    case credentialNotConfigured

    case alreadyLocked
    case alreadyUnlocked

    case lockFailed
    case displaySleepFailed
    case wakeFailed
    case unlockFailed
    case commandTimeout
    case internalError

    /// No display on this Mac has a backlight that can be driven, so there is
    /// no brightness to show or set.
    case brightnessUnavailable
    /// No output device exposes a volume control.
    case volumeUnavailable

    var remoteErrorCode: RemoteErrorCode {
        switch self {
        case .accessibilityPermissionRequired: return .accessibilityPermissionRequired
        case .credentialNotConfigured: return .credentialNotConfigured
        case .alreadyLocked: return .alreadyLocked
        case .alreadyUnlocked: return .alreadyUnlocked
        case .lockFailed: return .lockFailed
        case .displaySleepFailed: return .displaySleepFailed
        case .wakeFailed: return .wakeFailed
        case .unlockFailed: return .unlockFailed
        case .commandTimeout: return .commandTimeout
        case .internalError: return .internalError
        case .brightnessUnavailable: return .brightnessUnavailable
        case .volumeUnavailable: return .volumeUnavailable
        }
    }
}

/// Decides how a screen control action interacts with the BLE proximity
/// auto-unlock, which is the acceptance critical part of the remote feature:
/// a remote lock must not be undone by the phone still sitting next to the Mac,
/// while a remote explicit unlock must always be allowed through.
enum ScreenControlSuppressionPolicy {
    /// Locks requested by the user or by the iPhone suppress automatic unlock.
    /// A lock the BLE proximity logic triggered itself must not.
    static func suppressesAutomaticUnlock(source: ScreenControlSource) -> Bool {
        source != .bleAutomatic
    }

    /// Only an explicit unlock clears the suppression again.
    static func clearsAutomaticUnlockSuppression(source: ScreenControlSource) -> Bool {
        switch source {
        case .remoteExplicit, .localManual: return true
        case .bleAutomatic: return false
        }
    }
}

/// Result of one screen control action. `state` always reflects the machine as
/// observed after the action, so the caller never has to guess.
struct ScreenControlResult: Equatable, Sendable {
    let success: Bool
    let failure: ScreenControlFailure?
    let state: MacRemoteState

    static func success(_ state: MacRemoteState) -> ScreenControlResult {
        ScreenControlResult(success: true, failure: nil, state: state)
    }

    static func failure(_ failure: ScreenControlFailure, state: MacRemoteState) -> ScreenControlResult {
        ScreenControlResult(success: false, failure: failure, state: state)
    }
}
