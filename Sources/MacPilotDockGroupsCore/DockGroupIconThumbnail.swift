//
//  DockGroupIconThumbnail.swift
//  MacPilotDockGroupsCore
//
//  需求第 12 节：MacPilot 只缓存**自己的 PNG 缩略图**。
//
//  为什么必须有这一层：
//  `NSWorkspace.icon(forFile:)` 返回的是多表示（multi-representation）的 NSImage，
//  `image.size` 只是**显示尺寸**，底层表示往往还是 1024×1024。
//  直接 `tiffRepresentation` 会按原图尺寸物化整张位图并挂回 NSImage：
//  实测每个 App 约 70 MB、约 0.2 s；271 个 App 的应用列表会吃掉数 GB 内存，
//  并在主线程上一口气阻塞一分多钟（2026-09-14 的 Dock 分组「扫描应用」卡死）。
//
//  这里把图标按目标像素尺寸重绘成一张小位图：之后无论内存缓存、磁盘 PNG、
//  还是 SwiftUI 渲染，拿到的都是这张受限的小图。
//

import AppKit
import Foundation
import ImageIO

public enum DockGroupIconThumbnail {
    /// Retina 下的像素倍率：32pt 的图标按 64px 存。
    public static let pixelScale = 2

    /// 点数 → 像素边长（至少 1）。
    public static func pixelSize(forPoints points: CGFloat, scale: CGFloat = CGFloat(pixelScale)) -> Int {
        max(1, Int((points * max(1, scale)).rounded()))
    }

    /// 把任意 NSImage 重绘成 `pixelSize × pixelSize` 的小位图。
    ///
    /// - Parameters:
    ///   - pointSize: 返回图标的显示尺寸（点）。大图按这个尺寸缩放，不会保留原图表示。
    ///   - pixelSize: 位图的实际像素边长，通常是 `pointSize × 2`。
    public static func image(from source: NSImage, pointSize: CGFloat, pixelSize: Int) -> NSImage? {
        let side = max(1, pixelSize)
        let pointSide = pointSize > 0 ? pointSize : CGFloat(side) / CGFloat(self.pixelScale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pointSide, height: pointSide)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: pointSide, height: pointSide),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()

        let thumbnail = NSImage(size: NSSize(width: pointSide, height: pointSide))
        thumbnail.addRepresentation(rep)
        return thumbnail
    }

    /// 编码一张**已经受限**的位图；不要传系统图标原图进来。
    public static func pngData(from image: NSImage) -> Data? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// 重绘 + 编码一步到位：给缓存层用，保证落盘的一定是受限的小图。
    public static func pngData(from image: NSImage, pointSize: CGFloat, pixelSize: Int) -> Data? {
        guard let thumbnail = self.image(from: image, pointSize: pointSize, pixelSize: pixelSize) else {
            return nil
        }
        return pngData(from: thumbnail)
    }

    /// 供后台线程调用：取系统图标 → 限制尺寸 → 编码 PNG。
    ///
    /// 返回值是 `Data`（Sendable），可以安全地跨 actor 传回主线程；
    /// NSImage / NSWorkspace 这类非 Sendable 对象不会离开本函数。
    /// 每张图单独包一层 autoreleasepool：应用选择器要连着取两百多个图标，
    /// 不及时回收会让图标服务映射进来的数据一直挂着。
    public static func pngData(
        forFileAt url: URL,
        pointSize: CGFloat,
        scale: CGFloat = CGFloat(pixelScale)
    ) -> Data? {
        autoreleasepool {
            let source = NSWorkspace.shared.icon(forFile: url.path)
            return pngData(
                from: source,
                pointSize: pointSize,
                pixelSize: pixelSize(forPoints: pointSize, scale: scale)
            )
        }
    }

    // MARK: - PNG 像素尺寸（只读元数据）

    public static func pngPixelSize(in data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }

    public static func pngPixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return (width, height)
    }
}
