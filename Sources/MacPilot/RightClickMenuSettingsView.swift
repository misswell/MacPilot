//
//  RightClickMenuSettingsView.swift
//  MacPilot
//
//  Finder 右键菜单设置入口（融合 RClick 配置界面）。
//  该文件是主 App 内唯一 import MacPilotRightClickKit 的地方之一，
//  避免 Kit 的 SettingsView/MenuBarView 与主 App 同名符号冲突。
//

import SwiftUI
import MacPilotRightClickKit

/// MacPilot 主窗口内的 Finder 右键菜单设置页。
struct RightClickMenuSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(model.t("rightClickBack")) { showSettings = false }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    RightClickSettingsHost()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.t("rightClickMenu")).font(.system(size: 30, weight: .bold))
                            Text(model.t("rightClickMenuSubtitle")).foregroundStyle(.secondary)
                        }
                        Divider()

                    Button(model.t("rightClickOpenSettings")) {
                        showSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                    Text(model.t("rightClickMenuHint")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
                }
            }
        }
    }
}
