import Foundation
import ServiceManagement

/// Why the login item needs attention, if it does.
///
/// The app remembers what the user asked for, but the registration itself lives
/// in the system and is tied to the signed bundle: replacing the app during an
/// update, or re-signing it in place, can drop it. MacPilot used to notice this
/// only as "the toggle turned itself off", which is how a working login item
/// silently becomes "the app never starts after an update".
enum LoginItemRecovery: Equatable {
    /// Nothing to do: either the user does not want it, or it is registered.
    case none
    /// The user asked for it but the registration is gone; register again.
    case register
    /// macOS kept the registration and is waiting for the user to allow it in
    /// System Settings. Registering again would not change that.
    case needsApproval
}

enum LoginItemPolicy {
    /// Decides what to do at launch about a previously requested login item.
    ///
    /// - Parameters:
    ///   - wanted: the persisted user intent.
    ///   - status: the live `SMAppService.mainApp.status`.
    static func recovery(wanted: Bool, status: SMAppService.Status) -> LoginItemRecovery {
        guard wanted else { return .none }
        switch status {
        case .enabled:
            return .none
        case .requiresApproval:
            // The registration survived; only the user can finish it.
            return .needsApproval
        case .notRegistered, .notFound:
            return .register
        @unknown default:
            // An unrecognized status is not a reason to hammer `register()`.
            return .none
        }
    }
}
