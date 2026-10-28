import AppKit
import SwiftUI
import MacPilotDisplayControlCore

struct DisplayControlSettingsView: View {
    @EnvironmentObject private var model: MacPilotModel
    @ObservedObject var control: DisplayControlModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("displayControl")).font(.system(size: 30, weight: .bold))
                    Text(model.t("displayControlSubtitle")).foregroundStyle(.secondary)
                }
                // Failures used to appear at the bottom of the page only, below
                // the recovery card — after a UU confirmation timeout the page
                // looked normal even though nothing had been applied.
                if let key = control.errorKey {
                    InlineWarningBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(translatedError(key))
                            if control.uuObservation.status == .connected, control.settings.uuPolicy != .none {
                                Button(model.t("displayApplyUUNow")) {
                                    control.applyRemotePolicy(userInitiated: true)
                                }
                                .controlSize(.small)
                                .disabled(!control.canChange)
                            }
                        }
                    }
                }
                SettingsCard {
                    Text(model.t("displayCurrentScreens")).font(.headline)
                    Text(model.t("displayState_" + (control.snapshot?.state.rawValue ?? "unavailable")))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if control.displays.isEmpty {
                        Text(model.t("displayNoInventory")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(control.displays) { display in screenRow(display) }
                    HStack {
                        Button(model.t("displayRefresh")) { Task { await control.refresh() } }
                        Spacer()
                        Button(model.t("displayRestoreAll")) { control.restore() }
                            .macPilotProminentButtonStyle()
                    }
                    Text(model.t("displayTopologyHint")).font(.caption).foregroundStyle(.secondary)
                    if let deadline = control.snapshot?.confirmationDeadline {
                        Text(model.t("displayPendingConfirmation", control.remainingSeconds))
                            .font(.subheadline).foregroundStyle(.orange)
                            .accessibilityValue(deadline.formatted())
                        if !control.isConfirmingVirtual {
                            Button(model.t("displayKeepConfiguration")) { control.confirm() }
                                .disabled(control.isBusy)
                        }
                    }
                }
                SettingsCard {
                    Text(model.t("displayUURules")).font(.headline)
                    Picker(model.t("displayUUPolicy"), selection: setting(\.uuPolicy)) {
                        ForEach(UUDisplayPolicy.allCases) { policy in
                            Text(model.t(policy.titleKey)).tag(policy)
                        }
                    }
                    if control.settings.uuPolicy == .keepPhysical {
                        Picker(model.t("displayRetainedScreen"), selection: setting(\.targetUUID)) {
                            Text(model.t("displayChooseScreen")).tag("")
                            ForEach(control.displays.filter { !$0.isVirtual }) { display in
                                Text(displayName(display)).tag(display.uuid)
                            }
                        }
                    }
                    Text(model.t(control.uuObservation.statusTextKey))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !control.uuObservation.controllers.isEmpty {
                        Text(control.uuObservation.controllers.joined(separator: ", "))
                            .font(.caption).textSelection(.enabled)
                    }
                    Text(model.t("displayUUPermissionHint")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.t("displayAccessibility")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button(model.t("displayApplyUUNow")) { control.applyRemotePolicy(userInitiated: true) }
                            .disabled(!control.canChange || control.settings.uuPolicy == .none
                                      || control.uuObservation.status != .connected)
                    }
                    Text(model.t("displayRuleChangeHint")).font(.caption).foregroundStyle(.secondary)
                }
                SettingsCard {
                    Text(model.t("displayVirtualSpecification")).font(.headline)
                    HStack {
                        TextField(model.t("displayPixelWidth"), value: setting(\.virtualWidth), format: .number.grouping(.never))
                        Text("×").accessibilityHidden(true)
                        TextField(model.t("displayPixelHeight"), value: setting(\.virtualHeight), format: .number.grouping(.never))
                    }.textFieldStyle(.roundedBorder)
                    Toggle(model.t("displayHiDPI"), isOn: setting(\.hiDPI)).toggleStyle(.switch)
                    Text(model.t("displayVirtualHint")).font(.caption).foregroundStyle(.secondary)
                    if !control.settings.hasValidVirtualSize {
                        Text(model.t("displayInvalidSize")).font(.caption).foregroundStyle(.orange)
                    }
                }
                SettingsCard {
                    Text(model.t("displayRecoveryTitle")).font(.headline)
                    Text(model.t(control.helperReady ? "displayHelperReady" : "displayHelperUnavailable"))
                        .font(.subheadline).foregroundStyle(control.helperReady ? Color.secondary : Color.orange)
                    HStack {
                        Button(model.t("displayPrepareHelper")) { control.prepareHelper() }
                        Button(model.t("displayLoginItems")) { control.openLoginItems() }
                    }
                    Text(model.t("displayRecoveryHint")).font(.caption).foregroundStyle(.secondary)
                    Text(model.t("displayPrivateAPIHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
    }

    private func translatedError(_ key: String) -> String {
        let translated = model.t(key)
        return translated == key ? model.t("displayOperationFailed") : translated
    }

    private func setting<Value>(_ path: WritableKeyPath<DisplayControlSettings, Value>) -> Binding<Value> {
        Binding(get: { control.settings[keyPath: path] }, set: { value in
            control.updateSettings { $0[keyPath: path] = value }
        })
    }

    private func screenRow(_ display: DisplayControlDisplay) -> some View {
        HStack(spacing: 12) {
            Image(systemName: display.isVirtual ? "display.2" : (display.isBuiltIn ? "laptopcomputer" : "display"))
                .font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(display)).font(.body.weight(.medium))
                Text(model.t(display.isMain ? "displayMainScreen" : "displayOtherScreen") + " · "
                     + model.t(display.isActive ? "displayScreenActive" : "displayScreenInactive"))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(display.width) × \(display.height)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if !display.isActive, display.isOwned {
                Button(model.t("displayRestoreScreen")) { control.restore(targetUUID: display.uuid) }
            } else if display.isUsable, !display.isVirtual {
                Button(model.t("displayKeepOnly")) { control.keepOnly(display) }.disabled(!control.canChange)
                Button(model.t("displayDisableScreen")) { control.disable(display) }
                    .disabled(!control.canChange || control.displays.filter { !$0.isVirtual && $0.isUsable }.count < 2)
            }
        }
        .padding(.vertical, 5)
    }

    private func displayName(_ display: DisplayControlDisplay) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }), !screen.localizedName.isEmpty { return screen.localizedName }
        let key = display.isVirtual ? "displayKindVirtual" : (display.isBuiltIn ? "displayKindBuiltIn" : "displayKindExternal")
        return model.t(key) + " · " + display.uuid.prefix(8)
    }
}

struct DisplayControlConfirmationView: View {
    @ObservedObject var control: DisplayControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(control.t(control.isConfirmingVirtual ? "displayConfirmVirtualTitle" : "displayConfirmKeepTitle"))
                .font(.headline)
            Text(control.t(control.isConfirmingVirtual ? "displayConfirmVirtualHint" : "displayConfirmKeepHint"))
                .font(.subheadline)
            Text(AppText.value("displayPendingConfirmation", language: control.language, arguments: [control.remainingSeconds]))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.orange)
            HStack {
                Button(control.t("displayRestoreAll")) { control.restore() }
                Spacer()
                Button(control.t(control.isConfirmingVirtual ? "displayConfirmVisible" : "displayKeepConfiguration")) {
                    control.confirm()
                }.macPilotProminentButtonStyle().disabled(control.isBusy)
            }
        }.padding(24).frame(width: 470, height: 220)
    }
}

/// Non-interactive instructions on the screen the user is currently looking at.
///
/// The confirmation control itself must stay on the virtual display; this note
/// only explains how to get there, because otherwise the user is told to switch
/// displays by a window they cannot see yet.
struct DisplayControlGuidanceView: View {
    @ObservedObject var control: DisplayControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(control.t("displayGuidanceTitle")).font(.headline)
            Text(AppText.value("displayGuidanceHint", language: control.language,
                               arguments: [control.remainingSeconds]))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(control.t("displayGuidanceEmergency"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 470, height: 168, alignment: .leading)
    }
}
