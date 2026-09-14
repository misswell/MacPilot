//
//  DockGroupsSettings.swift
//  MacPilot
//
//  Dock Groups 的功能开关与全局偏好（并入 config.json）。
//
//  需求第 22 节：`dockGroupsEnabled` 默认 false；
//  关闭后不扫描 App、不监听 Workspace、不运行 Helper 管理任务、不启动后台 Timer。
//

import Foundation
import MacPilotDockGroupsCore

struct DockGroupsSettings: Codable, Equatable, Sendable {
    /// 功能总开关（需求中的 `dockGroupsEnabled`），默认关闭。
    var isEnabled: Bool
    /// 新建分组时的默认布局。
    var defaultLayout: DockGroupLayout
    /// 二级列表是否显示运行状态圆点。
    var showsRunningState: Bool

    init(
        isEnabled: Bool = false,
        defaultLayout: DockGroupLayout = .fallback,
        showsRunningState: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.defaultLayout = defaultLayout
        self.showsRunningState = showsRunningState
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, defaultLayout, showsRunningState
    }

    /// 逐键 `decodeIfPresent`：以后新增字段时旧配置仍可加载。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        defaultLayout = try container.decodeIfPresent(DockGroupLayout.self, forKey: .defaultLayout) ?? .fallback
        showsRunningState = try container.decodeIfPresent(Bool.self, forKey: .showsRunningState) ?? true
    }
}
