//
//  DockGroupEditor.swift
//  MacPilot
//
//  需求第 8、11、13、16、27 节：分组编辑器。
//  支持重命名、自定义图标、Grid / List、拖入 .app、拖拽排序、
//  「应用未找到」的重新定位 / 从分组移除，以及生成 Helper 后的
//  「添加到 Dock」引导。
//
//  编辑器自始至终只写 MacPilot 自己的配置；第三方 App 只读。
//

import AppKit
import MacPilotDockGroupsCore
import SwiftUI
import UniformTypeIdentifiers

struct DockGroupEditor: View {
    @ObservedObject var dockGroups: DockGroupsModel
    let groupID: String
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft = ""
    @State private var showsAppPicker = false
    @State private var isImportingApp = false
    @State private var relocationTarget: DockGroupApp?
    @State private var isImportingIcon = false
    @State private var isDropTarget = false

    private var group: DockGroup? {
        dockGroups.groups.first { $0.id == groupID }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if let group {
                content(for: group)
            } else {
                Text(model.t("dockGroupsGroupMissing"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 640)
        .onAppear { nameDraft = group?.name ?? "" }
        .sheet(isPresented: $showsAppPicker) {
            DockGroupAppPicker(dockGroups: dockGroups, groupID: groupID, existing: group?.apps ?? [])
                .environmentObject(model)
        }
        .fileImporter(
            isPresented: $isImportingApp,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                _ = dockGroups.addApp(at: url, to: groupID)
            }
        }
        .fileImporter(
            isPresented: $isImportingIcon,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                _ = dockGroups.importCustomIcon(from: url, for: groupID)
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { relocationTarget != nil },
                set: { if !$0 { relocationTarget = nil } }
            ),
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first, let target = relocationTarget {
                _ = dockGroups.relocateApp(target.id, in: groupID, to: url)
            }
            relocationTarget = nil
        }
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            if let group {
                Image(nsImage: dockGroups.groupIcon(for: group, size: 72))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                Text(group.name).font(.title3.bold()).lineLimit(1)
            }
            Spacer()
            Button(model.t("dockGroupsDone")) { dismiss() }
                .macPilotProminentButtonStyle()
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func content(for group: DockGroup) -> some View {
        List {
            basicsSection(group)
            appsSection(group)
            helperSection(group)
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            acceptDrop(providers, into: group.id)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 基本信息

    @ViewBuilder
    private func basicsSection(_ group: DockGroup) -> some View {
        Section(model.t("dockGroupsBasics")) {
            HStack(spacing: 12) {
                Text(model.t("dockGroupsName")).frame(width: 70, alignment: .leading)
                TextField(model.t("dockGroupsName"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitName() }
                Button(model.t("save"), action: commitName)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || nameDraft == group.name)
            }

            HStack(spacing: 12) {
                Text(model.t("dockGroupsLayout")).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { group.layout },
                    set: { dockGroups.setLayout($0, for: groupID) }
                )) {
                    Text(model.t("dockGroupsLayoutGrid")).tag(DockGroupLayout.grid)
                    Text(model.t("dockGroupsLayoutList")).tag(DockGroupLayout.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
            }

            HStack(spacing: 12) {
                Text(model.t("dockGroupsIcon")).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { group.icon.source },
                    set: { source in
                        let value: String
                        switch source {
                        case .symbol: value = DockGroupIcon.symbolChoices.first ?? "hammer"
                        case .emoji: value = DockGroupIcon.emojiChoices.first ?? "🛠"
                        case .composite, .customImage: value = ""
                        }
                        dockGroups.setIcon(DockGroupIcon(source: source, value: value), for: groupID)
                    }
                )) {
                    Text(model.t("dockGroupsIconComposite")).tag(DockGroupIconSource.composite)
                    Text(model.t("dockGroupsIconSymbol")).tag(DockGroupIconSource.symbol)
                    Text(model.t("dockGroupsIconEmoji")).tag(DockGroupIconSource.emoji)
                    Text(model.t("dockGroupsIconImage")).tag(DockGroupIconSource.customImage)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
            }

            iconChoices(group)
            Text(model.t("dockGroupsIconHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func iconChoices(_ group: DockGroup) -> some View {
        switch group.icon.source {
        case .composite:
            EmptyView()
        case .symbol:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 12), spacing: 8) {
                ForEach(DockGroupIcon.symbolChoices, id: \.self) { name in
                    Button {
                        dockGroups.setIcon(DockGroupIcon(source: .symbol, value: name), for: groupID)
                    } label: {
                        Image(systemName: name)
                            .frame(width: 26, height: 26)
                            .background(
                                group.icon.value == name ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
        case .emoji:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 12), spacing: 8) {
                ForEach(DockGroupIcon.emojiChoices, id: \.self) { emoji in
                    Button {
                        dockGroups.setIcon(DockGroupIcon(source: .emoji, value: emoji), for: groupID)
                    } label: {
                        Text(emoji)
                            .frame(width: 26, height: 26)
                            .background(
                                group.icon.value == emoji ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .customImage:
            HStack(spacing: 12) {
                Button(model.t("dockGroupsChooseImage")) { isImportingIcon = true }
                if !group.icon.value.isEmpty {
                    Text(group.icon.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
    }

    // MARK: - 应用列表

    @ViewBuilder
    private func appsSection(_ group: DockGroup) -> some View {
        Section {
            ForEach(group.apps) { reference in
                appRow(reference)
            }
            .onMove { source, destination in
                dockGroups.moveApps(in: groupID, from: source, to: destination)
            }

            HStack(spacing: 12) {
                Button {
                    showsAppPicker = true
                } label: {
                    Label(model.t("dockGroupsAddApp"), systemImage: "plus")
                }
                Button(model.t("browse")) { isImportingApp = true }
                Text(model.t("dockGroupsDropHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 4)
        } header: {
            Text(model.t("dockGroupsApps", group.apps.count))
        } footer: {
            Text(model.t("dockGroupsAppsFooter"))
                .font(.caption)
        }
    }

    @ViewBuilder
    private func appRow(_ reference: DockGroupApp) -> some View {
        let resolved = dockGroups.resolvedApp(reference)
        HStack(spacing: 10) {
            if let icon = dockGroups.icon(for: reference, size: 32) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            } else if resolved.isInstalled {
                // 图标在后台加载中，先占位（不是「应用未找到」）。
                Image(systemName: "app.dashed")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "questionmark.app")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(resolved.displayName)
                    .lineLimit(1)
                    .foregroundStyle(resolved.isInstalled ? .primary : .secondary)
                Text(reference.bundleIdentifier ?? reference.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if !resolved.isInstalled {
                Text(model.t("dockGroupsAppMissing"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(model.t("dockGroupsRelocate")) { relocationTarget = reference }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else if dockGroups.settings.showsRunningState, resolved.isRunning {
                Text(model.t("dockGroupsRunning"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button {
                dockGroups.removeApp(reference.id, from: groupID)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(model.t("dockGroupsRemoveApp"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helper

    @ViewBuilder
    private func helperSection(_ group: DockGroup) -> some View {
        Section(model.t("dockGroupsHelper")) {
            HStack(spacing: 10) {
                Image(systemName: dockGroups.helperExists(for: group) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(dockGroups.helperExists(for: group) ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.name).app").font(.subheadline)
                    Text(dockGroups.helperAppURL(for: group).path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(model.t("dockGroupsRegenerate")) { dockGroups.regenerateHelper(for: group) }
                Button(model.t("dockGroupsRevealHelper")) { dockGroups.revealHelper(for: group) }
                    .disabled(!dockGroups.helperExists(for: group))
            }

            HStack(spacing: 10) {
                Text(model.t("dockGroupsAddToDockHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(model.t("dockGroupsAddToDock")) {
                    dockGroups.revealHelper(for: group)
                }
                .disabled(!dockGroups.helperExists(for: group))
            }

            Label(model.t("dockGroupsReadOnlyNote"), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dockGroups.renameGroup(groupID, to: trimmed)
        nameDraft = dockGroups.groups.first { $0.id == groupID }?.name ?? trimmed
    }

    private func acceptDrop(_ providers: [NSItemProvider], into groupID: String) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, url.pathExtension.lowercased() == "app" else { return }
            Task { @MainActor in _ = dockGroups.addApp(at: url, to: groupID) }
        }
        return true
    }
}
