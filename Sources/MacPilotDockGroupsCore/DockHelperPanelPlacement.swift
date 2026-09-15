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
//  落点由两样东西决定：
//
//    1. **Dock 贴哪一边** —— 可见区域相对屏幕内缩的那条边（自动隐藏时退化成
//       「鼠标离哪条边最近」，点击 Dock 图标时鼠标必然贴在那条边上）；
//    2. **图标沿 Dock 方向的位置** —— 首选 MacPilot 读出来写进配置的图标矩形
//       （`DockGroupDockTile`，见下），把浮层居中到图标中心。
//
//  垂直于 Dock 的那一轴**永远不看鼠标**：浮层始终紧贴 Dock 内侧的固定间距。
//
//  为什么图标位置要靠配置而不是自己算：Helper 是独立进程，没有辅助功能权限
//  （`AXIsProcessTrusted` 在 Helper 里实测为 false，读 Dock 的 AX 树返回 -25211），
//  它根本不知道 Dock 图标在哪。所以由**有授权的 MacPilot** 读出来写进 `groups.json`。
//
//  万一没有那份几何（用户没给 MacPilot 辅助功能授权、分组还没被固定到 Dock 上、
//  或者 Dock 布局刚刚变过导致旧矩形已经不包含这次的点击点），就退回
//  「按点击位置落点」：点击那一刻鼠标就在这个图标上，沿 Dock 方向取鼠标坐标
//  虽然不如图标中心精确，但永远不会跑偏到别的图标上。
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
    ///   - tile: Dock 图标的矩形（MacPilot 读出来的那份）；有效时以它的中心定位。
    public static func origin(
        panelSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        pointer: CGPoint,
        tile: CGRect? = nil,
        gap: CGFloat = defaultGap,
        edgeMargin: CGFloat = edgeMargin
    ) -> CGPoint {
        let edge = dockEdge(screenFrame: screenFrame, visibleFrame: visibleFrame, pointer: pointer)
        let anchor = alongDockAnchor(pointer: pointer, tile: tile, edge: edge)

        var origin: CGPoint
        switch edge {
        case .left:
            // 紧贴 Dock 右侧，纵向居中到图标。
            origin = CGPoint(x: visibleFrame.minX + gap, y: anchor - panelSize.height / 2)
        case .right:
            origin = CGPoint(x: visibleFrame.maxX - panelSize.width - gap, y: anchor - panelSize.height / 2)
        case .bottom:
            // 紧贴 Dock 上侧，横向居中到图标。
            origin = CGPoint(x: anchor - panelSize.width / 2, y: visibleFrame.minY + gap)
        }

        // 先夹进可见区域，保证永远不会压住 Dock；可见区域装不下时再用屏幕 frame 兜底。
        origin.x = clamp(origin.x, lower: visibleFrame.minX + edgeMargin, upper: visibleFrame.maxX - panelSize.width - edgeMargin)
        origin.y = clamp(origin.y, lower: visibleFrame.minY + edgeMargin, upper: visibleFrame.maxY - panelSize.height - edgeMargin)
        origin.x = clamp(origin.x, lower: screenFrame.minX, upper: screenFrame.maxX - panelSize.width)
        origin.y = clamp(origin.y, lower: screenFrame.minY, upper: screenFrame.maxY - panelSize.height)
        return origin
    }

    /// 沿 Dock 方向用来居中的那个坐标：优先图标中心，其次点击点。
    ///
    /// 只有在「这次的点击确实落在 MacPilot 记录的那个图标里」时才相信图标矩形——
    /// Dock 里插入/移除图标会让整列平移，此时旧矩形已经不包含点击点，
    /// 用它的中心反而会把浮层放到别的图标旁边。
    static func alongDockAnchor(pointer: CGPoint, tile: CGRect?, edge: DockEdge) -> CGFloat {
        let pointerCoordinate = edge == .bottom ? pointer.x : pointer.y
        guard let tile else { return pointerCoordinate }
        let reach = tile.insetBy(dx: -Self.tileTolerance, dy: -Self.tileTolerance)
        guard reach.contains(pointer) else { return pointerCoordinate }
        return edge == .bottom ? tile.midX : tile.midY
    }

    /// 图标位置的容差（点）：Dock 图标被放大、或几何读到的是放大前的尺寸时，
    /// 点击点仍应被认作「落在这个图标里」。
    static let tileTolerance: CGFloat = 12

    /// 夹取。`upper < lower`（浮层比可用区域还大）时返回 `upper`，
    /// 即优先保证「不越出可见区域的上/右边界」。
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
