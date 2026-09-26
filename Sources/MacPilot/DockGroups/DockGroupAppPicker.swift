//
//  DockGroupAppPicker.swift
//  MacPilot
//
//  需求第 11、27 节：从已安装的应用中选择要加入分组的 App。
//
//  只做一次浅层、只读的扫描（/Applications、/System/Applications、~/Applications），
//  不修改、不复制、不移动任何 App。
//

import AppKit
import MacPilotDockGroupsCore
import SwiftUI
import UniformTypeIdentifiers

struct DockGroupAppPicker: View {
    @ObservedObject var dockGroups: DockGroupsModel
    let groupID: String
    let existing: [DockGroupApp]

    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var candidates: [DockGroupApp] = []
    @State private var isLoading = true
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(model.t("dockGroupsAddApp")).font(.title3.bold())
                Spacer()
                TextField(model.t("dockGroupsSearchApps"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button(model.t("browse")) { isImporting = true }
                Button(model.t("cancel")) { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if isLoading {
                ProgressView(model.t("dockGroupsScanning"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                Text(model.t("dockGroupsNoMatchingApps"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                appList
            }
        }
        .frame(width: 520, height: 520)
        .task {
            await loadCandidates()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                _ = dockGroups.addApp(at: url, to: groupID)
            }
        }
    }

    private var filtered: [DockGroupApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { candidate in
            candidate.name.localizedCaseInsensitiveContains(query)
                || (candidate.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var appList: some View {
        List(filtered) { candidate in
            HStack(spacing: 10) {
                if let icon = dockGroups.icon(for: candidate, size: 32) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "app.dashed").frame(width: 26, height: 26).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name).lineLimit(1)
                    Text(candidate.bundleIdentifier ?? candidate.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isAlreadyAdded(candidate) {
                    Label(model.t("dockGroupsAlreadyAdded"), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(model.t("addApp")) {
                        if dockGroups.addApp(candidate, to: groupID) {
                            dismiss()
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    private func isAlreadyAdded(_ candidate: DockGroupApp) -> Bool {
        existing.contains { DockGroupDocumentEditor.isSameApp($0, candidate) }
    }

    /// 扫描放到后台线程，避免打开选择器时卡住界面。
    private func loadCandidates() async {
        guard candidates.isEmpty else {
            isLoading = false
            return
        }
        let scan = Task.detached(priority: .userInitiated) {
            InstalledAppResolver.scanInstalledApps()
        }
        let scanned = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled else { return }
        candidates = scanned
        isLoading = false
    }
}
