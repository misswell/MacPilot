import Foundation
import MacPilotDockGroupsCore
import Testing
@testable import MacPilot

/// 回归测试：Dock 分组浮层「点外部 / 失去焦点就关闭」的判定闸门。
///
/// 背景（2026-09-14「加到 Dock 上就自己退出」）：双击图标启动 Helper 时，
/// 第二次点击会落在浮层外、启动瞬间的激活抖动会让浮层立刻 resignKey，
/// 旧实现见到这两个信号就关闭浮层并 `NSApp.terminate`，于是进程在
/// 0.2–1 秒内自己消失。真实日志（Finder/Dock 启动，`launchedByLS=1`）显示
/// 三次启动分别在 184ms 内被 AppKit 的 terminate 流程结束。
///
/// 这两类信号来自「启动手势本身」，不是用户想关掉浮层，因此必须被挡掉。
struct DockGroupPanelDismissalTests {

    private let shownAt: TimeInterval = 1_000

    @Test func launchGestureClickRightAfterShowingDoesNotDismissThePanel() {
        let policy = DockGroupPanelDismissalPolicy(shownAt: shownAt)

        // 双击的第二下：浮层刚出现 150ms，这一下只是启动手势的另一半。
        #expect(!policy.allowsDismissalForOutsideClick(eventTimestamp: shownAt + 0.15))
        // 排队中的旧事件（时间戳早于浮层出现）同样不算「点了别处」。
        #expect(!policy.allowsDismissalForOutsideClick(eventTimestamp: shownAt - 0.05))
        // 刚出现的瞬间也不算。
        #expect(!policy.allowsDismissalForOutsideClick(eventTimestamp: shownAt))
    }

    @Test func deliberateOutsideClickDismissesThePanel() {
        let policy = DockGroupPanelDismissalPolicy(shownAt: shownAt)
        #expect(policy.allowsDismissalForOutsideClick(eventTimestamp: shownAt + 1.2))
        // 边界：正好到闸门打开的时刻就算数。
        #expect(policy.allowsDismissalForOutsideClick(eventTimestamp: policy.dismissableAt))
    }

    @Test func activationChurnRightAfterShowingDoesNotDismissThePanel() {
        let policy = DockGroupPanelDismissalPolicy(shownAt: shownAt)
        // 启动瞬间系统把前台抢回去导致的一次 resignKey 不能关掉浮层。
        #expect(!policy.allowsDismissalForResignKey(now: shownAt + 0.05))
        #expect(!policy.allowsDismissalForResignKey(now: shownAt + 0.3))
        // 用户真的切到别的窗口时仍然按需求第 7 节关闭。
        #expect(policy.allowsDismissalForResignKey(now: shownAt + 0.9))
    }

    @Test func zeroGraceIntervalAcceptsEverything() {
        let policy = DockGroupPanelDismissalPolicy(shownAt: shownAt, graceInterval: 0)
        #expect(policy.allowsDismissalForOutsideClick(eventTimestamp: shownAt))
        #expect(policy.allowsDismissalForResignKey(now: shownAt))
    }

    @Test func negativeGraceIntervalIsClampedToZero() {
        let policy = DockGroupPanelDismissalPolicy(shownAt: shownAt, graceInterval: -5)
        #expect(policy.graceInterval == 0)
        #expect(policy.dismissableAt == shownAt)
    }

    /// 启动手势从第一次点击到浮层出现可能超过 0.3 秒，闸门不能设得太短。
    @Test func defaultGraceWindowCoversTheLaunchGesture() {
        #expect(DockGroupPanelDismissalPolicy.defaultGraceInterval >= 0.3)
        #expect(DockGroupPanelDismissalPolicy.defaultGraceInterval <= 1.0)
    }
}
