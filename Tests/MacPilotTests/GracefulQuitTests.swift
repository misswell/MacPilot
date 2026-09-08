import ApplicationServices
import Testing
@testable import MacPilot

struct GracefulQuitTests {
    @Test func onlyExplicitlyPermittedQuitEventsUseGracefulTermination() {
        #expect(automationQuitStrategy(for: noErr) == .graceful)
        #expect(automationQuitStrategy(for: OSStatus(errAEEventWouldRequireUserConsent)) == .signal)
        #expect(automationQuitStrategy(for: OSStatus(errAEEventNotHandled)) == .signal)
        #expect(automationQuitStrategy(for: 12345) == .signal)
    }
}
