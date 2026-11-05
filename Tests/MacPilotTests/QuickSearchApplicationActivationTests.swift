import Testing
@testable import MacPilot

@MainActor
struct QuickSearchApplicationActivationTests {
    private final class State {
        var isActive = false
        var captures = 0
        var activations = 0
        var deactivations = 0
        var restorations = 0
    }

    private func activation(_ state: State) -> SystemQuickSearchApplicationActivation {
        SystemQuickSearchApplicationActivation(environment: .init(
            isActive: { state.isActive },
            capturePreviousApplication: {
                state.captures += 1
                return { state.restorations += 1 }
            },
            activate: { state.activations += 1; state.isActive = true },
            deactivate: { state.deactivations += 1; state.isActive = false }
        ))
    }

    @Test func closingThePanelReturnsActivationToThePreviousApplicationOnlyOnce() {
        let state = State()
        let subject = activation(state)
        subject.activateForPanel()
        subject.restoreAfterPanel(preservingApplicationFocus: false)
        state.isActive = true
        subject.restoreAfterPanel(preservingApplicationFocus: false)

        #expect(state.activations == 1)
        #expect(state.deactivations == 1)
        #expect(state.restorations == 1)
    }

    @Test func selectingTheSettingsWindowKeepsMacPilotActive() {
        let state = State()
        let subject = activation(state)
        subject.activateForPanel()
        subject.restoreAfterPanel(preservingApplicationFocus: true)

        #expect(state.isActive)
        #expect(state.deactivations == 0)
        #expect(state.restorations == 0)
        // The old session is consumed even when its activation is retained.
        subject.restoreAfterPanel(preservingApplicationFocus: false)
        #expect(state.restorations == 0)
    }

    @Test func switchingToAnotherApplicationDoesNotReactivateThePreviousOne() {
        let state = State()
        let subject = activation(state)
        subject.activateForPanel()
        state.isActive = false
        subject.restoreAfterPanel(preservingApplicationFocus: false)

        #expect(state.deactivations == 0)
        #expect(state.restorations == 0)
    }

    @Test func openingFromMacPilotDoesNotBorrowAnExternalApplicationsActivation() {
        let state = State()
        state.isActive = true
        let subject = activation(state)
        subject.activateForPanel()
        subject.restoreAfterPanel(preservingApplicationFocus: false)

        #expect(state.captures == 0)
        #expect(state.activations == 0)
        #expect(state.deactivations == 0)
        #expect(state.restorations == 0)
    }

    @Test func aNewPanelSessionCapturesItsOwnPreviousApplication() {
        let state = State()
        let subject = activation(state)
        subject.activateForPanel()
        subject.restoreAfterPanel(preservingApplicationFocus: true)
        state.isActive = false
        subject.activateForPanel()
        subject.restoreAfterPanel(preservingApplicationFocus: false)

        #expect(state.captures == 2)
        #expect(state.activations == 2)
        #expect(state.deactivations == 1)
        #expect(state.restorations == 1)
    }
}
