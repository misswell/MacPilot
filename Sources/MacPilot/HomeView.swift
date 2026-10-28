import SwiftUI

/// 首页：每个功能一张开关卡片，按自适应网格排布。
///
/// 列宽固定在一个舒适区间内，窗口变宽时自动增加列数：
/// 默认窗口宽度两列，拉宽后三列甚至更多，不再是一条到底的长列表。
struct HomeView: View {
    @EnvironmentObject private var model: MacPilotModel
    /// Observed directly: the menu-bar warning icon's failures live on this
    /// nested model, and the Home card must disappear the moment they clear.
    @ObservedObject var awake: AwakeSessionManager

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
                attentionNotice
                summaryCard
                RemoteLocalNetworkNotice(server: model.remoteControl)
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

    /// 菜单栏警告图标的说明。
    ///
    /// 图标本身只说明「有东西要处理」；这里逐条列出具体原因，包括功能关闭后
    /// 仍可能出现的问题（后台电源服务未能退出），因此它不依赖 Awake 页面是否可达。
    /// 视觉上与远程网络提示一致：页面级橙色内联提示框，不再套一层卡片。
    @ViewBuilder
    private var attentionNotice: some View {
        let issues = awake.attentionIssues
        if !issues.isEmpty {
            InlineWarningBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.t("homeNeedsAttention"), systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(model.t("homeNeedsAttentionHint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(issues) { issue in
                        if issue.id != issues.first?.id {
                            Divider()
                        }
                        attentionRow(issue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attentionRow(_ issue: HomeAttentionIssue) -> some View {
        if let message = issue.diagnosticMessage {
            attentionRowContent(issue)
                .help(model.t("awakeClosedLidError", message))
        } else {
            attentionRowContent(issue)
        }
    }

    private func attentionRowContent(_ issue: HomeAttentionIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t(issue.titleKey))
                    .font(.subheadline.weight(.semibold))
                Text(AppText.value(issue.detailKey, language: model.language,
                                   arguments: issue.detailArguments))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            attentionAction(issue)
        }
    }

    @ViewBuilder
    private func attentionAction(_ issue: HomeAttentionIssue) -> some View {
        if model.isSectionAvailable(.awake) {
            Button(model.t("homeNeedsAttentionOpenAwake")) {
                model.requestSection(.awake)
            }
            .controlSize(.small)
        } else if case .closedLid(let failure) = issue, failure.stage == .retirement {
            // The feature is off, so its page is unreachable; retrying the
            // release is the only repair this build can offer.
            Button(model.t("homeNeedsAttentionRetryCleanup")) {
                model.awake.cleanupUnusedPowerServiceIfDisabled()
            }
            .controlSize(.small)
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
