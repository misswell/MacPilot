//
//  DockGroupsModel.swift
//  MacPilot
//
//  Dock Groups 的运行时模型：连接 MacPilot UI、
//  `groups.json` 存储与 Helper App 管理。
//
//  安全边界（需求第 2、23、25 节）：
//  - 只读写 MacPilot 自己的目录；
//  - 对第三方 App 只做「解析 + 启动 + 激活 + 读图标」；
//  - 功能关闭时不做任何扫描、不监听 Workspace、不跑后台 Timer。
//

import AppKit
import Combine
import Foundation
import MacPilotDockGroupsCore
import OSLog

@MainActor
final class DockGroupsModel: ObservableObject, ManagedFeature {
    let identifier = "dockGroups"
    var isRunning: Bool { isActive }
    func start() { activateFromConfiguration() }
    func stop() { shutdown() }
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "DockGroups")

    @Published private(set) var settings = DockGroupsSettings()
    @Published private(set) var groups: [DockGroup] = []
    /// 配置损坏等需要用户知情的提示（需求第 16 节：不崩溃）。
    @Published private(set) var configWarning: String?
    /// Helper 生成失败等提示（视图按当前语言展示对应文案）。
    @Published private(set) var helperUnavailable = false
    @Published private(set) var runningBundleIdentifiers: Set<String> = []
    @Published private(set) var isRegeneratingHelpers = false

    /// 由 MacPilotModel 注入，用于把功能开关写回 config.json。
    var persist: (() -> Void)?

    let helperManager: DockHelperManager
    private let store: DockGroupStore

    private var isActive = false
    private let runningTask = BackgroundTask()
    private let workspaceObservers = ObserverBag()
    /// 系统深浅外观变化（`.icns` 没有外观变体，只能靠重建 Helper 让 Dock 图标跟上）。
    private let appearanceObservers = ObserverBag()
    /// 外观 / Dock 布局变化后的合并刷新，避免连续通知触发多次重建。
    private var dockRefreshTask: Task<Void, Never>?
    /// 读取 Dock 图标位置的最小间隔：Dock 树的读取要跨进程，别被高频通知打满。
    private var lastDockTileRefresh: Date = .distantPast
    /// 只放已经按尺寸限制过的缩略图（见 DockGroupIconThumbnail）。
    private var iconCache: [String: NSImage] = [:]
    /// 需求第 12 节：图标缩略图缓存在 ~/Library/Caches/MacPilot/DockGroups/。
    private let iconCacheStore: DockGroupIconCache

    /// 已经排队或正在加载的图标，避免同一行被重复请求。
    private var pendingIconKeys: Set<String> = []
    /// 取图失败的键（App 被删、缓存目录不可写等），本进程内不再重试。
    private var failedIconKeys: Set<String> = []
    private var iconLoadQueue: [IconLoadRequest] = []
    private var activeIconLoads = 0
    /// 同时在跑的图标加载上限：既不排队几秒，也不把图标服务打满。
    private let maxConcurrentIconLoads = 4
    /// 图标就绪后合并刷新：271 个图标逐个 `objectWillChange` 会引发 271 轮重绘。
    private var iconFlushScheduled = false
    /// 图标加载完成后自增，SwiftUI 依赖它重新取图。
    @Published private(set) var iconRevision = 0

    /// 已渲染的分组图标：key 是「分组 + 尺寸」，值是签名与图。
    private var groupIconCache: [String: NSImage] = [:]
    private var groupIconSignatures: [String: String] = [:]

    private struct IconLoadRequest {
        let key: DockGroupIconCacheKey
        let url: URL
        let pointSize: CGFloat
    }

    init(
        store: DockGroupStore = DockGroupStore(),
        helperManager: DockHelperManager = DockHelperManager(),
        iconCacheDirectory: URL = DockGroupPaths.defaultCacheDirectory()
    ) {
        self.store = store
        self.helperManager = helperManager
        iconCacheStore = DockGroupIconCache(directory: iconCacheDirectory)
    }

    // MARK: - 生命周期

    func applyLoadedSettings(_ loaded: DockGroupsSettings) {
        settings = loaded
        reload()
    }

    /// 需求第 22 节：功能关闭时不做任何后台工作。
    func activateFromConfiguration() {
        guard settings.isEnabled else { return }
        isActive = true
        reload()
        // 早期版本把 1024×1024 原图当缩略图存过（单个 1–3 MB），顺手清一次。
        let purged = iconCacheStore.removeOversizedThumbnails()
        if purged > 0 {
            DiagnosticLog.write("DockGroups", "Removed \(purged) oversized icon thumbnails from the cache.")
        }
        startObservingWorkspace()
        ensureHelpersExistIfNeeded()
        scheduleDockRefresh()
    }

    func shutdown() {
        isActive = false
        stopObservingWorkspace()
        stopObservingAppearance()
        dockRefreshTask?.cancel()
        dockRefreshTask = nil
        stopMonitoring()
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            activateFromConfiguration()
            // 用户在当前页面直接打开开关时，立刻接上运行状态轮询。
            if isPageVisible { startMonitoring() }
        } else {
            shutdown()
        }
        persist?()
    }

    func setDefaultLayout(_ layout: DockGroupLayout) {
        guard settings.defaultLayout != layout else { return }
        settings.defaultLayout = layout
        persist?()
    }

    func setShowsRunningState(_ shows: Bool) {
        guard settings.showsRunningState != shows else { return }
        settings.showsRunningState = shows
        if shows, isPageVisible { startMonitoring() }
        persist?()
    }

    /// 页面可见时才轮询运行状态（与内存监控页一致的按需生命周期）。
    private(set) var isPageVisible = false

    func startMonitoring() {
        isPageVisible = true
        // 需求第 22 节：功能关闭时不监听 Workspace、不跑轮询。
        guard settings.isEnabled else { return }
        refreshRunningState()
        guard !runningTask.isRunning else { return }
        runningTask.start(interval: .seconds(3)) { [weak self] in
            self?.refreshRunningState()
        }
    }

    func stopMonitoring() {
        isPageVisible = false
        runningTask.stop()
    }

    // MARK: - 读取

    /// 需求第 6、16 节：按 bundleIdentifier 优先解析，path 兜底；找不到就标记未找到。
    func resolvedApps(for group: DockGroup) -> [ResolvedInstalledApp] {
        group.apps.map {
            InstalledAppResolver.resolve($0, runningBundleIdentifiers: runningBundleIdentifiers)
        }
    }

    func resolvedApp(_ reference: DockGroupApp) -> ResolvedInstalledApp {
        InstalledAppResolver.resolve(reference, runningBundleIdentifiers: runningBundleIdentifiers)
    }

    /// 图标命中缓存就同步返回；未命中则排队后台加载并先返回 nil（视图显示占位图），
    /// 加载完成后由 `iconRevision` 触发刷新。
    ///
    /// 这里绝不在视图 body 里同步取图标：应用选择器一次会列出两百多个 App，
    /// 同步取图会把主线程按在图标服务上几十秒（2026-09-14 的卡死事件）。
    func icon(for reference: DockGroupApp, size: CGFloat = 64) -> NSImage? {
        let resolved = resolvedApp(reference)
        return icon(for: resolved, size: size)
    }

    /// 需求第 12 节：图标只从系统读取 + 缓存 MacPilot 自己的 PNG 缩略图。
    /// 缓存键带 App 版本，第三方 App 升级换图标后会自然失效重取。
    func icon(for resolved: ResolvedInstalledApp, size: CGFloat = 64) -> NSImage? {
        guard let url = resolved.url else { return nil }
        let key = DockGroupIconCacheKey(
            bundleIdentifier: resolved.bundleIdentifier ?? url.path,
            version: resolved.version ?? "",
            size: Int(size)
        )
        return cachedIcon(for: key, url: url, pointSize: size)
    }

    private func cachedIcon(for key: DockGroupIconCacheKey, url: URL, pointSize: CGFloat) -> NSImage? {
        if let cached = iconCache[key.fileName] { return cached }
        if let cached = iconCacheStore.image(for: key) {
            iconCache[key.fileName] = cached
            return cached
        }
        guard !failedIconKeys.contains(key.fileName) else { return nil }
        requestIcon(key: key, url: url, pointSize: pointSize)
        return nil
    }

    // MARK: - 图标异步加载

    private func requestIcon(key: DockGroupIconCacheKey, url: URL, pointSize: CGFloat) {
        guard !pendingIconKeys.contains(key.fileName) else { return }
        pendingIconKeys.insert(key.fileName)
        iconLoadQueue.append(IconLoadRequest(key: key, url: url, pointSize: pointSize))
        drainIconQueue()
    }

    private func drainIconQueue() {
        while activeIconLoads < maxConcurrentIconLoads, !iconLoadQueue.isEmpty {
            let request = iconLoadQueue.removeFirst()
            activeIconLoads += 1
            Task { [weak self] in
                // 取图 + 按尺寸重绘 + PNG 编码全部离开主线程；跨 actor 只传 Data。
                let data = await Task.detached(priority: .userInitiated) {
                    DockGroupIconThumbnail.pngData(forFileAt: request.url, pointSize: request.pointSize)
                }.value
                guard let self else { return }
                self.activeIconLoads -= 1
                self.pendingIconKeys.remove(request.key.fileName)
                if let data, let image = self.iconCacheStore.storeThumbnailPNG(data, for: request.key) {
                    self.iconCache[request.key.fileName] = image
                } else {
                    // 取不到就记下来，避免每次重绘都重新问一遍图标服务。
                    self.failedIconKeys.insert(request.key.fileName)
                }
                self.scheduleIconFlush()
                self.drainIconQueue()
            }
        }
    }

    /// 图标到达后合并刷新，避免 271 个图标触发 271 轮重绘。
    private func scheduleIconFlush() {
        guard !iconFlushScheduled else { return }
        iconFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.iconFlushScheduled = false
            self.iconRevision &+= 1
        }
    }

    private func cancelPendingIconLoads() {
        iconLoadQueue.removeAll()
        pendingIconKeys.removeAll()
        failedIconKeys.removeAll()
    }

    /// 分组图标按「分组内容签名 + 尺寸 + 深浅外观」缓存：编辑器标题栏每次 body
    /// 求值都会调它，不缓存就会不停重绘合成图标（内部还要再取成员图标）。
    func groupIcon(
        for group: DockGroup,
        size: CGFloat,
        appearance: DockGroupIconAppearance = .current()
    ) -> NSImage {
        let memberURLs = group.apps.compactMap { InstalledAppResolver.resolveURL($0) }
        let cacheKey = "\(group.id)@\(Int(size))@\(appearance)"
        let signature = Self.groupIconSignature(group: group, memberURLs: memberURLs, size: size)
        if groupIconSignatures[cacheKey] == signature, let cached = groupIconCache[cacheKey] {
            return cached
        }
        let image = DockGroupIconRenderer.image(
            for: group,
            size: size,
            memberIconURLs: memberURLs,
            customIconDirectory: helperManager.rootDirectory,
            appearance: appearance
        )
        groupIconSignatures[cacheKey] = signature
        groupIconCache[cacheKey] = image
        return image
    }

    private static func groupIconSignature(group: DockGroup, memberURLs: [URL], size: CGFloat) -> String {
        [
            group.id,
            group.icon.source.rawValue,
            group.icon.value,
            String(group.updatedAt.timeIntervalSince1970),
            String(Int(size)),
            memberURLs.map(\.path).joined(separator: "|")
        ].joined(separator: ">")
    }

    /// 分组内容变化后，占位图与合成图标都可能失效。
    private func invalidateRenderedIcons() {
        groupIconCache.removeAll()
        groupIconSignatures.removeAll()
        cancelPendingIconLoads()
    }

    /// 需求第 13 节：自定义图片只拷贝用户选择的图片文件到 MacPilot 自己的目录，
    /// 原文件保持只读，更不会写进任何第三方 App。
    @discardableResult
    func importCustomIcon(from sourceURL: URL, for groupID: String) -> Bool {
        guard let image = NSImage(contentsOf: sourceURL),
              let png = ICNSWriter.renderPNG(image: image, pixels: 1024) else { return false }

        let fileName = "\(DockGroupIdentifier.sanitizedID(groupID))-\(UUID().uuidString.prefix(8)).png"
        let destination = DockGroupPaths.customIconURL(in: helperManager.rootDirectory, fileName: fileName)
        do {
            let target = try ManagedPathGuard.requireManaged(destination, root: helperManager.rootDirectory)
            try TargetAppAccessPolicy.requireWrite(.write, at: target, managedRoot: helperManager.rootDirectory)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: target, options: .atomic)
        } catch {
            Self.logger.error("Failed to import custom Dock group icon: \(error.localizedDescription, privacy: .public)")
            return false
        }

        setIcon(DockGroupIcon(source: .customImage, value: fileName), for: groupID)
        return true
    }

    func helperAppURL(for group: DockGroup) -> URL {
        helperManager.helperAppURL(for: group)
    }

    func helperExists(for group: DockGroup) -> Bool {
        helperManager.helperExists(for: group)
    }

    // MARK: - 读写配置

    func reload() {
        switch store.load() {
        case let .loaded(document):
            groups = document.groups
            configWarning = nil
        case .missing:
            groups = []
            configWarning = nil
        case let .corrupt(message):
            groups = []
            configWarning = message
        }
        invalidateRenderedIcons()
    }

    private func document() -> DockGroupsDocument {
        DockGroupsDocument(groups: groups)
    }

    private func commit(_ mutate: (inout DockGroupsDocument) -> Void) {
        var document = self.document()
        mutate(&document)
        groups = document.groups
        invalidateRenderedIcons()
        do {
            try store.save(document)
            configWarning = nil
        } catch {
            configWarning = error.localizedDescription
            Self.logger.error("Failed to save Dock Groups: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 分组编辑

    @discardableResult
    func createGroup(named name: String) -> DockGroup {
        var created = DockGroup(id: "", name: name)
        commit { document in
            created = DockGroupDocumentEditor.createGroup(named: name, in: &document)
            if let index = document.groups.firstIndex(where: { $0.id == created.id }) {
                document.groups[index].layout = settings.defaultLayout
                created = document.groups[index]
            }
        }
        regenerateHelper(for: created)
        return created
    }

    func renameGroup(_ groupID: String, to name: String) {
        var renamed: DockGroup?
        commit { document in
            _ = DockGroupDocumentEditor.rename(groupID: groupID, to: name, in: &document)
            renamed = document.groups.first { $0.id == groupID }
        }
        // 名称变化会改变 Helper 的 .app 文件名，需要重新生成并清理旧文件。
        if let renamed {
            regenerateHelper(for: renamed)
            helperManager.removeStaleHelpers(keeping: groups)
        }
    }

    func deleteGroup(_ groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        commit { document in
            _ = DockGroupDocumentEditor.removeGroup(groupID, in: &document)
        }
        // 需求第 15 节：只删除 MacPilot 自己创建的 Helper App 与配置。
        helperManager.removeHelper(for: group)
    }

    func setIcon(_ icon: DockGroupIcon, for groupID: String) {
        updateGroup(groupID) { $0.icon = icon }
    }

    func setLayout(_ layout: DockGroupLayout, for groupID: String) {
        updateGroup(groupID) { $0.layout = layout }
    }

    /// 「图标外观」：跟随系统 / 固定浅色 / 固定深色。
    /// `.icns` 没有外观变体，所以改动最终体现为重建 Helper（`updateGroup` 已经会做）。
    func setIconStyle(_ style: DockGroupIconStyle, for groupID: String) {
        updateGroup(groupID) { $0.iconStyle = style }
    }

    private func updateGroup(_ groupID: String, _ mutate: (inout DockGroup) -> Void) {
        var updated: DockGroup?
        commit { document in
            guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else { return }
            mutate(&document.groups[index])
            document.groups[index].updatedAt = DockGroupTimestamp.now()
            updated = document.groups[index]
        }
        if let updated { regenerateHelper(for: updated) }
    }

    // MARK: - App 引用编辑

    /// 需求第 11 节：拖入 `.app` 只保存引用，不复制、不移动、不修改。
    @discardableResult
    func addApp(at url: URL, to groupID: String) -> Bool {
        guard let reference = InstalledAppResolver.makeReference(from: url) else { return false }
        return addApp(reference, to: groupID)
    }

    @discardableResult
    func addApp(_ reference: DockGroupApp, to groupID: String) -> Bool {
        var added = false
        commit { document in
            added = DockGroupDocumentEditor.addApp(reference, to: groupID, in: &document)
        }
        if added, let group = groups.first(where: { $0.id == groupID }) {
            regenerateHelper(for: group)
        }
        return added
    }

    func removeApp(_ appID: UUID, from groupID: String) {
        var removed = false
        commit { document in
            removed = DockGroupDocumentEditor.removeApp(appID, from: groupID, in: &document)
        }
        if removed, let group = groups.first(where: { $0.id == groupID }) {
            regenerateHelper(for: group)
        }
    }

    func moveApps(in groupID: String, from source: IndexSet, to destination: Int) {
        // 顺序变化不影响 Helper App 本身，只更新配置。
        commit { document in
            _ = DockGroupDocumentEditor.moveApps(in: groupID, from: source, to: destination, in: &document)
        }
    }

    /// 需求第 16 节：应用被移动后提供「重新定位」，只改引用。
    @discardableResult
    func relocateApp(_ appID: UUID, in groupID: String, to url: URL) -> Bool {
        guard let reference = InstalledAppResolver.makeReference(from: url) else { return false }
        var relocated = false
        commit { document in
            relocated = DockGroupDocumentEditor.relocateApp(appID, in: groupID, to: reference, in: &document)
        }
        if relocated, let group = groups.first(where: { $0.id == groupID }) {
            regenerateHelper(for: group)
        }
        return relocated
    }

    // MARK: - Helper 管理

    func regenerateHelper(for group: DockGroup) {
        // 需求第 22 节：功能关闭时不运行任何 Helper 管理任务。
        guard settings.isEnabled else { return }
        let iconURLs = group.apps.compactMap { InstalledAppResolver.resolveURL($0) }
        if helperManager.ensureHelper(for: group, memberIconURLs: iconURLs) == nil {
            helperUnavailable = true
        }
        scheduleDockRefresh()
    }

    func regenerateAllHelpers() {
        guard isActive else { return }
        isRegeneratingHelpers = true
        helperUnavailable = false
        defer { isRegeneratingHelpers = false }
        ensureHelpersExistIfNeeded(force: true)
    }

    func revealHelper(for group: DockGroup) {
        helperManager.revealInFinder(for: group)
    }

    func revealGroupsFolder() {
        helperManager.revealGroupsFolder()
    }

    /// 启动时做一次「缺失 / 版本过期就重做」的轻量校验，避免每次启动都无脑重写磁盘。
    private func ensureHelpersExistIfNeeded(force: Bool = false) {
        guard settings.isEnabled, helperManager.isHelperExecutableAvailable else { return }
        var missing = false
        for group in groups {
            if force || helperManager.helperNeedsRegeneration(for: group) {
                regenerateHelper(for: group)
                missing = true
            }
        }
        if missing {
            helperManager.removeStaleHelpers(keeping: groups)
        }
    }

    // MARK: - 运行状态

    /// 需求第 9 节：只用公开的 NSWorkspace 运行列表，不接触目标进程内部。
    func refreshRunningState() {
        runningBundleIdentifiers = InstalledAppResolver.runningBundleIdentifiers()
    }

    private func startObservingWorkspace() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            // Dock 里图标的位置会随应用启停、Dock 设置变化而整体平移，
            // 所以每次前台应用切换都顺手刷新一次（有节流）。
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didWakeNotification
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRunningState()
                    self?.scheduleDockRefresh()
                }
            }
            workspaceObservers.add(observer, center: center)
        }

        let appearanceCenter = DistributedNotificationCenter.default()
        appearanceObservers.add(appearanceCenter.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleDockRefresh() }
        }, center: appearanceCenter)
    }

    private func stopObservingWorkspace() {
        workspaceObservers.removeAll()
    }

    private func stopObservingAppearance() {
        appearanceObservers.removeAll()
    }

    // MARK: - Dock 图标位置

    /// 合并刷新：外观变化要重建 Helper，Dock 布局变化要重读图标位置。
    /// 系统会连着发好几条通知，这里合成一次（300ms）。
    private func scheduleDockRefresh() {
        guard settings.isEnabled else { return }
        dockRefreshTask?.cancel()
        dockRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            // 外观变了：跟随系统的分组需要按新外观重建 Helper（Info.plist 里记录了外观）。
            self.ensureHelpersExistIfNeeded()
            self.refreshDockTileAnchors()
        }
    }

    /// 读出 Dock 上每个分组图标的位置并写进配置（Helper 没有辅助功能授权，只能读这里）。
    ///
    /// 位置没变就不写盘：Dock 布局在大多数时候是稳定的，而写配置会动用整个文档。
    func refreshDockTileAnchors() {
        guard settings.isEnabled, isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDockTileRefresh) >= 1 else { return }
        lastDockTileRefresh = now

        let helperURLs = groups.map { helperManager.helperAppURL(for: $0) }
        let rects = DockTileLocator.tileRects(forHelperAppsAt: helperURLs)
        DiagnosticLog.write(
            "DockGroups",
            "Dock tile anchors: trusted=\(DockTileLocator.isTrusted) groups=\(helperURLs.count) found=\(rects.count)"
        )
        guard !rects.isEmpty else { return }

        var document = self.document()
        var updated = 0
        for index in document.groups.indices {
            let group = document.groups[index]
            let path = helperManager.helperAppURL(for: group).standardizedFileURL.path
            guard let rect = rects[path] else { continue }
            let tile = DockGroupDockTile(rect: rect)
            if let existing = group.dockTile, existing.isClose(to: tile) { continue }
            document.groups[index].dockTile = tile
            updated += 1
        }
        guard updated > 0 else { return }

        groups = document.groups
        do {
            try store.save(document)
            configWarning = nil
            DiagnosticLog.write("DockGroups", "Published Dock tile anchors for \(updated) group(s)")
        } catch {
            configWarning = error.localizedDescription
            Self.logger.error("Failed to save Dock tile anchors: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 诊断

    /// 需求第 30 节自动化测试之外的自检入口：确认管理目录里没有第三方 App。
    func managedArtifactPaths() -> [String] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: helperManager.rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.map(\.path).sorted()
    }

    /// 需求第 26 节：卸载 / 清理 Dock Groups 时，只删除 MacPilot 自己的东西——
    /// Helper App、分组配置、自定义图标、图标缓存。
    ///
    /// 第三方 App 完全不在删除范围内：所有删除都经过 `ManagedPathGuard`
    /// （目标必须位于 MacPilot 自己的目录内）与「只删自己生成的 App」校验。
    /// - Returns: 是否清理干净（有残留时返回 false，UI 会提示）。
    @discardableResult
    func removeAllGroupData() -> Bool {
        stopMonitoring()
        invalidateRenderedIcons()
        let helpersRemoved = helperManager.removeAllHelpers()
        let configRemoved = store.removeGroupsFile()
        let iconsRemoved = store.removeCustomIcons()
        iconCache.removeAll()
        iconCacheStore.removeAll()

        let owned = DockGroupsDocument(groups: [])
        groups = owned.groups
        configWarning = nil
        DiagnosticLog.write(
            "DockGroups",
            "Removed all Dock Groups data (helpers: \(helpersRemoved), config: \(configRemoved), icons: \(iconsRemoved))."
        )
        return helpersRemoved && configRemoved && iconsRemoved
    }
}
