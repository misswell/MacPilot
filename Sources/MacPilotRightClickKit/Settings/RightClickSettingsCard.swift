import SwiftUI

// MARK: - 右键菜单设置界面卡片
//
// 与主 App 各功能页保持同一套视觉语言：
// macOS 26 使用 Liquid Glass，macOS 14–25 使用 regularMaterial。
// 由于 MacPilotRightClickKit 是独立模块，这里复制一份本地组件。

/// 右键菜单设置页的统一卡片容器。
struct RightClickSettingsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            cardContent
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            cardContent
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07))
                )
                .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RightClickSettingsSelectionPill: View {
    let isSelected: Bool

    var body: some View {
        if #available(macOS 26.0, *), isSelected {
            Color.clear
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.16)).interactive(),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
    }
}

extension Text {
    /// 用 Kit 的本地化词典渲染文本（设置界面专用；扩展进程不走 SwiftUI）。
    init(appLocalized key: String) {
        self.init(AppLocalization.localized(key))
    }
}
