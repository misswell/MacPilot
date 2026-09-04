//
//  RightClickMenuCoordinator.swift
//  MacPilot
//
//  Finder 右键菜单协调器（源自 RClick，GPLv3）。
//  负责与 FinderSync 扩展的生命周期协调：推送菜单配置（RightClickMenuConfigPublisher）、
//  路由扩展点击事件（RightClickFileOperations）、心跳监控与陈旧扩展进程清理。
//

import AppKit
import Foundation
import SwiftData

import OSLog

extension NSNotification.Name {
    static let menuConfigShouldUpdate = NSNotification.Name("com.misswell.macpilot.menuConfigShouldUpdate")
}

@MainActor
public final class RightClickMenuCoordinator {
    /// 主 App 使用的共享协调器。
    public static let shared = RightClickMenuCoordinator()

    @AppLog(category: "RightClickMenu")
    private var logger

    var appState: AppState = .shared
    var pluginRunning: Bool = false

    let messager = Messager.shared
    private lazy var configPublisher = RightClickMenuConfigPublisher(appState: appState, messager: messager)
    private lazy var fileOperations = RightClickFileOperations(appState: appState)

    /// 最大重试次数
    private let maxRunningMessageRetryCount: Int = 6

    public init() {}

    public func start() {
        logger.info("RightClickMenuCoordinator.start() called")

        // 自动清理重复/陈旧的 FinderSync 扩展进程，只保留当前 App 的一个实例。
        // macOS 会在登录/更新后拉起多个扩展进程（双屏或重复注册），无需用户手动清理。
        scheduleFinderSyncCleanup()

        // 监听菜单配置更新通知（设置页 toggle 动作时触发）
        NotificationCenter.default.addObserver(
            forName: .menuConfigShouldUpdate,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.sendMenuConfigurationUpdate()
            }
        }

        Task { @MainActor in
            do {
                // 初始化默认数据
                let context = ModelContext(SharedDataManager.sharedModelContainer)
                await SharedDataManager.initializeDefaultData(context: context)
            }

            // Preload icons for all apps to improve performance
            Task { @MainActor in
                IconCache.shared.preloadIcons(for: appState.apps.map { $0.url })
            }

            // Register message handlers using type-safe API
            logger.info("Registering message handlers")
            messager.onExtensionMessage(.click) { [weak self] data in
                guard let self = self else { return }
                if let event: ClickEventPayload = messager.decodeSignedData(data) {
                    Task { @MainActor in
                        await self.handleClickEvent(event)
                    }
                } else {
                    logger.warning("Invalid click event data")
                }
            }

            messager.onExtensionMessage(.heartbeat) { [weak self] _ in
                guard let self = self else { return }
                logger.debug("Received heartbeat from extension")
                pluginRunning = true
                // 心跳只做保活；配置未变化时不重复推送。
                configPublisher.publish(force: false)
            }

            // 处理 Extension 请求菜单配置
            messager.onExtensionMessage(.requestConfig) { [weak self] _ in
                guard let self = self else { return }
                logger.info("Received menu config request from extension")
                self.sendMenuConfigurationUpdate()
            }

            // 启动心跳超时检测
            startHeartbeatMonitoring()
            // 启动 running 消息重试机制
            startRunningMessageRetry()

            sendObserveDirMessage()
        }
    }

    // MARK: - Message Handlers

    func sendObserveDirMessage() {
        let directories: [String] = []
        messager.sendRunningNotification(directories: directories)
        if !pluginRunning {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                sendObserveDirMessage()
            }
        }
    }

    public func sendMenuConfigurationUpdate() {
        configPublisher.publish(force: true)
    }

    public func handleClickEvent(_ event: ClickEventPayload) async {
        logger.debug("Handling click event: \(event.itemId) type=\(event.itemType.rawValue) trigger=\(event.trigger.rawValue) target=\(event.target)")

        switch event.itemType {
        case .app:
            fileOperations.openApp(rid: event.itemId, target: event.target)
        case .action:
            await fileOperations.handleAction(rid: event.itemId, target: event.target, trigger: event.trigger.rawValue)
        case .newFile:
            await fileOperations.createFile(rid: event.itemId, target: event.target)
        case .commonDir:
            fileOperations.openCommonDirs(target: event.target)
        }
    }

    // MARK: - 重连机制

    /// 心跳监控 Task（可取消）
    private var heartbeatMonitorTask: Task<Void, Never>?

    /// 启动心跳监控（15 秒超时检测）
    private func startHeartbeatMonitoring() {
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                if pluginRunning {
                    pluginRunning = false
                } else {
                    logger.warning("Heartbeat timeout detected; waiting for the extension to request config again")
                }
            }
        }
    }

    /// 启动 running 消息重试机制（每 5 秒发送一次，持续 30 秒）
    private func startRunningMessageRetry() {
        Task { @MainActor in
            for retryCount in 0..<self.maxRunningMessageRetryCount {
                try? await Task.sleep(for: .seconds(5))
                guard !self.pluginRunning else { break }
                self.messager.sendRunningNotification()
                self.logger.debug("Sending running message retry \(retryCount + 1)/\(self.maxRunningMessageRetryCount)")
            }
            logger.debug("Running message retry completed")
        }
    }

    // MARK: - 进程自清理

    private var finderSyncCleanupTask: Task<Void, Never>?

    /// 启动后先等扩展就绪再清理，随后定期复查，自动处理重复/陈旧扩展进程。
    private func scheduleFinderSyncCleanup() {
        finderSyncCleanupTask?.cancel()
        finderSyncCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.cleanUpFinderSyncProcesses()
            // 每 5 分钟复查一次，处理运行中才新出现的重复实例。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard !Task.isCancelled else { return }
                self.cleanUpFinderSyncProcesses()
            }
        }
    }

    /// 清理多余的 FinderSync 扩展进程：保留当前 App 的一个实例，
    /// 杀掉重复的当前实例与来自旧/损坏 App 副本的陈旧实例。
    @MainActor private func cleanUpFinderSyncProcesses() {
        let currentExtensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.misswell.macpilot.finder-sync"
        )
        guard running.count > 1 else { return }

        let currentOnes = running.filter { $0.bundleURL?.standardizedFileURL == currentExtensionURL.standardizedFileURL }
        let staleOnes = running.filter { $0.bundleURL?.standardizedFileURL != currentExtensionURL.standardizedFileURL }

        if currentOnes.isEmpty {
            // 当前扩展尚未运行：只保留一个（避免完全没扩展），其余杀掉。
            for app in running.dropFirst() {
                logger.info("Terminating extra FinderSync instance: \(app.processIdentifier)")
                app.terminate()
            }
        } else {
            // 保留当前扩展的一个实例，其余（当前重复 + 陈旧副本）全杀。
            for app in currentOnes.dropFirst() {
                logger.info("Terminating duplicate FinderSync instance: \(app.processIdentifier)")
                app.terminate()
            }
            for app in staleOnes {
                logger.info("Terminating stale FinderSync instance: \(app.processIdentifier) (\(app.bundleURL?.path ?? "?"))")
                app.terminate()
            }
        }
    }
}
