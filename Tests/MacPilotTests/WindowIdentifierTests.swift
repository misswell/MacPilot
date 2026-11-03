import CoreGraphics
import Testing
@testable import MacPilot

/// `CGWindowID` is `UInt32`; AppKit hands out `Int`. The narrowing initializer
/// traps on a never-ordered window's `-1`, and the trap lands in whichever
/// closure compared the number first — on 2026-11-03 that was
/// `WindowFocusExecutor` raising MacPilot's own window, which killed the app
/// with SIGTRAP while the switcher was in use.
struct WindowIdentifierTests {
    @Test func unorderedWindowsYieldNoIdentifierInsteadOfTrapping() {
        #expect(CGWindowID.identifiable(-1) == nil)
        #expect(CGWindowID.identifiable(0) == nil)
        #expect(CGWindowID.identifiable(-4_000) == nil)
    }

    @Test func orderedWindowsKeepTheirExactIdentifier() {
        #expect(CGWindowID.identifiable(42) == 42)
        #expect(CGWindowID.identifiable(Int(CGWindowID.max)) == CGWindowID.max)
    }

    @Test func valuesOutsideTheWindowIdRangeAreRejected() {
        #expect(CGWindowID.identifiable(Int.max) == nil)
    }
}
