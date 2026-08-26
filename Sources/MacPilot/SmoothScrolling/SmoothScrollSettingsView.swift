import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SmoothScrollSettingsView: View {
    @ObservedObject var smoothScrolling: SmoothScrollModel
    @EnvironmentObject private var model: MacPilotModel
    @State private var applicationListRevision = 0

    private struct ExcludedApplication: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let isRunning: Bool
    }

    private var excludedApplications: [ExcludedApplication] {
        smoothScrolling.settings.excludedApplicationBundleIdentifiers.map { identifier in
            let runningApplication = NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
            ).first
            let applicationURL = runningApplication?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            let name = runningApplication?.localizedName
                ?? applicationURL.flatMap(Self.applicationDisplayName)
                ?? identifier
            let icon = runningApplication?.icon
                ?? applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return ExcludedApplication(
                id: identifier,
                name: name,
                icon: icon,
                isRunning: runningApplication != nil
            )
        }
    }

    private var availableApplications: [NSRunningApplication] {
        let excludedIdentifiers = Set(
            smoothScrolling.settings.excludedApplicationBundleIdentifiers.map(
                SmoothScrollApplicationExclusions.canonicalIdentifier
            )
        )
        var seenIdentifiers = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { application in
                guard let identifier = application.bundleIdentifier,
                      identifier.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") != .orderedSame
                else { return false }
                let canonicalIdentifier = SmoothScrollApplicationExclusions.canonicalIdentifier(identifier)
                return excludedIdentifiers.contains(canonicalIdentifier) == false
                    && seenIdentifiers.insert(canonicalIdentifier).inserted
            }
            .sorted {
                ($0.localizedName ?? $0.bundleIdentifier ?? "")
                    .localizedCaseInsensitiveCompare($1.localizedName ?? $1.bundleIdentifier ?? "")
                    == .orderedAscending
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("smoothScrolling")).font(.system(size: 30, weight: .bold))
                    Text(model.t("smoothScrollingSubtitle")).foregroundStyle(.secondary)
                }

                SettingsCard {
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
                }

                SettingsCard {
                    Text(model.t("smoothScrollingExcludedApps")).font(.headline)
                    Text(model.t("smoothScrollingExcludedAppsHint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if excludedApplications.isEmpty {
                        Text(model.t("smoothScrollingNoExcludedApps"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(excludedApplications) { application in
                            HStack(spacing: 10) {
                                if let icon = application.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .frame(width: 28, height: 28)
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(application.name).lineLimit(1)
                                    Text(application.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 6) {
                                    Toggle(model.t("smoothScrollingExcludedAppReverse"), isOn: Binding(
                                        get: { smoothScrolling.isExcludedApplicationReversed(application.id) },
                                        set: {
                                            smoothScrolling.setExcludedApplicationReversed(application.id, reversed: $0)
                                        }
                                    ))
                                    .toggleStyle(.switch)

                                    HStack(spacing: 8) {
                                        if !application.isRunning {
                                            Text(model.t("smoothScrollingExcludedAppNotRunning"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Button {
                                            smoothScrolling.setExcludedApplication(application.id, enabled: false)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red)
                                        .help(model.t("smoothScrollingRemoveExcludedApp"))
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Menu {
                        if availableApplications.isEmpty {
                            Text(model.t("smoothScrollingNoAvailableApps"))
                        } else {
                            Section(model.t("runningApps")) {
                                ForEach(availableApplications, id: \.processIdentifier) { application in
                                    if let identifier = application.bundleIdentifier {
                                        Button(application.localizedName ?? identifier) {
                                            smoothScrolling.setExcludedApplication(identifier, enabled: true)
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button(model.t("smoothScrollingBrowseExcludedApp"), action: browseForExcludedApp)
                    } label: {
                        Label(model.t("smoothScrollingAddExcludedApp"), systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                }
                .id(applicationListRevision)

                SettingsCard {
                    Toggle(model.t("smoothScrollingVertical"), isOn: Binding(
                        get: { smoothScrolling.settings.smoothVertical },
                        set: { smoothScrolling.setSmoothVertical($0) }
                    ))
                    Toggle(model.t("smoothScrollingHorizontal"), isOn: Binding(
                        get: { smoothScrolling.settings.smoothHorizontal },
                        set: { smoothScrolling.setSmoothHorizontal($0) }
                    ))
                    Toggle(model.t("smoothScrollingReverseVertical"), isOn: Binding(
                        get: { smoothScrolling.settings.reverseVertical },
                        set: { smoothScrolling.setReverseVertical($0) }
                    ))
                    Toggle(model.t("smoothScrollingReverseHorizontal"), isOn: Binding(
                        get: { smoothScrolling.settings.reverseHorizontal },
                        set: { smoothScrolling.setReverseHorizontal($0) }
                    ))
                    Toggle(model.t("smoothScrollingBlockWithCommand"), isOn: Binding(
                        get: { smoothScrolling.settings.blockSmoothWhileCommandHeld },
                        set: { smoothScrolling.setBlockSmoothWhileCommandHeld($0) }
                    ))
                }

                SettingsCard {
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

                    Divider()

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

                    Divider()

                    Toggle(model.t("smoothScrollingSimulatePhases"), isOn: Binding(
                        get: { smoothScrolling.settings.simulatesTrackpadPhases },
                        set: { smoothScrolling.setSimulatesTrackpadPhases($0) }
                    ))
                }
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            applicationListRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            applicationListRevision &+= 1
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

    private func browseForExcludedApp() {
        let panel = NSOpenPanel()
        panel.title = model.t("smoothScrollingChooseExcludedApp")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              identifier.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") != .orderedSame
        else { return }
        smoothScrolling.setExcludedApplication(identifier, enabled: true)
    }

    private static func applicationDisplayName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}
