//
//  AppLocalization.swift
//  RClick
//
//  Created by Codex on 2026/7/3.
//

import Foundation
import SwiftUI

enum AppLocalization {
    static let tableName = "Localizable"

    /// The Finder extension is compiled separately from the main app and does
    /// not inherit the app's resource bundle. Keep the small set of strings
    /// used by the context menu here so both processes render the same menu.
    private static let simplifiedChinese: [String: String] = [
        "Actions": "操作",
        "Open With": "打开方式",
        "New File": "新建文件",
        "Common Dirs": "常用目录",
        "MacPilot (loading...)": "MacPilot（加载中…）",
        "Copy Path": "复制路径",
        "Copy File Path": "复制文件路径",
        "Copy Folder Path": "复制文件夹路径",
        "Open Terminal": "打开终端",
        "Delete Direct": "直接删除",
        "Hide": "隐藏",
        "Unhide": "显示",
        "AirDrop": "AirDrop",
        "Desktop": "桌面",
        "Documents": "文稿",
        "Downloads": "下载",
        "Applications": "应用程序",
        "Home": "个人文件夹",
    ]

    static func localized(_ key: String) -> String {
        if Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true,
           let translation = simplifiedChinese[key] {
            return translation
        }

        return Bundle.main.localizedString(forKey: key, value: key, table: tableName)
    }

    /// Localize an action by its stable identifier rather than its persisted
    /// display name. This also updates actions created by an older version.
    static func localizedActionName(id: String, fallback: String) -> String {
        let key: String
        switch id {
        case "copy-path": key = "Copy Path"
        case "copy-file-path": key = "Copy File Path"
        case "copy-folder-path": key = "Copy Folder Path"
        case "open-terminal": key = "Open Terminal"
        case "delete-direct": key = "Delete Direct"
        case "hide": key = "Hide"
        case "unhide": key = "Unhide"
        case "airdrop": key = "AirDrop"
        default: return fallback
        }
        return localized(key)
    }
}

extension Text {
    init(appLocalized key: String) {
        self.init(AppLocalization.localized(key))
    }
}
