//
//  DockHelperPanelPlacementTests.swift
//  MacPilotTests
//
//  锁住「浮层出现在 Dock 图标旁边」的落点规则。
//  用真实的屏幕几何（外接 1920×1080 + Dock 在左边）和常见尺寸做输入。
//

import CoreGraphics
import Testing
@testable import MacPilotDockGroupsCore

struct DockHelperPanelPlacementTests {
    /// Dock 在左边：可见区域从左边内缩 55pt。
    private let leftDockFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let leftDockVisible = CGRect(x: 55, y: 0, width: 1865, height: 1049)
    /// Dock 在下边：可见区域从下边内缩 55pt（菜单栏占顶部 31pt）。
    private let bottomDockFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let bottomDockVisible = CGRect(x: 0, y: 55, width: 1920, height: 994)
    /// Dock 在右边：可见区域从右边内缩 55pt。
    private let rightDockFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let rightDockVisible = CGRect(x: 0, y: 0, width: 1865, height: 1049)

    private let panel = CGSize(width: 290, height: 366)

    @Test func dockEdgeComesFromWhicheverSideTheVisibleFrameInsets() {
        #expect(DockHelperPanelPlacement.dockEdge(
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 29, y: 900)
        ) == .left)
        #expect(DockHelperPanelPlacement.dockEdge(
            screenFrame: bottomDockFrame,
            visibleFrame: bottomDockVisible,
            pointer: CGPoint(x: 900, y: 29)
        ) == .bottom)
        #expect(DockHelperPanelPlacement.dockEdge(
            screenFrame: rightDockFrame,
            visibleFrame: rightDockVisible,
            pointer: CGPoint(x: 1891, y: 500)
        ) == .right)
    }

    /// 菜单栏造成的顶部内缩不是 Dock：没有 Dock 的屏幕上要靠鼠标位置判断。
    @Test func hiddenDockFallsBackToTheNearestScreenEdge() {
        let menuBarOnly = CGRect(x: 0, y: 0, width: 1920, height: 1049)
        #expect(DockHelperPanelPlacement.dockEdge(
            screenFrame: bottomDockFrame,
            visibleFrame: menuBarOnly,
            pointer: CGPoint(x: 900, y: 3)
        ) == .bottom)
        #expect(DockHelperPanelPlacement.dockEdge(
            screenFrame: bottomDockFrame,
            visibleFrame: menuBarOnly,
            pointer: CGPoint(x: 2, y: 600)
        ) == .left)
        #expect(DockHelperPanelPlacement.dockEdge(
            screenFrame: bottomDockFrame,
            visibleFrame: menuBarOnly,
            pointer: CGPoint(x: 1918, y: 600)
        ) == .right)
    }

    /// 左边 Dock：紧贴 Dock 右侧，纵向居中到被点的图标（不是居中到鼠标那一轴）。
    @Test func leftDockPlacesPanelBesideTheIconVerticallyCentered() {
        // 这个 y 就是用户那台机器上「集合」图标的位置：左边 Dock 的图标从上往下排。
        let origin = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 29, y: 600)
        )
        #expect(origin.x == leftDockVisible.minX + DockHelperPanelPlacement.defaultGap)
        #expect(origin.y == 600 - panel.height / 2)
        #expect(origin.y + panel.height == 600 + panel.height / 2)
    }

    /// 下边 Dock：紧贴 Dock 上侧，横向居中到被点的图标。
    @Test func bottomDockPlacesPanelAboveTheIconHorizontallyCentered() {
        let origin = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: bottomDockFrame,
            visibleFrame: bottomDockVisible,
            pointer: CGPoint(x: 700, y: 29)
        )
        #expect(origin.y == bottomDockVisible.minY + DockHelperPanelPlacement.defaultGap)
        #expect(origin.x == 700 - panel.width / 2)
    }

    /// 右边 Dock：紧贴 Dock 左侧（面板右边缘离 Dock 一个 gap）。
    @Test func rightDockPlacesPanelLeftOfTheDock() {
        let origin = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: rightDockFrame,
            visibleFrame: rightDockVisible,
            pointer: CGPoint(x: 1891, y: 500)
        )
        #expect(origin.x + panel.width == rightDockVisible.maxX - DockHelperPanelPlacement.defaultGap)
        #expect(origin.y == 500 - panel.height / 2)
    }

    /// 垂直于 Dock 的那一轴完全不看鼠标：鼠标在屏幕上乱跑，落点也只由图标位置决定。
    @Test func perpendicularAxisIgnoresWhereThePointerSits() {
        let nearDock = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 20, y: 600)
        )
        let farFromDock = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 1800, y: 600)
        )
        #expect(nearDock.x == farFromDock.x)
        #expect(nearDock.y == farFromDock.y)
    }

    /// 贴近屏幕上下边缘的图标：面板被夹回可见区域，但不会压住 Dock。
    @Test func panelIsSqueezedBackIntoTheVisibleFrame() {
        let top = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 29, y: 1075)
        )
        #expect(top.y == leftDockVisible.maxY - panel.height - DockHelperPanelPlacement.edgeMargin)
        #expect(top.y + panel.height <= leftDockVisible.maxY)

        let bottom = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 29, y: 2)
        )
        #expect(bottom.y == leftDockVisible.minY + DockHelperPanelPlacement.edgeMargin)
        #expect(bottom.y >= leftDockVisible.minY)
    }

    /// 比可见区域还高的浮层：宁可顶到上边界，也不能越出屏幕/压住 Dock。
    @Test func oversizedPanelStillNeverLeavesTheScreen() {
        let tall = CGSize(width: 290, height: 2000)
        let origin = DockHelperPanelPlacement.origin(
            panelSize: tall,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: 29, y: 500)
        )
        #expect(origin.y + tall.height <= leftDockFrame.maxY)
        #expect(origin.y <= leftDockVisible.maxY)
        #expect(origin.x >= leftDockVisible.minX)
    }

    /// 浮层永远落在 Dock 内侧：不会盖住 Dock，也不会跑到另一块屏幕上。
    @Test func panelStaysInsideTheDockScreen() {
        for pointer in [CGPoint(x: 5, y: 5), CGPoint(x: 29, y: 540), CGPoint(x: 29, y: 1079)] {
            let origin = DockHelperPanelPlacement.origin(
                panelSize: panel,
                screenFrame: leftDockFrame,
                visibleFrame: leftDockVisible,
                pointer: pointer
            )
            #expect(origin.x >= leftDockVisible.minX)
            #expect(origin.x + panel.width <= leftDockFrame.maxX)
            #expect(origin.y >= leftDockFrame.minY)
            #expect(origin.y + panel.height <= leftDockFrame.maxY)
        }
    }

    // MARK: - 有 Dock 图标位置时：只认图标，不认鼠标

    /// 真机上「集合」图标的 AX frame（左上角原点）换算成 Cocoa 之后的矩形。
    private let tile = CGRect(x: 5.0, y: 197.44, width: 49.33, height: 37.33)

    /// 同一个图标，点在它的上沿还是下沿，浮层都必须落在同一个位置
    /// ——「点击展开依然随着鼠标上下移动」就是这么修掉的。
    @Test func tileAnchorIgnoresWhereInsideTheIconTheClickLands() {
        let top = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: tile.midX, y: tile.maxY - 2),
            tile: tile
        )
        let bottom = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: CGPoint(x: tile.midX, y: tile.minY + 2),
            tile: tile
        )
        #expect(top == bottom)
        // 浮层纵向居中到**图标中心**，而不是点击点。
        #expect(top.y == tile.midY - panel.height / 2)
        #expect(top.x == leftDockVisible.minX + DockHelperPanelPlacement.defaultGap)
    }

    @Test func bottomDockTileCentersHorizontallyOnTheIcon() {
        let icon = CGRect(x: 700, y: 20, width: 49.33, height: 37.33)
        let origin = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: bottomDockFrame,
            visibleFrame: bottomDockVisible,
            pointer: CGPoint(x: icon.minX + 3, y: icon.midY),
            tile: icon
        )
        #expect(origin.x == icon.midX - panel.width / 2)
        #expect(origin.y == bottomDockVisible.minY + DockHelperPanelPlacement.defaultGap)
    }

    /// Dock 里插入/移除图标会让整列平移：此时旧矩形不包含这次的点击点，
    /// 必须退回「按点击位置落点」，否则浮层会跑到别的图标旁边。
    @Test func staleTileIsIgnoredWhenTheClickLandsOutsideIt() {
        // 取一个远离屏幕上下边缘的图标，落点就不会被夹取影响，
        // 能干净地看出用的是「点击点」还是「旧图标中心」。
        let stale = CGRect(x: 5, y: 600, width: 49.33, height: 37.33)
        let pointer = CGPoint(x: stale.midX, y: stale.minY - 80)
        let origin = DockHelperPanelPlacement.origin(
            panelSize: panel,
            screenFrame: leftDockFrame,
            visibleFrame: leftDockVisible,
            pointer: pointer,
            tile: stale
        )
        #expect(origin.y == pointer.y - panel.height / 2)
        #expect(origin.y != stale.midY - panel.height / 2)
    }

    /// 容差之内（Dock 图标放大等小幅变化）仍然认这份几何。
    @Test func tileAnchorToleratesASmallOverflowFromIconMagnification() {
        let anchor = DockHelperPanelPlacement.alongDockAnchor(
            pointer: CGPoint(x: tile.midX, y: tile.maxY + 6),
            tile: tile,
            edge: .left
        )
        #expect(anchor == tile.midY)
    }

    @Test func anchorFallsBackToThePointerWithoutAnyTileGeometry() {
        let anchor = DockHelperPanelPlacement.alongDockAnchor(
            pointer: CGPoint(x: 29, y: 512),
            tile: nil,
            edge: .left
        )
        #expect(anchor == 512)
    }
}
