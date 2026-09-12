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

    /// Cap for the "observe directories" re-arm loop. Without it a Finder
    /// extension that never enables itself makes the coordinator retry every
    /// three seconds for the whole life of the app.
    private static let maxObserveDirRetryCount: Int = 20

    private var configObserver: NSObjectProtocol?
    private var observeDirTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard configObserver == nil else { return }
        PermissionDiagnostics.record("coordinator.start")
        logger.info("RightClickMenuCoordinator.start() called")

        // 监听菜单配置更新通知（设置页 toggle 动作时触发）
        configObserver = NotificationCenter.default.addObserver(
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
        guard !pluginRunning else { return }
        observeDirTask?.cancel()
        observeDirTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.maxObserveDirRetryCount {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, !self.pluginRunning else { return }
                self.messager.sendRunningNotification(directories: [])
            }
            self?.logger.debug("Observe-directory retry budget exhausted")
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

    /// Tears the coordinator down: removes the config observer and cancels the
    /// heartbeat / retry loops. Called when the right-click menu is disabled and
    /// on app termination.
    public func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        observeDirTask?.cancel()
        observeDirTask = nil
        pluginRunning = false
        logger.info("RightClickMenuCoordinator.stop() called")
    }

}
