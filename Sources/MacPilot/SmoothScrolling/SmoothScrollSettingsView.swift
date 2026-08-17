import SwiftUI

struct SmoothScrollSettingsView: View {
    @ObservedObject var smoothScrolling: SmoothScrollModel
    @EnvironmentObject private var model: MacPilotModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("smoothScrolling")).font(.system(size: 30, weight: .bold))
                    Text(model.t("smoothScrollingSubtitle")).foregroundStyle(.secondary)
                }
                Toggle(model.t("smoothScrollingEnable"), isOn: Binding(
                    get: { smoothScrolling.settings.isEnabled },
                    set: { smoothScrolling.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                if !smoothScrolling.settings.isEnabled {
                    Label(model.t("smoothScrollingNotConfiguredHint"), systemImage: "info.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                permissionStatus
                Divider()
                controlGroup {
                    Toggle(model.t("smoothScrollingVertical"), isOn: Binding(
                        get: { smoothScrolling.settings.smoothVertical },
                        set: { smoothScrolling.setSmoothVertical($0) }
                    ))
                    Toggle(model.t("smoothScrollingHorizontal"), isOn: Binding(
                        get: { smoothScrolling.settings.smoothHorizontal },
                        set: { smoothScrolling.setSmoothHorizontal($0) }
                    ))
                }
                Divider()
                controlGroup {
                    Toggle(model.t("smoothScrollingAdaptiveSpeed"), isOn: Binding(
                        get: { smoothScrolling.settings.adaptiveSpeedEnabled },
                        set: { smoothScrolling.setAdaptiveSpeedEnabled($0) }
                    ))
                    if smoothScrolling.settings.adaptiveSpeedEnabled {
                        sliderRow(model.t("smoothScrollingAdaptiveSpeedMaximum"), value: Binding(
                            get: { smoothScrolling.settings.adaptiveSpeedMaximum },
                            set: { smoothScrolling.setAdaptiveSpeedMaximum($0) }
                        ), range: SmoothScrollSettings.adaptiveSpeedRange, step: 0.1, display: { String(format: "%.1f×", $0) })
                    }
                }
                Divider()
                controlGroup {
                    Toggle(model.t("smoothScrollingReverseVertical"), isOn: Binding(
                        get: { smoothScrolling.settings.reverseVertical },
                        set: { smoothScrolling.setReverseVertical($0) }
                    ))
                    Toggle(model.t("smoothScrollingReverseHorizontal"), isOn: Binding(
                        get: { smoothScrolling.settings.reverseHorizontal },
                        set: { smoothScrolling.setReverseHorizontal($0) }
                    ))
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sliderRow(model.t("smoothScrollingStep"), value: Binding(
                        get: { smoothScrolling.settings.minimumStep },
                        set: { smoothScrolling.setMinimumStep($0) }
                    ), range: SmoothScrollSettings.stepRange, step: 1, display: { "\(Int($0))" })
                    sliderRow(model.t("smoothScrollingSpeed"), value: Binding(
                        get: { smoothScrolling.settings.speed },
                        set: { smoothScrolling.setSpeed($0) }
                    ), range: SmoothScrollSettings.speedRange, step: 0.1, display: { String(format: "%.1f×", $0) })
                    sliderRow(model.t("smoothScrollingDuration"), value: Binding(
                        get: { smoothScrolling.settings.duration },
                        set: { smoothScrolling.setDuration($0) }
                    ), range: SmoothScrollSettings.durationRange, step: 0.05, display: { String(format: "%.2f", $0) })
                    sliderRow(model.t("smoothScrollingDeadZone"), value: Binding(
                        get: { smoothScrolling.settings.deadZone },
                        set: { smoothScrolling.setDeadZone($0) }
                    ), range: SmoothScrollSettings.deadZoneRange, step: 0.1, display: { String(format: "%.1f", $0) })
                }
                Divider()
                Toggle(model.t("smoothScrollingSimulatePhases"), isOn: Binding(
                    get: { smoothScrolling.settings.simulatesTrackpadPhases },
                    set: { smoothScrolling.setSimulatesTrackpadPhases($0) }
                ))
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
    }

    private var permissionStatus: some View {
        Group {
            if smoothScrolling.hasAccessibilityPermission {
                Label(model.t("smoothScrollingAccessibilityReady"), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 12) {
                    Label(model.t("smoothScrollingAccessibilityRequired"), systemImage: "lock.shield")
                    Spacer()
                    Button(model.t("smoothScrollingGrantAccessibility")) {
                        smoothScrolling.requestAccessibility()
                    }
                    Button(model.t("smoothScrollingOpenAccessibility")) {
                        smoothScrolling.openAccessibilitySettings()
                    }
                }
                .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func controlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
