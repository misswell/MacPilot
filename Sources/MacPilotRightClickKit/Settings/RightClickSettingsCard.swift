import SwiftUI

// MARK: - 右键菜单设置界面卡片
//
// 与主 App 各功能页保持同一套视觉语言：
// 毛玻璃卡片（regularMaterial + 连续圆角 16 + 细描边 + 轻阴影）。
// 由于 MacPilotRightClickKit 是独立模块，这里复制一份本地组件。

/// 右键菜单设置页的统一卡片容器。
struct RightClickSettingsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07))
            )
            .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
    }
}

extension Text {
    /// 用 Kit 的本地化词典渲染文本（设置界面专用；扩展进程不走 SwiftUI）。
    init(appLocalized key: String) {
        self.init(AppLocalization.localized(key))
    }
}
