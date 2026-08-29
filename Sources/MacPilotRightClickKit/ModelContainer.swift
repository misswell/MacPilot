//
//  ModelContainer.swift
//  RClick
//
//  Created by 李旭 on 2025/10/3.
//

import Foundation
import SwiftData
import OSLog

// 共享 ModelContainer 配置工具类
@MainActor
class SharedDataManager {
    static let appGroupIdentifier = RightClickConstants.appGroupIdentifier

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.macpilot.rightclick",
        category: "ModelContainer"
    )

    static var sharedModelContainer: ModelContainer = {
        // 候选数据库路径：
        // 1. App Group 共享目录 —— 只有沙盒进程（如 Finder 扩展）可写；
        //    非沙盒主 App 访问会被 TCC 拒绝（errno 1），必须跳过。
        // 2. 本地 Application Support —— 非沙盒主 App 使用。
        let fallbackDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("MacPilot/RightClick", isDirectory: true)

        var candidates: [(url: URL, label: String)] = []
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ), FileManager.default.isWritableFile(atPath: containerURL.path) {
            candidates.append((containerURL.appendingPathComponent("RClickDatabase.sqlite"), "App Group"))
        }
        candidates.append((fallbackDirectory.appendingPathComponent("RClickDatabase.sqlite"), "Application Support"))

        var lastError: Error?
        for candidate in candidates {
            do {
                try FileManager.default.createDirectory(
                    at: candidate.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // 创建 ModelConfiguration 使用候选路径
                let configuration = ModelConfiguration(
                    url: candidate.url,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )

                // 创建 ModelContainer，注册所有模型
                let container = try ModelContainer(
                    for: AppEntity.self,
                         ActionEntity.self,
                         NewFileTypeEntity.self,
                         CommonDirEntity.self,
                         BookmarkEntity.self,
                         DataVersion.self,
                    configurations: configuration
                )

                if candidate.label == "Application Support" {
                    logger.warning("App Group 不可写；使用本地 right-click 数据库: \(candidate.url.path)")
                }
                return container
            } catch {
                lastError = error
                logger.error("ModelContainer 初始化失败（\(candidate.label)）: \(error.localizedDescription)")
            }
        }

        // Right-click integration is optional; a corrupt or unmigratable
        // on-disk store must not prevent the whole menu-bar app from launching.
        logger.error("持久化数据库不可用，使用临时内存数据库: \(lastError.map(String.init(describing:)) ?? "未知错误")")
        do {
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(
                for: AppEntity.self,
                     ActionEntity.self,
                     NewFileTypeEntity.self,
                     CommonDirEntity.self,
                     BookmarkEntity.self,
                     DataVersion.self,
                configurations: fallback
            )
        } catch {
            fatalError("创建内存 ModelContainer 失败（模型配置错误）: \(error)")
        }
    }()

    /// 初始化默认数据
    static func initializeDefaultData(context: ModelContext) async {
        // 检查是否已有数据
        let actionDescriptor = FetchDescriptor<ActionEntity>()
        let actionCount = try? context.fetchCount(actionDescriptor)

        if actionCount == 0 {
            // 插入默认动作
            for action in ActionEntity.createDefaultActions() {
                context.insert(action)
            }
            Self.logger.info("已初始化默认动作")
        }

        let fileTypeDescriptor = FetchDescriptor<NewFileTypeEntity>()
        let fileTypeCount = try? context.fetchCount(fileTypeDescriptor)

        if fileTypeCount == 0 {
            // 插入默认文件类型
            for fileType in NewFileTypeEntity.createDefaultFileTypes() {
                context.insert(fileType)
            }
            Self.logger.info("已初始化默认文件类型")
        }

        let appDescriptor = FetchDescriptor<AppEntity>()
        let appCount = try? context.fetchCount(appDescriptor)

        if appCount == 0 {
            for app in OpenWithApp.defaultApps {
                context.insert(AppEntity(from: app))
            }
            Self.logger.info("已初始化默认应用")
        }

        let commonDirDescriptor = FetchDescriptor<CommonDirEntity>()
        let commonDirCount = try? context.fetchCount(commonDirDescriptor)

        if commonDirCount == 0 {
            // 插入默认常用目录
            for dir in CommonDirEntity.createDefaultCommonDirs() {
                context.insert(dir)
            }
            Self.logger.info("已初始化默认常用目录")
        }

        try? context.save()
    }
}
