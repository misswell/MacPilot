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

    @State private var isSessionProtectionSheetPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("awake")).font(.system(size: 30, weight: .bold))
                    Text(model.t("awakeSubtitle")).foregroundStyle(.secondary)
                }

                sessionCard
                sessionDetailsCard
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
            AwakeSessionProtectionSheet(awake: awake)
                .environmentObject(model)
        }
    }

    /// 统一的 Session 卡片：这里的全部配置就是「默认会话」——手动开始与
    /// 启动、唤醒后的自动开始使用同一套设置，只有一处需要维护。
    private var sessionCard: some View {
        SettingsCard {
            Text(model.t("awakeSessionConfig")).font(.headline)
            Text(model.t("awakeSessionConfigHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker(model.t("awakeSessionDuration"), selection: defaultDurationBinding) {
                Text(model.t("awakeUnlimited")).tag(AwakeDefaultDurationPreset.unlimited)
                Text(model.t("awake30Minutes")).tag(AwakeDefaultDurationPreset.thirtyMinutes)
                Text(model.t("awakeOneHour")).tag(AwakeDefaultDurationPreset.oneHour)
                Text(model.t("awakeTwoHours")).tag(AwakeDefaultDurationPreset.twoHours)
                Text(model.t("awakeFourHours")).tag(AwakeDefaultDurationPreset.fourHours)
                Text(model.t("awakeCustomDuration")).tag(AwakeDefaultDurationPreset.customDuration)
                Text(model.t("awakeUntilDate")).tag(AwakeDefaultDurationPreset.untilDate)
            }

            if defaultDurationPreset == .customDuration {
                HStack {
                    Text(model.t("awakeCustomDuration"))
                    Spacer()
                    TextField(model.t("awakeCustomDuration"), value: customDurationMinutesBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } else if defaultDurationPreset == .untilDate {
                DatePicker(
                    model.t("awakeUntilDate"),
                    selection: untilDateBinding,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            Picker(model.t("awakeEndCalculation"), selection: endCalculationBinding) {
                Text(model.t("awakeEndCalculationTimer")).tag(SessionEndCalculation.timer)
                Text(model.t("awakeEndCalculationAwakeTime")).tag(SessionEndCalculation.pausesDuringSleep)
            }

            sectionLabel(model.t("awakeForceSleep"))
            Toggle(model.t("awakeEndOnForcedSleep"), isOn: endOnForcedSleepBinding)
                .toggleStyle(.switch)

            sectionLabel(model.t("awakeDisplaySection"))
            Toggle(model.t("awakeDisplaySleepAllowed"), isOn: displaySleepAllowedBinding)
                .toggleStyle(.switch)
            Text(model.t("awakeDisplaySleepHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(model.t("awakeAllowSystemSleepWhenDisplayOff"), isOn: allowSystemSleepWhenDisplayOffBinding)
                .toggleStyle(.switch)

            Toggle(model.t("awakeClosedLidSleep"), isOn: closedLidSleepBinding)
                .toggleStyle(.switch)
            Text(model.t("awakeClosedLidSleepHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if awake.settings.defaultPolicy.preventClosedLidSleep {
                Text(model.t("awakeClosedLidSleepWarning"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                closedLidServiceStatus
            }

            sectionLabel(model.t("awakeScreenSaver"))
            Toggle(model.t("awakeBlockScreenSaver"), isOn: blockScreenSaverBinding)
                .toggleStyle(.switch)
            if awake.settings.defaultPolicy.blockScreenSaver {
                SettingsSlider(
                    value: screenSaverIdleBinding,
                    in: 5...180,
                    step: 5,
                    label: model.t("awakeScreenSaverAllowsAfter", awake.settings.defaultPolicy.screenSaverIdleMinutes),
                    format: { model.t("awakeScreenSaverAllowsAfter", Int($0.rounded())) }
                )
                Text(model.t("awakeScreenSaverAllowsAfter", awake.settings.defaultPolicy.screenSaverIdleMinutes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.t("awakeScreenSaverAccessibilityHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(model.t("awakeStartSession")) {
                    isSessionProtectionSheetPresented = true
                }
                .macPilotProminentButtonStyle()
                if awake.hasManualSession {
                    Button(model.t("awakeStop"), action: awake.endAllManualSessions)
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

    private var displaySleepAllowedBinding: Binding<Bool> {
        Binding(
            get: { !awake.settings.defaultPolicy.preventDisplaySleep },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.preventDisplaySleep = !value }
            }
        )
    }

    private var defaultDurationPreset: AwakeDefaultDurationPreset {
        if awake.settings.defaultSession.usesUntilDate { return .untilDate }
        switch awake.settings.defaultSession.durationMinutes {
        case 0: return .unlimited
        case 30: return .thirtyMinutes
        case 60: return .oneHour
        case 120: return .twoHours
        case 240: return .fourHours
        default: return .customDuration
        }
    }

    private var defaultDurationBinding: Binding<AwakeDefaultDurationPreset> {
        Binding(
            get: { defaultDurationPreset },
            set: { preset in
                awake.updateSettings { settings in
                    settings.defaultSession.usesUntilDate = preset == .untilDate
                    if preset == .untilDate {
                        // 切换预设时补一个未过期的默认日期，避免隐性落到手动结束
                        let fallback = Date().addingTimeInterval(60 * 60)
                        let existing = settings.defaultSession.untilDate ?? fallback
                        settings.defaultSession.untilDate = max(existing, Date().addingTimeInterval(60))
                    }
                    if preset != .untilDate, let minutes = preset.minutes {
                        settings.defaultSession.durationMinutes = minutes
                    }
                }
            }
        )
    }

    private var untilDateBinding: Binding<Date> {
        Binding(
            get: {
                max(
                    awake.settings.defaultSession.untilDate ?? Date().addingTimeInterval(60 * 60),
                    Date()
                )
            },
            set: { value in
                awake.updateSettings { $0.defaultSession.untilDate = value }
            }
        )
    }

    private var customDurationMinutesBinding: Binding<Int> {
        Binding(
            get: { max(1, awake.settings.defaultSession.durationMinutes) },
            set: { value in
                awake.updateSettings { $0.defaultSession.durationMinutes = max(1, value) }
            }
        )
    }

    private var endCalculationBinding: Binding<SessionEndCalculation> {
        Binding(
            get: { awake.settings.defaultPolicy.endCalculation },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.endCalculation = value }
            }
        )
    }

    private var endOnForcedSleepBinding: Binding<Bool> {
        Binding(
            get: { awake.settings.defaultPolicy.endOnForcedSleep },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.endOnForcedSleep = value }
            }
        )
    }

    private var allowSystemSleepWhenDisplayOffBinding: Binding<Bool> {
        Binding(
            get: { awake.settings.defaultPolicy.allowSystemSleepWhenDisplayOff },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.allowSystemSleepWhenDisplayOff = value }
            }
        )
    }

    private var closedLidSleepBinding: Binding<Bool> {
        Binding(
            get: { awake.settings.defaultPolicy.preventClosedLidSleep },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.setPreventClosedLidSleep(value) }
            }
        )
    }

    /// Status of the privileged background power service. The user never sees
    /// `pmset`, `root`, `XPC`, or `LaunchDaemon` here.
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
            warningBanner(Label(
                model.t("awakeClosedLidError", message),
                systemImage: "exclamationmark.triangle.fill"
            ))
        case .ready, .enabling, .enabled:
            EmptyView()
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
                    .controlSize(.small)
            }
        )
    }

    private var blockScreenSaverBinding: Binding<Bool> {
        Binding(
            get: { awake.settings.defaultPolicy.blockScreenSaver },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.blockScreenSaver = value }
            }
        )
    }

    private var screenSaverIdleBinding: Binding<Double> {
        Binding(
            get: { Double(awake.settings.defaultPolicy.screenSaverIdleMinutes) },
            set: { value in
                awake.updateSettings { $0.defaultPolicy.screenSaverIdleMinutes = Int(value.rounded()) }
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
    var safetyPolicy = AwakeSafetyPolicy.standard
    var warnBeforeBatteryTermination = false
    var ignoreBatteryLevelOnExternalPower = true
    var restartOnPowerReconnect = false
    var autoStartOnLaunch = false
    var autoStartOnWake = false
}

private struct AwakeSessionProtectionSheet: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var awake: AwakeSessionManager

    @State private var draft = AwakeSessionProtectionDraft()

    init(awake: AwakeSessionManager) {
        self.awake = awake
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

                    batteryProtectionSection
                    Divider()
                    powerAdapterSection
                    Divider()
                    autoStartSection
                }
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button(model.t("cancel")) {
                    dismiss()
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
        .onAppear {
            draft = AwakeSessionProtectionDraft()
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

    private func confirm() {
        let selected = draft
        let shouldRequestBatteryNotification =
            !awake.settings.defaultSession.warnBeforeBatteryTermination
            && selected.warnBeforeBatteryTermination

        if shouldRequestBatteryNotification {
            AwakeNotifications.requestAuthorization()
        }

        awake.updateSettings { settings in
            settings.safetyPolicy = selected.safetyPolicy
            settings.defaultSession.warnBeforeBatteryTermination = selected.warnBeforeBatteryTermination
            settings.defaultSession.ignoreBatteryLevelOnExternalPower = selected.ignoreBatteryLevelOnExternalPower
            settings.defaultSession.restartOnPowerReconnect = selected.restartOnPowerReconnect
            settings.defaultSession.autoStartOnLaunch = selected.autoStartOnLaunch
            settings.defaultSession.autoStartOnWake = selected.autoStartOnWake
        }
        _ = awake.startDefaultSession()
        dismiss()
    }
}

private struct AwakeSessionDetailRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let session: AwakeSession
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
                value: session.policy.preventClosedLidSleep ? model.t("awakePrevented") : model.t("awakeAllowed")
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
    let openSettings: () -> Void

    var body: some View {
        Group {
            if awake.isActive {
                Text(statusText)
                    .foregroundStyle(.secondary)
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

            Button(model.t("awakeOpenSettings"), action: openSettings)
        }
    }

    private var statusText: String {
        if awake.safetyProtectionActive { return model.t("awakeSafetyActive") }
        if awake.activeSessionCount == 1 { return model.t("awakeActive") }
        return model.t("awakeMultipleSessions", awake.activeSessionCount)
    }

    private var expiryText: String? {
        guard let date = awake.activeSessions.compactMap(\.expectedEndAt).min() else { return nil }
        let formattedDate = date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(model.language.locale))
        return "\(model.t("awakeEndsAt")) \(formattedDate)"
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
