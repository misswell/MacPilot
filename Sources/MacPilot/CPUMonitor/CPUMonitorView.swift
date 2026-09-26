import AppKit
import SwiftUI

/// CPU 监控页：系统 CPU 总览 + 按应用聚合的 CPU 占用列表。
/// 与内存监控共用统一的页头、SettingsCard 和原生全高 List。
struct CPUMonitorView: View {
    let monitor: CPUMonitorModel
    let lifecycle: FeatureLifecycleManager
    @ObservedObject var store: CPUStore

    let language: AppLanguage

    init(monitor: CPUMonitorModel, lifecycle: FeatureLifecycleManager, language: AppLanguage) {
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
                Text(t("cpuMonitor")).font(.system(size: 30, weight: .bold))
                Text(t("cpuMonitorSubtitle")).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 22)

            if let snapshot = store.systemCPU {
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

    private func overviewCard(_ snapshot: SystemCPUSnapshot) -> some View {
        SettingsCard {
            Text(t("cpuOverview")).font(.headline)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                overviewValue(t("cpuTotalUsage"), CPUPercentFormatter.string(from: snapshot.totalPercent))
                overviewValue(t("cpuUserUsage"), CPUPercentFormatter.string(from: snapshot.userPercent))
                overviewValue(t("cpuSystemUsage"), CPUPercentFormatter.string(from: snapshot.systemPercent))
                overviewValue(t("cpuNiceUsage"), CPUPercentFormatter.string(from: snapshot.nicePercent))
                overviewValue(t("cpuIdleUsage"), CPUPercentFormatter.string(from: snapshot.idlePercent))
                overviewValue(t("cpuLogicalCores"), "\(snapshot.logicalCoreCount)")
                overviewValue(t("cpuLoadOne"), loadAverageValue(snapshot, index: 0))
                overviewValue(t("cpuLoadFive"), loadAverageValue(snapshot, index: 1))
                overviewValue(t("cpuLoadFifteen"), loadAverageValue(snapshot, index: 2))
            }
        }
    }

    private func loadAverageValue(_ snapshot: SystemCPUSnapshot, index: Int) -> String {
        guard snapshot.loadAverage.indices.contains(index) else { return "-" }
        return String(format: "%.2f", snapshot.loadAverage[index])
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

    private var listControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("appCPUList"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let lastUpdated = store.lastUpdated {
                    Text(t("lastUpdated", lastUpdated.formatted(date: .omitted, time: .standard)))
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
            Button { monitor.refresh() } label: {
                Label(t("refreshNow"), systemImage: "arrow.clockwise")
            }
            .fixedSize()
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 12)
    }

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
                let maxPercent = store.apps.first?.cpuPercent ?? 0
                ForEach(filteredApps) { app in
                    AppCPUUsageRow(
                        language: language,
                        app: app,
                        maxPercent: maxPercent,
                        totalPercent: store.systemCPU?.totalPercent
                    )
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

    private var filteredApps: [AppCPUUsage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.apps }
        return store.apps.filter { app in
            app.name.lowercased().contains(query)
                || app.processes.contains { $0.name.lowercased().contains(query) }
        }
    }
}

private struct AppCPUUsageRow: View {
    let language: AppLanguage
    let app: AppCPUUsage
    let maxPercent: Double
    let totalPercent: Double?
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
            Text(CPUPercentFormatter.string(from: app.cpuPercent))
                .font(.body.monospacedDigit().weight(.medium))
                .frame(minWidth: 70, alignment: .trailing)
                .help(helpText)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(app.name), \(t("processCount", app.processCount)), \(CPUPercentFormatter.string(from: app.cpuPercent))"
        )
    }

    private func processRow(_ process: ProcessCPUSample) -> some View {
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
            Text(t("processID", Int(process.pid)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 16)
            Text(CPUPercentFormatter.string(from: process.cpuPercent))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 62)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let path = app.bundlePath {
            Image(nsImage: AppIconCache.shared.icon(for: path))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }

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
        guard maxPercent > 0 else { return 0 }
        return min(1, app.cpuPercent / maxPercent)
    }

    private func gaugeWidth(available: CGFloat) -> CGFloat {
        max(3, available * fraction)
    }

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
        guard let totalPercent, totalPercent > 0 else {
            return CPUPercentFormatter.string(from: app.cpuPercent)
        }
        let share = min(100, app.cpuPercent / totalPercent * 100)
        return "\(CPUPercentFormatter.string(from: app.cpuPercent)) (\(String(format: "%.1f%%", share)))"
    }
}
