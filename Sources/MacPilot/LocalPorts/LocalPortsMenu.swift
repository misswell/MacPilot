import MacPilotLocalPortsCore
import SwiftUI

/// What the menu-bar 「本地端口」 submenu lists.
///
/// One row per listening process, carrying every port that process holds — the
/// same grouping the page uses, reduced to what one menu line can read.
enum LocalPortsMenuPresentation {
    /// A menu stays scannable; the page owns search and the full list.
    static let maximumRows = 10

    struct Row: Identifiable, Equatable {
        let pid: Int32
        let ports: [Int]
        let ownerLabel: String
        let category: LocalPortOwnerCategory
        let isLAN: Bool

        var id: Int32 { pid }
        var isProject: Bool { category == .project }

        var portList: String { ports.map(String.init).joined(separator: ", ") }

        func title(lanLabel: String) -> String {
            let lan = isLAN ? " · \(lanLabel)" : ""
            return "\(portList) — \(ownerLabel) · PID \(pid)\(lan)"
        }
    }

    static func rows(from snapshot: LocalPortSnapshot) -> [Row] {
        Dictionary(grouping: snapshot.activities, by: { $0.process.pid })
            .compactMap { pid, activities in
                guard let owner = activities.first?.owner else { return nil }
                return Row(
                    pid: pid,
                    ports: Array(Set(activities.map(\.listener.port))).sorted(),
                    ownerLabel: owner.label,
                    category: owner.category,
                    isLAN: activities.contains { $0.scope == .lan }
                )
            }
            .sorted {
                if $0.category.sortIndex != $1.category.sortIndex {
                    return $0.category.sortIndex < $1.category.sortIndex
                }
                if $0.ports.first != $1.ports.first {
                    return ($0.ports.first ?? 0) < ($1.ports.first ?? 0)
                }
                return $0.ownerLabel.localizedStandardCompare($1.ownerLabel) == .orderedAscending
            }
    }

    static func hiddenRowCount(from snapshot: LocalPortSnapshot) -> Int {
        max(0, rows(from: snapshot).count - maximumRows)
    }

    /// Which empty state the submenu is allowed to claim.
    ///
    /// A scan that failed must not read as "nothing is listening", and neither
    /// must the first second of the very first one: until a scan has landed the
    /// empty list is a promise, not a finding.
    static func emptyStateKey(isRefreshing: Bool, hasLoadedOnce: Bool, scanFailed: Bool) -> String {
        if scanFailed { return "localPortsScanFailed" }
        return isRefreshing || !hasLoadedOnce ? "localPortsRefreshing" : "localPortsNoServices"
    }
}

/// The order both the page's list and the menu's rows use: what the user is
/// most likely after comes first, so truncating the menu never costs a project.
extension LocalPortOwnerCategory {
    var sortIndex: Int {
        switch self {
        case .project: 0
        case .service: 1
        case .application: 2
        case .systemService: 3
        case .unknown: 4
        }
    }
}

/// 菜单栏「本地端口」子菜单：展开即显示最近一轮扫描的端口列表，底部入口跳转到
/// 完整页面。层级与「内存监控」一致，区别是端口要起 lsof/ps 子进程，采样不能
/// 同步返回，所以首帧显示上一轮结果，扫描落地后再刷新这一份列表。
struct LocalPortsMenuSection: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var ports: LocalPortsModel
    let openPorts: () -> Void

    var body: some View {
        // Menu content is built when the menu opens, which is the earliest hook
        // there is; the call itself only queues work and re-checks its own TTL.
        let _ = ports.refreshForMenu()
        let snapshot = ports.snapshot
        let rows = LocalPortsMenuPresentation.rows(from: snapshot)
        let shown = Array(rows.prefix(LocalPortsMenuPresentation.maximumRows))
        let projects = shown.filter(\.isProject)
        let services = shown.filter { !$0.isProject }

        Menu(model.t("localPorts")) {
            Section(model.t("localPortsOverview")) {
                Text(model.t("localPortsListening", snapshot.portCount))
                Text(model.t("localPortsClosable", snapshot.closablePortCount))
                Text(model.t("localPortsLAN", snapshot.lanPortCount))
                if let lastRefresh = ports.lastRefresh {
                    Text(model.t(
                        "localPortsLastUpdated",
                        lastRefresh.formatted(.dateTime
                            .hour().minute().second()
                            .locale(model.language.locale))
                    ))
                }
            }
            Divider()
            if shown.isEmpty {
                Text(model.t(emptyStateKey))
            } else {
                if !projects.isEmpty {
                    Section(model.t("localPortsProjects")) {
                        ForEach(projects) { Text($0.title(lanLabel: model.t("localPortsLANScope"))) }
                    }
                }
                if !services.isEmpty {
                    Section(model.t("localPortsServices")) {
                        ForEach(services) { Text($0.title(lanLabel: model.t("localPortsLANScope"))) }
                    }
                }
                let hidden = rows.count - shown.count
                if hidden > 0 {
                    Text(model.t("localPortsMenuMore", hidden))
                }
            }
            Divider()
            Button(model.t("localPortsOpen")) { openPorts() }
        }
    }

    /// The three empty states are not interchangeable; see
    /// `LocalPortsMenuPresentation.emptyStateKey`.
    private var emptyStateKey: String {
        LocalPortsMenuPresentation.emptyStateKey(
            isRefreshing: ports.isRefreshing,
            hasLoadedOnce: ports.lastRefresh != nil,
            scanFailed: ports.lastScanError != nil
        )
    }
}
