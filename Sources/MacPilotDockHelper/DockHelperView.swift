//
//  DockHelperView.swift
//  MacPilotDockHelper
//
//  需求第 7、8、9 节：轻量浮层内容。
//  Grid / List 两种布局、运行状态圆点、键盘导航、深色模式适配。
//  刻意保持简单——这不是 MacPilot 主界面的缩小版。
//

import AppKit
import MacPilotDockGroupsCore
import SwiftUI

struct DockHelperView: View {
    @ObservedObject var model: DockHelperModel
    @FocusState private var focusedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: DockHelperLayout.sectionSpacing) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(DockHelperLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DockHelperLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DockHelperLayout.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.10))
        )
        .onAppear { focusedIndex = model.apps.isEmpty ? nil : 0 }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(spacing: 8) {
            if let group = model.group {
                Image(nsImage: DockGroupIconRenderer.image(
                    for: group,
                    size: 44,
                    memberIconURLs: group.apps.compactMap { InstalledAppResolver.resolveURL($0) }
                ))
                .resizable()
                .frame(width: 22, height: 22)
            }
            Text(model.groupName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: DockHelperLayout.headerHeight, alignment: .leading)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.group == nil {
            missingGroupState
        } else if model.apps.isEmpty {
            emptyState
        } else if model.group?.layout == .list {
            listLayout
        } else {
            gridLayout
        }
    }

    private var missingGroupState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.t("groupMissing"), systemImage: "questionmark.folder")
                .font(.subheadline)
            Text(model.t("groupMissingHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.t("emptyGroup"), systemImage: "square.dashed")
                .font(.subheadline)
            Text(model.t("emptyGroupHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columns: Int {
        model.group.map { DockHelperLayout.columns(for: $0) } ?? DockGroupGridMetrics.minimumColumns
    }

    private var gridLayout: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(DockHelperLayout.gridCellWidth), spacing: DockHelperLayout.gap),
                count: columns
            ),
            spacing: 6
        ) {
            ForEach(Array(model.apps.enumerated()), id: \.element.reference.id) { index, app in
                appCell(app, index: index)
            }
        }
    }

    private var listLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.apps.enumerated()), id: \.element.reference.id) { index, app in
                appRow(app, index: index)
            }
        }
    }

    // MARK: - 单元格

    private func appCell(_ app: ResolvedInstalledApp, index: Int) -> some View {
        Button {
            model.open(app)
        } label: {
            VStack(spacing: 4) {
                appIcon(app, side: 46)
                Text(app.displayName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(app.isInstalled ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: DockHelperLayout.gridCellWidth, height: DockHelperLayout.gridRowHeight - 4, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedIndex, equals: index)
        .onKeyPress(.rightArrow) { moveFocus(to: index + 1) }
        .onKeyPress(.leftArrow) { moveFocus(to: index - 1) }
        .onKeyPress(.downArrow) { moveFocus(to: index + columns) }
        .onKeyPress(.upArrow) { moveFocus(to: index - columns) }
        .help(app.isInstalled ? app.displayName : model.t("appMissing"))
        .accessibilityLabel(app.isInstalled ? app.displayName : "\(app.displayName) — \(model.t("appMissing"))")
        .accessibilityValue(app.isRunning ? model.t("running") : model.t("notRunning"))
    }

    private func appRow(_ app: ResolvedInstalledApp, index: Int) -> some View {
        Button {
            model.open(app)
        } label: {
            HStack(spacing: 10) {
                appIcon(app, side: 22)
                Text(app.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(app.isInstalled ? .primary : .secondary)
                Spacer(minLength: 4)
                if !app.isInstalled {
                    Text(model.t("appMissing"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                runningDot(app)
            }
            .frame(height: DockHelperLayout.listRowHeight - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedIndex, equals: index)
        .onKeyPress(.downArrow) { moveFocus(to: index + 1) }
        .onKeyPress(.upArrow) { moveFocus(to: index - 1) }
        .accessibilityLabel(app.isInstalled ? app.displayName : "\(app.displayName) — \(model.t("appMissing"))")
        .accessibilityValue(app.isRunning ? model.t("running") : model.t("notRunning"))
    }

    @ViewBuilder
    private func appIcon(_ app: ResolvedInstalledApp, side: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let icon = model.icon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
            } else {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: side, height: side)
                    .overlay(
                        Image(systemName: "questionmark.app")
                            .font(.system(size: side * 0.5))
                            .foregroundStyle(.secondary)
                    )
            }
            if app.isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: side * 0.24, height: side * 0.24)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: side * 0.06, y: side * 0.06)
            }
        }
        .frame(width: side, height: side)
    }

    private func runningDot(_ app: ResolvedInstalledApp) -> some View {
        Circle()
            .strokeBorder(app.isRunning ? .green : .secondary.opacity(0.5), lineWidth: app.isRunning ? 0 : 1.5)
            .background(Circle().fill(app.isRunning ? .green : .clear))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 8) {
            // 启动失败等提示直接占用页脚的提示位，
            // 这样浮层尺寸始终是预先算好的那一份，不会被撑高或裁切。
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text(model.t("hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(model.t("settings")) {
                model.openMacPilotSettings()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .keyboardShortcut(",", modifiers: .command)
        }
        .frame(height: DockHelperLayout.footerHeight)
        .overlay(alignment: .top) {
            Divider().offset(y: -DockHelperLayout.sectionSpacing / 2)
        }
    }

    /// 方向键在 Grid / List 中移动焦点，符合「支持键盘导航」的要求。
    private func moveFocus(to index: Int) -> KeyPress.Result {
        guard !model.apps.isEmpty else { return .ignored }
        focusedIndex = min(max(index, 0), model.apps.count - 1)
        return .handled
    }
}
