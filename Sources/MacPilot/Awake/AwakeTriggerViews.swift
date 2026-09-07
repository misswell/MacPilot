import SwiftUI

private enum AwakeConditionKind: String, CaseIterable, Identifiable {
    case applicationRunning
    case applicationFrontmost
    case processRunning
    case processExecutable
    case powerAdapter
    case externalDisplay

    var id: String { rawValue }
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
                Button(model.t("awakeAddTrigger")) { showingAdd = true }
                    .buttonStyle(.borderedProminent)
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
            Image(systemName: runtimeState.sessionActive ? "sun.max.fill" : "wand.and.stars")
                .foregroundStyle(runtimeState.sessionActive ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(trigger.name).font(.body.weight(.medium))
                    if runtimeState.conditionMatched {
                        Text(model.t("awakeConditionMatched"))
                            .font(.caption2)
                            .foregroundStyle(.green)
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
                    .buttonStyle(.borderedProminent)
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
                        Toggle(model.t("awakeDisplaySleepToggle"), isOn: policyBinding(\.preventDisplaySleep))
                            .toggleStyle(.switch)
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
                Text(model.t("awakeApplicationRunning")).tag(AwakeConditionKind.applicationRunning)
                Text(model.t("awakeApplicationFrontmost")).tag(AwakeConditionKind.applicationFrontmost)
                Text(model.t("awakeProcessRunning")).tag(AwakeConditionKind.processRunning)
                Text(model.t("awakeProcessExecutable")).tag(AwakeConditionKind.processExecutable)
                Text(model.t("awakePowerAdapter")).tag(AwakeConditionKind.powerAdapter)
                Text(model.t("awakeExternalDisplay")).tag(AwakeConditionKind.externalDisplay)
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
        case .externalDisplay(let minimumCount):
            Stepper(
                model.t("awakeMinimumDisplayCount") + ": " + String(minimumCount),
                value: intBinding(at: index, value: minimumCount) { .externalDisplay(minimumCount: $0) },
                in: 1...32
            )
        case .charging, .batteryLevel, .displayMirroring:
            Text(model.t("awakeConditionNotMatched")).foregroundStyle(.secondary)
        }
    }

    private func kind(for condition: TriggerConditionConfiguration) -> AwakeConditionKind {
        switch condition {
        case .applicationRunning: .applicationRunning
        case .applicationFrontmost: .applicationFrontmost
        case .processRunning: .processRunning
        case .processExecutable: .processExecutable
        case .powerAdapter: .powerAdapter
        case .externalDisplay: .externalDisplay
        case .charging, .batteryLevel, .displayMirroring: .processRunning
        }
    }

    private func makeCondition(_ kind: AwakeConditionKind) -> TriggerConditionConfiguration {
        switch kind {
        case .applicationRunning: .applicationRunning(bundleID: "com.example.app")
        case .applicationFrontmost: .applicationFrontmost(bundleID: "com.example.app")
        case .processRunning: .processRunning(name: "claude")
        case .processExecutable: .processExecutable(path: "/usr/bin/example")
        case .powerAdapter: .powerAdapter(connected: true)
        case .externalDisplay: .externalDisplay(minimumCount: 1)
        }
    }

    private func policyBinding(_ keyPath: WritableKeyPath<SessionPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { draft.sessionPolicy[keyPath: keyPath] },
            set: { draft.sessionPolicy[keyPath: keyPath] = $0 }
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
        if case .powerAdapter(let connected) = draft.conditions[index] { return connected }
        return nil
    }

    private func intValueForCondition(at index: Int) -> Int? {
        guard draft.conditions.indices.contains(index) else { return nil }
        if case .externalDisplay(let count) = draft.conditions[index] { return count }
        return nil
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty, !draft.conditions.isEmpty else { return }
        onSave(draft)
        dismiss()
    }
}
