import AppKit
import Foundation
import MacPilotLocalPortsCore
import SwiftUI

struct LocalPortsView: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @ObservedObject var model: LocalPortsModel
    @State private var protectedExpanded = false
    @State private var selectedActivity: LocalPortActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summary
            searchBar

            if model.isRefreshing && model.snapshot.activities.isEmpty {
                ProgressView(appModel.t("localPortsRefreshing"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                activityList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            model.startVisibleSession()
        }
        .onDisappear {
            model.stopVisibleSession()
        }
        .onChange(of: model.query) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                protectedExpanded = true
            }
        }
        .sheet(item: $selectedActivity) { activity in
            LocalPortDetailView(activity: activity, model: model)
                .environmentObject(appModel)
        }
        .sheet(item: $model.pendingClosePlan) { plan in
            LocalPortCloseView(plan: plan, model: model)
                .environmentObject(appModel)
        }
        .alert(
            appModel.t("localPortsScanFailed"),
            isPresented: Binding(
                get: { model.lastScanError != nil },
                set: { if !$0 { model.clearScanError() } }
            )
        ) {
            Button(appModel.t("scOK"), role: .cancel) { model.clearScanError() }
        } message: {
            Text(scanErrorMessage)
        }
        .alert(
            appModel.t("localPortsCloseFailed"),
            isPresented: Binding(
                get: { model.lastCloseError != nil },
                set: { if !$0 { model.clearCloseFeedback() } }
            )
        ) {
            Button(appModel.t("scOK"), role: .cancel) { model.clearCloseFeedback() }
        } message: {
            Text(closeErrorMessage)
        }
        .alert(
            appModel.t("localPortsCloseResult"),
            isPresented: Binding(
                get: { model.lastCloseResult != nil },
                set: { if !$0 { model.clearCloseFeedback() } }
            )
        ) {
            Button(appModel.t("scOK"), role: .cancel) { model.clearCloseFeedback() }
        } message: {
            Text(closeResultMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appModel.t("localPorts"))
                .font(.system(size: 30, weight: .bold))
            Text(appModel.t("localPortsSubtitle"))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 36)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }

    private var scanErrorMessage: String {
        LocalPortErrorFormatter.scan(model.lastScanError, language: appModel.language)
    }

    private var closeErrorMessage: String {
        LocalPortErrorFormatter.close(model.lastCloseError, language: appModel.language)
    }

    private var closeResultMessage: String {
        LocalPortErrorFormatter.result(model.lastCloseResult, language: appModel.language)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                summaryItem(appModel.t("localPortsListening", model.snapshot.portCount))
                summaryItem(appModel.t("localPortsClosable", model.snapshot.closablePortCount), tint: .green)
                summaryItem(appModel.t("localPortsLAN", model.snapshot.lanPortCount), tint: .orange)
                if let lastRefresh = model.lastRefresh {
                    summaryItem(appModel.t("localPortsLastUpdated", lastRefresh.formatted(.dateTime.hour().minute().second().locale(appModel.language.locale))))
                }
                Spacer(minLength: 0)
            }
            if model.snapshot.lanPortCount > 0 {
                Text(appModel.t("localPortsLANWarning"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !model.snapshot.limitations.isEmpty {
                Text(appModel.t("localPortsScanLimitations"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 36)
        .padding(.bottom, 14)
    }

    private func summaryItem(_ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let tint {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(text)
                .foregroundStyle(tint ?? .secondary)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField(appModel.t("localPortsSearch"), text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 430)
            Button {
                model.refreshNow()
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(appModel.t("localPortsRefresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 10)
    }

    private var activityList: some View {
        let groups = groupedActivities
        let projects = groups.filter { $0.owner.category == .project }
        let services = groups.filter { $0.owner.category != .project && !$0.isProtected }
        let protected = groups.filter(\.isProtected)
        let hasResults = !projects.isEmpty || !services.isEmpty || !protected.isEmpty

        return List {
            if !projects.isEmpty {
                Section(appModel.t("localPortsProjects")) {
                    ForEach(projects) { group in row(group) }
                }
            }
            if !services.isEmpty {
                Section(appModel.t("localPortsServices")) {
                    ForEach(services) { group in row(group) }
                }
            }
            if !protected.isEmpty {
                Section {
                    if protectedExpanded {
                        ForEach(protected) { group in row(group) }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { protectedExpanded.toggle() }
                    } label: {
                        Label(
                            appModel.t("localPortsProtected", protected.count),
                            systemImage: protectedExpanded ? "chevron.down" : "chevron.right"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if !hasResults {
                ContentUnavailableView(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? appModel.t("localPortsNoServices")
                        : appModel.t("localPortsNoSearchResults"),
                    systemImage: "network"
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private func row(_ group: LocalPortProcessGroup) -> some View {
        LocalPortRow(group: group, model: model) {
            selectedActivity = group.representative
        }
        .environmentObject(appModel)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var groupedActivities: [LocalPortProcessGroup] {
        let groups = Dictionary(grouping: model.snapshot.activities, by: { $0.process.pid })
        return groups.values
            .map { LocalPortProcessGroup(activities: $0.sorted { $0.listener.port < $1.listener.port }) }
            .filter { group in
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || group.activities.contains(where: model.matchesQuery)
            }
            .sorted {
                if $0.owner.category.sortIndex != $1.owner.category.sortIndex {
                    return $0.owner.category.sortIndex < $1.owner.category.sortIndex
                }
                return $0.owner.label.localizedStandardCompare($1.owner.label) == .orderedAscending
            }
    }
}

private struct LocalPortProcessGroup: Identifiable {
    let activities: [LocalPortActivity]

    var id: String { "pid:\(representative.process.pid)" }
    var representative: LocalPortActivity { activities[0] }
    var owner: LocalPortOwner { representative.owner }
    var ports: [Int] { activities.map(\.listener.port) }
    var isLAN: Bool { activities.contains { $0.scope == .lan } }
    var isProtected: Bool { activities.contains { LocalPortCloseService.protectionReason(for: $0) != nil } }
    var protectionReason: LocalPortProtectionReason? {
        activities.lazy.compactMap { LocalPortCloseService.protectionReason(for: $0) }.first
    }
}

private extension LocalPortOwnerCategory {
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

private struct LocalPortRow: View {
    @EnvironmentObject private var appModel: MacPilotModel
    let group: LocalPortProcessGroup
    @ObservedObject var model: LocalPortsModel
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    LocalPortIconView(activity: group.representative)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(LocalPortErrorFormatter.ownerLabel(group.owner, language: appModel.language))
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(group.ports.map(String.init).joined(separator: "  "))
                                .font(.body.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text(group.representative.process.command)
                            Text("·")
                            Text(appModel.t("localPortsPID", group.representative.process.pid))
                            if let uptime = group.representative.process.compactUptime {
                                Text("·")
                                Text(uptime)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let cwd = group.representative.process.cwd {
                            Text(localPortCompactPath(cwd))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(appModel.t(group.isLAN ? "localPortsLANScope" : "localPortsLocal"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(group.isLAN ? .orange : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let url = LocalPortURLResolver.url(
                port: group.representative.listener.port,
                addresses: group.representative.listener.addresses
            ) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help(appModel.t("localPortsOpenBrowser"))
            }

            if group.isProtected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(LocalPortErrorFormatter.protection(group.protectionReason, language: appModel.language))
            } else {
                Button(role: .destructive) {
                    model.prepareClose(for: group.representative)
                } label: {
                    if model.isPreparingClose {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "stop.circle")
                    }
                }
                .buttonStyle(.borderless)
                .help(appModel.t("localPortsClose"))
                .disabled(model.isPreparingClose || model.isClosing)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LocalPortDetailView: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    let activity: LocalPortActivity
    @ObservedObject var model: LocalPortsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                LocalPortIconView(activity: activity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalPortErrorFormatter.ownerLabel(activity.owner, language: appModel.language)).font(.title2.bold())
                    Text(activity.process.command).foregroundStyle(.secondary)
                }
                Spacer()
                Text(appModel.t(activity.scope == .lan ? "localPortsLANScope" : "localPortsLocal"))
                    .foregroundStyle(activity.scope == .lan ? .orange : .secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    detail(appModel.t("localPortsPort"), String(activity.listener.port))
                    detail(appModel.t("localPortsAddresses"), activity.listener.addresses.joined(separator: ", "))
                    detail(appModel.t("localPortsPID"), String(activity.process.pid))
                    detail(appModel.t("localPortsPPID"), activity.process.ppid.map(String.init) ?? "—")
                    detail(appModel.t("localPortsUser"), activity.process.user ?? "—")
                    detail(appModel.t("localPortsExecutable"), activity.process.executablePath ?? "—")
                    detail(appModel.t("localPortsWorkingDirectory"), localPortCompactPath(activity.process.cwd))
                    detail(appModel.t("localPortsUptime"), activity.process.uptime ?? "—")
                    detail(appModel.t("localPortsArguments"), activity.process.arguments ?? "—")
                    detail(appModel.t("localPortsProcess"), activity.process.command)
                    if let project = activity.project {
                        detail(appModel.t("localPortsProjectRoot"), localPortCompactPath(project.root))
                    }
                    if !activity.parentChain.isEmpty {
                        detail(
                            appModel.t("localPortsParentChain"),
                            activity.parentChain.map { "\($0.command) (PID \($0.pid))" }.joined(separator: " → ")
                        )
                    }
                    detail(
                        appModel.t("localPortsOwnerEvidence"),
                        LocalPortErrorFormatter.ownerEvidence(activity.owner.reason, language: appModel.language)
                    )
                    detail(
                        appModel.t("localPortsProtectedReason"),
                        LocalPortErrorFormatter.protection(
                            LocalPortCloseService.protectionReason(for: activity),
                            language: appModel.language
                        )
                    )
                }
            }

            HStack {
                Button(appModel.t("cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(appModel.t("localPortsCopyPort")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(activity.listener.port), forType: .string)
                }
                Button(appModel.t("localPortsCopyPID")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(activity.process.pid), forType: .string)
                }
                if let path = activity.process.executablePath {
                    Button(appModel.t("localPortsCopyPath")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
                if let url = LocalPortURLResolver.url(
                    port: activity.listener.port,
                    addresses: activity.listener.addresses
                ) {
                    Button(appModel.t("localPortsOpenBrowser")) { NSWorkspace.shared.open(url) }
                }
                if let cwd = activity.process.cwd {
                    Button(appModel.t("localPortsRevealProject")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                    }
                }
                if LocalPortCloseService.protectionReason(for: activity) == nil {
                    Button(appModel.t("localPortsClose"), role: .destructive) {
                        model.prepareClose(for: activity)
                    }
                    .disabled(model.isPreparingClose || model.isClosing)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 460)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.subheadline.weight(.medium)).frame(width: 150, alignment: .leading)
            Text(value).font(.subheadline.monospaced()).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct LocalPortCloseView: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    let plan: LocalPortClosePlan
    @ObservedObject var model: LocalPortsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(appModel.t("localPortsCloseTitle", LocalPortErrorFormatter.ownerLabel(plan.activity.owner, language: appModel.language)))
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 7) {
                Text(plan.activity.process.command).font(.headline)
                Text(appModel.t("localPortsPID", plan.pid))
                Text(appModel.t("localPortsPort", plan.port))
                if let uptime = plan.activity.process.uptime {
                    Text(appModel.t("localPortsUptime", uptime))
                }
                if let project = plan.activity.project {
                    Text(appModel.t("localPortsProjectRoot", localPortCompactPath(project.root)))
                }
            }

            if !plan.otherPorts.isEmpty {
                Text(appModel.t("localPortsOtherPorts", plan.otherPorts.map(String.init).joined(separator: ", ")))
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Text(appModel.t("localPortsCloseHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(appModel.t("cancel")) {
                    model.cancelPendingClose()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(appModel.t("localPortsCloseConfirm"), role: .destructive) {
                    model.confirmClose()
                }
                .disabled(model.isClosing)
                if model.isClosing { ProgressView().controlSize(.small) }
            }
        }
        .padding(24)
        .frame(minWidth: 430)
    }
}

enum LocalPortErrorFormatter {
    static func ownerLabel(_ owner: LocalPortOwner, language: AppLanguage) -> String {
        owner.category == .unknown
            ? AppText.value("localPortsUnknown", language: language)
            : owner.label
    }

    static func scan(_ error: LocalPortScanError?, language: AppLanguage) -> String {
        guard let error else { return AppText.value("localPortsScanFailed", language: language) }
        switch error {
        case let .commandFailed(command, status):
            return AppText.value("localPortsCommandFailed", language: language, command, status)
        case let .missingTool(path):
            return AppText.value("localPortsMissingTool", language: language, path)
        }
    }

    static func close(_ error: LocalPortCloseError?, language: AppLanguage) -> String {
        guard let error else { return AppText.value("localPortsCloseFailed", language: language) }
        switch error {
        case let .nothingListening(port): return AppText.value("localPortsNothingListening", language: language, port)
        case let .multipleOwners(port, pids):
            return AppText.value("localPortsMultipleOwners", language: language, port, pids.map(String.init).joined(separator: ", "))
        case let .processNotListening(pid, port): return AppText.value("localPortsProcessNotListening", language: language, pid, port)
        case let .protected(reason): return protection(reason, language: language)
        case let .missingIdentity(pid): return AppText.value("localPortsMissingIdentity", language: language, pid)
        case let .missingStartTime(pid): return AppText.value("localPortsMissingStartTime", language: language, pid)
        case let .processDisappeared(pid): return AppText.value("localPortsProcessDisappeared", language: language, pid)
        case let .newPortOwner(port, pid): return AppText.value("localPortsNewPortOwner", language: language, port, pid)
        case let .identityChanged(pid): return AppText.value("localPortsIdentityChanged", language: language, pid)
        case let .signalFailed(pid, errno): return AppText.value("localPortsSignalFailed", language: language, pid, errno)
        case .verificationFailed: return AppText.value("localPortsVerificationFailed", language: language)
        case .rescanFailed: return AppText.value("localPortsRescanFailed", language: language)
        }
    }

    static func protection(_ reason: LocalPortProtectionReason?, language: AppLanguage) -> String {
        guard let reason else { return AppText.value("localPortsClosableProcess", language: language) }
        switch reason {
        case .runningAsRoot: return AppText.value("localPortsProtectedRoot", language: language)
        case let .protectedPID(pid): return AppText.value("localPortsProtectedPID", language: language, pid)
        case let .unknownUser(pid): return AppText.value("localPortsUnknownUser", language: language, pid)
        case let .anotherUser(pid): return AppText.value("localPortsOtherUser", language: language, pid)
        case let .unknownExecutable(pid): return AppText.value("localPortsUnknownExecutable", language: language, pid)
        case let .systemExecutable(path): return AppText.value("localPortsSystemProcess", language: language, localPortCompactPath(path))
        case let .applicationBundle(path): return AppText.value("localPortsApplicationProcess", language: language, localPortCompactPath(path))
        }
    }

    static func ownerEvidence(_ reason: LocalPortOwnerReason, language: AppLanguage) -> String {
        switch reason {
        case let .project(marker, markerPath):
            return AppText.value(
                "localPortsEvidenceProject",
                language: language,
                marker,
                localPortCompactPath(markerPath)
            )
        case let .directApplication(path):
            return AppText.value("localPortsEvidenceDirectApplication", language: language, localPortCompactPath(path))
        case let .parentApplication(pid, path):
            return AppText.value(
                "localPortsEvidenceParentApplication",
                language: language,
                pid,
                localPortCompactPath(path)
            )
        case let .systemExecutable(path):
            return AppText.value("localPortsEvidenceSystemExecutable", language: language, localPortCompactPath(path))
        case let .nodePackage(name, directory):
            return AppText.value(
                "localPortsEvidenceNodePackage",
                language: language,
                name,
                localPortCompactPath(directory)
            )
        case let .pythonModule(name):
            return AppText.value("localPortsEvidencePythonModule", language: language, name)
        case let .knownService(name):
            return AppText.value("localPortsEvidenceKnownService", language: language, name)
        case let .userInstalledExecutable(path):
            return AppText.value("localPortsEvidenceUserExecutable", language: language, localPortCompactPath(path))
        case .unknown:
            return AppText.value("localPortsEvidenceUnknown", language: language)
        }
    }

    static func result(_ result: LocalPortCloseResult?, language: AppLanguage) -> String {
        guard let result else { return "" }
        if result.portFree {
            return AppText.value("localPortsPortFreed", language: language)
        }
        if result.targetStoppedListening {
            return AppText.value("localPortsProcessStoppedPortTaken", language: language)
        }
        return AppText.value("localPortsStillListening", language: language)
    }
}
