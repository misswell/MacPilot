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

/// 卡片内嵌列表：固定高度、无自带背景，避免与卡片视觉冲突。
extension View {
    func rightClickListStyle() -> some View {
        self
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
    }
}
