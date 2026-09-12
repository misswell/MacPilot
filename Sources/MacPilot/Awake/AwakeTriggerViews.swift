import SwiftUI

enum AwakeConditionKind: String, CaseIterable, Identifiable {
    case applicationRunning
    case applicationFrontmost
    case processRunning
    case processExecutable
    case powerAdapter
    case charging
    case batteryLevel
    case externalDisplay
    case displayMirroring

    var id: String { rawValue }

    init(condition: TriggerConditionConfiguration) {
        switch condition {
        case .applicationRunning: self = .applicationRunning
        case .applicationFrontmost: self = .applicationFrontmost
        case .processRunning: self = .processRunning
        case .processExecutable: self = .processExecutable
        case .powerAdapter: self = .powerAdapter
        case .charging: self = .charging
        case .batteryLevel: self = .batteryLevel
        case .externalDisplay: self = .externalDisplay
        case .displayMirroring: self = .displayMirroring
        }
    }

    var titleKey: String {
        switch self {
        case .applicationRunning: "awakeApplicationRunning"
        case .applicationFrontmost: "awakeApplicationFrontmost"
        case .processRunning: "awakeProcessRunning"
        case .processExecutable: "awakeProcessExecutable"
        case .powerAdapter: "awakePowerAdapter"
        case .charging: "awakeChargingCondition"
        case .batteryLevel: "awakeBatteryLevelCondition"
        case .externalDisplay: "awakeExternalDisplay"
        case .displayMirroring: "awakeDisplayMirroringCondition"
        }
    }

    var defaultCondition: TriggerConditionConfiguration {
        switch self {
        case .applicationRunning: .applicationRunning(bundleID: "com.example.app")
        case .applicationFrontmost: .applicationFrontmost(bundleID: "com.example.app")
        case .processRunning: .processRunning(name: "claude")
        case .processExecutable: .processExecutable(path: "/usr/bin/example")
        case .powerAdapter: .powerAdapter(connected: true)
        case .charging: .charging(value: true)
        case .batteryLevel: .batteryLevel(comparison: .greaterThanOrEqual, value: 50)
        case .externalDisplay: .externalDisplay(minimumCount: 1)
        case .displayMirroring: .displayMirroring(active: true)
        }
    }
}

extension NumericComparison {
    var titleKey: String {
        switch self {
        case .lessThan: "awakeComparisonLessThan"
        case .lessThanOrEqual: "awakeComparisonLessThanOrEqual"
        case .equal: "awakeComparisonEqual"
        case .greaterThanOrEqual: "awakeComparisonGreaterThanOrEqual"
        case .greaterThan: "awakeComparisonGreaterThan"
        }
    }
}

struct AwakeTriggerListView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var triggerEngine: AwakeTriggerEngine

    @State private var showingAdd = false
    @State private var editingTrigger: AwakeTrigger?

    var body: some View {
        SettingsCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("awakeAutomation")).font(.headline)
                    Text(model.t("awakeAutomationHint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu(model.t("awakeAgentPresets")) {
                    ForEach(AwakeAgentPreset.allCases) { preset in
                        Button(model.t(preset.titleKey)) {
                            triggerEngine.addTrigger(preset.makeTrigger(name: model.t(preset.titleKey)))
                        }
                    }
                }
                Button(model.t("awakeAddTrigger")) { showingAdd = true }
                    .macPilotProminentButtonStyle()
            }

            if triggerEngine.triggers.isEmpty {
                Label(model.t("awakeNoTriggers"), systemImage: "wand.and.stars")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(triggerEngine.triggers) { trigger in
                        AwakeTriggerRow(
                            trigger: trigger,
                            runtimeState: triggerEngine.runtimeState(for: trigger.id),
                            isEnabled: Binding(
                                get: { triggerEngine.trigger(for: trigger.id)?.enabled ?? false },
                                set: { triggerEngine.setTriggerEnabled(trigger.id, enabled: $0) }
                            ),
                            edit: { editingTrigger = trigger },
                            remove: { triggerEngine.removeTrigger(trigger.id) }
                        )
                        if trigger.id != triggerEngine.triggers.last?.id { Divider().padding(.vertical, 10) }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AwakeTriggerEditorView(trigger: nil) { trigger in
                triggerEngine.addTrigger(trigger)
            }
        }
        .sheet(item: $editingTrigger) { trigger in
            AwakeTriggerEditorView(trigger: trigger) { updated in
                triggerEngine.updateTrigger(updated)
            }
        }
    }
}

private struct AwakeTriggerRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let trigger: AwakeTrigger
    let runtimeState: TriggerRuntimeState
    @Binding var isEnabled: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(trigger.name).font(.body.weight(.medium))
                    if runtimeState.conditionMatched {
                        Text(model.t(runtimeState.sessionStoppedByUser ? "awakeSessionStopped" : "awakeConditionMatched"))
                            .font(.caption2)
                            .foregroundStyle(runtimeState.sessionStoppedByUser ? .orange : .green)
                    }
                }
                Text(conditionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
            Menu {
                Button(model.t("edit"), action: edit)
                Button(model.t("deleteRule"), role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var statusIcon: String {
        if runtimeState.sessionActive { return "sun.max.fill" }
        if runtimeState.sessionStoppedByUser { return "pause.circle.fill" }
        return "wand.and.stars"
    }

    private var statusColor: Color {
        if runtimeState.sessionActive { return .green }
        if runtimeState.sessionStoppedByUser { return .orange }
        return .secondary
    }

    private var conditionSummary: String {
        let values = trigger.conditions.map { condition in
            switch condition {
            case .applicationRunning(let bundleID):
                return model.t("awakeApplicationRunning") + ": " + bundleID
            case .applicationFrontmost(let bundleID):
                return model.t("awakeApplicationFrontmost") + ": " + bundleID
            case .processRunning(let name):
                return model.t("awakeProcessRunning") + ": " + name
            case .processExecutable(let path):
                return model.t("awakeProcessExecutable") + ": " + path
            case .powerAdapter(let connected):
                return model.t("awakePowerAdapter") + ": " + (connected ? model.t("awakeConnected") : model.t("awakeDisconnected"))
            case .charging, .batteryLevel, .externalDisplay, .displayMirroring:
                return model.t("awakeCondition") + ": " + condition.summaryValue
            }
        }
        let separator = trigger.operatorType == .all ? " · " : " / "
        return values.joined(separator: separator)
    }
}

struct AwakeTriggerEditorView: View {
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss

    private let onSave: (AwakeTrigger) -> Void
    private let isNew: Bool
    @State private var draft: AwakeTrigger

    init(trigger: AwakeTrigger?, onSave: @escaping (AwakeTrigger) -> Void) {
        self.onSave = onSave
        self.isNew = trigger == nil
        _draft = State(initialValue: trigger ?? AwakeTrigger(
            name: "",
            conditions: [.processRunning(name: "claude")]
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.t(isNew ? "awakeAddTrigger" : "awakeEditTrigger"))
                    .font(.title2.bold())
                Spacer()
                Button(model.t("cancel")) { dismiss() }
                Button(model.t("save"), action: save)
                    .macPilotProminentButtonStyle()
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.conditions.isEmpty)
            }
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsCard {
                        Text(model.t("awakeTriggerName")).font(.headline)
                        TextField(model.t("awakeTriggerName"), text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                        Picker(model.t("awakeCondition"), selection: $draft.operatorType) {
                            Text(model.t("awakeAllConditions")).tag(ConditionOperator.all)
                            Text(model.t("awakeAnyCondition")).tag(ConditionOperator.any)
                        }
                    }

                    SettingsCard {
                        HStack {
                            Text(model.t("awakeCondition")).font(.headline)
                            Spacer()
                            Button(model.t("awakeAddCondition")) {
                                draft.conditions.append(.processRunning(name: "claude"))
                            }
                        }
                        ForEach(Array(draft.conditions.indices), id: \.self) { index in
                            conditionEditor(at: index)
                            if index < draft.conditions.count - 1 { Divider() }
                        }
                    }

                    SettingsCard {
                        Text(model.t("awakeSessionDetails")).font(.headline)
                        Toggle(model.t("awakeSystemSleepToggle"), isOn: policyBinding(\.preventSystemSleep))
                            .toggleStyle(.switch)
                            .disabled(draft.sessionPolicy.preventClosedLidSleep)
                        Toggle(model.t("awakeDisplaySleepToggle"), isOn: policyBinding(\.preventDisplaySleep))
                            .toggleStyle(.switch)
                        Toggle(model.t("awakeClosedLidSleep"), isOn: closedLidSleepBinding)
                            .toggleStyle(.switch)
                        Text(model.t("awakeClosedLidSleepHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle(model.t("awakeAllowSystemSleepWhenDisplayOff"), isOn: policyBinding(\.allowSystemSleepWhenDisplayOff))
                            .toggleStyle(.switch)
                        Toggle(model.t("awakeEndOnForcedSleep"), isOn: policyBinding(\.endOnForcedSleep))
                            .toggleStyle(.switch)

                        Picker(model.t("awakeEndCalculation"), selection: endCalculationBinding) {
                            Text(model.t("awakeEndCalculationTimer")).tag(SessionEndCalculation.timer)
                            Text(model.t("awakeEndCalculationAwakeTime")).tag(SessionEndCalculation.pausesDuringSleep)
                        }

                        Toggle(model.t("awakeBlockScreenSaver"), isOn: policyBinding(\.blockScreenSaver))
                            .toggleStyle(.switch)
                        if draft.sessionPolicy.blockScreenSaver {
                            Stepper(
                                model.t("awakeScreenSaverAllowsAfter", draft.sessionPolicy.screenSaverIdleMinutes),
                                value: screenSaverIdleBinding,
                                in: 5...180,
                                step: 5
                            )
                            Text(model.t("awakeScreenSaverAccessibilityHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        TextField(
                            model.t("awakeActivationDelay"),
                            value: timingBinding(\.activationDelay),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        TextField(
                            model.t("awakeDeactivationDelay"),
                            value: timingBinding(\.deactivationDelay),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 500)
    }

    @ViewBuilder
    private func conditionEditor(at index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Picker(
                model.t("awakeCondition"),
                selection: Binding(
                    get: { kind(for: draft.conditions[index]) },
                    set: { draft.conditions[index] = makeCondition($0) }
                )
            ) {
                ForEach(AwakeConditionKind.allCases) { kind in
                    Text(model.t(kind.titleKey)).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            conditionValueEditor(at: index)

            Button {
                draft.conditions.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(model.t("awakeRemoveCondition"))
        }
    }

    @ViewBuilder
    private func conditionValueEditor(at index: Int) -> some View {
        switch draft.conditions[index] {
        case .applicationRunning(let bundleID):
            TextField(model.t("awakeBundleID"), text: stringBinding(at: index, value: bundleID) { .applicationRunning(bundleID: $0) })
                .textFieldStyle(.roundedBorder)
        case .applicationFrontmost(let bundleID):
            TextField(model.t("awakeBundleID"), text: stringBinding(at: index, value: bundleID) { .applicationFrontmost(bundleID: $0) })
                .textFieldStyle(.roundedBorder)
        case .processRunning(let name):
            TextField(model.t("awakeProcessName"), text: stringBinding(at: index, value: name) { .processRunning(name: $0) })
                .textFieldStyle(.roundedBorder)
        case .processExecutable(let path):
            TextField(model.t("awakeExecutablePath"), text: stringBinding(at: index, value: path) { .processExecutable(path: $0) })
                .textFieldStyle(.roundedBorder)
        case .powerAdapter(let connected):
            Toggle(model.t(connected ? "awakeConnected" : "awakeDisconnected"), isOn: boolBinding(at: index, value: connected) { .powerAdapter(connected: $0) })
                .toggleStyle(.switch)
        case .charging(let charging):
            Toggle(
                model.t("awakeChargingCondition"),
                isOn: boolBinding(at: index, value: charging) { .charging(value: $0) }
            )
            .toggleStyle(.switch)
        case .batteryLevel(let comparison, let value):
            HStack(spacing: 8) {
                Picker(
                    model.t("awakeComparison"),
                    selection: comparisonBinding(at: index, value: comparison)
                ) {
                    ForEach(NumericComparison.allCases, id: \.rawValue) { item in
                        Text(model.t(item.titleKey)).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                TextField(
                    model.t("awakeBatteryLevelCondition"),
                    value: doubleBinding(at: index, value: value),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                Text("%")
            }
        case .externalDisplay(let minimumCount):
            Stepper(
                model.t("awakeMinimumDisplayCount") + ": " + String(minimumCount),
                value: intBinding(at: index, value: minimumCount) { .externalDisplay(minimumCount: $0) },
                in: 1...32
            )
        case .displayMirroring(let active):
            Toggle(
                model.t("awakeDisplayMirroringCondition"),
                isOn: boolBinding(at: index, value: active) { .displayMirroring(active: $0) }
            )
            .toggleStyle(.switch)
        }
    }

    private func kind(for condition: TriggerConditionConfiguration) -> AwakeConditionKind {
        AwakeConditionKind(condition: condition)
    }

    private func makeCondition(_ kind: AwakeConditionKind) -> TriggerConditionConfiguration {
        kind.defaultCondition
    }

    private func policyBinding(_ keyPath: WritableKeyPath<SessionPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { draft.sessionPolicy[keyPath: keyPath] },
            set: { draft.sessionPolicy[keyPath: keyPath] = $0 }
        )
    }

    /// Turning this on also turns system-sleep prevention on, so the two
    /// toggles can never describe an impossible state.
    private var closedLidSleepBinding: Binding<Bool> {
        Binding(
            get: { draft.sessionPolicy.preventClosedLidSleep },
            set: { draft.sessionPolicy.setPreventClosedLidSleep($0) }
        )
    }

    private var endCalculationBinding: Binding<SessionEndCalculation> {
        Binding(
            get: { draft.sessionPolicy.endCalculation },
            set: { draft.sessionPolicy.endCalculation = $0 }
        )
    }

    private var screenSaverIdleBinding: Binding<Int> {
        Binding(
            get: { draft.sessionPolicy.screenSaverIdleMinutes },
            set: { draft.sessionPolicy.screenSaverIdleMinutes = $0 }
        )
    }

    private func timingBinding(_ keyPath: WritableKeyPath<TriggerTimingPolicy, TimeInterval>) -> Binding<TimeInterval> {
        Binding(
            get: { draft.timingPolicy[keyPath: keyPath] },
            set: { draft.timingPolicy[keyPath: keyPath] = max(0, $0) }
        )
    }

    private func stringBinding(
        at index: Int,
        value: String,
        make: @escaping (String) -> TriggerConditionConfiguration
    ) -> Binding<String> {
        Binding(
            get: { valueForCondition(at: index) ?? value },
            set: { draft.conditions[index] = make($0) }
        )
    }

    private func boolBinding(
        at index: Int,
        value: Bool,
        make: @escaping (Bool) -> TriggerConditionConfiguration
    ) -> Binding<Bool> {
        Binding(
            get: { boolValueForCondition(at: index) ?? value },
            set: { draft.conditions[index] = make($0) }
        )
    }

    private func intBinding(
        at index: Int,
        value: Int,
        make: @escaping (Int) -> TriggerConditionConfiguration
    ) -> Binding<Int> {
        Binding(
            get: { intValueForCondition(at: index) ?? value },
            set: { draft.conditions[index] = make($0) }
        )
    }

    private func doubleBinding(at index: Int, value: Double) -> Binding<Double> {
        Binding(
            get: { doubleValueForCondition(at: index) ?? value },
            set: { newValue in
                let comparison = comparisonValueForCondition(at: index) ?? .greaterThanOrEqual
                draft.conditions[index] = .batteryLevel(
                    comparison: comparison,
                    value: min(100, max(0, newValue))
                )
            }
        )
    }

    private func comparisonBinding(
        at index: Int,
        value: NumericComparison
    ) -> Binding<NumericComparison> {
        Binding(
            get: { comparisonValueForCondition(at: index) ?? value },
            set: { comparison in
                draft.conditions[index] = .batteryLevel(
                    comparison: comparison,
                    value: doubleValueForCondition(at: index) ?? 50
                )
            }
        )
    }

    private func valueForCondition(at index: Int) -> String? {
        guard draft.conditions.indices.contains(index) else { return nil }
        switch draft.conditions[index] {
        case .applicationRunning(let bundleID), .applicationFrontmost(let bundleID): return bundleID
        case .processRunning(let name): return name
        case .processExecutable(let path): return path
        default: return nil
        }
    }

    private func boolValueForCondition(at index: Int) -> Bool? {
        guard draft.conditions.indices.contains(index) else { return nil }
        return switch draft.conditions[index] {
        case .powerAdapter(let connected): connected
        case .charging(let value): value
        case .displayMirroring(let active): active
        default: nil
        }
    }

    private func intValueForCondition(at index: Int) -> Int? {
        guard draft.conditions.indices.contains(index) else { return nil }
        if case .externalDisplay(let count) = draft.conditions[index] { return count }
        return nil
    }

    private func doubleValueForCondition(at index: Int) -> Double? {
        guard draft.conditions.indices.contains(index),
              case .batteryLevel(_, let value) = draft.conditions[index] else { return nil }
        return value
    }

    private func comparisonValueForCondition(at index: Int) -> NumericComparison? {
        guard draft.conditions.indices.contains(index),
              case .batteryLevel(let comparison, _) = draft.conditions[index] else { return nil }
        return comparison
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty, !draft.conditions.isEmpty else { return }
        onSave(draft)
        dismiss()
    }
}
