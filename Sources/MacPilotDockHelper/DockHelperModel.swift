//
//  DockHelperModel.swift
//  MacPilotDockHelper
//
//  需求第 6、7、9、10、24 节：Helper 的职责只有四件事——
//  读取分组配置、显示浮层、启动/激活 App、打开 MacPilot 设置。
//
//  Helper 由 MacPilot 生成，不加载外部 dylib、不执行第三方脚本、
//  不运行 shell 命令，也绝不修改任何第三方 App。
//
//  性能约定（见 SUMMARY「Dock 分组：点开即现」）：
//  展开浮层分成两步，**面板先上屏、内容后到**：
//
//  1. `loadConfiguration()`：只读 `groups.json`（毫秒级），面板尺寸只取决于它，
//     所以这一步之后就能建面板并显示；
//  2. `loadContent()`：解析版本 / 运行状态、渲染图标，全部在面板已经出现在
//     屏幕上之后进行，每画一个图标让出一次主线程。
//
//  于是「按图标服务的速度」不再决定「浮层出现的速度」。图标结果留在内存里
//  （`Entry.icon`），不在每次 SwiftUI body 求值时重画；2 秒一次的运行状态轮询
//  也只改 `isRunning`，不重新解析（原先每次轮询都要读盘 + 问 LaunchServices）。
//

import AppKit
import Combine
import MacPilotDockGroupsCore
import SwiftUI

@MainActor
final class DockHelperModel: ObservableObject {
    /// 浮层里的一格/一行。
    /// `resolved` 与 `icon` 都是**后到**的：面板先按配置里的原始引用出现，
    /// 解析结果与图标随后补齐，因此两者都必须是可空的。
    struct Entry: Identifiable {
        let reference: DockGroupApp
        var resolved: ResolvedInstalledApp?
        var icon: NSImage?
        /// 图标对应的缓存键（Bundle ID + 版本 + 尺寸）：键没变就不重画。
        var iconKey: String?

        var id: UUID { reference.id }

        var displayName: String {
            let live = resolved?.displayName ?? ""
            if !live.isEmpty { return live }
            return reference.name.isEmpty ? reference.path : reference.name
        }

        /// 只在**已经解析完**且确实找不到时才说「应用未找到」；
        /// 还在解析中时按正常状态显示，避免闪一下错误样式。
        var isMissing: Bool { resolved.map { !$0.isInstalled } ?? false }
        var isRunning: Bool { resolved?.isRunning ?? false }
    }

    /// 浮层里图标的目标尺寸（点）。图标准备好之前只显示占位方块。
    static let iconSize: CGFloat = 56

    @Published private(set) var group: DockGroup?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var errorMessage: String?

    let language: DockHelperLanguage
    private let store: DockGroupStore
    private let groupID: String?
    private var refreshTimer: Timer?
    /// 每次重新读配置都自增：让上一轮还没跑完的异步加载结果作废。
    private var contentGeneration = 0

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        rootDirectory: URL = DockGroupPaths.defaultRootDirectory(),
        language: DockHelperLanguage = .system
    ) {
        self.language = language
        store = DockGroupStore(rootDirectory: rootDirectory)
        groupID = DockGroupIdentifier.groupID(fromHelperBundleIdentifier: bundleIdentifier)
    }

    var groupName: String {
        group?.name ?? groupID ?? "Dock Group"
    }

    func t(_ key: String) -> String {
        DockHelperStrings.value(key, language: language)
    }

    // MARK: - 第一步：只读配置（毫秒级）

    /// 读取分组配置并立刻铺好占位条目。
    ///
    /// 这一步之后 `group` 与每个 App 的名字就是对的，面板可以马上显示；
    /// 版本号、运行状态与图标都留到 `loadContent()`。
    func loadConfiguration() {
        contentGeneration += 1
        errorMessage = nil

        guard groupID != nil else {
            group = nil
            entries = []
            return
        }
        switch store.load() {
        case let .loaded(document):
            group = groupID.flatMap { document.group(withID: $0) }
        case .missing, .corrupt:
            group = nil
        }

        // 重新读配置时保留「引用没变」的条目：热进程再次展开时不会闪一下占位图。
        let previous = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = (group?.apps ?? []).map { reference in
            var entry = Entry(reference: reference, resolved: nil, icon: nil, iconKey: nil)
            if let old = previous[reference.id], old.reference == reference {
                entry.resolved = old.resolved
                entry.icon = old.icon
                entry.iconKey = old.iconKey
            }
            return entry
        }
    }

    // MARK: - 第二步：解析内容（面板已经在屏幕上之后再调用）

    /// 后台开始解析与画图标；面板此刻已经在屏幕上，所以这一步不影响出现速度。
    func startLoadingContent() {
        Task { [weak self] in
            await self?.loadContent()
        }
    }

    /// 解析每个 App 的版本 / 运行状态，然后逐个渲染图标。
    /// 每次 `await Task.yield()` 都把主线程还给 SwiftUI，图标因此是「渐次到位」的。
    func loadContent() async {
        let generation = contentGeneration
        guard let group, !group.apps.isEmpty else { return }

        let running = InstalledAppResolver.runningBundleIdentifiers()
        var resolved: [ResolvedInstalledApp] = []
        resolved.reserveCapacity(group.apps.count)
        for reference in group.apps {
            resolved.append(InstalledAppResolver.resolve(reference, runningBundleIdentifiers: running))
        }
        guard generation == contentGeneration else { return }
        apply(resolved)

        for (index, app) in resolved.enumerated() {
            guard let url = app.url, entries.indices.contains(index) else { continue }
            let key = iconKey(for: app, url: url)
            if entries[index].iconKey == key, entries[index].icon != nil { continue }
            let icon = InstalledAppResolver.icon(for: url, size: Self.iconSize)
            guard generation == contentGeneration, entries.indices.contains(index) else { return }
            entries[index].icon = icon
            entries[index].iconKey = icon == nil ? nil : key
            await Task.yield()
        }
    }

    private func apply(_ resolved: [ResolvedInstalledApp]) {
        for (index, app) in resolved.enumerated() where entries.indices.contains(index) {
            guard entries[index].reference == app.reference else { continue }
            entries[index].resolved = app
        }
    }

    private func iconKey(for app: ResolvedInstalledApp, url: URL) -> String {
        "\(app.bundleIdentifier ?? url.path)@\(app.version ?? "")@\(Int(Self.iconSize))"
    }

    // MARK: - 运行状态轮询（只在浮层显示期间运行）

    func startRefreshing() {
        refreshRunningState()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunningState() }
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 浮层收起后交出图标与解析结果：这是待命进程里唯一真正值钱的东西。
    ///
    /// 配置（`group`）留着，下一次 `show()` 仍然能立刻算出尺寸；自增代号同时
    /// 作废还在后台跑的那一轮加载，避免它把图标写回已经关掉的面板。
    func releaseContent() {
        contentGeneration += 1
        guard !entries.isEmpty else { return }
        var updated = entries
        for index in updated.indices {
            updated[index].icon = nil
            updated[index].iconKey = nil
            updated[index].resolved = nil
        }
        entries = updated
    }

    /// 需求第 9 节：按 bundleIdentifier 匹配 NSWorkspace.runningApplications，
    /// 不注入、不读内存、不修改目标进程。
    ///
    /// 只更新运行状态：解析要读 `Info.plist`、问 LaunchServices，没必要 2 秒来一次。
    /// 而且真的变了才写回 `entries`——`@Published` 不看内容是否相等，
    /// 每 2 秒无脑赋值会让整个浮层白重绘一次。
    func refreshRunningState() {
        guard !entries.isEmpty else { return }
        let running = InstalledAppResolver.runningBundleIdentifiers()
        var updated = entries
        var changed = false
        for index in updated.indices {
            guard var resolved = updated[index].resolved else { continue }
            let isRunning = resolved.bundleIdentifier.map { running.contains($0) } ?? false
            guard isRunning != resolved.isRunning else { continue }
            resolved.isRunning = isRunning
            updated[index].resolved = resolved
            changed = true
        }
        guard changed else { return }
        entries = updated
    }

    // MARK: - 动作

    /// 需求第 10 节：未运行 → 启动；已运行 → 激活。
    func open(_ entry: Entry) {
        guard let app = entry.resolved, app.isInstalled else {
            errorMessage = t("appMissing")
            return
        }
        Task { @MainActor in
            do {
                try await AppLaunchService.open(app.reference)
                DockHelperPanelController.shared?.dismiss()
            } catch {
                errorMessage = String(
                    format: t("launchFailed"),
                    app.displayName
                )
            }
        }
    }

    /// 需求第 7 节：浮层里的「设置…」打开 MacPilot 的 Dock 分组页面。
    func openMacPilotSettings() {
        guard let url = URL(string: "macpilot://dock-groups") else { return }
        NSWorkspace.shared.open(url)
        DockHelperPanelController.shared?.dismiss()
    }

    func revealInFinder(_ entry: Entry) {
        guard let url = entry.resolved?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - 浮层尺寸

/// 浮层与 SwiftUI 内容共用同一套尺寸计算，避免两边不一致。
enum DockHelperLayout {
    static let padding: CGFloat = 18
    static let headerHeight: CGFloat = 30
    static let sectionSpacing: CGFloat = 8
    static let gridCellWidth: CGFloat = 78
    static let gridRowHeight: CGFloat = 82
    static let listRowHeight: CGFloat = 34
    static let listWidth: CGFloat = 260
    static let gap: CGFloat = 10
    static let cornerRadius: CGFloat = 14

    static func columns(for group: DockGroup) -> Int {
        DockGroupGridMetrics.columns(forAppCount: group.apps.count)
    }

    static func size(for group: DockGroup) -> NSSize {
        guard !group.apps.isEmpty else {
            return NSSize(width: listWidth, height: 190)
        }
        switch group.layout {
        case .grid:
            let columns = columns(for: group)
            let rows = Int(ceil(Double(group.apps.count) / Double(columns)))
            let width = padding * 2
                + CGFloat(columns) * gridCellWidth
                + CGFloat(max(0, columns - 1)) * gap
            let height = padding * 2
                + headerHeight
                + sectionSpacing
                + CGFloat(rows) * gridRowHeight
            return NSSize(width: max(200, width), height: max(160, height))
        case .list:
            let height = padding * 2
                + headerHeight
                + sectionSpacing
                + CGFloat(group.apps.count) * listRowHeight
            return NSSize(width: listWidth, height: max(160, height))
        }
    }
}
