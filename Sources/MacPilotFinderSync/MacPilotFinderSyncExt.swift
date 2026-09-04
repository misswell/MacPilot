//
//  MacPilotFinderSyncExt.swift
//  MacPilot
//
//  Finder Sync 扩展主体（菜单渲染与事件转发）。
//

import AppKit
import Cocoa
import FinderSync
import OSLog
import MacPilotRightClickKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.misswell.macpilot.finder-sync",
    category: "FinderSyncExt"
)

/// FinderSync Extension - 瘦 Extension 架构
/// 只负责菜单渲染和事件转发，不读取 SwiftData
class MacPilotFinderSyncExt: FIFinderSync, @unchecked Sendable {

    // MARK: - Properties

    /// 菜单配置缓存（内存缓存，从 Main App 推送）
    private var cachedMenuConfig: MenuConfigPayload?

    /// 图标内存缓存，避免每次构建菜单都重新创建 NSImage
    private var iconCache: [String: NSImage] = [:]

    /// 文件类型图标提供者
    private let iconProvider = FileTypeIconProvider.shared

    /// 消息管理器
    private let messager = Messager.shared

    /// 当前菜单触发类型（工具栏 or 右键）
    private var currentMenuKind: FIMenuKind = .contextualMenuForItems

    // MARK: - Initialization

    override init() {
        super.init()

        logger.info("MacPilotFinderSync launched from \(Bundle.main.bundlePath)")

        // 设置监听目录（全盘监听）
        setupObservingDirectories()

        // 注册消息处理器
        setupMessageHandlers()

        // 启动心跳机制
        startHeartbeat()

        // 主动请求菜单配置
        requestMenuConfig()
    }

    // MARK: - Directory Observing

    /// 设置监听目录（全盘监听）
    ///
    /// Observing "/" covers every reachable folder — /Users, /Applications,
    /// /opt, /tmp, external and network volumes (mounted under /Volumes) —
    /// which is what the original per-path list intended but missed for
    /// anything on the system volume outside /Users. FileProvider-backed
    /// locations (iCloud Drive, synced Desktop & Documents) still get no
    /// FinderSync menus; that is a macOS restriction on all FinderSync
    /// extensions, not something an observation URL can change.
    private func setupObservingDirectories() {
        let directories: Set<URL> = [URL(fileURLWithPath: "/")]
        FIFinderSyncController.default().directoryURLs = directories
        logger.info("Observing directories: \(directories.map { $0.path })")
    }

    // MARK: - Message Handling

    /// 注册消息处理器
    private func setupMessageHandlers() {
        // 处理主程序发送的菜单配置
        messager.onMainMessage(.menuConfig) { [weak self] data in
            guard let self = self else { return }
            // 使用 decodeSignedData 解码签名数据
            if let config = self.messager.decodeSignedData(data, as: MenuConfigPayload.self) {
                self.handleMenuConfig(config)
            } else {
                logger.warning("Invalid menu config data")
            }
        }

        // 处理主程序发送的 running 通知
        messager.onMainMessage(.running) { [weak self] data in
            guard let self = self else { return }
            if let payload = self.messager.decodeSignedData(data, as: RunningPayload.self) {
                logger.info("Received running notification: \(payload.directories)")
                // 可以根据 payload 更新监听目录
            }
        }

        // 处理主程序发送的退出通知
        messager.onMainMessage(.quit) { _ in
            logger.info("Received quit notification from main app")
            // 可以标记主程序已退出
        }
    }

    /// 处理菜单配置
    private func handleMenuConfig(_ config: MenuConfigPayload) {
        cachedMenuConfig = config
        iconCache.removeAll()
        logger.debug("Menu config cached: version=\(config.version), actions=\(config.actions.count), apps=\(config.apps.count), icons cleared")
    }

    /// 请求菜单配置
    private func requestMenuConfig() {
        logger.info("Requesting menu config from main app")
        messager.requestMenuConfig()
    }

    // MARK: - Heartbeat

    /// 启动心跳机制（每 10 秒发送一次）
    private func startHeartbeat() {
        scheduleHeartbeat()
    }

    private func scheduleHeartbeat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { @MainActor [weak self] in
            self?.messager.sendHeartbeat()
            self?.scheduleHeartbeat()
        }
    }

    // MARK: - Primary Finder Sync protocol methods

    override func beginObservingDirectory(at url: URL) {
        logger.debug("beginObservingDirectoryAtURL: \(url.path)")
    }

    override func endObservingDirectory(at url: URL) {
        logger.debug("endObservingDirectoryAtURL: \(url.path)")
    }

    override func requestBadgeIdentifier(for url: URL) {
        // 不设置任何徽章标识，避免 Finder 在项目上叠加 MacPilot 图标。
        // 非空徽章 ID 会使 Finder 在文件/磁盘图标上显示扩展的图标叠加层，
        // 这会导致移动磁盘和光盘等外部卷的图标被 MacPilot 图标覆盖。
        FIFinderSyncController.default().setBadgeIdentifier("", for: url)
    }

    // MARK: - Menu and toolbar item support

    override var toolbarItemName: String {
        return "MacPilot"
    }

    override var toolbarItemToolTip: String {
        return "MacPilot: Click for menu options"
    }

    override var toolbarItemImage: NSImage {
        let image = NSImage(named: "toolbar") ?? NSImage()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Building

    /// 构建并返回 Finder 上下文菜单
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        currentMenuKind = menuKind
        logger.info("构建菜单，触发方式: \(menuKind.rawValue)")

        let menu = NSMenu(title: "MacPilot")

        // 如果缓存为空，触发请求并返回加载中的菜单
        guard let config = cachedMenuConfig else {
            requestMenuConfig()
            menu.addItem(withTitle: AppLocalization.localized("MacPilot (loading...)"), action: nil, keyEquivalent: "")
            return menu
        }

        // 全部为空时给出明确反馈。
        if config.actions.isEmpty, config.apps.isEmpty, config.newFiles.isEmpty, config.commonDirs.isEmpty {
            let emptyItem = NSMenuItem(title: AppLocalization.localized("No items"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return menu
        }

        appendSection(
            to: menu,
            titleKey: "Actions",
            sectionSymbol: "bolt.square",
            collapsed: config.actionsCollapsed,
            items: actionItems(for: config.actions)
        )
        appendSection(
            to: menu,
            titleKey: "Open With",
            sectionSymbol: "app.badge",
            collapsed: config.appsCollapsed,
            items: appItems(for: config.apps)
        )
        appendSection(
            to: menu,
            titleKey: "New File",
            sectionSymbol: "doc.badge.plus",
            collapsed: config.newFilesCollapsed,
            items: newFileItems(for: config.newFiles)
        )
        appendSection(
            to: menu,
            titleKey: "Common Dirs",
            sectionSymbol: "folder.badge.gearshape",
            collapsed: config.commonDirsCollapsed,
            items: commonDirItems(for: config.commonDirs)
        )

        return menu
    }

    /// 构建一个菜单分组：折叠时渲染为子菜单，展开时渲染为分组标题 + 平铺项。
    /// 空分组直接跳过（与动作/应用/常用目录分组的既有行为一致）。
    private func appendSection(
        to menu: NSMenu,
        titleKey: String,
        sectionSymbol: String,
        collapsed: Bool,
        items: [NSMenuItem]
    ) {
        MenuSectionLayout.append(
            to: menu,
            title: AppLocalization.localized(titleKey),
            sectionSymbol: sectionSymbol,
            symbolLoader: { templateSymbol($0) },
            collapsed: collapsed,
            items: items
        )
    }

    private func actionItems(for actions: [ActionMenuItem]) -> [NSMenuItem] {
        actions.map { action in
            let item = NSMenuItem(
                title: AppLocalization.localizedActionName(id: action.id, fallback: action.name),
                action: #selector(handleActionClick(_:)),
                keyEquivalent: ""
            )
            item.tag = MenuTag.forAction(action.id)
            item.target = self
            if let icon = templateSymbol(action.icon) {
                item.image = icon
            }
            return item
        }
    }

    private func appItems(for apps: [AppMenuItem]) -> [NSMenuItem] {
        apps.map { app in
            let item = NSMenuItem(
                title: app.name,
                action: #selector(handleAppClick(_:)),
                keyEquivalent: ""
            )
            item.tag = MenuTag.forApp(app.id)
            item.target = self
            item.image = cachedAppIcon(app: app)
            return item
        }
    }

    private func newFileItems(for newFiles: [NewFileMenuItem]) -> [NSMenuItem] {
        newFiles.map { newFile in
            let item = NSMenuItem(
                title: newFile.name,
                action: #selector(handleNewFileClick(_:)),
                keyEquivalent: ""
            )
            item.tag = MenuTag.forNewFile(newFile.id)
            item.target = self
            item.image = iconProvider.icon(for: newFile.ext, fallbackSymbol: newFile.icon)
            item.image?.accessibilityDescription = newFile.name
            return item
        }
    }

    private func commonDirItems(for commonDirs: [CommonDirMenuItem]) -> [NSMenuItem] {
        commonDirs.map { commonDir in
            let item = NSMenuItem(
                title: commonDir.name,
                action: #selector(handleCommonDirClick(_:)),
                keyEquivalent: ""
            )
            item.tag = MenuTag.forCommonDir(commonDir.id)
            item.target = self
            item.image = loadIcon(named: commonDir.icon, accessibilityDescription: commonDir.name)
            return item
        }
    }

    // MARK: - Icon Helpers

    /// 获取 App 图标（带缓存）。菜单构建在主线程执行，无需额外调度。
    private func cachedAppIcon(app: AppMenuItem) -> NSImage? {
        if let appURL = app.appURL {
            let cacheKey = "app:\(appURL)"
            if let cached = iconCache[cacheKey] { return cached }
            let icon = NSWorkspace.shared.icon(forFile: appURL)
            if icon.size.width > 0 {
                iconCache[cacheKey] = icon
                return icon
            }
        }
        if let icon = NSImage(named: app.icon) { return icon }
        return templateSymbol(app.icon)
    }

    /// 加载 SF Symbol 并使用 hierarchicalColor 适配亮色/暗色模式（带缓存）
    private func templateSymbol(_ name: String) -> NSImage? {
        let cacheKey = "sf:\(name)"
        if let cached = iconCache[cacheKey] { return cached }
        let config = NSImage.SymbolConfiguration(hierarchicalColor: .labelColor)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        iconCache[cacheKey] = image
        return image
    }

    /// 从 Assets 或 SF Symbol 加载图标（带缓存）
    private func loadIcon(named iconName: String, accessibilityDescription description: String) -> NSImage? {
        let cacheKey = "load:\(iconName)"
        if let cached = iconCache[cacheKey] { return cached }
        if let icon = NSImage(named: iconName) {
            iconCache[cacheKey] = icon
            return icon
        }
        if let icon = templateSymbol(iconName) {
            iconCache[cacheKey] = icon
            return icon
        }
        let fallback = FileTypeIconProvider.resolvedFallbackSymbol(for: iconName)
        if let icon = templateSymbol(fallback) {
            iconCache[cacheKey] = icon
            return icon
        }
        return nil
    }

    // MARK: - Menu Action Handlers

    @objc private func handleActionClick(_ sender: NSMenuItem) {
        guard let config = cachedMenuConfig,
              let action = config.actions.first(where: { MenuTag.forAction($0.id) == sender.tag }) else {
            logger.warning("Action not found for tag: \(sender.tag)")
            return
        }

        logger.debug("Action clicked: \(action.name) (id: \(action.id))")

        // 获取选中的文件/目录
        let itemPaths = actionTargetPaths()
        logger.info("[Action] action target paths: \(itemPaths)")

        // 发送点击事件到主程序
        let event = ClickEventPayload(
            itemId: action.id,
            itemType: .action,
            target: itemPaths,
            trigger: getTriggerForMenuKind()
        )
        messager.sendClickEvent(event)
    }

    @objc private func handleAppClick(_ sender: NSMenuItem) {
        guard let config = cachedMenuConfig,
              let app = config.apps.first(where: { MenuTag.forApp($0.id) == sender.tag }) else {
            logger.warning("App not found for tag: \(sender.tag)")
            return
        }

        logger.debug("App clicked: \(app.name) (id: \(app.id))")

        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        let itemPaths = selectedItems.map { $0.path }
        logger.info("[App] selectedItemURLs 返回 \(selectedItems.count) 个文件: \(itemPaths)")

        let event = ClickEventPayload(
            itemId: app.id,
            itemType: .app,
            target: itemPaths,
            trigger: getTriggerForMenuKind()
        )
        logger.debug("Sending click event for app: \(app.name)")
        messager.sendClickEvent(event)
    }

    @objc private func handleNewFileClick(_ sender: NSMenuItem) {
        guard let config = cachedMenuConfig,
              let newFile = config.newFiles.first(where: { MenuTag.forNewFile($0.id) == sender.tag }) else {
            logger.warning("NewFile not found for tag: \(sender.tag)")
            return
        }
        let itemId = newFile.id
        logger.debug("NewFile clicked: \(newFile.name) (id: \(newFile.id))")

        let event = ClickEventPayload(
            itemId: itemId,
            itemType: .newFile,
            target: newFileTargetPaths(),
            trigger: getTriggerForMenuKind()
        )
        messager.sendClickEvent(event)
    }

    @objc private func handleCommonDirClick(_ sender: NSMenuItem) {
        guard let config = cachedMenuConfig,
              let commonDir = config.commonDirs.first(where: { MenuTag.forCommonDir($0.id) == sender.tag }) else {
            logger.warning("CommonDir not found for tag: \(sender.tag)")
            return
        }

        logger.debug("CommonDir clicked: \(commonDir.name) (id: \(commonDir.id))")

        // 使用常用目录自身的路径，而不是 Finder 当前选中的路径
        let target = commonDir.url.map { [$0] } ?? []

        let event = ClickEventPayload(
            itemId: commonDir.id,
            itemType: .commonDir,
            target: target,
            trigger: getTriggerForMenuKind()
        )
        messager.sendClickEvent(event)
    }

    // MARK: - Helper Methods

    /// 获取触发来源
    private func getTriggerForMenuKind() -> MenuTrigger {
        switch currentMenuKind {
        case .toolbarItemMenu:
            return .toolbar
        case .contextualMenuForItems:
            return .contextualItems
        case .contextualMenuForContainer:
            return .contextualContainer
        case .contextualMenuForSidebar:
            return .contextualSidebar
        default:
            return .contextualItems
        }
    }

    private func newFileTargetPaths() -> [String] {
        if currentMenuKind == .contextualMenuForContainer,
           let targetURL = FIFinderSyncController.default().targetedURL() {
            return [targetURL.path]
        }

        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        if !selectedItems.isEmpty {
            return selectedItems.map { $0.path }
        }

        if let targetURL = FIFinderSyncController.default().targetedURL() {
            return [targetURL.path]
        }

        return []
    }

    /// Context-menu actions need the targeted folder when the user clicks the
    /// blank area of a Finder window (there are no selected item URLs then).
    private func actionTargetPaths() -> [String] {
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        if !selectedItems.isEmpty {
            return selectedItems.map { $0.path }
        }

        if let targetURL = FIFinderSyncController.default().targetedURL() {
            return [targetURL.path]
        }

        return []
    }
}
