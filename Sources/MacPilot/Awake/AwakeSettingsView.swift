import SwiftUI

private enum AwakeDefaultDurationPreset: String, CaseIterable, Identifiable {
    case unlimited
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case customDuration
    case untilDate

    var id: String { rawValue }

    var minutes: Int? {
        switch self {
        case .unlimited: 0
        case .thirtyMinutes: 30
        case .oneHour: 60
        case .twoHours: 120
        case .fourHours: 240
        case .customDuration, .untilDate: nil
        }
    }
}

struct AwakeSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var awake: AwakeSessionManager
    @ObservedObject var triggerEngine: AwakeTriggerEngine
    @ObservedObject var profiles: AwakeProfileStore

    @State private var isSessionProtectionSheetPresented = false
    @State private var editingProfile: AwakeSessionProfile?
    @State private var isProfileEditorPresented = false
    @State private var profilePendingDeletion: AwakeSessionProfile?
    @State private var profilePendingLaunch: AwakeSessionProfile?
    @State private var showsProfileSwitchConfirmation = false
    @State private var showsProfileDeletionConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("awake")).font(.system(size: 30, weight: .bold))
                    Text(model.t("awakeSubtitle")).foregroundStyle(.secondary)
                }

                sessionCard
                sessionDetailsCard
                profilesCard
                AwakeTriggerListView(triggerEngine: triggerEngine)
                powerStateCard
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .onAppear {
            // The closed-lid service status is a snapshot; System Settings can
            // change it while this page is closed, so re-read it on entry.
            awake.refreshClosedLidServiceState()
        }
        .sheet(isPresented: $isSessionProtectionSheetPresented) {
            AwakeSessionProtectionSheet(awake: awake, profiles: profiles)
                .environmentObject(model)
        }
        .sheet(isPresented: $isProfileEditorPresented) {
            if let editingProfile {
                AwakeProfileEditorSheet(profiles: profiles, profile: editingProfile)
                    .environmentObject(model)
            } else {
                AwakeProfileEditorSheet(profiles: profiles, configuration: AwakeSessionProfileConfiguration.capture(from: awake.settings))
                    .environmentObject(model)
            }
        }
        .confirmationDialog(
            profileSwitchMessage,
            isPresented: $showsProfileSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.t("awakeProfileSwitchConfirm")) {
                guard let profile = profilePendingLaunch else { return }
                profiles.launch(profile.id, in: awake, replacingActiveSessions: true)
            }
            Button(model.t("cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            model.t("awakeProfileDeleteMessage", profilePendingDeletion?.name ?? ""),
            isPresented: $showsProfileDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.t("awakeProfileDelete"), role: .destructive) {
                guard let profile = profilePendingDeletion else { return }
                profiles.delete(id: profile.id)
            }
            Button(model.t("cancel"), role: .cancel) {}
        }
    }

    /// 会话页与方案的新建、编辑共用同一套选项。
    private var sessionCard: some View {
        SettingsCard {
            Text(model.t("awakeSessionConfig")).font(.headline)
            Text(model.t("awakeSessionConfigHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            AwakeSessionOptionsView(configuration: sessionConfigurationBinding)
            if awake.settings.defaultPolicy.preventClosedLidSleep || awake.desiredAwakeState.preventClosedLidSleep {
                closedLidServiceStatus
            }

            HStack {
                Button(model.t("awakeStartSession")) {
                    isSessionProtectionSheetPresented = true
                }
                .macPilotProminentButtonStyle()
                if awake.hasInteractiveSession {
                    Button(model.t("awakeStop"), action: awake.endAllInteractiveSessions)
                }
            }
        }
    }

    private var sessionDetailsCard: some View {
        SettingsCard {
            Text(model.t("awakeSessionDetails")).font(.headline)

            if awake.settings.defaultSession.autoStartOnLaunch || awake.settings.defaultSession.autoStartOnWake {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("awakeAutoStart"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if awake.settings.defaultSession.autoStartOnLaunch {
                        Label(model.t("awakeAutoStartOnLaunch"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if awake.settings.defaultSession.autoStartOnWake {
                        Label(model.t("awakeAutoStartOnWake"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if awake.activeSessions.isEmpty {
                Label(model.t("awakeNoActiveSession"), systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(awake.activeSessions) { session in
                            AwakeSessionDetailRow(
                                session: session,
                                isClosedLidSleepActive: awake.isClosedLidSleepActive,
                                now: context.date,
                                triggerName: awakeTriggerName(for: session.source, triggerEngine: triggerEngine),
                                onStop: { stopAwakeSession(session, awake: awake, triggerEngine: triggerEngine) }
                            )
                            if session.id != awake.activeSessions.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            if awake.safetyProtectionActive {
                warningBanner(Label(model.t("awakeSafetyActive"), systemImage: "battery.25"))
            }
            if let failure = awake.lastAssertionFailure {
                warningBanner(Label(model.t("awakeAssertionError", failure.code), systemImage: "exclamationmark.triangle.fill"))
            }
        }
    }

    /// 方案管理：列表按「最近使用」倒序，点击开始即可按保存的配置启动。
    private var profilesCard: some View {
        SettingsCard {
            HStack {
                Text(model.t("awakeProfiles")).font(.headline)
                Spacer()
                Button {
                    editingProfile = nil
                    isProfileEditorPresented = true
                } label: {
                    Label(model.t("awakeProfileNew"), systemImage: "plus")
                }
            }
            Text(model.t("awakeProfilesHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if profiles.profiles.isEmpty {
                Text(model.t("awakeProfilesEmpty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedProfiles) { profile in
                    AwakeProfileRowView(
                        profile: profile,
                        summary: profileSummary(for: profile.configuration),
                        onStart: { requestProfileLaunch(profile) },
                        onEdit: {
                            editingProfile = profile
                            isProfileEditorPresented = true
                        },
                        onDuplicate: { duplicateProfile(profile) },
                        onDelete: {
                            profilePendingDeletion = profile
                            showsProfileDeletionConfirmation = true
                        }
                    )
                    if profile.id != sortedProfiles.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var sortedProfiles: [AwakeSessionProfile] {
        profiles.profiles.sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (lhsDate?, rhsDate?): lhsDate > rhsDate
            case (nil, .some): false
            case (.some, nil): true
            default: lhs.createdAt > rhs.createdAt
            }
        }
    }

    /// 点击方案：空闲时直接启动；已有用户主动开始的 Session 时先确认切换。
    private func requestProfileLaunch(_ profile: AwakeSessionProfile) {
        guard awake.hasInteractiveSession else {
            profiles.launch(profile.id, in: awake)
            return
        }
        profilePendingLaunch = profile
        showsProfileSwitchConfirmation = true
    }

    private func duplicateProfile(_ profile: AwakeSessionProfile) {
        let base = profile.name + model.t("awakeProfileDuplicateSuffix")
        _ = profiles.duplicate(id: profile.id, suggestedName: base)
    }

    private var profileSwitchMessage: String {
        let separator = model.language.locale.language.languageCode?.identifier == "zh" ? "、" : ", "
        let runningNames = awake.activeInteractiveSessions.map { sessionName($0) }.joined(separator: separator)
        return model.t("awakeProfileSwitchMessage", runningNames, profilePendingLaunch?.name ?? "")
    }

    private func sessionName(_ session: AwakeSession) -> String {
        if case .profile(let name) = session.source { return name }
        return model.t("awakeManualSource")
    }

    /// 方案摘要：时长 + 关键行为，一行看懂这个方案会做什么。
    private func profileSummary(for configuration: AwakeSessionProfileConfiguration) -> String {
        var parts: [String] = [profileDurationText(configuration.durationMinutes)]
        if configuration.preventClosedLidSleep {
            parts.append(model.t("awakeClosedLidSleep"))
        }
        parts.append(
            configuration.preventDisplaySleep
                ? model.t("awakeDisplaySleepToggle")
                : model.t("awakeDisplaySleepAllowed")
        )
        if configuration.lowBatteryProtectionEnabled {
            parts.append(model.t("awakeEndSessionBelowBattery", configuration.minimumBatteryLevel))
        }
        if configuration.blockScreenSaver {
            parts.append(model.t("awakeBlockScreenSaver"))
        }
        if configuration.endOnForcedSleep {
            parts.append(model.t("awakeEndOnForcedSleep"))
        }
        return parts.joined(separator: " · ")
    }

    private func profileDurationText(_ minutes: Int) -> String {
        guard minutes > 0 else { return model.t("awakeUnlimited") }
        return Duration.seconds(TimeInterval(minutes) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.top, 2)
    }

    private var powerStateCard: some View {
        SettingsCard {
            Text(model.t("awakePowerState")).font(.headline)
            HStack {
                Label(model.t("awakeBattery"), systemImage: "battery.75")
                Spacer()
                Text(batteryDescription)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(model.t("awakeExternalPower"), systemImage: "powerplug")
                Spacer()
                Text(awake.powerState.onExternalPower ? model.t("awakeConnected") : model.t("awakeDisconnected"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(model.t("awakeCharging"), systemImage: "bolt.fill")
                Spacer()
                Text(awake.powerState.charging ? model.t("awakeYes") : model.t("awakeNo"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sessionConfigurationBinding: Binding<AwakeSessionProfileConfiguration> {
        Binding(
            get: { AwakeSessionProfileConfiguration.capture(from: awake.settings) },
            set: { configuration in
                awake.updateSettings { configuration.applySessionSettings(to: &$0) }
            }
        )
    }

    @ViewBuilder
    private var closedLidServiceStatus: some View {
        switch awake.closedLidServiceState {
        case .unavailable:
            warningBanner(Label(
                model.t("awakeClosedLidServiceUnavailable"),
                systemImage: "exclamationmark.triangle.fill"
            ))
        case .notRegistered:
            closedLidServiceBanner(
                message: model.t("awakeClosedLidServiceRequired"),
                actionTitle: model.t("awakeClosedLidServiceApprove"),
                action: { Task { await awake.prepareClosedLidService() } }
            )
        case .requiresApproval:
            closedLidServiceBanner(
                message: model.t("awakeClosedLidServiceRequiresApproval"),
                actionTitle: model.t("awakeClosedLidServiceOpenSettings"),
                action: { awake.openClosedLidServiceSettings() }
            )
        case .error(let message):
            closedLidServiceBanner(
                message: model.t("awakeClosedLidServiceNotApplied"),
                actionTitle: model.t("awakeClosedLidServiceRepair"),
                action: { Task { await awake.prepareClosedLidService() } }
            )
            .help(model.t("awakeClosedLidError", message))
        case .ready:
            if awake.desiredAwakeState.preventClosedLidSleep {
                closedLidServiceBanner(
                    message: model.t("awakeClosedLidServiceNotApplied"),
                    actionTitle: model.t("awakeClosedLidServiceRepair"),
                    action: { awake.refreshClosedLidServiceState() }
                )
            } else {
                Label(model.t("awakeClosedLidServiceReady"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .enabling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.t("awakeClosedLidServiceEnabling"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .enabled:
            Label(
                model.t(awake.isClosedLidSleepActive ? "awakeClosedLidServiceVerified" : "awakeClosedLidServiceNotApplied"),
                systemImage: awake.isClosedLidSleepActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(awake.isClosedLidSleepActive ? Color.green : Color.orange)
        }
    }

    private func closedLidServiceBanner(
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        warningBanner(
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                Button(actionTitle, action: action)
                    .macPilotProminentButtonStyle()
                    .controlSize(.small)
            }
        )
    }

    private var batteryDescription: String {
        guard let level = awake.powerState.batteryLevelPercentage else { return model.t("awakeUnknown") }
        return model.t("awakeBatteryValue", level)
    }

    private func warningBanner<Content: View>(_ content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.orange.opacity(0.35))
            )
    }

}

struct AwakeSessionProtectionDraft {
    /// 第二步的选项每次都从固定默认值开始，不记住上次的选择。
    var endOnForcedSleep = false
    var safetyPolicy = AwakeSafetyPolicy.standard
    var warnBeforeBatteryTermination = false
    var ignoreBatteryLevelOnExternalPower = true
    var restartOnPowerReconnect = false
    var autoStartOnLaunch = false
    var autoStartOnWake = false
    var launchProfileEnabled = false
    var launchProfileID: UUID?

    init() {}

    init(configuration: AwakeSessionProfileConfiguration) {
        endOnForcedSleep = configuration.endOnForcedSleep
        safetyPolicy.lowBatteryProtectionEnabled = configuration.lowBatteryProtectionEnabled
        safetyPolicy.minimumBatteryLevel = configuration.minimumBatteryLevel
        warnBeforeBatteryTermination = configuration.warnBeforeBatteryTermination
        ignoreBatteryLevelOnExternalPower = configuration.ignoreBatteryLevelOnExternalPower
        restartOnPowerReconnect = configuration.restartOnPowerReconnect
        autoStartOnLaunch = configuration.autoStartOnLaunch
        autoStartOnWake = configuration.autoStartOnWake
    }

    func applying(to configuration: AwakeSessionProfileConfiguration) -> AwakeSessionProfileConfiguration {
        var result = configuration
        result.endOnForcedSleep = endOnForcedSleep
        result.lowBatteryProtectionEnabled = safetyPolicy.lowBatteryProtectionEnabled
        result.minimumBatteryLevel = safetyPolicy.minimumBatteryLevel
        result.warnBeforeBatteryTermination = warnBeforeBatteryTermination
        result.ignoreBatteryLevelOnExternalPower = ignoreBatteryLevelOnExternalPower
        result.restartOnPowerReconnect = restartOnPowerReconnect
        result.autoStartOnLaunch = autoStartOnLaunch
        result.autoStartOnWake = autoStartOnWake
        return result
    }

}

private struct AwakeSessionProtectionSheet: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var awake: AwakeSessionManager
    @ObservedObject var profiles: AwakeProfileStore

    @State private var draft = AwakeSessionProtectionDraft()
    @State private var isSaveProfileSheetPresented = false

    init(awake: AwakeSessionManager, profiles: AwakeProfileStore) {
        self.awake = awake
        self.profiles = profiles
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.t("awakeSessionProtectionTitle"))
                            .font(.system(size: 24, weight: .bold))
                        Text(model.t("awakeSessionProtectionHint"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    AwakeSessionProtectionOptionsView(draft: $draft)
                }
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button(model.t("cancel")) {
                    dismiss()
                }
                Button(model.t("awakeSaveProfile")) {
                    isSaveProfileSheetPresented = true
                }
                Button(model.t("awakeSessionProtectionConfirm")) {
                    confirm()
                }
                .macPilotProminentButtonStyle()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 580, idealHeight: 660)
        .sheet(isPresented: $isSaveProfileSheetPresented) {
            // 保存方案在第二步：把弹窗里确认前的完整配置（含本页保护选项）
            // 存为方案，保存后这一步也一并收起。
            AwakeProfileSaveSheet(profiles: profiles, onSaved: { dismiss() }) {
                draftConfiguration()
            }
            .environmentObject(model)
        }
    }

    private func draftConfiguration() -> AwakeSessionProfileConfiguration {
        draft.applying(to: AwakeSessionProfileConfiguration.capture(from: awake.settings))
    }

    private func confirm() {
        let selected = draft
        let shouldRequestBatteryNotification =
            !awake.settings.defaultSession.warnBeforeBatteryTermination
            && selected.warnBeforeBatteryTermination

        if shouldRequestBatteryNotification {
            AwakeNotifications.requestAuthorization()
        }

        awake.updateSettings { settings in
            settings.defaultPolicy.endOnForcedSleep = selected.endOnForcedSleep
            settings.safetyPolicy = selected.safetyPolicy
            settings.defaultSession.warnBeforeBatteryTermination = selected.warnBeforeBatteryTermination
            settings.defaultSession.ignoreBatteryLevelOnExternalPower = selected.ignoreBatteryLevelOnExternalPower
            settings.defaultSession.restartOnPowerReconnect = selected.restartOnPowerReconnect
            settings.defaultSession.autoStartOnLaunch = selected.autoStartOnLaunch
            settings.defaultSession.autoStartOnWake = selected.autoStartOnWake
            // 本会话的自动开启不再间接指向另一个方案；保留历史存储键。
            settings.defaultSession.launchProfileEnabled = false
            settings.defaultSession.launchProfileID = nil
        }
        _ = awake.startDefaultSession()
        dismiss()
    }
}

private struct AwakeProfileRowView: View {
    @EnvironmentObject private var model: MacPilotModel
    let profile: AwakeSessionProfile
    let summary: String
    let onStart: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(profile.name, systemImage: "flame.fill")
                    .font(.body.weight(.semibold))
                Spacer()
                Button(model.t("awakeProfileStart"), action: onStart)
                    .macPilotProminentButtonStyle()
                    .controlSize(.small)
                Menu {
                    Button(model.t("edit"), action: onEdit)
                    Button(model.t("awakeProfileDuplicate"), action: onDuplicate)
                    Button(model.t("awakeProfileDelete"), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text(model.t("awakeProfileActions")))
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(lastUsedText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lastUsedText: String {
        guard let lastUsedAt = profile.lastUsedAt else { return model.t("awakeProfileNeverUsed") }
        return model.t(
            "awakeProfileLastUsed",
            lastUsedAt.formatted(.relative(presentation: .named).locale(model.language.locale))
        )
    }
}

/// 保存方案弹窗：命名当前配置。同名时先确认再覆盖。
/// `onSaved` 在成功保存（新建或覆盖）后回调，供承载它的第二步弹窗收起自己。
private struct AwakeProfileSaveSheet: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profiles: AwakeProfileStore
    let makeConfiguration: () -> AwakeSessionProfileConfiguration
    var onSaved: (() -> Void)?

    init(
        profiles: AwakeProfileStore,
        onSaved: (() -> Void)? = nil,
        makeConfiguration: @escaping () -> AwakeSessionProfileConfiguration
    ) {
        self.profiles = profiles
        self.onSaved = onSaved
        self.makeConfiguration = makeConfiguration
    }

    @State private var name = ""
    @State private var pendingOverwrite: AwakeSessionProfile?
    @State private var showsOverwriteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("awakeProfileSaveTitle"))
                        .font(.system(size: 24, weight: .bold))
                    Text(model.t("awakeProfileSaveHint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(model.t("awakeProfileName"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                TextField(model.t("awakeProfileNamePlaceholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(24)

            Spacer()

            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button(model.t("cancel")) { dismiss() }
                Button(model.t("save"), action: save)
                    .macPilotProminentButtonStyle()
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 240, idealHeight: 260)
        .confirmationDialog(
            model.t("awakeProfileOverwriteMessage", pendingOverwrite?.name ?? ""),
            isPresented: $showsOverwriteConfirmation,
            titleVisibility: .visible
        ) {
            Button(model.t("awakeProfileOverwrite"), action: overwrite)
            Button(model.t("cancel"), role: .cancel) {}
        }
    }

    private var trimmedName: String {
        AwakeSessionProfile.normalizedName(name)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let existing = profiles.profile(named: trimmedName) {
            pendingOverwrite = existing
            showsOverwriteConfirmation = true
            return
        }
        profiles.create(name: trimmedName, configuration: makeConfiguration())
        onSaved?()
        dismiss()
    }

    private func overwrite() {
        guard let existing = pendingOverwrite else { return }
        profiles.overwriteConfiguration(of: existing.id, with: makeConfiguration())
        onSaved?()
        dismiss()
    }
}

/// 方案时长预设。方案不提供「直到指定时间」：绝对日期保存后必然过期，
/// 保存流程会把剩余时间折算成分钟。
/// 所有创建和编辑入口共用的第一步会话选项。
private struct AwakeSessionOptionsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @Binding var configuration: AwakeSessionProfileConfiguration

    var body: some View {
        Picker(model.t("awakeSessionDuration"), selection: durationPresetBinding) {
            Text(model.t("awakeUnlimited")).tag(AwakeDefaultDurationPreset.unlimited)
            Text(model.t("awake30Minutes")).tag(AwakeDefaultDurationPreset.thirtyMinutes)
            Text(model.t("awakeOneHour")).tag(AwakeDefaultDurationPreset.oneHour)
            Text(model.t("awakeTwoHours")).tag(AwakeDefaultDurationPreset.twoHours)
            Text(model.t("awakeFourHours")).tag(AwakeDefaultDurationPreset.fourHours)
            Text(model.t("awakeCustomDuration")).tag(AwakeDefaultDurationPreset.customDuration)
            Text(model.t("awakeUntilDate")).tag(AwakeDefaultDurationPreset.untilDate)
        }

        if durationPreset == .customDuration {
            HStack {
                Text(model.t("awakeCustomDuration"))
                Spacer()
                TextField(model.t("awakeCustomDuration"), value: customDurationMinutesBinding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        } else if durationPreset == .untilDate {
            DatePicker(
                model.t("awakeUntilDate"),
                selection: untilDateBinding,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
        }

        sectionLabel(model.t("awakeDisplaySection"))
        Toggle(model.t("awakeDisplaySleepAllowed"), isOn: displaySleepAllowedBinding)
            .toggleStyle(.switch)
        Text(model.t("awakeDisplaySleepHint"))
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle(model.t("awakeAllowSystemSleepWhenDisplayOff"), isOn: $configuration.allowSystemSleepWhenDisplayOff)
            .toggleStyle(.switch)

        Toggle(model.t("awakeClosedLidSleep"), isOn: $configuration.preventClosedLidSleep)
            .toggleStyle(.switch)
        Text(model.t("awakeClosedLidSleepHint"))
            .font(.caption)
            .foregroundStyle(.secondary)
        if configuration.preventClosedLidSleep {
            Text(model.t("awakeClosedLidSleepWarning"))
                .font(.caption)
                .foregroundStyle(.orange)
        }

        sectionLabel(model.t("awakeScreenSaver"))
        Toggle(model.t("awakeBlockScreenSaver"), isOn: $configuration.blockScreenSaver)
            .toggleStyle(.switch)
        if configuration.blockScreenSaver {
            SettingsSlider(
                value: screenSaverIdleBinding,
                in: 5...180,
                step: 5,
                label: model.t("awakeScreenSaverAllowsAfter", configuration.screenSaverIdleMinutes),
                format: { model.t("awakeScreenSaverAllowsAfter", Int($0.rounded())) }
            )
            Text(model.t("awakeScreenSaverAllowsAfter", configuration.screenSaverIdleMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.t("awakeScreenSaverAccessibilityHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    }

    private var durationPreset: AwakeDefaultDurationPreset {
        if configuration.untilDate != nil { return .untilDate }
        switch configuration.durationMinutes {
        case 0: return .unlimited
        case 30: return .thirtyMinutes
        case 60: return .oneHour
        case 120: return .twoHours
        case 240: return .fourHours
        default: return .customDuration
        }
    }

    private var durationPresetBinding: Binding<AwakeDefaultDurationPreset> {
        Binding(
            get: { durationPreset },
            set: { preset in
                if preset == .untilDate {
                    configuration.untilDate = max(configuration.untilDate ?? Date().addingTimeInterval(3600), Date().addingTimeInterval(60))
                } else {
                    configuration.untilDate = nil
                    if let minutes = preset.minutes { configuration.durationMinutes = minutes }
                }
            }
        )
    }

    private var untilDateBinding: Binding<Date> {
        Binding(
            get: { configuration.untilDate ?? Date().addingTimeInterval(3600) },
            set: { configuration.untilDate = $0 }
        )
    }

    private var customDurationMinutesBinding: Binding<Int> {
        Binding(
            get: { max(1, configuration.durationMinutes) },
            set: { configuration.durationMinutes = max(1, $0) }
        )
    }

    private var displaySleepAllowedBinding: Binding<Bool> {
        Binding(
            get: { !configuration.preventDisplaySleep },
            set: { configuration.preventDisplaySleep = !$0 }
        )
    }

    private var screenSaverIdleBinding: Binding<Double> {
        Binding(
            get: { Double(configuration.screenSaverIdleMinutes) },
            set: { configuration.screenSaverIdleMinutes = Int($0.rounded()) }
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.subheadline).fontWeight(.semibold).padding(.top, 2)
    }
}

private struct AwakeSessionProtectionOptionsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @Binding var draft: AwakeSessionProtectionDraft

    var body: some View {
        forceSleepSection
        Divider()
        batteryProtectionSection
        Divider()
        powerAdapterSection
        Divider()
        autoStartSection
    }

    /// 创建会话和编辑方案共用的保护选项。
    private var forceSleepSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(model.t("awakeForceSleep"))
            Toggle(model.t("awakeEndOnForcedSleep"), isOn: endOnForcedSleepBinding)
                .toggleStyle(.switch)
        }
    }

    private var batteryProtectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(model.t("awakeBatteryProtection"))
            Toggle(
                model.t("awakeEndSessionBelowBattery", draft.safetyPolicy.minimumBatteryLevel),
                isOn: batteryProtectionBinding
            )
            .toggleStyle(.switch)

            if draft.safetyPolicy.lowBatteryProtectionEnabled {
                HStack(spacing: 12) {
                    SettingsSlider(
                        value: batteryThresholdBinding,
                        in: 10...50,
                        step: 1,
                        label: model.t("awakeEndSessionBelowBattery", draft.safetyPolicy.minimumBatteryLevel),
                        format: { model.t("awakeBatteryValue", Int($0.rounded())) }
                    )
                    Text("\(draft.safetyPolicy.minimumBatteryLevel)%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle(model.t("awakeWarnBeforeBatteryEnd"), isOn: warnBeforeBatteryEndBinding)
                    .toggleStyle(.switch)
                Text(model.t("awakeBatteryProtectionHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var powerAdapterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(model.t("awakePowerAdapterSection"))
            Toggle(model.t("awakeIgnoreBatteryOnPower"), isOn: ignoreBatteryOnPowerBinding)
                .toggleStyle(.switch)
            Toggle(model.t("awakeRestartOnPowerReconnect"), isOn: restartOnPowerReconnectBinding)
                .toggleStyle(.switch)
            if draft.restartOnPowerReconnect {
                Text(model.t("awakeRestartUsesDefaultDuration"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var autoStartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(model.t("awakeAutoStart"))
            Toggle(model.t("awakeAutoStartOnLaunch"), isOn: autoStartOnLaunchBinding)
                .toggleStyle(.switch)
            Toggle(model.t("awakeAutoStartOnWake"), isOn: autoStartOnWakeBinding)
                .toggleStyle(.switch)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.top, 2)
    }

    private var endOnForcedSleepBinding: Binding<Bool> {
        Binding(
            get: { draft.endOnForcedSleep },
            set: { draft.endOnForcedSleep = $0 }
        )
    }

    private var batteryProtectionBinding: Binding<Bool> {
        Binding(
            get: { draft.safetyPolicy.lowBatteryProtectionEnabled },
            set: { draft.safetyPolicy.lowBatteryProtectionEnabled = $0 }
        )
    }

    private var batteryThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(draft.safetyPolicy.minimumBatteryLevel) },
            set: { draft.safetyPolicy.minimumBatteryLevel = Int($0.rounded()) }
        )
    }

    private var warnBeforeBatteryEndBinding: Binding<Bool> {
        Binding(
            get: { draft.warnBeforeBatteryTermination },
            set: { draft.warnBeforeBatteryTermination = $0 }
        )
    }

    private var ignoreBatteryOnPowerBinding: Binding<Bool> {
        Binding(
            get: { draft.ignoreBatteryLevelOnExternalPower },
            set: { draft.ignoreBatteryLevelOnExternalPower = $0 }
        )
    }

    private var restartOnPowerReconnectBinding: Binding<Bool> {
        Binding(
            get: { draft.restartOnPowerReconnect },
            set: { draft.restartOnPowerReconnect = $0 }
        )
    }

    private var autoStartOnLaunchBinding: Binding<Bool> {
        Binding(
            get: { draft.autoStartOnLaunch },
            set: { draft.autoStartOnLaunch = $0 }
        )
    }

    private var autoStartOnWakeBinding: Binding<Bool> {
        Binding(
            get: { draft.autoStartOnWake },
            set: { draft.autoStartOnWake = $0 }
        )
    }

}

/// 编辑 / 新建方案弹窗：完整可编辑的业务配置草稿，保存即更新方案本身，
/// 不触碰运行中的 Session 与全局 Awake 设置。
private struct AwakeProfileEditorSheet: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profiles: AwakeProfileStore
    let existingProfile: AwakeSessionProfile?

    @State private var name: String
    @State private var configuration: AwakeSessionProfileConfiguration

    init(profiles: AwakeProfileStore, profile: AwakeSessionProfile) {
        self.profiles = profiles
        self.existingProfile = profile
        _name = State(initialValue: profile.name)
        _configuration = State(initialValue: profile.configuration)
    }

    /// 新建方案：以当前 Session 配置为起点。
    init(profiles: AwakeProfileStore, configuration startingConfiguration: @autoclosure () -> AwakeSessionProfileConfiguration) {
        self.profiles = profiles
        self.existingProfile = nil
        _name = State(initialValue: "")
        _configuration = State(initialValue: startingConfiguration())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.t(existingProfile == nil ? "awakeProfileNew" : "awakeProfileEditTitle"))
                            .font(.system(size: 24, weight: .bold))
                        Text(model.t("awakeProfileSaveHint"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(model.t("awakeProfileName"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    TextField(model.t("awakeProfileNamePlaceholder"), text: $name)
                        .textFieldStyle(.roundedBorder)

                    Divider()

                    AwakeSessionOptionsView(configuration: $configuration)
                    Divider()
                    AwakeSessionProtectionOptionsView(draft: protectionDraftBinding)
                }
                .padding(24)
            }

            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button(model.t("cancel")) { dismiss() }
                Button(existingProfile == nil ? model.t("save") : model.t("awakeProfileSaveChanges"), action: save)
                    .macPilotProminentButtonStyle()
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 580, idealHeight: 660)
    }

    private var trimmedName: String {
        AwakeSessionProfile.normalizedName(name)
    }

    private var protectionDraftBinding: Binding<AwakeSessionProtectionDraft> {
        Binding(
            get: { AwakeSessionProtectionDraft(configuration: configuration) },
            set: { configuration = $0.applying(to: configuration) }
        )
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if var profile = existingProfile {
            profile.name = trimmedName
            profile.configuration = configuration
            profiles.update(profile)
        } else {
            profiles.create(name: trimmedName, configuration: configuration)
        }
        dismiss()
    }
}

private struct AwakeSessionDetailRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let session: AwakeSession
    let isClosedLidSleepActive: Bool
    let now: Date
    let triggerName: String?
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.t("awakeActive"), systemImage: "sun.max.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text(model.t("awakeRunningFor", durationString))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive, action: onStop) {
                    Label(model.t("awakeStopSession"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
            }
            detailLine(model.t("awakeSource"), value: sourceDescription)
            detailLine(model.t("awakeStartedAt"), value: dateDescription(session.startedAt))
            detailLine(
                model.t("awakeSystemSleep"),
                value: session.policy.preventSystemSleep ? model.t("awakePrevented") : model.t("awakeAllowed")
            )
            detailLine(
                model.t("awakeDisplaySleep"),
                value: session.policy.preventDisplaySleep ? model.t("awakePrevented") : model.t("awakeAllowed")
            )
            detailLine(
                model.t("awakeClosedLidSleepDetail"),
                value: session.policy.preventClosedLidSleep
                    ? model.t(isClosedLidSleepActive ? "awakePrevented" : "awakeClosedLidNotApplied")
                    : model.t("awakeAllowed")
            )
            if let expectedEndAt = session.expectedEndAt {
                detailLine(model.t("awakeEndsAt"), value: dateDescription(expectedEndAt))
            }
        }
    }

    private var sourceDescription: String {
        awakeSessionSourceDescription(session.source, triggerName: triggerName, model: model)
    }

    private var durationString: String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func dateDescription(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second().locale(model.language.locale))
    }

    private func detailLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

struct AwakeMenuView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var awake: AwakeSessionManager
    @ObservedObject var triggerEngine: AwakeTriggerEngine
    @ObservedObject var profiles: AwakeProfileStore
    let openSettings: () -> Void

    var body: some View {
        // Keep Awake to one row in the main menu, regardless of session,
        // profile or trigger count. Details and actions live in this submenu.
        Menu {
            if awake.isActive {
                Text(statusText)
                    .foregroundStyle(.secondary)
                Text("\(model.t("awakeSystemSleep")): \(assertionStatus(active: awake.isSystemAssertionActive, desired: awake.desiredAwakeState.preventSystemSleep, kind: .systemSleep))")
                Text("\(model.t("awakeDisplaySleep")): \(assertionStatus(active: awake.isDisplayAssertionActive, desired: awake.desiredAwakeState.preventDisplaySleep, kind: .displaySleep))")
                if awake.desiredAwakeState.preventClosedLidSleep {
                    Text("\(model.t("awakeClosedLidSleepDetail")): \(model.t(awake.isClosedLidSleepActive ? "awakePrevented" : "awakeClosedLidNotApplied"))")
                }
                if let expiryText {
                    Text(expiryText)
                        .foregroundStyle(.secondary)
                }
                Menu(model.t("awakeActiveSessions")) {
                    ForEach(Array(awake.activeSessions.enumerated()), id: \.element.id) { index, session in
                        Button {
                            stopAwakeSession(session, awake: awake, triggerEngine: triggerEngine)
                        } label: {
                            Text(sessionMenuDescription(session, number: index + 1))
                        }
                    }
                }
            }

            if let failure = awake.lastAssertionFailure {
                Text(model.t("awakeAssertionError", failure.code))
            }

            if !profiles.profiles.isEmpty {
                Menu(model.t("awakeQuickLaunch")) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            launchProfileFromMenu(profile)
                        } label: {
                            Label(profile.name, systemImage: "flame.fill")
                        }
                    }
                }
            }

            if !triggerEngine.triggers.isEmpty {
                Divider()
                ForEach(triggerEngine.triggers) { trigger in
                    Label(
                        trigger.name,
                        systemImage: triggerStatusIcon(for: trigger.id)
                    )
                    .foregroundStyle(triggerStatusColor(for: trigger))
                }
            }

            Menu(model.t("awakeDuration")) {
                Button(model.t("awake30Minutes")) { _ = awake.startManualSession(duration: 30 * 60) }
                Button(model.t("awakeOneHour")) { _ = awake.startManualSession(duration: 60 * 60) }
                Button(model.t("awakeTwoHours")) { _ = awake.startManualSession(duration: 2 * 60 * 60) }
                Button(model.t("awakeFourHours")) { _ = awake.startManualSession(duration: 4 * 60 * 60) }
                Button(model.t("awakeUnlimited")) { _ = awake.startManualSession() }
            }

            if awake.hasInteractiveSession {
                Button(model.t("awakeStop"), action: awake.endAllInteractiveSessions)
            }

            Button(model.t("awakeOpenSettings"), action: openSettings)
        } label: {
            Label(model.t("awake"), systemImage: menuIcon)
        }
    }

    private var menuIcon: String {
        if awake.lastAssertionFailure != nil || awake.lastClosedLidFailure != nil {
            return "exclamationmark.triangle"
        }
        return awake.isKeepingAwake ? "sun.max.fill" : "moon.zzz"
    }

    private var statusText: String {
        if awake.safetyProtectionActive { return model.t("awakeSafetyActive") }
        if awake.activeSessionCount == 1, let only = awake.activeSessions.first {
            // 方案会话直接显示方案名，让用户知道现在跑的是哪套配置。
            if case .profile(let name) = only.source { return name }
            return model.t(awake.isKeepingAwake ? "awakeActive" : "awakeSessionRunning")
        }
        return model.t("awakeMultipleSessions", awake.activeSessionCount)
    }

    private func assertionStatus(active: Bool, desired: Bool, kind: AwakeAssertionFailure.Kind) -> String {
        if awake.lastAssertionFailure?.kind == kind || (desired && !active) {
            return model.t("awakeUnknown")
        }
        return model.t(active ? "awakePrevented" : "awakeAllowed")
    }

    private var expiryText: String? {
        guard let end = awake.activeSessions.compactMap(\.expectedEndAt).min() else { return nil }
        let remaining = end.timeIntervalSince(Date())
        guard remaining > 0 else {
            let formattedDate = end.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(model.language.locale))
            return "\(model.t("awakeEndsAt")) \(formattedDate)"
        }
        let remainingText = Duration.seconds(remaining)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
        return model.t("awakeRemaining", remainingText)
    }

    /// 菜单里点击方案：空闲时直接启动；已有用户主动开始的 Session 时，
    /// 用系统弹窗确认切换（菜单关闭后弹出）。
    private func launchProfileFromMenu(_ profile: AwakeSessionProfile) {
        guard !awake.hasInteractiveSession else {
            confirmProfileSwitchFromMenu(profile)
            return
        }
        profiles.launch(profile.id, in: awake)
    }

    private func confirmProfileSwitchFromMenu(_ profile: AwakeSessionProfile) {
        let separator = model.language.locale.language.languageCode?.identifier == "zh" ? "、" : ", "
        let runningNames = awake.activeInteractiveSessions.map { session in
            if case .profile(let name) = session.source { return name }
            return model.t("awakeManualSource")
        }.joined(separator: separator)
        let alert = NSAlert()
        alert.messageText = model.t("awakeProfileSwitchTitle")
        alert.informativeText = model.t("awakeProfileSwitchMessage", runningNames, profile.name)
        alert.addButton(withTitle: model.t("awakeProfileSwitchConfirm"))
        alert.addButton(withTitle: model.t("cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            profiles.launch(profile.id, in: awake, replacingActiveSessions: true)
        }
    }

    private func sessionMenuDescription(_ session: AwakeSession, number: Int) -> String {
        let source = awakeSessionSourceDescription(
            session.source,
            triggerName: awakeTriggerName(for: session.source, triggerEngine: triggerEngine),
            model: model
        )
        let startedAt = session.startedAt.formatted(
            .dateTime.hour().minute().second().locale(model.language.locale)
        )
        return model.t("awakeStopSessionMenuItem", number, source, startedAt)
    }

    private func triggerStatusIcon(for id: UUID) -> String {
        let state = triggerEngine.runtimeState(for: id)
        if state.sessionActive { return "sun.max.fill" }
        if state.sessionStoppedByUser { return "pause.circle.fill" }
        return "circle"
    }

    private func triggerStatusColor(for trigger: AwakeTrigger) -> Color {
        guard trigger.enabled else { return .secondary }
        return triggerEngine.runtimeState(for: trigger.id).sessionStoppedByUser ? .orange : .primary
    }
}

@MainActor
private func awakeTriggerName(for source: SessionSource, triggerEngine: AwakeTriggerEngine) -> String? {
    guard case .trigger(let id) = source else { return nil }
    return triggerEngine.trigger(for: id)?.name
}

@MainActor
private func awakeSessionSourceDescription(
    _ source: SessionSource,
    triggerName: String?,
    model: MacPilotModel
) -> String {
    switch source {
    case .manual:
        return model.t("awakeManualSource")
    case .trigger:
        return triggerName ?? model.t("awakeTriggerSource")
    case .application(let bundleID):
        return bundleID
    case .process(let name):
        return name
    case .file(let url):
        return url.lastPathComponent
    case .automation(let identifier):
        return identifier
    case .profile(let name):
        return name
    }
}

@MainActor
private func stopAwakeSession(
    _ session: AwakeSession,
    awake: AwakeSessionManager,
    triggerEngine: AwakeTriggerEngine
) {
    if case .trigger = session.source {
        triggerEngine.stopSession(session.id)
    } else {
        awake.endSession(session.id)
    }
}
