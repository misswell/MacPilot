import SwiftUI

// MARK: - 统一设置界面组件
//
// 所有功能页共用同一套视觉语言：
//  - 页头：30pt 粗体标题 + 副标题
//  - 内容：毛玻璃卡片（regularMaterial + 连续圆角 16 + 细描边 + 轻阴影）
//  - 卡片内小节标题：headline

/// 统一的功能页卡片：毛玻璃材质 + 连续圆角 16 + 细描边 + 轻阴影。
struct SettingsCard<Content: View>: View {
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
