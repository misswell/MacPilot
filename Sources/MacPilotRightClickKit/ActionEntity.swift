//
//  ActionEntity.swift
//  RClick
//
//  Created by Claude on 2026/01/16.
//

import SwiftData
import Foundation

/// 动作实体 - 用于存储右键菜单动作配置
@Model
final class ActionEntity {
    @Attribute(.unique) var id: String
    var name: String
    var icon: String
    var isEnabled: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         icon: String,
         isEnabled: Bool = true,
         sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// 从 RCAction 转换
    convenience init(from action: RCAction) {
        self.init(
            id: action.id,
            name: action.name,
            icon: action.icon,
            isEnabled: action.enabled,
            sortOrder: action.idx
        )
    }

    // 预定义动作的工厂方法（默认开启复制、终端和删除）
    static func createDefaultActions() -> [ActionEntity] {
        RCAction.all.map { action in
            ActionEntity(
                id: action.id,
                name: action.name,
                icon: action.icon,
                isEnabled: action.enabled,
                sortOrder: action.idx
            )
        }
    }
}
