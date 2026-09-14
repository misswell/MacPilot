import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: MacPilotModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("home"))
                        .font(.system(size: 30, weight: .bold))
                    Text(model.t("homeSubtitle"))
                        .foregroundStyle(.secondary)
                }

                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.t("homeEnabledCount", model.enabledFeatureCount))
                                .font(.headline)
                            Text(model.t("homeFeatureHint"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                featureGroup(titleKey: "homeAutomation", sections: MainSection.automationSections)
                featureGroup(titleKey: "homeUtilities", sections: MainSection.utilitySections)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func featureGroup(titleKey: String, sections: [MainSection]) -> some View {
        SettingsCard {
            Text(model.t(titleKey))
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                    FeatureToggleRow(section: section)
                        .padding(.vertical, 8)
                    if index < sections.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

private struct FeatureToggleRow: View {
    @EnvironmentObject private var model: MacPilotModel
    let section: MainSection

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { model.isFeatureEnabled(section) },
                set: { model.setFeatureEnabled($0, for: section) }
            )
        ) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t(section.titleKey))
                        .font(.body.weight(.medium))
                    Text(model.t(section.featureDescriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.switch)
    }
}
