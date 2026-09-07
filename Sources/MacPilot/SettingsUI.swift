import SwiftUI

// MARK: - 统一设置界面组件
//
// 所有功能页共用同一套视觉语言：
//  - 页头：30pt 粗体标题 + 副标题
//  - 内容：macOS 26 使用 Liquid Glass，macOS 14–25 使用 regularMaterial
//  - 卡片内小节标题：headline

/// 统一的功能页卡片：macOS 26 使用原生 Liquid Glass，旧系统自动降级为毛玻璃材质。
struct SettingsCard<Content: View>: View {
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

extension View {
    /// Primary actions use the native Liquid Glass emphasis on macOS 26.
    /// Earlier systems retain the familiar bordered prominent treatment.
    @ViewBuilder
    func macPilotProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Multi-page feature navigation uses a single adaptive selection treatment.
/// Liquid Glass remains interactive on macOS 26; older releases use the accent fill.
struct SettingsSelectionPill: View {
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

// MARK: - 设置页滑块

/// 统一的设置页滑块：胶囊轨道 + accent 已选区间 + 白色圆形滑块。
///
/// 系统 `Slider` 在指定 `step` 时会渲染成一排刻度线，范围大时密不可看；
/// 本组件在保留步进取整的前提下去掉刻度，并提供键盘 ←/→ 微调与 VoiceOver 调节。
/// 设置页需要滑块时一律使用本组件，不要直接用系统 `Slider`。
struct SettingsSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let label: String?
    private let format: ((Double) -> String)?

    @State private var isDragging = false

    private static let knobRadius: CGFloat = 9
    private static let trackHeight: CGFloat = 5

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        label: String? = nil,
        format: ((Double) -> String)? = nil
    ) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
        self.format = format
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(0, proxy.size.width - Self.knobRadius * 2)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.14))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: Self.knobRadius + travel * fraction, height: Self.trackHeight)
                knob
                    .offset(x: travel * fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(travel: travel))
        }
        .frame(height: 22)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: Self.knobRadius * 2, height: Self.knobRadius * 2)
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(isDragging ? 0.28 : 0.2), radius: isDragging ? 3 : 2, y: 1)
            .scaleEffect(isDragging ? 1.1 : 1)
            .animation(.easeOut(duration: 0.12), value: isDragging)
    }

    private var increment: Double {
        if let step, step > 0 { return step }
        return (range.upperBound - range.lowerBound) / 20
    }

    private var accessibilityValue: String {
        format?(value) ?? String(format: "%.2f", value)
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                isDragging = true
                let fraction = travel == 0
                    ? 0
                    : min(max((gesture.location.x - Self.knobRadius) / travel, 0), 1)
                value = snapped(range.lowerBound + (range.upperBound - range.lowerBound) * fraction)
            }
            .onEnded { _ in isDragging = false }
    }

    private func adjust(_ direction: Double) {
        value = snapped(value + direction * increment)
    }

    private func snapped(_ raw: Double) -> Double {
        Self.normalizedValue(raw, in: range, step: step)
    }

    nonisolated static func normalizedValue(
        _ raw: Double,
        in range: ClosedRange<Double>,
        step: Double?
    ) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        guard let step, step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let snappedValue = range.lowerBound + steps * step
        // 抹平二进制浮点累计的尾数（如 0.30000000000000004），保持持久化数值干净
        let cleaned = (snappedValue * 1e9).rounded() / 1e9
        return min(range.upperBound, max(range.lowerBound, cleaned))
    }
}
