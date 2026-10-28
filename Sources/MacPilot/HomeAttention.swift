import Foundation

/// One explainable problem behind the menu-bar warning icon.
///
/// `MenuBarIcon` draws a warning triangle whenever Awake reports a failed power
/// assertion or a failed closed-lid service. Those failures used to be named
/// only on the Awake page — which is unreachable while the feature is switched
/// off, and says nothing at all about a service that failed to retire. The Home
/// page renders these entries, built from the same two values as the icon, so a
/// visible warning always has an explanation somewhere in the app.
enum HomeAttentionIssue: Equatable, Identifiable, Sendable {
    case assertion(AwakeAssertionFailure)
    case closedLid(ClosedLidSleepFailure)

    var id: String {
        switch self {
        case .assertion(let failure):
            "assertion.\(failure.kind.rawValue)"
        case .closedLid(let failure):
            "closedLid.\(failure.stage.rawValue).\(failure.kind.rawValue)"
        }
    }

    /// The failures the menu bar collapses into one warning icon.
    static func active(
        assertionFailure: AwakeAssertionFailure?,
        closedLidFailure: ClosedLidSleepFailure?
    ) -> [HomeAttentionIssue] {
        var issues: [HomeAttentionIssue] = []
        if let assertionFailure { issues.append(.assertion(assertionFailure)) }
        if let closedLidFailure { issues.append(.closedLid(closedLidFailure)) }
        return issues
    }

    /// The headline of the Home page row.
    var titleKey: String {
        switch self {
        case .assertion(let failure):
            failure.kind == .systemSleep ? "awakeIssueSystemSleepTitle" : "awakeIssueDisplaySleepTitle"
        case .closedLid(let failure):
            failure.stage == .retirement ? "awakeIssueRetirementTitle" : "awakeIssueClosedLidTitle"
        }
    }

    /// What the failure means for the user, in their language.
    var detailKey: String {
        switch self {
        case .assertion(let failure):
            return failure.kind == .systemSleep ? "awakeIssueSystemSleepDetail" : "awakeIssueDisplaySleepDetail"
        case .closedLid(let failure):
            switch failure.stage {
            case .retirement:
                return "awakeIssueRetirementDetail"
            case .protection:
                switch failure.kind {
                case .helperUnavailable: return "awakeClosedLidServiceUnavailable"
                case .notRegistered: return "awakeClosedLidServiceRequired"
                case .requiresApproval: return "awakeClosedLidServiceRequiresApproval"
                case .registrationFailed: return "awakeIssueClosedLidRegistrationDetail"
                case .requestFailed: return "awakeClosedLidServiceNotApplied"
                }
            }
        }
    }

    /// Values interpolated into `detailKey`; empty when it takes none.
    var detailArguments: [CVarArg] {
        switch self {
        case .assertion(let failure):
            [failure.code]
        case .closedLid(let failure):
            failure.stage == .retirement || failure.kind == .registrationFailed
                ? [failure.message] : []
        }
    }

    /// The untranslated diagnostic behind a closed-lid failure, for a tooltip.
    var diagnosticMessage: String? {
        guard case .closedLid(let failure) = self else { return nil }
        return failure.message
    }
}

extension AwakeSessionManager {
    /// The failures the menu-bar icon summarises and the Home page explains.
    ///
    /// Both surfaces read this one list, so the icon can never show a warning
    /// the app has no words for.
    var attentionIssues: [HomeAttentionIssue] {
        HomeAttentionIssue.active(
            assertionFailure: lastAssertionFailure,
            closedLidFailure: lastClosedLidFailure
        )
    }

    var hasAttentionIssue: Bool { !attentionIssues.isEmpty }
}
