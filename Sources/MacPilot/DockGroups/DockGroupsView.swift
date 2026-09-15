//
//  DockGroupsView.swift
//  MacPilot
//
//  需求第 7、13、14、21、31 节：Dock Groups 设置页。
//  遵循统一 UI 语言：30pt 页头 + 自适应玻璃卡片 + 原生全高 List。
//
//  页面只负责编辑 MacPilot 自己的配置与 Helper；
//  被管理的第三方 App 全程只读。
//

import AppKit
import MacPilotDockGroupsCore
import SwiftUI
import UniformTypeIdentifiers

struct DockGroupsView: View {
    @ObservedObject var dockGroups: DockGroupsModel
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var editingGroupID: String?
    @State private var groupPendingDeletion: DockGroup?
    @State private var dropTargetGroupID: String?
    @State private var showsAddToDockGuide = false
    @State private var showsCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            settingsCard

            if let warning = dockGroups.configWarning {
                warningBanner(Text(model.t("dockGroupsConfigWarning", warning)))
                    .padding(.horizontal, 36)
                    .padding(.bottom, 12)
            } else if dockGroups.helperUnavailable {
                warningBanner(Text(model.t("dockGroupsHelperUnavailable")))
                    .padding(.horizontal, 36)
                    .padding(.bottom, 12)
            }

            groupSectionControls

            if dockGroups.groups.isEmpty {
                emptyState
            } else {
                groupList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { dockGroups.startMonitoring() }
        .onDisappear { dockGroups.stopMonitoring() }
        .sheet(item: editingGroup) { group in
            DockGroupEditor(dockGroups: dockGroups, groupID: group.id)
                .environmentObject(model)
        }
        .sheet(isPresented: $showsAddToDockGuide) {
            AddToDockGuideView(model: model) { showsAddToDockGuide = false }
        }
        .alert(
            model.t("dockGroupsDeleteGroup"),
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            )
        ) {
            Button(model.t("dockGroupsDeleteGroupAction"), role: .destructive) {
                if let group = groupPendingDeletion {
                    dockGroups.deleteGroup(group.id)
                }
                groupPendingDeletion = nil
            }
            Button(model.t("cancel"), role: .cancel) { groupPendingDeletion = nil }
        } message: {
            Text(model.t("dockGroupsDeleteGroupMessage", groupPendingDeletion?.name ?? ""))
        }
    }

    private var editingGroup: Binding<DockGroup?> {
        Binding(
            get: { dockGroups.groups.first { $0.id == editingGroupID } },
            set: { editingGroupID = $0?.id }
        )
    }

    // MARK: - 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.t("dockGroups")).font(.system(size: 30, weight: .bold))
            Text(model.t("dockGroupsSubtitle")).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 22)
    }

    // MARK: - 设置卡片

    /// 偏好在同一张卡片里：它们都是「设置」，混在针对列表的操作行里会让那一行
    /// 既没有标题也没有重心。功能总开关在首页，这里不重复放一个。
    private var settingsCard: some View {
        SettingsCard {
            Text(model.t("dockGroupsGroupSettings"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 16) {
                Text(model.t("dockGroupsDefaultLayout"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { dockGroups.settings.defaultLayout },
                    set: { dockGroups.setDefaultLayout($0) }
                )) {
                    Text(model.t("dockGroupsLayoutGrid")).tag(DockGroupLayout.grid)
                    Text(model.t("dockGroupsLayoutList")).tag(DockGroupLayout.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                Spacer(minLength: 24)

                Toggle(model.t("dockGroupsShowRunningState"), isOn: Binding(
                    get: { dockGroups.settings.showsRunningState },
                    set: { dockGroups.setShowsRunningState($0) }
                ))
                .toggleStyle(.switch)
                .fixedSize()
            }

            Text(model.t("dockGroupsLayoutHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 20)
    }

    // MARK: - 分组列表上方的操作行

    /// 与内存监控页一致：左侧是小节标题 + 一句统计，右侧才是操作按钮。
    private var groupSectionControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t("dockGroupsGroupsSection"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(groupSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                let group = dockGroups.createGroup(named: model.t("dockGroupsNewGroupName"))
                editingGroupID = group.id
            } label: {
                Label(model.t("dockGroupsNewGroup"), systemImage: "plus")
            }
            .macPilotProminentButtonStyle()
                        .fixedSize()

            Button {
                dockGroups.regenerateAllHelpers()
            } label: {
                Label(model.t("dockGroupsRegenerate"), systemImage: "arrow.clockwise")
            }
            .disabled(dockGroups.isRegeneratingHelpers || dockGroups.groups.isEmpty)
            .fixedSize()

            Button {
                dockGroups.revealGroupsFolder()
            } label: {
                Label(model.t("dockGroupsRevealFolder"), systemImage: "folder")
            }
            .fixedSize()

            // 需求第 26 节：清理入口只删 MacPilot 自己的 Helper / 配置 / 缓存。
            Button {
                showsCleanupConfirmation = true
            } label: {
                Label(model.t("dockGroupsCleanup"), systemImage: "trash")
            }
            .disabled(dockGroups.groups.isEmpty)
            .fixedSize()
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 12)
        .alert(model.t("dockGroupsCleanup"), isPresented: $showsCleanupConfirmation) {
            Button(model.t("dockGroupsCleanupAction"), role: .destructive) {
                dockGroups.removeAllGroupData()
            }
            Button(model.t("cancel"), role: .cancel) {}
        } message: {
            Text(model.t("dockGroupsCleanupMessage"))
        }
    }

    private var groupSummaryText: String {
        let appCount = dockGroups.groups.reduce(0) { $0 + $1.apps.count }
        return model.t("dockGroupsGroupSummary", dockGroups.groups.count, appCount)
    }

    private func warningBanner(_ content: Text) -> some View {
        content
            .font(.subheadline)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.orange.opacity(0.35))
            )
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2").font(.system(size: 46)).foregroundStyle(.blue)
            Text(model.t("dockGroupsNoGroups")).font(.title2.bold())
            Text(model.t("dockGroupsNoGroupsDetail"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                let group = dockGroups.createGroup(named: model.t("dockGroupsNewGroupName"))
                editingGroupID = group.id
            } label: {
                Label(model.t("dockGroupsNewGroup"), systemImage: "plus")
            }
            .macPilotProminentButtonStyle()

            Button(model.t("dockGroupsAddToDockGuide")) { showsAddToDockGuide = true }
                .buttonStyle(.link)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 70)
    }

    // MARK: - 分组列表

    private var groupList: some View {
        List {
            ForEach(dockGroups.groups) { group in
                groupRow(group)
                    .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private func groupRow(_ group: DockGroup) -> some View {
        Button {
            editingGroupID = group.id
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: dockGroups.groupIcon(
                    for: group,
                    size: 72,
                    appearance: group.iconStyle.appearance(isDark: colorScheme == .dark)
                ))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text(summary(for: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if missingCount(for: group) > 0 {
                    Label(
                        model.t("dockGroupsMissingCount", missingCount(for: group)),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(dropTargetGroupID == group.id ? 0.12 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(dropTargetGroupID == group.id ? 0.5 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], delegate: DockGroupDropDelegate(
            isTargeted: Binding(
                get: { dropTargetGroupID == group.id },
                set: { dropTargetGroupID = $0 ? group.id : (dropTargetGroupID == group.id ? nil : dropTargetGroupID) }
            ),
            onDrop: { url in
                _ = dockGroups.addApp(at: url, to: group.id)
            }
        ))
        .contextMenu {
            Button(model.t("edit")) { editingGroupID = group.id }
            Button(model.t("dockGroupsRevealHelper")) { dockGroups.revealHelper(for: group) }
            Divider()
            Button(model.t("dockGroupsDeleteGroupAction"), role: .destructive) { groupPendingDeletion = group }
        }
    }

    private func summary(for group: DockGroup) -> String {
        var parts = [model.t("dockGroupsAppCount", group.apps.count)]
        parts.append(group.layout == .grid ? model.t("dockGroupsLayoutGrid") : model.t("dockGroupsLayoutList"))
        if dockGroups.settings.showsRunningState {
            let running = dockGroups.resolvedApps(for: group).filter(\.isRunning).count
            if running > 0 { parts.append(model.t("dockGroupsRunningCount", running)) }
        }
        return parts.joined(separator: " · ")
    }

    private func missingCount(for group: DockGroup) -> Int {
        dockGroups.resolvedApps(for: group).filter { !$0.isInstalled }.count
    }
}

// MARK: - 拖入 .app

/// 需求第 11 节：把 `.app` 拖到某个分组上，只保存引用。
struct DockGroupDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, url.pathExtension.lowercased() == "app" else { return }
            Task { @MainActor in onDrop(url) }
        }
        return true
    }
}

// MARK: - 添加到 Dock 引导

/// 需求第 14 节：第一版不直接改写 com.apple.dock.plist，
/// 只把 Helper 显示在访达中并说明如何拖入 Dock。
struct AddToDockGuideView: View {
    @ObservedObject var model: MacPilotModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.t("dockGroupsAddToDockGuide")).font(.title2.bold())
            Text(model.t("dockGroupsAddToDockGuideBody"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.t("dockGroupsSafetyNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.t("dockGroupsDone"), action: dismiss)
                    .macPilotProminentButtonStyle()
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
