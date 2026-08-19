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
        "General": "通用",
        "Apps": "应用",
        "Actions": "操作",
        "Open With": "打开方式",
        "New File": "新建文件",
        "Common Dirs": "常用目录",
        "Common Dir": "常用目录",
        "About": "关于",
        "Right-click Menu": "右键菜单",
        "Right-click Menu Subtitle": "在访达中右键文件或文件夹，快速执行动作、打开方式、新建文件与常用目录。",
        "MacPilot (loading...)": "MacPilot（加载中…）",
        "No items": "暂无可用菜单项",
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
        "Added Folders": "已添加的文件夹",
        "Backup": "备份",
        "Checking for updates...": "正在检查更新…",
        "Collapse actions menu": "折叠动作菜单",
        "Collapse apps menu": "折叠应用菜单",
        "Collapse menu": "折叠菜单",
        "Collapse new file menu": "折叠新建文件菜单",
        "Default Open App": "默认打开应用",
        "Display Name": "显示名称",
        "Edit App Properties": "编辑应用属性",
        "Enable common folders": "启用常用文件夹",
        "Enable MacPilot Finder extension to show its actions in Finder context menus": "启用 MacPilot Finder 扩展，以在 Finder 右键菜单中显示其动作",
        "Enable MacPilot Finder extension": "启用 MacPilot Finder 扩展",
        "Enter an SF Symbol name, for example doc.text or curlybraces": "输入 SF Symbol 名称，例如 doc.text 或 curlybraces",
        "Environment Variables": "环境变量",
        "Failed to Check for Updates": "检查更新失败",
        "File Extension": "文件扩展名",
        "Folder access permission is required to use this feature.": "使用此功能需要文件夹访问权限。",
        "For example: txt, md, json": "例如：txt、md、json",
        "Format: KEY=VALUE, one per line": "格式：KEY=VALUE，每行一个",
        "Icon": "图标",
        "Invalid Folder": "无效文件夹",
        "Launch at login": "登录时启动",
        "Logs": "日志",
        "MacPilot's Finder context menu provides quick actions for opening folders, managing files, and creating new files.": "MacPilot 的 Finder 右键菜单提供打开文件夹、管理文件与新建文件的快捷动作。",
        "Main Controls": "主要控制",
        "Name": "名称",
        "New Version Available": "有新版本可用",
        "Permissions": "权限",
        "Preview:": "预览：",
        "Quit": "退出",
        "Resetting all settings restores the default configuration and cannot be undone": "重置所有设置将恢复默认配置，且无法撤销",
        "Run Arguments": "运行参数",
        "Separate multiple arguments with semicolons (;)": "多个参数之间用分号 (;) 分隔",
        "Settings Management": "设置管理",
        "Settings": "设置",
        "Show icon in menu bar": "在菜单栏显示图标",
        "System Settings: Select MacPilot in the list to enable the Finder context menu": "系统设置：在列表中选择 MacPilot 以启用 Finder 右键菜单",
        "Template": "模板",
        "The current version is already up to date.": "当前已是最新版本。",
        "The selected folder is a subfolder of an already selected folder. Please choose a different folder.": "所选文件夹是已选文件夹的子文件夹，请选择其他文件夹。",
        "Unauthorized Folder": "未授权文件夹",
        "Up to Date": "已是最新",
        "Accessibility": "辅助功能",
        "Add a Folder…": "添加文件夹…",
        "Add App": "添加应用",
        "Add File Type": "添加文件类型",
        "Add Folder": "添加文件夹",
        "Arguments (semicolon separated)": "参数（分号分隔）",
        "Arguments: %@": "参数：%@",
        "Authorize folders to let MacPilot create, delete, and manage files from Finder.": "授权文件夹，让 MacPilot 可以从 Finder 创建、删除和管理文件。",
        "Authorized": "已授权",
        "Cancel": "取消",
        "Choose a folder for MacPilot to access from Finder context-menu actions.": "选择 MacPilot 在 Finder 右键菜单动作中可访问的文件夹。",
        "Delete": "删除",
        "Delete App": "删除应用",
        "Delete File Type": "删除文件类型",
        "Done": "完成",
        "Download and Install": "下载并安装",
        "Download Manually": "手动下载",
        "Edit App": "编辑应用",
        "Edit File Type": "编辑文件类型",
        "Enabled": "已启用",
        "Environment variables: %lld": "环境变量：%lld",
        "Export…": "导出…",
        "Export Logs…": "导出日志…",
        "Extension: %@": "扩展：%@",
        "Extraction failed: %@": "解压失败：%@",
        "Finder Extension": "Finder 扩展",
        "Folder Permissions": "文件夹权限",
        "Folders cannot be shared via AirDrop: %@": "无法通过 AirDrop 共享文件夹：%@",
        "Grant Access": "授予访问权限",
        "Grant MacPilot access to this folder to perform Finder context-menu file operations.": "授予 MacPilot 该文件夹的访问权限，以执行 Finder 右键菜单文件操作。",
        "Grant Permission": "授予权限",
        "Ignore This Version": "忽略此版本",
        "Import…": "导入…",
        "Installation failed: %@": "安装失败：%@",
        "Manage…": "管理…",
        "No .app application was found in the ZIP file.": "ZIP 文件中未找到 .app 应用。",
        "No .app.zip application package was found.": "未找到 .app.zip 应用包。",
        "No folders authorized": "未授权文件夹",
        "No update is available.": "没有可用更新。",
        "Not Authorized": "未授权",
        "Notice": "提示",
        "OK": "好",
        "Please select the correct Applications folder.": "请选择正确的应用程序文件夹。",
        "Protected system folders cannot be deleted: %@": "受保护的系统文件夹无法删除：%@",
        "Protected system folders cannot be shared: %@": "受保护的系统文件夹无法共享：%@",
        "MacPilot needs permission to install the update into your Applications folder.": "MacPilot 需要权限才能将更新安装到您的应用程序文件夹。",
        "Remove folder permission": "移除文件夹权限",
        "Reset": "重置",
        "Reset All Settings…": "重置所有设置…",
        "Reset All Settings?": "重置所有设置？",
        "Restart Later": "稍后重启",
        "Restart Now": "立即重启",
        "Restore Defaults": "恢复默认",
        "Save": "保存",
        "Settings…": "设置…",
        "SF Symbol Name": "SF Symbol 名称",
        "The application bundle is invalid or damaged.": "应用包无效或已损坏。",
        "The application has been updated successfully. Restart the app to finish the update.": "应用已更新成功。重启应用以完成更新。",
        "The current folder cannot be deleted. Please select files or subfolders instead.": "无法删除当前文件夹，请改为选择文件或子文件夹。",
        "The current folder cannot be shared. Please select files or subfolders instead.": "无法共享当前文件夹，请改为选择文件或子文件夹。",
        "The user cancelled authorization.": "用户已取消授权。",
        "This will delete all custom configurations and restore the defaults. This action cannot be undone.": "这将删除所有自定义配置并恢复默认值，且无法撤销。",
        "Unknown": "未知",
        "Untitled": "无标题",
        "Update Installed": "更新已安装",
        "Version %@": "版本 %@",
        "Version %@ (%@)": "版本 %@（%@）",
        "Version %@ is ignored": "已忽略版本 %@",
        "Warning": "警告",
        "RClick needs permission to install the update into your Applications folder.": "安装更新到应用程序文件夹需要权限，请授予 MacPilot 相应权限。",
    ]

    private static var usesChinese: Bool {
        let identifiers = [
            Locale.current.identifier,
            Locale.autoupdatingCurrent.identifier,
        ] + Locale.preferredLanguages
        let systemLanguages = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]) ?? []

        return (identifiers + systemLanguages).contains { identifier in
            identifier.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix("zh")
        }
    }

    static func localized(_ key: String) -> String {
        if usesChinese,
           let translation = simplifiedChinese[key] {
            return translation
        }

        let bundledValue = Bundle.main.localizedString(forKey: key, value: nil, table: tableName)
        if bundledValue != key {
            return bundledValue
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
