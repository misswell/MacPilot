import Foundation
import ServiceManagement
import Testing
@testable import MacPilot

/// The login item is a system-side registration tied to the signed bundle, so an
/// update that replaces or re-signs the app can drop it while the user's wish to
/// start at login stays true. These cases pin the decision that turns that pair
/// into an action, because getting it wrong means the app silently stops
/// launching after an update.
struct LoginItemPolicyTests {
    @Test func nothingHappensWhenTheUserDidNotAskForIt() {
        #expect(LoginItemPolicy.recovery(wanted: false, status: .notRegistered) == .none)
        #expect(LoginItemPolicy.recovery(wanted: false, status: .enabled) == .none)
        #expect(LoginItemPolicy.recovery(wanted: false, status: .requiresApproval) == .none)
    }

    @Test func anAlreadyRegisteredLoginItemIsLeftAlone() {
        #expect(LoginItemPolicy.recovery(wanted: true, status: .enabled) == .none)
    }

    /// The case this fix exists for: the registration disappeared with an app
    /// replacement, but the persisted intent says the user still wants it.
    @Test func aDroppedRegistrationIsRestoredFromThePersistedIntent() {
        #expect(LoginItemPolicy.recovery(wanted: true, status: .notRegistered) == .register)
        #expect(LoginItemPolicy.recovery(wanted: true, status: .notFound) == .register)
    }

    /// macOS kept the registration and only the user can allow it, so hammering
    /// `register()` would change nothing — we just say so in the UI.
    @Test func pendingApprovalIsReportedInsteadOfRetried() {
        #expect(LoginItemPolicy.recovery(wanted: true, status: .requiresApproval) == .needsApproval)
    }
}

/// The intent has to survive a round trip, because it is the only record of the
/// user's wish once the system-side registration is gone.
struct LoginItemPersistenceTests {
    @Test func theIntentIsPersistedAndReadBack() throws {
        let decoded = try JSONDecoder().decode(
            MacPilotModel.StoredConfiguration.self,
            from: Data(#"{"launchesAtLogin":true}"#.utf8)
        )
        #expect(decoded.launchesAtLogin)
        #expect(decoded.launchesAtLoginWasStored)

        let reencoded = try JSONEncoder().encode(decoded)
        let readBack = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: reencoded)
        #expect(readBack.launchesAtLogin)
        #expect(readBack.launchesAtLoginWasStored)
    }

    /// A configuration written before the key existed must be recognizable, so
    /// that `apply(_:)` can adopt the current system status instead of silently
    /// treating a working login item as "never opted in".
    @Test func aConfigurationWithoutTheKeyIsReportedAsUnstored() throws {
        let decoded = try JSONDecoder().decode(
            MacPilotModel.StoredConfiguration.self,
            from: Data("{}".utf8)
        )
        #expect(!decoded.launchesAtLogin)
        #expect(!decoded.launchesAtLoginWasStored)
    }

    @Test func theMigrationFlagItselfIsNeverWrittenBack() throws {
        let decoded = try JSONDecoder().decode(
            MacPilotModel.StoredConfiguration.self,
            from: Data(#"{"launchesAtLogin":true}"#.utf8)
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(json["launchesAtLoginWasStored"] == nil)
        #expect(json["launchesAtLogin"] as? Bool == true)
    }
}
