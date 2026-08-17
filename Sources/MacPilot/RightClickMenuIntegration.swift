//
//  RightClickMenuIntegration.swift
//  MacPilot
//
//  Finder 右键菜单融合层（源自 RClick, GPLv3 — https://github.com/wflixu/RClick）。
//  MacPilot 主 App 通过 RightClickMenuCoordinator 与内嵌的 FinderSync 扩展通信，
//  让 Finder 右键菜单具备：复制路径、直接删除、隐藏/显示、AirDrop、
//  外部应用打开、新建文件、常用目录快捷访问等能力。
//

import AppKit
import MacPilotRightClickKit

extension MacPilotModel {
    /// Finder 右键菜单协调器（启动时创建）。
    var rightClickMenu: RightClickMenuCoordinator { RightClickMenuCoordinator.shared }

    /// 启动 Finder 右键菜单（应在 applicationDidFinishLaunching 时调用）。
    func startRightClickMenu() {
        rightClickMenu.start()
    }
}
