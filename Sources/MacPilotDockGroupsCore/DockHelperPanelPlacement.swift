//
//  DockHelperPanelPlacement.swift
//  MacPilotDockGroupsCore
//
//  需求第 7 节：浮层出现在 **Dock 图标旁边**，而不是跟着鼠标跑。
//
//  坐标约定：这里一律用 **Cocoa 屏幕坐标**（主屏左下角为原点、y 轴向上），
//  与 `NSScreen.frame` / `NSScreen.visibleFrame` / `NSEvent.mouseLocation`
//  完全一致，调用方不需要做任何翻转。
//
//  为什么只能用推的：Helper 是独立进程，没有辅助功能权限（`AXIsProcessTrusted`
//  在 Helper 里实测为 false），拿不到 Dock 图标的 AX frame。所以落点只用两样东西：
//
//    1. **Dock 贴哪一边** —— 可见区域相对屏幕内缩的那条边；
//    2. **图标在 Dock 上的位置** —— 点击 Dock 图标的那一刻，鼠标就在图标上，
//       因此取鼠标「沿 Dock 方向」的那个坐标，把浮层居中到图标上。
//
//  垂直于 Dock 的那一轴**不看鼠标**：浮层永远紧贴 Dock 内侧的固定间距，
//  于是「点哪个图标就在哪个图标旁边出现」，与鼠标在图标上的具体落点无关。
//

import CoreGraphics

/// 浮层相对 Dock 的落点计算。纯函数，便于用单元测试锁住行为。
public enum DockHelperPanelPlacement {
    /// Dock 贴在屏幕的哪一边。macOS 的 Dock 只有左 / 下 / 右三种位置。
    public enum DockEdge: String, Sendable, CaseIterable {
        case left
        case right
        case bottom
    }

    /// 浮层与 Dock 内侧之间的间距（点）。
    public static let defaultGap: CGFloat = 10
    /// 浮层与可见区域边缘的最小留白（点）。
    public static let edgeMargin: CGFloat = 8
    /// 判断「可见区域是否在某条边内缩」的最小差值，避开舍入噪声。
    private static let insetThreshold: CGFloat = 1

    /// 判断 Dock 贴在哪一边。
    ///
    /// - 可见区域在某条边内缩 ⇒ 那条边被 Dock 占了。
    /// - Dock 自动隐藏时可见区域等于屏幕 frame，此时退化成「鼠标离哪条边最近」：
    ///   点击 Dock 图标时鼠标必然贴在那条边上，因此结论依然可靠。
    /// - 菜单栏造成的**顶部**内缩不是 Dock，这里不参与判断。
    public static func dockEdge(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        pointer: CGPoint
    ) -> DockEdge {
        let insetBottom = visibleFrame.minY - screenFrame.minY
        let insetLeft = visibleFrame.minX - screenFrame.minX
        let insetRight = screenFrame.maxX - visibleFrame.maxX

        if insetBottom > insetThreshold { return .bottom }
        if insetLeft > insetThreshold { return .left }
        if insetRight > insetThreshold { return .right }

        let candidates: [(DockEdge, CGFloat)] = [
            (.bottom, pointer.y - screenFrame.minY),
            (.left, pointer.x - screenFrame.minX),
            (.right, screenFrame.maxX - pointer.x)
        ]
        return candidates.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    /// 计算浮层原点（左下角）。
    ///
    /// - Parameters:
    ///   - panelSize: 浮层尺寸。
    ///   - screenFrame: 图标所在屏幕的 `frame`。
    ///   - visibleFrame: 同一屏幕的 `visibleFrame`（已扣掉 Dock 与菜单栏）。
    ///   - pointer: 点击 Dock 图标时的鼠标位置（`NSEvent.mouseLocation`）。
    public static func origin(
        panelSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        pointer: CGPoint,
        gap: CGFloat = defaultGap,
        edgeMargin: CGFloat = edgeMargin
    ) -> CGPoint {
        let edge = dockEdge(screenFrame: screenFrame, visibleFrame: visibleFrame, pointer: pointer)

        var origin: CGPoint
        switch edge {
        case .left:
            // 紧贴 Dock 右侧，纵向居中到被点的图标。
            origin = CGPoint(x: visibleFrame.minX + gap, y: pointer.y - panelSize.height / 2)
        case .right:
            origin = CGPoint(x: visibleFrame.maxX - panelSize.width - gap, y: pointer.y - panelSize.height / 2)
        case .bottom:
            // 紧贴 Dock 上侧，横向居中到被点的图标。
            origin = CGPoint(x: pointer.x - panelSize.width / 2, y: visibleFrame.minY + gap)
        }

        // 先夹进可见区域，保证永远不会压住 Dock；可见区域装不下时再用屏幕 frame 兜底。
        origin.x = clamp(origin.x, lower: visibleFrame.minX + edgeMargin, upper: visibleFrame.maxX - panelSize.width - edgeMargin)
        origin.y = clamp(origin.y, lower: visibleFrame.minY + edgeMargin, upper: visibleFrame.maxY - panelSize.height - edgeMargin)
        origin.x = clamp(origin.x, lower: screenFrame.minX, upper: screenFrame.maxX - panelSize.width)
        origin.y = clamp(origin.y, lower: screenFrame.minY, upper: screenFrame.maxY - panelSize.height)
        return origin
    }

    /// 夹取。`upper < lower`（浮层比可用区域还大）时返回 `upper`，
    /// 即优先保证「不越出可见区域的上/右边界」。
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
