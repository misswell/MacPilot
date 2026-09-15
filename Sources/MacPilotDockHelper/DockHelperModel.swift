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

import AppKit
import Combine
import MacPilotDockGroupsCore
import SwiftUI

@MainActor
final class DockHelperModel: ObservableObject {
    @Published private(set) var group: DockGroup?
    @Published private(set) var apps: [ResolvedInstalledApp] = []
    @Published private(set) var errorMessage: String?

    let language: DockHelperLanguage
    private let store: DockGroupStore
    private let groupID: String?
    private var refreshTimer: Timer?

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

    /// 读取配置并开始轮询运行状态（只在浮层显示期间运行）。
    func start() {
        loadGroup()
        refreshRunningState()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunningState() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func loadGroup() {
        guard groupID != nil else {
            group = nil
            return
        }
        switch store.load() {
        case let .loaded(document):
            group = groupID.flatMap { document.group(withID: $0) }
        case .missing, .corrupt:
            group = nil
        }
    }

    /// 需求第 9 节：按 bundleIdentifier 匹配 NSWorkspace.runningApplications，
    /// 不注入、不读内存、不修改目标进程。
    func refreshRunningState() {
        guard let group else { return }
        let running = InstalledAppResolver.runningBundleIdentifiers()
        apps = group.apps.map { InstalledAppResolver.resolve($0, runningBundleIdentifiers: running) }
    }

    // MARK: - 动作

    /// 需求第 10 节：未运行 → 启动；已运行 → 激活。
    func open(_ app: ResolvedInstalledApp) {
        guard app.isInstalled else {
            errorMessage = t("appMissing")
            return
        }
        Task { @MainActor in
            do {
                try await AppLaunchService.open(app.reference)
                DockHelperPanelController.shared?.close()
            } catch {
                errorMessage = String(
                    format: t("launchFailed"),
                    app.displayName
                )
            }
        }
    }

    func icon(for app: ResolvedInstalledApp) -> NSImage? {
        guard let url = app.url else { return nil }
        return InstalledAppResolver.icon(for: url, size: 56)
    }

    /// 需求第 7 节：浮层里的「设置…」打开 MacPilot 的 Dock 分组页面。
    func openMacPilotSettings() {
        guard let url = URL(string: "macpilot://dock-groups") else { return }
        NSWorkspace.shared.open(url)
        DockHelperPanelController.shared?.close()
    }

    func revealInFinder(_ app: ResolvedInstalledApp) {
        guard let url = app.url else { return }
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
