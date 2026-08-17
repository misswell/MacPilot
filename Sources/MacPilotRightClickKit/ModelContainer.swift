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
        do {
            // 获取 App Group 共享目录
            let storeURL: URL

            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
                storeURL = containerURL.appendingPathComponent("RClickDatabase.sqlite")
            } else {
                // SwiftPM debug runs do not carry the packaged app's
                // entitlements. Keep that workflow usable with a local
                // fallback; the signed app and FinderSync extension use the
                // shared App Group path above.
                let fallbackDirectory = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0].appendingPathComponent("MacPilot/RightClick", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: fallbackDirectory,
                    withIntermediateDirectories: true
                )
                logger.warning("App Group unavailable; using local right-click database fallback")
                storeURL = fallbackDirectory.appendingPathComponent("RClickDatabase.sqlite")
            }

            // 创建 ModelConfiguration 使用共享路径
            let configuration = ModelConfiguration(
                url: storeURL,
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

            return container
        } catch {
            fatalError("创建共享 ModelContainer 失败: \(error)")
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
