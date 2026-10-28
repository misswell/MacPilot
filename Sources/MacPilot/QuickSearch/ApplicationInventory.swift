//
//  ApplicationInventory.swift
//  MacPilot
//
//  应用清单：在后台把已安装的 .app 收成一份轻量元数据索引（名称与它的别称、路径、
//  Bundle ID、拼音、用途标签等搜索字段），磁盘枚举与 Info.plist 读取都不在主线程。
//  这里没有定时扫描——面板打开时按过期状态补一次，其余时间零开销。
//

import AppKit
import Foundation
import MacPilotDockGroupsCore

/// 索引里的一条应用。只存轻量元数据，图标与运行状态都不在这里。
struct QuickSearchApplicationEntry: Sendable, Equatable {
    /// 稳定 ID：标准化路径。同一个 Bundle ID 的不同安装路径是两份真实存在的
    /// 版本，不能无条件合并成一条，否则用户会丢版本。
    let id: String
    let name: String
    let path: String
    let bundleIdentifier: String?
    /// 索引阶段算好的匹配字段（含拼音），输入时不再重算。
    let fields: QuickSearchSearchFields
    let directoryDisplayName: String
    let url: URL

    init(
        url: URL,
        name: String,
        bundleIdentifier: String?,
        alternateNames: [String] = [],
        tags: [String] = [],
        descriptions: [String] = [],
        inferredKeywords: [String] = []
    ) {
        let standardized = url.standardizedFileURL
        self.url = standardized
        self.path = standardized.path
        self.id = standardized.path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.fields = QuickSearchSearchFields(
            title: name,
            alternateTitles: alternateNames,
            tags: tags,
            description: descriptions.joined(separator: "\n"),
            extraKeywords: inferredKeywords
        )
        self.directoryDisplayName = standardized.deletingLastPathComponent().lastPathComponent
    }

    /// 用途标签的原样形式，行上解释命中原因时用。
    var displayTags: [String] { fields.tags.map(\.display) }
}

/// 运行中的应用，用于把只装在非默认目录的应用补进索引。
struct QuickSearchRunningApplication: Sendable, Equatable {
    let url: URL
    let bundleIdentifier: String?
    let name: String?
}

enum QuickSearchScanFailure: String, Equatable, Sendable {
    /// 应用目录暂时读不到（权限、外接盘未挂载等）。
    case directoriesUnreadable
}

@MainActor
final class ApplicationInventory: ObservableObject {
    enum State: Equatable {
        case empty
        case building
        case ready
        case stale
    }

    /// 距上次成功构建超过这个时长即视为过期。只在面板打开时检查，不靠定时器。
    static let defaultFreshnessInterval: TimeInterval = 600

    private(set) var state: State = .empty
    private(set) var entries: [QuickSearchApplicationEntry] = []
    private(set) var builtAt: Date?
    private(set) var lastFailure: QuickSearchScanFailure?
    /// 运行中应用的 Bundle ID 集合。只影响标记，不改变索引内容。
    private(set) var runningBundleIdentifiers: Set<String> = []

    var extraDirectories: [String] = [] {
        didSet { if oldValue != extraDirectories { markStale() } }
    }
    var freshnessInterval: TimeInterval = ApplicationInventory.defaultFreshnessInterval
    /// 扫描落地后的回调（主 Actor）。面板可以据此把「索引还在建」刷成真实条数，
    /// 测试也能等到一个确定的完成点，不靠墙钟轮询。
    var onIndexRebuilt: (() -> Void)?

    /// 可注入的磁盘扫描（测试用假实现，绝不碰真实文件系统）。
    private let scanner: @Sendable ([URL]) -> [QuickSearchApplicationEntry]
    private let runningApplicationsProvider: @MainActor () -> [QuickSearchRunningApplication]
    private let baseDirectoriesProvider: @Sendable () -> [URL]
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    var isScanning: Bool { scanTask != nil }
    var entryCount: Int { entries.count }
    var hasIndex: Bool { !entries.isEmpty }

    init(
        scanner: (@Sendable ([URL]) -> [QuickSearchApplicationEntry])? = nil,
        runningApplicationsProvider: (@MainActor () -> [QuickSearchRunningApplication])? = nil,
        baseDirectoriesProvider: (@Sendable () -> [URL])? = nil
    ) {
        self.scanner = scanner ?? ApplicationInventory.scanInstalledEntries
        self.runningApplicationsProvider = runningApplicationsProvider ?? ApplicationInventory.workspaceRunningApplications
        self.baseDirectoriesProvider = baseDirectoriesProvider ?? { InstalledAppResolver.defaultSearchDirectories() }
    }

    // MARK: - 构建与过期

    /// 面板打开时调用：没有索引就建，过期就补，正在建则什么都不做。
    func refreshIfStale() {
        switch state {
        case .building: return
        case .empty, .stale: rebuild()
        case .ready:
            if isExpired { rebuild() }
        }
    }

    /// 重新扫描。`force == false` 时若已在扫描则直接返回。
    func rebuild(force: Bool = true) {
        guard force || scanTask == nil else { return }
        cancelPendingScan()
        state = .building
        lastFailure = nil
        scanGeneration += 1
        let generation = scanGeneration
        let directories = searchDirectories()
        let scanner = self.scanner
        // 磁盘枚举与 Info.plist 读取全部离开主线程；跨 actor 只传值类型。
        let worker = Task.detached(priority: .userInitiated) { scanner(directories) }
        scanTask = Task { [weak self] in
            let scanned = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.scanTask = nil
            self.apply(scanned)
        }
    }

    func markStale() {
        // 已经有索引才谈得上「过期」；空索引保持 empty，由 refreshIfStale 直接重建。
        if state == .ready { state = .stale }
    }

    /// 安装、删除、移动后的失效：路径不存在了就把这条摘掉并让索引过期。
    func invalidate(entryID id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        builtAt = nil
        state = entries.isEmpty ? .empty : .stale
    }

    var isExpired: Bool {
        guard let builtAt else { return true }
        return Date().timeIntervalSince(builtAt) >= freshnessInterval
    }

    /// 停用时丢弃在飞的扫描与内存索引。同步完成：退出流程不留后台任务。
    func shutdown() {
        cancelPendingScan()
        entries = []
        builtAt = nil
        runningBundleIdentifiers = []
        lastFailure = nil
        state = .empty
    }

    // MARK: - 运行状态

    /// 从 Workspace 同步运行状态。只读 `runningApplications`，不触碰目标进程。
    func syncRunningState() {
        let running = runningApplicationsProvider()
        runningBundleIdentifiers = Set(running.compactMap(\.bundleIdentifier))
        guard state != .building else { return }
        var known = Set(entries.map(\.id))
        let appended = runningCompactMap(running, &known)
        guard !appended.isEmpty else { return }
        entries.append(contentsOf: appended)
        sortEntries()
    }

    func isRunning(_ entry: QuickSearchApplicationEntry) -> Bool {
        guard let bundleIdentifier = entry.bundleIdentifier else { return false }
        return runningBundleIdentifiers.contains(bundleIdentifier)
    }

    // MARK: - 内部

    private func runningCompactMap(
        _ running: [QuickSearchRunningApplication],
        _ known: inout Set<String>
    ) -> [QuickSearchApplicationEntry] {
        var appended: [QuickSearchApplicationEntry] = []
        for application in running {
            let entry = Self.entry(for: application)
            guard known.insert(entry.id).inserted else { continue }
            appended.append(entry)
        }
        return appended
    }

    private func apply(_ scanned: [QuickSearchApplicationEntry]) {
        // 扫描返回空而索引非空：多半是目录暂时读不到，保留旧索引而不是清空它。
        if scanned.isEmpty, !entries.isEmpty {
            state = .ready
            lastFailure = .directoriesUnreadable
            onIndexRebuilt?()
            return
        }
        var seen = Set<String>()
        var merged: [QuickSearchApplicationEntry] = []
        merged.reserveCapacity(scanned.count)
        for entry in scanned where seen.insert(entry.id).inserted {
            merged.append(entry)
        }
        merged.append(contentsOf: runningCompactMap(runningApplicationsProvider(), &seen))
        entries = merged
        sortEntries()
        builtAt = Date()
        lastFailure = nil
        state = .ready
        onIndexRebuilt?()
    }

    private func sortEntries() {
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func cancelPendingScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
    }

    func searchDirectories() -> [URL] {
        var directories = baseDirectoriesProvider()
        for path in extraDirectories where !path.isEmpty {
            directories.append(URL(fileURLWithPath: path).standardizedFileURL)
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func entry(for application: QuickSearchRunningApplication) -> QuickSearchApplicationEntry {
        let fallbackName = application.url.deletingPathExtension().lastPathComponent
        let name = (application.name?.isEmpty == false) ? application.name! : fallbackName
        return QuickSearchApplicationEntry(url: application.url, name: name, bundleIdentifier: application.bundleIdentifier)
    }

    // MARK: - 真实扫描

    /// 复用 Dock Groups 的只读扫描：浅层目录枚举 + Bundle 名称/ID 读取，
    /// 不复制、不移动、不修改任何应用。
    ///
    /// 之后为每个应用再读一次 `Contents/Info.plist`，拿用途声明（分类、URL 方案、
    /// 文档类型）和未本地化的名字。这仍然只在那条已经扫到的路径上做一次 `Data`
    /// 读取，不新增目录遍历，而且整段都在后台线程。
    ///
    /// 直接用扫到的路径，**不**再按 Bundle ID 向 Launch Services 解析——
    /// 那样会把同一个 Bundle ID 的不同安装路径折叠成一条。
    nonisolated static func scanInstalledEntries(in directories: [URL]) -> [QuickSearchApplicationEntry] {
        entries(for: InstalledAppResolver.scanInstalledApps(in: directories), reader: QuickSearchAppInfoReader.read)
    }

    nonisolated static func entries(
        for references: [DockGroupApp],
        reader: (URL) -> QuickSearchAppInfoReader.Info
    ) -> [QuickSearchApplicationEntry] {
        var entries: [QuickSearchApplicationEntry] = []
        for reference in references {
            guard !Task.isCancelled else { return [] }
            guard !reference.path.isEmpty else { continue }
            let url = URL(fileURLWithPath: reference.path, isDirectory: true)
            let info = reader(url)
            guard !Task.isCancelled else { return [] }
            entries.append(QuickSearchApplicationEntry(
                url: url,
                name: reference.name,
                bundleIdentifier: reference.bundleIdentifier,
                alternateNames: info.alternateNames,
                tags: info.tags,
                descriptions: info.descriptions,
                inferredKeywords: info.inferredKeywords
            ))
        }
        return entries
    }

    static func workspaceRunningApplications() -> [QuickSearchRunningApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let url = application.bundleURL, url.pathExtension.lowercased() == "app" else { return nil }
            return QuickSearchRunningApplication(
                url: url,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName
            )
        }
    }
}
