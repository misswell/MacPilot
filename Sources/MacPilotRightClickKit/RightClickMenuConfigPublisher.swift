//
//  RightClickMenuConfigPublisher.swift
//  MacPilot
//
//  从 AppState 构建菜单配置并推送给 FinderSync 扩展。
//

import Foundation

/// 从 AppState 构建菜单配置并推送给 FinderSync 扩展。
///
/// 内容未变化时跳过推送：否则每次心跳（10 秒一次）都会重新编码、
/// 重新签名并让扩展清空图标缓存。
@MainActor
final class RightClickMenuConfigPublisher {
    /// 与版本号无关的配置内容快照，用于判断是否有变化。
    struct ContentSnapshot: Equatable {
        var actions: [ActionMenuItem]
        var apps: [AppMenuItem]
        var newFiles: [NewFileMenuItem]
        var commonDirs: [CommonDirMenuItem]
        var actionsCollapsed: Bool
        var appsCollapsed: Bool
        var newFilesCollapsed: Bool
        var commonDirsCollapsed: Bool
    }

    @AppLog(category: "RightClickMenu")
    private var logger

    private let appState: AppState
    private let messager: Messager
    private var menuVersion = 0
    private var lastPushedContent: ContentSnapshot?

    init(appState: AppState, messager: Messager = .shared) {
        self.appState = appState
        self.messager = messager
    }

    /// 构建并推送菜单配置。`force` 为 false 时，内容与上次推送一致则跳过。
    func publish(force: Bool) {
        let content = makeContentSnapshot()
        if !force, content == lastPushedContent {
            logger.debug("Menu config unchanged; skipping push")
            return
        }

        menuVersion += 1
        let config = MenuConfigPayload(
            version: menuVersion,
            actions: content.actions,
            apps: content.apps,
            newFiles: content.newFiles,
            commonDirs: content.commonDirs,
            actionsCollapsed: content.actionsCollapsed,
            appsCollapsed: content.appsCollapsed,
            newFilesCollapsed: content.newFilesCollapsed,
            commonDirsCollapsed: content.commonDirsCollapsed
        )
        lastPushedContent = content
        messager.sendMenuConfig(config)
        logger.debug("Sent menu configuration v\(self.menuVersion): \(content.actions.count) actions, \(content.apps.count) apps")
    }

    private func makeContentSnapshot() -> ContentSnapshot {
        ContentSnapshot(
            actions: appState.actions.filter(\.enabled).map { $0.toActionMenuItem() },
            apps: appState.apps.map { $0.toAppMenuItem() },
            newFiles: appState.newFiles.filter(\.enabled).map { NewFileMenuItem(id: $0.id, name: $0.name, ext: $0.ext, icon: $0.icon) },
            commonDirs: appState.showCommonDirs ? appState.cdirs.map { CommonDirMenuItem(id: $0.id, name: $0.displayName, icon: $0.icon, url: $0.url.path) } : [],
            actionsCollapsed: appState.foldActionsMenu,
            appsCollapsed: appState.foldAppsMenu,
            newFilesCollapsed: appState.foldNewFileMenu,
            commonDirsCollapsed: appState.foldCommonDirMenu
        )
    }
}
