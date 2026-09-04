//
//  RightClickMenuSettingsView.swift
//  MacPilot
//
//  Finder 右键菜单设置入口。
//  该文件是主 App 内唯一 import MacPilotRightClickKit 的地方之一，
//  避免 Kit 的 SettingsView/MenuBarView 与主 App 同名符号冲突。
//

import SwiftUI
import MacPilotRightClickKit

/// MacPilot 主窗口内的 Finder 右键菜单设置页。
struct RightClickMenuSettingsView: View {
    var body: some View {
        RightClickSettingsHost()
    }
}
