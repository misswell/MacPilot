import AppKit
import Foundation
import Testing
@testable import MacPilot

/// The identifiers below are the ones macOS actually exposes here: the WeChat
/// input method publishes exactly one selectable source whose mode id equals its
/// source id, so its 中/英 state never reaches TIS.
private let wechatIdentifier = "com.tencent.inputmethod.wetype.pinyin::com.tencent.inputmethod.wetype.pinyin"
private let abcIdentifier = "com.apple.keylayout.ABC"
private let shuangpinIdentifier = "com.apple.inputmethod.SCIM.Shuangpin"

/// Scripted stand-in for `MacPilotInputSourceCatalog`. It never talks to TIS, so
/// these tests cannot read or change the user's real input source.
private final class InputSourceCatalogMock: @unchecked Sendable {
    let identifiers: [String]
    var liveIdentifier: String?
    private(set) var selectCalls = 0
    private(set) var selectedIdentifiers: [String] = []
    /// Selections that report success but that the system does not apply —
    /// macOS' per-context input-source memory restoring the previous source.
    var ignoredSelects = 0
    var refusesSelection = false
    var afterSelect: (() -> Void)?

    init(identifiers: [String], live: String?) {
        self.identifiers = identifiers
        self.liveIdentifier = live
    }

    var seams: MacPilotInputSourceCatalogSeams {
        MacPilotInputSourceCatalogSeams(
            list: { self.identifiers.map(Self.source) },
            current: { self.liveIdentifier.map(Self.source) },
            select: { identifier in
                self.selectCalls += 1
                defer { self.afterSelect?() }
                guard !self.refusesSelection else { return false }
                self.selectedIdentifiers.append(identifier)
                if self.ignoredSelects > 0 {
                    self.ignoredSelects -= 1
                    return true
                }
                self.liveIdentifier = identifier
                return true
            }
        )
    }

    static func source(_ identifier: String) -> MacPilotInputSource {
        let parts = identifier.components(separatedBy: "::")
        return MacPilotInputSource(
            sourceID: parts.first ?? identifier,
            inputModeID: parts.count > 1 ? parts[1] : nil,
            name: identifier,
            isCJKV: identifier.contains("wetype") || identifier.contains("SCIM")
        )
    }
}

private final class EvidenceClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
struct InputSourceSwitchTests {
    private func switcher(
        for mock: InputSourceCatalogMock,
        policy: InputSourceSwitchPolicy = .standard
    ) -> InputSourceSwitcher {
        InputSourceSwitcher(seams: mock.seams, policy: policy, sleep: { _ in }, uptime: { 0 })
    }

    @Test func verifiedSelectionIsConfirmedOnlyAfterTheSettlePass() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        let report = await switcher(for: mock).run(
            InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic)
        )

        #expect(report.outcome == .verified)
        #expect(report.attempts == 1)
        #expect(report.initialIdentifier == abcIdentifier)
        #expect(report.finalIdentifier == wechatIdentifier)
        #expect(report.isConfirmed)
        #expect(mock.selectCalls == 1)
        #expect(mock.liveIdentifier == wechatIdentifier)
    }

    /// The bug from issue 2: the select returned `noErr` but macOS re-applied the
    /// per-context source right afterwards. The chain must notice the live
    /// catalog disagrees and re-apply instead of recording a success.
    @Test func selectionLostToThePerContextRestoreIsReapplied() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        mock.ignoredSelects = 1

        let report = await switcher(for: mock).run(
            InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic)
        )

        #expect(report.outcome == .verified)
        #expect(report.attempts == 2)
        #expect(report.finalIdentifier == wechatIdentifier)
        #expect(mock.selectCalls == 2)
        #expect(mock.liveIdentifier == wechatIdentifier)
    }

    @Test func exhaustedBudgetLeavesTheSystemSourceSelected() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        mock.ignoredSelects = 99

        let report = await switcher(for: mock).run(
            InputSourceSwitchRequest(
                desiredIdentifier: wechatIdentifier,
                origin: .automatic,
                applicationBundleIdentifier: "com.apple.Terminal"
            )
        )

        #expect(report.outcome == .exhausted)
        #expect(report.attempts == InputSourceSwitchPolicy.standard.maximumAttempts)
        #expect(report.finalIdentifier == abcIdentifier)
        #expect(!report.isConfirmed)
        #expect(mock.liveIdentifier == abcIdentifier)
        #expect(mock.selectCalls == InputSourceSwitchPolicy.standard.maximumAttempts)
    }

    @Test func manualSourceChangeBetweenAttemptsStopsTheChain() async {
        let mock = InputSourceCatalogMock(
            identifiers: [abcIdentifier, wechatIdentifier, shuangpinIdentifier],
            live: abcIdentifier
        )
        mock.ignoredSelects = 1
        mock.afterSelect = { mock.liveIdentifier = shuangpinIdentifier }

        let report = await switcher(for: mock).run(
            InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic)
        )

        #expect(report.outcome == .interruptedByUser)
        #expect(report.attempts == 1)
        #expect(report.finalIdentifier == shuangpinIdentifier)
        #expect(mock.selectCalls == 1)
        #expect(mock.liveIdentifier == shuangpinIdentifier)
    }

    @Test func targetAlreadyCurrentMakesNoSelectionCall() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: wechatIdentifier)

        let report = await switcher(for: mock).run(
            InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic)
        )

        #expect(report.outcome == .alreadyCurrent)
        #expect(report.attempts == 0)
        #expect(report.finalIdentifier == wechatIdentifier)
        #expect(mock.selectCalls == 0)
    }

    @Test func refusedSelectionReportsUnavailableWithoutTouchingTheSource() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        mock.refusesSelection = true

        let report = await switcher(for: mock).run(
            InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .manual)
        )

        #expect(report.outcome == .unavailable)
        #expect(report.attempts == 0)
        #expect(report.finalIdentifier == abcIdentifier)
        #expect(!report.isConfirmed)
        #expect(mock.liveIdentifier == abcIdentifier)
    }

    @Test func standardPolicyKeepsTheRetriesBounded() {
        let policy = InputSourceSwitchPolicy.standard

        #expect(policy.retryDelays == [
            .zero, .milliseconds(80), .milliseconds(200), .milliseconds(400)
        ])
        #expect(policy.confirmationDelay == .milliseconds(400))
        #expect(policy.maximumAttempts == 4)
    }

    @Test func olderChainStopsWhenANewerActivationArrives() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        let scheduler = InputSourceSwitchScheduler(
            seams: { mock.seams },
            sleep: { _ in },
            uptime: { 0 }
        )
        var reports: [InputSourceSwitchReport] = []
        scheduler.onReport = { reports.append($0) }

        let first = scheduler.begin(InputSourceSwitchRequest(desiredIdentifier: abcIdentifier, origin: .automatic))
        let second = scheduler.begin(InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic))

        let firstReport = await first.value
        let secondReport = await second.value

        #expect(firstReport.outcome == .superseded)
        #expect(firstReport.attempts == 0)
        #expect(secondReport.outcome == .verified)
        #expect(secondReport.request.desiredIdentifier == wechatIdentifier)
        #expect(reports.map(\.request.desiredIdentifier) == [wechatIdentifier])
        #expect(mock.liveIdentifier == wechatIdentifier)
    }

    @Test func activationAlreadyOnDesiredSourceCancelsOlderUnconfirmedChain() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        let model = InputSourceModel(catalogSeams: mock.seams)
        let older = model.applyInputSourceSelection(
            wechatIdentifier,
            origin: .automatic,
            applicationBundleIdentifier: "app.A"
        )

        // The old chain has selected WeChat and is waiting for verification.
        for _ in 0..<100 where mock.selectCalls == 0 { await Task.yield() }
        #expect(mock.selectCalls == 1)

        // macOS restores ABC as app B becomes active. B needs no selection,
        // so its activation starts no new selection chain but must still
        // invalidate A's pending confirmation.
        mock.liveIdentifier = abcIdentifier
        model.handleApplicationNotification(NSRunningApplication.current)
        let report = await older.value

        #expect(report.outcome == .superseded)
        #expect(report.attempts == 1)
        #expect(mock.selectCalls == 1)
        #expect(mock.liveIdentifier == abcIdentifier)
    }

    @Test func cancelledSchedulerDropsThePendingChain() async {
        let mock = InputSourceCatalogMock(identifiers: [abcIdentifier, wechatIdentifier], live: abcIdentifier)
        let scheduler = InputSourceSwitchScheduler(
            seams: { mock.seams },
            sleep: { _ in },
            uptime: { 0 }
        )
        var reports: [InputSourceSwitchReport] = []
        scheduler.onReport = { reports.append($0) }

        let pending = scheduler.begin(InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic))
        scheduler.cancel()

        let outcome = await pending.value.outcome
        #expect(outcome == .superseded)
        #expect(reports.isEmpty)
        #expect(mock.selectCalls == 0)
        #expect(mock.liveIdentifier == abcIdentifier)
    }
}

@MainActor
struct InputSourceSwitchEvidenceTests {
    @Test func evidenceLineNamesDesiredAndLiveIdentifiers() {
        let report = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(
                desiredIdentifier: wechatIdentifier,
                origin: .automatic,
                applicationBundleIdentifier: "com.apple.Terminal"
            ),
            outcome: .exhausted,
            initialIdentifier: abcIdentifier,
            finalIdentifier: abcIdentifier,
            attempts: 4,
            elapsedMilliseconds: 1_080
        )

        let line = InputSourceSwitchEvidence.line(for: report)
        // Written by DiagnosticLog as "[<timestamp>] [InputSource] <this line>".
        #expect(line == "switch origin=automatic app=com.apple.Terminal"
            + " desired=\(wechatIdentifier) from=\(abcIdentifier) live=\(abcIdentifier)"
            + " attempts=4 elapsedMs=1080 verified=false outcome=exhausted")
    }

    @Test func verifiedEvidenceLineReportsConfirmedSelection() {
        let report = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .manual),
            outcome: .verified,
            initialIdentifier: abcIdentifier,
            finalIdentifier: wechatIdentifier,
            attempts: 2,
            elapsedMilliseconds: 80
        )

        let line = InputSourceSwitchEvidence.line(for: report)
        #expect(line == "switch origin=manual app=- desired=\(wechatIdentifier)"
            + " from=\(abcIdentifier) live=\(wechatIdentifier)"
            + " attempts=2 elapsedMs=80 verified=true outcome=verified")
    }

    @Test func identicalEvidenceIsThrottledInsideTheWindow() {
        let clock = EvidenceClock()
        let evidence = InputSourceSwitchEvidence(now: { clock.now })
        let report = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic),
            outcome: .verified,
            initialIdentifier: abcIdentifier,
            finalIdentifier: wechatIdentifier,
            attempts: 1,
            elapsedMilliseconds: 80
        )

        #expect(evidence.shouldRecord(report))
        #expect(!evidence.shouldRecord(report))

        clock.now = clock.now.addingTimeInterval(evidence.minimumInterval + 0.5)
        #expect(evidence.shouldRecord(report))
    }

    @Test func automaticAlreadyCurrentAndSupersededChainsWriteNoEvidence() {
        let clock = EvidenceClock()
        let evidence = InputSourceSwitchEvidence(now: { clock.now })

        let automaticAlreadyCurrent = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic),
            outcome: .alreadyCurrent,
            initialIdentifier: wechatIdentifier,
            finalIdentifier: wechatIdentifier,
            attempts: 0,
            elapsedMilliseconds: 0
        )
        let superseded = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .manual),
            outcome: .superseded,
            initialIdentifier: abcIdentifier,
            finalIdentifier: abcIdentifier,
            attempts: 1,
            elapsedMilliseconds: 80
        )

        #expect(!evidence.shouldRecord(automaticAlreadyCurrent))
        #expect(!evidence.shouldRecord(superseded))
        #expect(evidence.shouldRecord(InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .manual),
            outcome: .alreadyCurrent,
            initialIdentifier: wechatIdentifier,
            finalIdentifier: wechatIdentifier,
            attempts: 0,
            elapsedMilliseconds: 0
        )))
    }

    @Test func exhaustedChainDescribesTheLiveSourceInsteadOfSuccess() {
        let report = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic),
            outcome: .exhausted,
            initialIdentifier: abcIdentifier,
            finalIdentifier: abcIdentifier,
            attempts: 4,
            elapsedMilliseconds: 1_080
        )

        let description = report.failureDescription { identifier in
            if identifier == wechatIdentifier { return "微信输入法" }
            if identifier == abcIdentifier { return "ABC" }
            return "—"
        }
        #expect(description == "Could not switch to 微信输入法 after 4 attempts; ABC is still active.")

        let verified = InputSourceSwitchReport(
            request: InputSourceSwitchRequest(desiredIdentifier: wechatIdentifier, origin: .automatic),
            outcome: .verified,
            initialIdentifier: abcIdentifier,
            finalIdentifier: wechatIdentifier,
            attempts: 1,
            elapsedMilliseconds: 80
        )
        #expect(verified.failureDescription { _ in "—" } == nil)
    }
}
