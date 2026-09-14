//
//  DockGroupPanelDismissalPolicy.swift
//  MacPilotDockGroupsCore
//
//  需求第 7 节：「点击外部自动关闭 / 失去焦点自动关闭」的判定闸门。
//
//  为什么需要这一层（2026-09-14 的「点一下图标，浮层一闪，App 自己退出」）：
//
//  Helper 浮层出现后，任何一次「别处的鼠标按下」或「浮层失去 key」都会
//  关闭浮层；而浮层关闭就意味着 `NSApp.terminate`（Helper 不常驻）。
//  于是「启动它的那一次点击手势」本身就会把它关掉：
//
//  * 双击 Dock / Finder 里的图标时，第一次点击负责启动进程，浮层出现后，
//    第二次点击正好落在浮层外面 —— 全局鼠标监听把它当成「用户点了别处」；
//  * 启动瞬间的激活状态抖动会让刚出现的浮层立刻 resignKey。
//
//  两次真实启动都在 0.2–1 秒内自己退出，用户看到的就是「刚加到 Dock 上就退出」。
//
//  这里用两道闸门把「启动手势的残留」和「用户真的想关掉」区分开：
//
//  1. 早于浮层出现时刻的事件（启动手势里已经在路上的那次点击）一律忽略；
//  2. 浮层出现后的极短时间内（默认 0.5s）不接受「点外部 / 失去 key」信号。
//
//  ESC 与浮层内的按钮（启动 App、打开设置）不经过这里，永远立即生效——
//  那些是明确的用户意图。
//

import Foundation

/// 浮层关闭信号的判定闸门。时间基准与 `NSEvent.timestamp` 一致
/// （都是 `ProcessInfo.processInfo.systemUptime` 的「开机后秒数」）。
public struct DockGroupPanelDismissalPolicy: Sendable {
    /// 浮层出现后忽略「点外部 / 失去 key」的时间窗口。
    public static let defaultGraceInterval: TimeInterval = 0.5

    /// 浮层出现（`makeKeyAndOrderFront`）的时刻。
    public let shownAt: TimeInterval
    /// 出现后多久之内忽略关闭信号。
    public let graceInterval: TimeInterval

    public init(shownAt: TimeInterval, graceInterval: TimeInterval = DockGroupPanelDismissalPolicy.defaultGraceInterval) {
        self.shownAt = shownAt
        self.graceInterval = max(0, graceInterval)
    }

    /// 从这个时刻起，关闭信号才被接受。
    public var dismissableAt: TimeInterval {
        shownAt + graceInterval
    }

    /// 全局「点击外部」事件是否应该关闭浮层。
    ///
    /// 比 `dismissableAt` 更早的事件都判为「启动手势的残留 / 排队中的旧事件」，
    /// 不关闭浮层。
    public func allowsDismissalForOutsideClick(eventTimestamp: TimeInterval) -> Bool {
        eventTimestamp >= dismissableAt
    }

    /// 浮层失去 key window 是否应该关闭浮层。
    /// 启动瞬间的激活抖动发生在这个窗口内，因此被忽略。
    public func allowsDismissalForResignKey(now: TimeInterval) -> Bool {
        now >= dismissableAt
    }
}
