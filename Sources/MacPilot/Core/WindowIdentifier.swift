import CoreGraphics

extension CGWindowID {
    /// `CGWindowID` is `UInt32`, while AppKit and AX hand out `Int`. A window
    /// that was never ordered — a released switcher panel, a just-created
    /// sheet, an AX element without a window number — reports `-1` (or `0`),
    /// and the narrowing initializer traps on it. That trap is fatal and
    /// SIGTRAP-shaped (EXC_BREAKPOINT), and it fires from whichever closure
    /// happened to compare the number first, which is how "选中 MacPilot 自己
    /// 的窗口" crashed the app inside `WindowFocusExecutor`.
    ///
    /// Always convert through this.
    static func identifiable(_ windowNumber: Int) -> CGWindowID? {
        guard windowNumber > 0 else { return nil }
        return CGWindowID(exactly: windowNumber)
    }
}
