//
//  DockHelperWarmLifetimePolicy.swift
//  MacPilotDockGroupsCore
//
//  需求第 7、10 节：Helper 是「点一下才出现」的进程，不该长期驻留。
//  面板收起后它仍待命一段时间，为的是让下一次点击走热展开而不是冷启动；
//  这个时长是「不留后台进程」与「点开即现」之间的唯一折衷，所以放到可测的
//  核心包里，由单元测试锁住上界。
//

import Foundation

public enum DockHelperWarmLifetimePolicy {
    /// Closing the panel ends use: do not keep an idle helper resident.
    public static let seconds: TimeInterval = 0
}
