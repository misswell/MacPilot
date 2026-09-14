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

@MainActor
public enum DockGroupIconRenderer {
    /// Dock 图标画布的常用留白比例。
    static let contentInsetRatio: CGFloat = 0.08
    static let cornerRadiusRatio: CGFloat = 0.2237

    /// 渲染分组图标。
    /// - Parameters:
    ///   - group: 分组。
    ///   - size: 输出边长（点）。
    ///   - memberIconURLs: 组合图标时使用的成员 App 路径（最多取前 4 个）。
    ///   - customIconDirectory: 自定义图片所在目录；默认 MacPilot 的管理目录。
    public static func image(
        for group: DockGroup,
        size: CGFloat,
        memberIconURLs: [URL] = [],
        customIconDirectory: URL? = nil
    ) -> NSImage {
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
            drawSymbolBackground(in: path, rect: content, group: group)
            drawSymbol(named: group.icon.value, in: content, fallback: group.name)
        case .emoji:
            drawEmojiBackground(in: path, rect: content)
            drawEmoji(group.icon.value, in: content, fallback: group.name)
        case .customImage:
            if !drawCustomImage(named: group.icon.value, in: path, rect: content, directory: customIconDirectory) {
                drawComposite(in: path, rect: content, memberIconURLs: memberIconURLs)
                drawFallbackSymbol(in: content)
            }
        case .composite:
            drawComposite(in: path, rect: content, memberIconURLs: memberIconURLs)
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
    static func accentColor(for group: DockGroup) -> NSColor {
        let hash = group.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.62, brightness: 0.86, alpha: 1)
    }

    private static func drawSymbolBackground(in path: NSBezierPath, rect: NSRect, group: DockGroup) {
        let base = accentColor(for: group)
        let lighter = base.blended(withFraction: 0.28, of: .white) ?? base
        let darker = base.blended(withFraction: 0.22, of: .black) ?? base
        path.addClip()
        NSGradient(starting: lighter, ending: darker)?.draw(in: rect, angle: -90)
        strokeBorder(path)
    }

    private static func drawEmojiBackground(in path: NSBezierPath, rect: NSRect) {
        path.addClip()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        rect.fill()
        NSGradient(
            starting: NSColor(calibratedWhite: 1.0, alpha: 1),
            ending: NSColor(calibratedWhite: 0.88, alpha: 1)
        )?.draw(in: rect, angle: -90)
        strokeBorder(path)
    }

    private static func drawComposite(in path: NSBezierPath, rect: NSRect, memberIconURLs: [URL]) {
        path.addClip()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        rect.fill()
        NSGradient(
            starting: NSColor(calibratedWhite: 0.99, alpha: 1),
            ending: NSColor(calibratedWhite: 0.86, alpha: 1)
        )?.draw(in: rect, angle: -90)
        strokeBorder(path)

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
        directory: URL?
    ) -> Bool {
        guard !fileName.isEmpty else { return false }
        let base = directory ?? DockGroupPaths.defaultRootDirectory()
        let url = DockGroupPaths.customIconURL(in: base, fileName: fileName)
        guard let image = NSImage(contentsOf: url) else { return false }
        path.addClip()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        strokeBorder(path)
        return true
    }

    private static func strokeBorder(_ path: NSBezierPath) {
        NSColor(calibratedWhite: 0, alpha: 0.10).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: - 前景

    private static func drawSymbol(named name: String, in rect: NSRect, fallback: String) {
        let symbolName = name.isEmpty ? fallbackSymbolName(for: fallback) : name
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            drawEmoji(fallback.first.map(String.init) ?? "▦", in: rect, fallback: "▦")
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

    private static func drawFallbackSymbol(in rect: NSRect) {
        drawEmoji("▦", in: rect, fallback: "▦")
    }

    private static func drawEmoji(_ value: String, in rect: NSRect, fallback: String) {
        let text = value.isEmpty ? String(fallback.prefix(2)) : value
        let fontSize = rect.width * 0.56
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
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
