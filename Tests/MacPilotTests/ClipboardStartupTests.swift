import Testing
@testable import MacPilot

@Suite @MainActor
struct ClipboardStartupTests {
    @Test func disabledClipboardDoesNotLoadHistoryAtLaunch() {
        let clipboard = ClipboardModel()
        clipboard.applyLoadedSettings(ClipboardSettings(), activate: false)
        #expect(!clipboard.hasLoadedHistory)
        clipboard.shutdown()
        #expect(!clipboard.hasLoadedHistory)
    }
}
