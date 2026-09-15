//
//  DockGroupIconRenderer.swift
//  MacPilotDockGroupsCore
//
//  需求第 12、13 节：分组图标支持
//  SF Symbol / Emoji / 自定义图片 / 组合 App 图标（默认，2×2 Folder Preview）。
//
//  渲染只读取 App 的 NSImage 图标（NSWorkspace.icon(forFile:)），
//  绝不写入目标 App 的 Resources。
//

import AppKit
import Foundation

/// 分组图标要按哪种外观绘制。
///
/// 深色模式下 macOS 自己的文件夹图标会换成压暗的版本，白色的分组图标在深色
/// 界面里则会亮得刺眼，所以分组图标也必须有深色版本。
///
/// 注意：**只有界面内绘制跟随外观**。写进 Helper `.app` 的 Dock 图标仍然使用
/// 浅色版本——`.icns` 无法携带外观变体，Dock 里的第三方图标本来也不随系统
/// 外观变化，跟随生成时的外观反而会让图标在用户切换外观后变得不一致。
public enum DockGroupIconAppearance: Sendable {
    case light
    case dark

    public init(isDark: Bool) {
        self = isDark ? .dark : .light
    }

    /// 由 AppKit 当前外观推断；SwiftUI 视图里更推荐显式传 `colorScheme`。
    /// `NSApp` 只在主线程可读，所以这里跟着主 actor 走。
    @MainActor
    public static func current() -> DockGroupIconAppearance {
        current(NSApp?.effectiveAppearance)
    }

    static func current(_ appearance: NSAppearance?) -> DockGroupIconAppearance {
        guard let appearance,
              appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        else { return .light }
        return .dark
    }
}

@MainActor
public enum DockGroupIconRenderer {
    /// Dock 图标画布的常用留白比例。
    static let contentInsetRatio: CGFloat = 0.08
    static let cornerRadiusRatio: CGFloat = 0.2237

    /// 一套按外观取的绘制颜色。
    private struct Palette {
        let baseFill: NSColor
        let gradientStart: NSColor
        let gradientEnd: NSColor
        let border: NSColor
        /// 文字 / 兜底符号的前景色。Emoji 本身是彩色字形，不受它影响。
        let glyph: NSColor

        static func make(for appearance: DockGroupIconAppearance) -> Palette {
            switch appearance {
            case .light:
                Palette(
                    baseFill: NSColor(calibratedWhite: 0.93, alpha: 1),
                    gradientStart: NSColor(calibratedWhite: 0.99, alpha: 1),
                    gradientEnd: NSColor(calibratedWhite: 0.86, alpha: 1),
                    border: NSColor(calibratedWhite: 0, alpha: 0.10),
                    glyph: NSColor(calibratedWhite: 0.12, alpha: 1)
                )
            case .dark:
                // 对齐 macOS 深色模式的文件夹图标：整体压暗，描边改成浅色，
                // 否则在深色背景上完全看不出边界。
                Palette(
                    baseFill: NSColor(calibratedWhite: 0.24, alpha: 1),
                    gradientStart: NSColor(calibratedWhite: 0.30, alpha: 1),
                    gradientEnd: NSColor(calibratedWhite: 0.15, alpha: 1),
                    border: NSColor(calibratedWhite: 1, alpha: 0.18),
                    glyph: NSColor(calibratedWhite: 0.96, alpha: 1)
                )
            }
        }
    }

    /// 渲染分组图标。
    /// - Parameters:
    ///   - group: 分组。
    ///   - size: 输出边长（点）。
    ///   - memberIconURLs: 组合图标时使用的成员 App 路径（最多取前 4 个）。
    ///   - customIconDirectory: 自定义图片所在目录；默认 MacPilot 的管理目录。
    ///   - appearance: 按浅色还是深色绘制；默认跟随当前 App 外观。
    public static func image(
        for group: DockGroup,
        size: CGFloat,
        memberIconURLs: [URL] = [],
        customIconDirectory: URL? = nil,
        appearance: DockGroupIconAppearance = .current()
    ) -> NSImage {
        let palette = Palette.make(for: appearance)
        let canvas = max(64, size)
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        defer { image.unlockFocus() }

        let content = NSRect(
            x: canvas * contentInsetRatio,
            y: canvas * contentInsetRatio,
            width: canvas * (1 - contentInsetRatio * 2),
            height: canvas * (1 - contentInsetRatio * 2)
        )
        let path = roundedPath(in: content)

        switch group.icon.source {
        case .symbol:
            drawSymbolBackground(in: path, rect: content, group: group, palette: palette, appearance: appearance)
            drawSymbol(named: group.icon.value, in: content, fallback: group.name)
        case .emoji:
            drawEmojiBackground(in: path, rect: content, palette: palette)
            drawEmoji(group.icon.value, in: content, fallback: group.name, glyph: palette.glyph)
        case .customImage:
            if !drawCustomImage(
                named: group.icon.value,
                in: path,
                rect: content,
                directory: customIconDirectory,
                palette: palette
            ) {
                drawComposite(in: path, rect: content, memberIconURLs: memberIconURLs, palette: palette, appearance: appearance)
                drawFallbackSymbol(in: content, glyph: palette.glyph)
            }
        case .composite:
            drawComposite(in: path, rect: content, memberIconURLs: memberIconURLs, palette: palette, appearance: appearance)
        }

        return image
    }

    // MARK: - 背景

    private static func roundedPath(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(
            roundedRect: rect,
            xRadius: rect.width * cornerRadiusRatio,
            yRadius: rect.width * cornerRadiusRatio
        )
    }

    /// 由分组 ID 派生稳定的强调色，让每个分组一眼可辨。
    /// 深色模式下略微降低饱和与亮度，避免彩色图标在暗色界面里过于刺眼。
    static func accentColor(
        for group: DockGroup,
        appearance: DockGroupIconAppearance = .light
    ) -> NSColor {
        let hash = group.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        let hue = CGFloat(hash % 360) / 360
        switch appearance {
        case .light:
            return NSColor(calibratedHue: hue, saturation: 0.62, brightness: 0.86, alpha: 1)
        case .dark:
            return NSColor(calibratedHue: hue, saturation: 0.52, brightness: 0.66, alpha: 1)
        }
    }

    private static func drawSymbolBackground(
        in path: NSBezierPath,
        rect: NSRect,
        group: DockGroup,
        palette: Palette,
        appearance: DockGroupIconAppearance
    ) {
        let base = accentColor(for: group, appearance: appearance)
        let lighter = base.blended(withFraction: 0.28, of: .white) ?? base
        let darker = base.blended(withFraction: 0.22, of: .black) ?? base
        path.addClip()
        NSGradient(starting: lighter, ending: darker)?.draw(in: rect, angle: -90)
        strokeBorder(path, palette: palette)
    }

    private static func drawEmojiBackground(in path: NSBezierPath, rect: NSRect, palette: Palette) {
        path.addClip()
        palette.baseFill.setFill()
        rect.fill()
        NSGradient(starting: palette.gradientStart, ending: palette.gradientEnd)?.draw(in: rect, angle: -90)
        strokeBorder(path, palette: palette)
    }

    private static func drawComposite(
        in path: NSBezierPath,
        rect: NSRect,
        memberIconURLs: [URL],
        palette: Palette,
        appearance: DockGroupIconAppearance
    ) {
        path.addClip()
        palette.baseFill.setFill()
        rect.fill()
        NSGradient(starting: palette.gradientStart, ending: palette.gradientEnd)?.draw(in: rect, angle: -90)
        strokeBorder(path, palette: palette)

        let padding = rect.width * 0.14
        let available = rect.insetBy(dx: padding, dy: padding)
        let cellSide = available.width / 2
        let iconSide = cellSide * 0.94

        // 成员图标同样只取「按格子尺寸重绘过的小图」：系统原图是多表示的
        // 1024×1024，直接画会把大位图物化出来（见 DockGroupIconThumbnail）。
        let icons = memberIconURLs.prefix(4).compactMap { url -> NSImage? in
            InstalledAppResolver.icon(for: url, size: iconSide)
        }
        guard !icons.isEmpty else { return }

        for (index, icon) in icons.enumerated() {
            let column = index % 2
            let row = index / 2
            let origin = NSPoint(
                x: available.minX + CGFloat(column) * cellSide + (cellSide - iconSide) / 2,
                y: available.maxY - CGFloat(row + 1) * cellSide + (cellSide - iconSide) / 2
            )
            icon.draw(
                in: NSRect(x: origin.x, y: origin.y, width: iconSide, height: iconSide),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
    }

    private static func drawCustomImage(
        named fileName: String,
        in path: NSBezierPath,
        rect: NSRect,
        directory: URL?,
        palette: Palette
    ) -> Bool {
        guard !fileName.isEmpty else { return false }
        let base = directory ?? DockGroupPaths.defaultRootDirectory()
        let url = DockGroupPaths.customIconURL(in: base, fileName: fileName)
        guard let image = NSImage(contentsOf: url) else { return false }
        path.addClip()
        palette.baseFill.setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        strokeBorder(path, palette: palette)
        return true
    }

    private static func strokeBorder(_ path: NSBezierPath, palette: Palette) {
        palette.border.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: - 前景

    private static func drawSymbol(named name: String, in rect: NSRect, fallback: String) {
        let symbolName = name.isEmpty ? fallbackSymbolName(for: fallback) : name
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            drawEmoji(fallback.first.map(String.init) ?? "▦", in: rect, fallback: "▦", glyph: .white)
            return
        }

        let pointSize = rect.width * 0.46
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let configured = symbol.withSymbolConfiguration(configuration) else { return }

        let side = rect.width * 0.5
        let target = NSRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )

        let tinted = NSImage(size: target.size)
        tinted.lockFocus()
        NSColor.white.set()
        configured.draw(in: NSRect(origin: .zero, size: target.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSRect(origin: .zero, size: target.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func drawFallbackSymbol(in rect: NSRect, glyph: NSColor) {
        drawEmoji("▦", in: rect, fallback: "▦", glyph: glyph)
    }

    private static func drawEmoji(_ value: String, in rect: NSRect, fallback: String, glyph: NSColor) {
        let text = value.isEmpty ? String(fallback.prefix(2)) : value
        let fontSize = rect.width * 0.56
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            // 不指定前景色时 AppKit 按黑色绘制，深色背景下会完全看不见。
            .foregroundColor: glyph
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        string.draw(at: origin)
    }

    /// 名称 → SF Symbol 的启发式映射，用于组合图标没有任何成员时的兜底。
    static func fallbackSymbolName(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("ai") || lowered.contains("智能") { return "brain" }
        if lowered.contains("dev") || lowered.contains("开发") { return "chevron.left.forwardslash.chevron.right" }
        if lowered.contains("tool") || lowered.contains("工具") { return "wrench.and.screwdriver" }
        if lowered.contains("design") || lowered.contains("设计") { return "paintbrush" }
        if lowered.contains("media") || lowered.contains("媒体") { return "film" }
        return "square.grid.2x2"
    }
}
