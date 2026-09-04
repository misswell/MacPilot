//
//  Messager.swift
//  MacPilot
//
//  进程间通信（IPC）管理器
//  基于：DistributedNotificationCenter + Codable 协议
//

import Foundation
import OSLog
import AppKit
import CryptoKit

// MARK: - 消息类型枚举

/// 主程序发送给 Extension 的消息类型
public enum MainToExtensionAction: String, Codable {
    /// 发送完整菜单配置
    case menuConfig = "menu-config"
    /// 主程序启动通知
    case running = "running"
    /// 主程序退出通知
    case quit = "quit"
    /// 响应菜单配置请求（携带菜单配置）
    case requestConfig = "request-config"
}

/// Extension 发送给主程序的消息类型
public enum ExtensionToMainAction: String, Codable {
    /// 菜单点击事件
    case click = "click"
    /// 心跳消息
    case heartbeat = "heartbeat"
    /// 请求菜单配置
    case requestConfig = "request-config"
}

// MARK: - 消息载荷

/// 菜单配置消息载荷
public struct MenuConfigPayload: Codable {
    /// 菜单版本号，用于防重复和防乱序
    public let version: Int
    /// 动作菜单项列表
    public let actions: [ActionMenuItem]
    /// 应用菜单项列表
    public let apps: [AppMenuItem]
    /// 新建文件菜单项列表
    public let newFiles: [NewFileMenuItem]
    /// 常用目录菜单项列表
    public let commonDirs: [CommonDirMenuItem]
    /// 是否折叠动作菜单（默认 false）
    public let actionsCollapsed: Bool
    /// 是否折叠应用菜单（默认 false）
    public let appsCollapsed: Bool
    /// 是否折叠新建文件菜单（默认 true）
    public let newFilesCollapsed: Bool
    /// 是否折叠常用目录菜单（默认 true）
    public let commonDirsCollapsed: Bool

    init(
        version: Int = 1,
        actions: [ActionMenuItem] = [],
        apps: [AppMenuItem] = [],
        newFiles: [NewFileMenuItem] = [],
        commonDirs: [CommonDirMenuItem] = [],
        actionsCollapsed: Bool = false,
        appsCollapsed: Bool = false,
        newFilesCollapsed: Bool = true,
        commonDirsCollapsed: Bool = true
    ) {
        self.version = version
        self.actions = actions
        self.apps = apps
        self.newFiles = newFiles
        self.commonDirs = commonDirs
        self.actionsCollapsed = actionsCollapsed
        self.appsCollapsed = appsCollapsed
        self.newFilesCollapsed = newFilesCollapsed
        self.commonDirsCollapsed = commonDirsCollapsed
    }
}

/// 点击事件消息载荷
public struct ClickEventPayload: Codable {
    /// 点击的菜单项 ID
    public let itemId: String
    /// 菜单项类型
    public let itemType: MenuItemType
    /// 目标文件/目录路径列表
    public let target: [String]
    /// 触发来源
    public let trigger: MenuTrigger

    public init(
        itemId: String,
        itemType: MenuItemType,
        target: [String] = [],
        trigger: MenuTrigger
    ) {
        self.itemId = itemId
        self.itemType = itemType
        self.target = target
        self.trigger = trigger
    }
}

// MARK: - 辅助类型

/// 运行状态消息载荷（用于通知 Extension 主程序运行状态）
public struct RunningPayload: Codable {
    /// 监听目录列表
    public let directories: [String]

    init(directories: [String] = []) {
        self.directories = directories
    }
}

/// 菜单项类型
public enum MenuItemType: String, Codable {
    case action = "action"  // 动作菜单
    case app = "app"  // 应用菜单
    case newFile = "new-file"  // 新建文件
    case commonDir = "common-dir"  // 常用目录
}

/// 触发来源
public enum MenuTrigger: String, Codable {
    /// 选中文件/文件夹右键
    case contextualItems = "ctx-items"
    /// 空白处右键
    case contextualContainer = "ctx-container"
    /// 侧边栏右键
    case contextualSidebar = "ctx-sidebar"
    /// 工具栏
    case toolbar = "toolbar"
}

// MARK: - 消息结构

/// 主程序发送给 Extension 的消息（带签名）
public struct MainToExtensionMessage: Codable {
    /// 消息 ID，用于追踪和去重
    let id: UUID
    /// 消息类型
    let action: MainToExtensionAction
    /// JSON 编码的签名载荷数据（SignedPayload）
    let signedData: Data?

    init<T: Codable>(
        id: UUID = UUID(),
        action: MainToExtensionAction,
        data: T? = nil
    ) {
        self.id = id
        self.action = action

        do {
            let signedPayload = try MessageSecurity.sign(
                data,
                messageID: id,
                action: action.rawValue
            )
            signedData = try JSONEncoder().encode(signedPayload)
        } catch {
            logger.error("Failed to sign main-to-extension message: \(error)")
            self.signedData = nil
        }
    }
}

/// Extension 发送给主程序的消息（带签名）
public struct ExtensionToMainMessage: Codable {
    /// 消息 ID，用于追踪和去重
    let id: UUID
    /// 消息类型
    let action: ExtensionToMainAction
    /// JSON 编码的签名载荷数据（SignedPayload）
    let signedData: Data?

    init<T: Codable>(
        id: UUID = UUID(),
        action: ExtensionToMainAction,
        data: T? = nil
    ) {
        self.id = id
        self.action = action

        do {
            let signedPayload = try MessageSecurity.sign(
                data,
                messageID: id,
                action: action.rawValue
            )
            signedData = try JSONEncoder().encode(signedPayload)
        } catch {
            logger.error("Failed to sign extension-to-main message: \(error)")
            self.signedData = nil
        }
    }
}

// MARK: - Logger

/// Logger for Messager operations
private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.macpilot.rightclick",
    category: "Messager"
)

// MARK: - 消息管理器

/// 消息管理器 - 处理主程序和 Extension 之间的通信
public final class Messager: @unchecked Sendable {
    public static let shared = Messager()

    // 消息处理器存储
    // 安全说明：注册发生在启动阶段，之后处理器字典只读；
    // 注册与分发都可能来自不同线程，统一由 handlerLock 保护。
    private let handlerLock = NSLock()
    nonisolated(unsafe) private var mainToExtensionHandlers: [MainToExtensionAction: (Data?) -> Void] = [:]
    nonisolated(unsafe) private var extensionToMainHandlers: [ExtensionToMainAction: (Data?) -> Void] = [:]

    // 通知名称
    static let mainToExtensionNotification = "com.misswell.macpilot.MainToExtension"
    static let extensionToMainNotification = "com.misswell.macpilot.ExtensionToMain"

    private let isExtension: Bool
    private let replayGuard = MessageReplayGuard()

    public init() {
        // 判断当前是否为 Extension 进程
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        self.isExtension = bundleId == "com.misswell.macpilot.finder-sync"

        // Danger note: DistributedNotificationCenter 初始化线程安全
        let center = DistributedNotificationCenter.default()
        if isExtension {
            center.addObserver(
                self,
                selector: #selector(handleMainToExtensionMessage(_:)),
                name: NSNotification.Name(Self.mainToExtensionNotification),
                object: nil
            )
        } else {
            center.addObserver(
                self,
                selector: #selector(handleExtensionToMainMessage(_:)),
                name: NSNotification.Name(Self.extensionToMainNotification),
                object: nil
            )
        }
    }

    // MARK: - 发送消息（nonisolated，不访问 @MainActor 状态）

    /// 主程序发送消息给 Extension
    func sendToExtension<T: Codable>(_ action: MainToExtensionAction, data: T? = nil) {
        let message = MainToExtensionMessage(action: action, data: data)
        sendMessage(message, via: Self.mainToExtensionNotification)
        logger.debug("Sent to extension: \(action.rawValue)")
    }

    /// Extension 发送消息给主程序
    func sendToMain<T: Codable>(_ action: ExtensionToMainAction, data: T? = nil) {
        let message = ExtensionToMainMessage(action: action, data: data)
        sendMessage(message, via: Self.extensionToMainNotification)
        logger.debug("Sent to main: \(action.rawValue)")
    }

    /// 发送消息到通知中心
    private func sendMessage(_ message: some Encodable, via notificationName: String) {
        guard let jsonData = try? JSONEncoder().encode(message) else {
            logger.error("Failed to encode message")
            return
        }

        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to convert message to string")
            return
        }

        logger.debug("Sending message via \(notificationName)")
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(notificationName),
            object: jsonString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - 注册处理器

    /// Extension 注册主程序消息处理器
    public func onMainMessage(_ action: MainToExtensionAction, handler: @escaping (Data?) -> Void) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        mainToExtensionHandlers[action] = handler
    }

    /// 主程序注册 Extension 消息处理器
    public func onExtensionMessage(_ action: ExtensionToMainAction, handler: @escaping (Data?) -> Void) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        extensionToMainHandlers[action] = handler
    }

    // MARK: - 处理消息

    @objc private func handleMainToExtensionMessage(_ notification: NSNotification) {
        guard let jsonString = notification.object as? String,
              let jsonData = jsonString.data(using: .utf8) else {
            logger.error("Invalid message format")
            return
        }

        do {
            let message = try JSONDecoder().decode(MainToExtensionMessage.self, from: jsonData)
            logger.debug("Received main-to-extension message: \(message.action.rawValue)")

            guard let payload = authenticatedPayload(
                from: message.signedData,
                messageID: message.id,
                action: message.action.rawValue
            ) else {
                logger.warning("Rejected unauthenticated main-to-extension message")
                return
            }

            let handler = handlerLock.withLock { mainToExtensionHandlers[message.action] }
            if let handler {
                handler(payload)
            } else {
                logger.warning("No handler registered for action: \(message.action.rawValue)")
            }
        } catch {
            logger.error("Failed to decode message: \(error)")
        }
    }

    @objc private func handleExtensionToMainMessage(_ notification: NSNotification) {
        guard let jsonString = notification.object as? String,
              let jsonData = jsonString.data(using: .utf8) else {
            logger.error("Invalid message format")
            return
        }

        do {
            let message = try JSONDecoder().decode(ExtensionToMainMessage.self, from: jsonData)
            logger.debug("Received extension-to-main message: \(message.action.rawValue)")

            guard let payload = authenticatedPayload(
                from: message.signedData,
                messageID: message.id,
                action: message.action.rawValue
            ) else {
                logger.warning("Rejected unauthenticated extension-to-main message")
                return
            }

            let handler = handlerLock.withLock { extensionToMainHandlers[message.action] }
            if let handler {
                handler(payload)
            } else {
                logger.warning("No handler registered for action: \(message.action.rawValue)")
            }
        } catch {
            logger.error("Failed to decode message: \(error)")
        }
    }

    // MARK: - 便捷方法

    /// 主程序发送菜单配置给 Extension
    func sendMenuConfig(_ config: MenuConfigPayload) {
        sendToExtension(.menuConfig, data: config)
    }

    /// 发送主程序启动通知
    func sendRunningNotification(directories: [String] = []) {
        let payload = RunningPayload(directories: directories)
        sendToExtension(.running, data: payload)
    }

    /// 发送主程序退出通知
    func sendQuitNotification() {
        sendToExtension(.quit, data: Optional<Int>.none)
    }

    /// Extension 发送心跳
    public func sendHeartbeat() {
        sendToMain(.heartbeat, data: Optional<Int>.none)
    }

    /// 请求菜单配置
    public func requestMenuConfig() {
        sendToMain(.requestConfig, data: Optional<Int>.none)
    }

    /// Extension 发送点击事件
    public func sendClickEvent(_ event: ClickEventPayload) {
        sendToMain(.click, data: event)
    }

    // MARK: - 解码辅助

    /// Decode payload bytes that were authenticated before handler dispatch.
    public func decodeSignedData<T: Codable>(_ signedData: Data?, as type: T.Type = T.self) -> T? {
        guard let signedData = signedData else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: signedData)
        } catch {
            logger.error("Failed to decode signed data: \(error)")
            return nil
        }
    }

    private func authenticatedPayload(
        from signedData: Data?,
        messageID: UUID,
        action: String
    ) -> Data? {
        guard let signedData,
              let signed = try? JSONDecoder().decode(SignedPayload.self, from: signedData),
              let payload = MessageSecurity.verifiedPayload(
                  signed,
                  expectedMessageID: messageID,
                  expectedAction: action
              ),
              replayGuard.accept(
                  messageID,
                  issuedAtMilliseconds: signed.issuedAtMilliseconds
              ) else {
            return nil
        }
        return payload
    }
}
