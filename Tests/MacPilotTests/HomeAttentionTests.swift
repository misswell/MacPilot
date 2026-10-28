import Foundation
import Testing
@testable import MacPilot

/// The Home page's "needs attention" card and the menu-bar warning icon must
/// describe the same failures: the icon may never point at a problem the app
/// cannot name somewhere.
@MainActor
struct HomeAttentionTests {
    private static let allIssues: [HomeAttentionIssue] = {
        var issues: [HomeAttentionIssue] = [
            .assertion(AwakeAssertionFailure(kind: .systemSleep, operation: "create", code: "kIOReturnError")),
            .assertion(AwakeAssertionFailure(kind: .displaySleep, operation: "create", code: "kIOReturnError"))
        ]
        let kinds: [ClosedLidSleepFailure.Kind] = [
            .helperUnavailable, .notRegistered, .requiresApproval, .registrationFailed, .requestFailed
        ]
        for kind in kinds {
            let failure = ClosedLidSleepFailure(kind: kind, message: "diagnostic")
            issues.append(.closedLid(failure))
            issues.append(.closedLid(failure.duringRetirement()))
        }
        return issues
    }()

    @Test func noFailureMeansNoRowAndNoWarningIcon() {
        let issues = HomeAttentionIssue.active(assertionFailure: nil, closedLidFailure: nil)
        #expect(issues.isEmpty)
        #expect(MenuBarIcon.systemImage(awakeActive: false, enforcing: false,
            awakeFailed: !issues.isEmpty) == "pause.circle")
    }

    @Test func eachFailureAddsExactlyOneRowAndTheWarningIcon() {
        for issue in Self.allIssues {
            let issues = HomeAttentionIssue.active(
                assertionFailure: assertionFailure(of: issue),
                closedLidFailure: closedLidFailure(of: issue)
            )
            #expect(issues == [issue])
            #expect(MenuBarIcon.systemImage(awakeActive: false, enforcing: false,
                awakeFailed: !issues.isEmpty) == "exclamationmark.triangle")
        }
        let both = HomeAttentionIssue.active(
            assertionFailure: .init(kind: .systemSleep, operation: "create", code: "code"),
            closedLidFailure: .requestFailed("diagnostic")
        )
        #expect(both.count == 2)
    }

    @Test func systemAndDisplayAssertionFailuresGetTheirOwnRows() {
        let system = HomeAttentionIssue.assertion(
            AwakeAssertionFailure(kind: .systemSleep, operation: "create", code: "kIOReturnError")
        )
        let display = HomeAttentionIssue.assertion(
            AwakeAssertionFailure(kind: .displaySleep, operation: "create", code: "kIOReturnError")
        )
        #expect(system.titleKey != display.titleKey)
        #expect(system.detailKey != display.detailKey)
    }

    /// A failed release is not lost sleep protection; labelling it as such was
    /// the reason a warning icon appeared for a problem no page described.
    @Test func aRetirementFailureIsNotDescribedAsLostProtection() {
        for kind in [ClosedLidSleepFailure.Kind.registrationFailed, .requestFailed] {
            let protection = HomeAttentionIssue.closedLid(ClosedLidSleepFailure(kind: kind, message: "diagnostic"))
            let retirement = HomeAttentionIssue.closedLid(
                ClosedLidSleepFailure(kind: kind, message: "diagnostic").duringRetirement()
            )
            #expect(protection.titleKey != retirement.titleKey)
            #expect(protection.detailKey != retirement.detailKey)
            #expect(protection.id != retirement.id)
        }
        #expect(ClosedLidSleepFailure.requestFailed("x").duringRetirement().stage == .retirement)
        #expect(ClosedLidSleepFailure.requestFailed("x").stage == .protection)
    }

    @Test func closedLidDiagnosticsStayAvailableForTheTooltip() {
        let retirement = HomeAttentionIssue.closedLid(
            ClosedLidSleepFailure.registrationFailed("The old power service did not unload.").duringRetirement()
        )
        #expect(retirement.diagnosticMessage == "The old power service did not unload.")
        #expect(HomeAttentionIssue.assertion(
            AwakeAssertionFailure(kind: .systemSleep, operation: "create", code: "code")
        ).diagnosticMessage == nil)
    }

    @Test func everyRowResolvesInBothLanguages() {
        for issue in Self.allIssues {
            let chineseTitle = AppText.value(issue.titleKey, language: .simplifiedChinese)
            let englishTitle = AppText.value(issue.titleKey, language: .english)
            #expect(chineseTitle != issue.titleKey, "\(issue.titleKey) 缺少中文文案")
            #expect(englishTitle != issue.titleKey, "\(issue.titleKey) is missing English copy")
            #expect(chineseTitle != englishTitle)

            let chineseDetail = AppText.value(issue.detailKey, language: .simplifiedChinese,
                                              arguments: issue.detailArguments)
            let englishDetail = AppText.value(issue.detailKey, language: .english,
                                              arguments: issue.detailArguments)
            #expect(chineseDetail != issue.detailKey, "\(issue.detailKey) 缺少中文文案")
            #expect(englishDetail != issue.detailKey, "\(issue.detailKey) is missing English copy")
            #expect(chineseDetail != englishDetail)
        }
    }

    private func assertionFailure(of issue: HomeAttentionIssue) -> AwakeAssertionFailure? {
        guard case .assertion(let failure) = issue else { return nil }
        return failure
    }

    private func closedLidFailure(of issue: HomeAttentionIssue) -> ClosedLidSleepFailure? {
        guard case .closedLid(let failure) = issue else { return nil }
        return failure
    }
}
