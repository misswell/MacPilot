import Foundation

/// One explainable problem shared by the Home page and menu-bar warning icon.
/// Awake failures remain visible even after the feature is disabled.
enum HomeAttentionIssue: Equatable, Identifiable, Sendable {
    case assertion(AwakeAssertionFailure)
    case closedLid(ClosedLidSleepFailure)
    case windowSwitcherSecureInput

    var id: String {
        switch self {
        case .windowSwitcherSecureInput:
            "windowSwitcher.secureInput"
        case .assertion(let failure):
            "assertion.\(failure.kind.rawValue)"
        case .closedLid(let failure):
            "closedLid.\(failure.stage.rawValue).\(failure.kind.rawValue)"
        }
    }

    /// The failures the menu bar collapses into one warning icon.
    static func active(
        assertionFailure: AwakeAssertionFailure?,
        closedLidFailure: ClosedLidSleepFailure?,
        windowSwitcherEnabled: Bool = false,
        secureInputActive: Bool = false
    ) -> [HomeAttentionIssue] {
        var issues: [HomeAttentionIssue] = []
        if let assertionFailure { issues.append(.assertion(assertionFailure)) }
        if let closedLidFailure { issues.append(.closedLid(closedLidFailure)) }
        if windowSwitcherEnabled && secureInputActive { issues.append(.windowSwitcherSecureInput) }
        return issues
    }

    /// The headline of the Home page row.
    var titleKey: String {
        switch self {
        case .windowSwitcherSecureInput:
            "windowSwitcherSecureInputTitle"
        case .assertion(let failure):
            failure.kind == .systemSleep ? "awakeIssueSystemSleepTitle" : "awakeIssueDisplaySleepTitle"
        case .closedLid(let failure):
            failure.stage == .retirement ? "awakeIssueRetirementTitle" : "awakeIssueClosedLidTitle"
        }
    }

    /// What the failure means for the user, in their language.
    var detailKey: String {
        switch self {
        case .windowSwitcherSecureInput:
            return "windowSwitcherSecureInputHint"
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
        case .windowSwitcherSecureInput:
            []
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

@MainActor
extension MacPilotModel {
    var homeAttentionIssues: [HomeAttentionIssue] {
        HomeAttentionIssue.active(
            assertionFailure: awake.lastAssertionFailure,
            closedLidFailure: awake.lastClosedLidFailure,
            windowSwitcherEnabled: isFeatureEnabled(.windowSwitcher) && windowSwitcher.settings.isEnabled,
            secureInputActive: windowSwitcher.isSecureInputActive
        )
    }
}
