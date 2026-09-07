import SwiftUI

private enum AwakeSessionPreset: String, CaseIterable, Identifiable {
    case unlimited
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case customDuration
    case untilDate

    var id: String { rawValue }
}

struct AwakeSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var awake: AwakeSessionManager

    @State private var selectedPreset: AwakeSessionPreset = .unlimited
    @State private var customMinutes = 60
    @State private var untilDate = Date().addingTimeInterval(60 * 60)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("awake")).font(.system(size: 30, weight: .bold))
                    Text(model.t("awakeSubtitle")).foregroundStyle(.secondary)
                }

                sessionControlCard
                sessionDetailsCard
                batteryProtectionCard
                powerStateCard
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
    }

    private var sessionControlCard: some View {
        SettingsCard {
            Text(model.t("awakeStartSession")).font(.headline)
            Text(model.t("awakeDisplaySleepHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker(model.t("awakeSessionDuration"), selection: $selectedPreset) {
                Text(model.t("awakeUnlimited")).tag(AwakeSessionPreset.unlimited)
                Text(model.t("awake30Minutes")).tag(AwakeSessionPreset.thirtyMinutes)
                Text(model.t("awakeOneHour")).tag(AwakeSessionPreset.oneHour)
                Text(model.t("awakeTwoHours")).tag(AwakeSessionPreset.twoHours)
                Text(model.t("awakeFourHours")).tag(AwakeSessionPreset.fourHours)
                Text(model.t("awakeCustomDuration")).tag(AwakeSessionPreset.customDuration)
                Text(model.t("awakeUntilDate")).tag(AwakeSessionPreset.untilDate)
            }

            if selectedPreset == .customDuration {
                HStack {
                    Text(model.t("awakeCustomDuration"))
                    Spacer()
                    TextField(model.t("awakeCustomDuration"), value: $customMinutes, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } else if selectedPreset == .untilDate {
                DatePicker(
                    model.t("awakeUntilDate"),
                    selection: $untilDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            Toggle(model.t("awakeDisplaySleepAllowed"), isOn: displaySleepAllowedBinding)
                .toggleStyle(.switch)

            HStack {
                Button(model.t("awakeStart"), action: startSelectedSession)
                    .buttonStyle(.borderedProminent)
                if awake.hasManualSession {
                    Button(model.t("awakeStop"), action: awake.endAllManualSessions)
                }
            }
        }
    }

    private var sessionDetailsCard: some View {
        SettingsCard {
            Text(model.t("awakeSessionDetails")).font(.headline)
            if awake.activeSessions.isEmpty {
                Label(model.t("awakeNoActiveSession"), systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(awake.activeSessions) { session in
                            AwakeSessionDetailRow(session: session, now: context.date)
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

    private var batteryProtectionCard: some View {
        SettingsCard {
            Text(model.t("awakeBatteryProtection")).font(.headline)
            Toggle(model.t("awakeLowBatteryProtection"), isOn: batteryProtectionBinding)
                .toggleStyle(.switch)
            Text(model.t("awakeBatteryProtectionHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if awake.settings.safetyPolicy.lowBatteryProtectionEnabled {
                Stepper(value: batteryThresholdBinding, in: 10...50) {
                    Text(model.t("awakeBatteryThresholdValue", awake.settings.safetyPolicy.minimumBatteryLevel))
                }
            }
        }
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

    private var batteryProtectionBinding: Binding<Bool> {
        Binding(
            get: { awake.settings.safetyPolicy.lowBatteryProtectionEnabled },
            set: { value in
                awake.updateSettings { $0.safetyPolicy.lowBatteryProtectionEnabled = value }
            }
        )
    }

    private var batteryThresholdBinding: Binding<Int> {
        Binding(
            get: { awake.settings.safetyPolicy.minimumBatteryLevel },
            set: { value in
                awake.updateSettings { $0.safetyPolicy.minimumBatteryLevel = value }
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

    private func startSelectedSession() {
        switch selectedPreset {
        case .unlimited:
            _ = awake.startManualSession()
        case .thirtyMinutes:
            _ = awake.startManualSession(duration: 30 * 60)
        case .oneHour:
            _ = awake.startManualSession(duration: 60 * 60)
        case .twoHours:
            _ = awake.startManualSession(duration: 2 * 60 * 60)
        case .fourHours:
            _ = awake.startManualSession(duration: 4 * 60 * 60)
        case .customDuration:
            _ = awake.startManualSession(duration: TimeInterval(max(1, customMinutes) * 60))
        case .untilDate:
            _ = awake.startManualSession(until: untilDate)
        }
    }
}

private struct AwakeSessionDetailRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let session: AwakeSession
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.t("awakeActive"), systemImage: "sun.max.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text(model.t("awakeRunningFor", durationString))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            if let expectedEndAt = session.expectedEndAt {
                detailLine(model.t("awakeEndsAt"), value: dateDescription(expectedEndAt))
            }
        }
    }

    private var sourceDescription: String {
        switch session.source {
        case .manual:
            return model.t("awakeManualSource")
        case .trigger:
            return model.t("awakeTriggerSource")
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
    let openSettings: () -> Void

    var body: some View {
        Section {
            Button {
                awake.toggleManualSession()
            } label: {
                Label(
                    awake.hasManualSession ? model.t("awakeStop") : model.t("awakeKeepAwake"),
                    systemImage: awake.hasManualSession ? "stop.circle" : "sun.max.fill"
                )
            }

            if awake.isActive {
                Text(statusText)
                    .foregroundStyle(.secondary)
                Button(model.t("awakeStopAllManual"), action: awake.endAllManualSessions)
                    .disabled(!awake.hasManualSession)
            }

            Menu(model.t("awakeDuration")) {
                Button(model.t("awake30Minutes")) { _ = awake.startManualSession(duration: 30 * 60) }
                Button(model.t("awakeOneHour")) { _ = awake.startManualSession(duration: 60 * 60) }
                Button(model.t("awakeTwoHours")) { _ = awake.startManualSession(duration: 2 * 60 * 60) }
                Button(model.t("awakeFourHours")) { _ = awake.startManualSession(duration: 4 * 60 * 60) }
                Button(model.t("awakeUnlimited")) { _ = awake.startManualSession() }
            }

            Button(model.t("awakeUntilDate"), action: openSettings)

            Button(model.t("awakeOpenSettings"), action: openSettings)
        } header: {
            Label(model.t("awake"), systemImage: "sun.max.fill")
        }
    }

    private var statusText: String {
        if awake.safetyProtectionActive { return model.t("awakeSafetyActive") }
        if awake.activeSessionCount == 1 { return model.t("awakeActive") }
        return model.t("awakeMultipleSessions", awake.activeSessionCount)
    }
}
