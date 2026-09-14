import SwiftUI

/// 首页：每个功能一张开关卡片，按自适应网格排布。
///
/// 列宽固定在一个舒适区间内，窗口变宽时自动增加列数：
/// 默认窗口宽度两列，拉宽后三列甚至更多，不再是一条到底的长列表。
struct HomeView: View {
    @EnvironmentObject private var model: MacPilotModel

    /// 单张功能卡片的最小宽度。窗口默认宽度下正好两列，拉宽后自动三列。
    private static let tileMinimumWidth: CGFloat = 250
    /// 卡片之间的间距（横向与纵向一致）。
    private static let tileSpacing: CGFloat = 14

    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Self.tileMinimumWidth), spacing: Self.tileSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summaryCard
                featureGroup(titleKey: "homeAutomation", sections: MainSection.automationSections)
                featureGroup(titleKey: "homeUtilities", sections: MainSection.utilitySections)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.t("home"))
                .font(.system(size: 30, weight: .bold))
            Text(model.t("homeSubtitle"))
                .foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 12) {
                FeatureIconBadge(systemImage: "checkmark.circle.fill", isEnabled: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("homeEnabledCount", model.enabledFeatureCount))
                        .font(.headline)
                    Text(model.t("homeFeatureHint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func featureGroup(titleKey: String, sections: [MainSection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t(titleKey))
                .font(.headline)
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: Self.tileSpacing) {
                ForEach(sections) { section in
                    FeatureToggleTile(section: section)
                }
            }
        }
    }
}

/// 功能卡片图标底座：统一 34pt 圆角方块，开启时加深着色。
private struct FeatureIconBadge: View {
    let systemImage: String
    let isEnabled: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 34, height: 34)
            .background(
                Color.accentColor.opacity(isEnabled ? 0.22 : 0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

/// 单个功能的开关卡片：图标 + 开关在上，标题与说明在下。
private struct FeatureToggleTile: View {
    @EnvironmentObject private var model: MacPilotModel
    let section: MainSection

    private var isEnabled: Bool { model.isFeatureEnabled(section) }

    var body: some View {
        SettingsCard(accented: isEnabled) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    FeatureIconBadge(systemImage: section.systemImage, isEnabled: isEnabled)
                    Spacer(minLength: 0)
                    Toggle("", isOn: binding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text(model.t(section.titleKey)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t(section.titleKey))
                        .font(.body.weight(.semibold))
                    Text(model.t(section.featureDescriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3, reservesSpace: true)
                }
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { model.isFeatureEnabled(section) },
            set: { model.setFeatureEnabled($0, for: section) }
        )
    }
}
