import AppKit
import SwiftUI

/// 内存监控页：系统内存总览 + 按应用聚合的内存占用列表。
/// 遵循统一 UI 语言：30pt 页头 + 自适应玻璃卡片 + 原生全高 List。
struct MemoryMonitorView: View {
    let monitor: MemoryMonitorModel
    let lifecycle: FeatureLifecycleManager
    @ObservedObject var store: MemoryStore

    let language: AppLanguage

    init(monitor: MemoryMonitorModel, lifecycle: FeatureLifecycleManager, language: AppLanguage) {
        self.monitor = monitor
        self.lifecycle = lifecycle
        self.store = monitor.store
        self.language = language
    }
    @State private var searchText = ""
    @State private var autoRefresh = true

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("memoryMonitor")).font(.system(size: 30, weight: .bold))
                Text(t("memoryMonitorSubtitle")).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 22)

            if let snapshot = store.systemMemory {
                overviewCard(snapshot)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 16)
            }

            listControls

            appList
        }
        .onAppear {
            if autoRefresh { lifecycle.start(monitor.identifier) } else { monitor.refresh() }
        }
        .onDisappear { lifecycle.stop(monitor.identifier) }
        .onChange(of: autoRefresh) { _, enabled in
            if enabled { lifecycle.start(monitor.identifier) } else { lifecycle.stop(monitor.identifier) }
        }
    }

    // MARK: - 系统内存总览

    private func overviewCard(_ snapshot: SystemMemorySnapshot) -> some View {
        SettingsCard {
            Text(t("memoryOverview")).font(.headline)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                overviewValue(
                    t("physicalMemory"),
                    MemoryByteFormatter.string(fromBytes: snapshot.physicalBytes)
                )
                overviewValue(
                    t("usedMemory"),
                    MemoryByteFormatter.string(fromBytes: snapshot.usedBytes)
                )
                overviewValue(
                    t("appMemory"),
                    MemoryByteFormatter.string(fromBytes: snapshot.appBytes)
                )
                overviewValue(
                    t("wiredMemory"),
                    MemoryByteFormatter.string(fromBytes: snapshot.wiredBytes)
                )
                overviewValue(
                    t("compressedMemory"),
                    MemoryByteFormatter.string(fromBytes: snapshot.compressedBytes)
                )
                overviewValue(
                    t("cachedFiles"),
                    MemoryByteFormatter.string(fromBytes: snapshot.cachedFilesBytes)
                )
                overviewValue(
                    t("swapUsed"),
                    MemoryByteFormatter.string(fromBytes: snapshot.swapUsedBytes)
                )
                pressureValue(snapshot.pressure)
                overviewValue(
                    t("bootedAt"),
                    snapshot.bootDate.formatted(date: .abbreviated, time: .shortened)
                )
                overviewValue(
                    t("uptime"),
                    MemoryDurationFormatter.string(fromInterval: snapshot.uptimeInterval)
                )
            }
        }
    }

    private func overviewValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func pressureValue(_ pressure: SystemMemorySnapshot.PressureLevel) -> some View {
        HStack(spacing: 8) {
            Text(t("memoryPressure"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(color(for: pressure)).frame(width: 8, height: 8)
                Text(t(pressure.labelKey))
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for pressure: SystemMemorySnapshot.PressureLevel) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    // MARK: - 列表控制行

    private var listControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("appMemoryList"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let lastUpdated = store.lastUpdated {
                    Text(
                        t(
                            "lastUpdated",
                            lastUpdated.formatted(date: .omitted, time: .standard)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            TextField(t("searchApps"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Toggle(t("autoRefresh"), isOn: $autoRefresh)
                .toggleStyle(.switch)
                .fixedSize()
            Button {
                monitor.refresh()
            } label: {
                Label(t("refreshNow"), systemImage: "arrow.clockwise")
            }
            .fixedSize()
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 12)
    }

    // MARK: - 应用内存列表

    private var appList: some View {
        List {
            if store.apps.isEmpty && store.isRefreshing {
                HStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text(t("loadingProcesses")).foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if filteredApps.isEmpty {
                Text(t("noMatchingApps"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
            } else {
                let maxBytes = store.apps.first?.footprintBytes ?? 0
                ForEach(filteredApps) { app in
                    AppMemoryRow(language: language, app: app, icons: store.icons, maxBytes: maxBytes, usedBytes: store.systemMemory?.usedBytes)
                        .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private var filteredApps: [AppMemoryUsage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.apps }
        return store.apps.filter { app in
            app.name.lowercased().contains(query)
                || app.processes.contains { $0.name.lowercased().contains(query) }
        }
    }
}

/// 单个应用的内存行：图标 + 名称与占比条 + 总占用；展开可看每个进程的明细。
/// 不用 DisclosureGroup：系统箭头的垂直对齐不受控，这里自绘折叠箭头保证居中。
private struct AppMemoryRow: View {
    let language: AppLanguage
    let app: AppMemoryUsage
    @ObservedObject var icons: ProcessIconStore
    let maxBytes: UInt64
    let usedBytes: UInt64?
    @State private var isExpanded = false

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                labelContent
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(app.processes) { process in
                    processRow(process)
                }
            }
        }
    }

    private var labelContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            appIcon
            VStack(alignment: .leading, spacing: 5) {
                labelText
                gauge
            }
            // 固定数值列宽：所有行的内存值右对齐，占比条终点一致
            Text(MemoryByteFormatter.string(fromBytes: app.footprintBytes))
                .font(.body.monospacedDigit().weight(.medium))
                .frame(minWidth: 88, alignment: .trailing)
                .help(helpText)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(t("processCount", app.processCount)), \(MemoryByteFormatter.string(fromBytes: app.footprintBytes))")
    }

    /// 明细行左缘对齐名称列（箭头 14 + 间距 10 + 图标 26 + 间距 12 = 62），
    /// 进程名靠前，PID 作为次要信息内联跟随，右缘与主行数值列对齐。
    private func processRow(_ process: ProcessMemorySample) -> some View {
        HStack(spacing: 10) {
            Text(process.name)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let interval = process.runningDurationInterval {
                Text(MemoryDurationFormatter.string(fromInterval: interval))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text("PID \(process.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 16)
            Text(MemoryByteFormatter.string(fromBytes: process.footprintBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 62)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let path = app.bundlePath, let icon = icons.image(for: path) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }

    /// 占比条相对列表中最大的应用，便于横向比较；悬停提示给出占系统已用内存的比例。
    private var gauge: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: gaugeWidth(available: proxy.size.width))
            }
        }
        .frame(height: 4)
    }

    private var fraction: Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, Double(app.footprintBytes) / Double(maxBytes))
    }

    private func gaugeWidth(available: CGFloat) -> CGFloat {
        max(3, available * fraction)
    }

    /// 标题行：应用名 + 进程数 + 运行时长（取家族内最早启动的进程）。
    private var labelText: Text {
        var text = Text(app.name).font(.body.weight(.semibold))
            + Text("  \(t("processCount", app.processCount))")
                .font(.caption)
                .foregroundStyle(.secondary)
        if let interval = app.runningDurationInterval {
            text = text + Text("  \(t("appRunningFor", MemoryDurationFormatter.string(fromInterval: interval)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        return text
    }

    private var helpText: String {
        guard let usedBytes, usedBytes > 0 else { return MemoryByteFormatter.string(fromBytes: app.footprintBytes) }
        let percent = min(100, Double(app.footprintBytes) / Double(usedBytes) * 100)
        return String(format: "%.1f%%", percent)
    }
}
