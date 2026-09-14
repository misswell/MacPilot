//
//  ICNSWriter.swift
//  MacPilotDockGroupsCore
//
//  需求第 5、24 节：Helper 需要的 `AppIcon.icns` 由 MacPilot 自己生成。
//  这里直接按 ICNS 容器格式写入 PNG 元素，不调用 iconutil / 不执行 shell 命令。
//

import AppKit
import Foundation

public enum ICNSWriter {
    /// OSType → 像素边长。使用 PNG 元素（`ic07` 系列）以保持 Retina 清晰度。
    static let typeSizes: [(type: String, pixels: Int)] = [
        ("icp4", 16),
        ("icp5", 32),
        ("icp6", 64),
        ("ic07", 128),
        ("ic08", 256),
        ("ic09", 512),
        ("ic10", 1024),
        ("ic11", 32),
        ("ic12", 64),
        ("ic13", 256),
        ("ic14", 512)
    ]

    /// 由图像渲染器生成 `.icns` 数据。
    public static func data(renderPNG: (Int) -> Data?) -> Data {
        var elements = Data()
        for (type, pixels) in typeSizes {
            guard let png = renderPNG(pixels), !png.isEmpty else { continue }
            elements.append(contentsOf: Array(type.utf8))
            var length = UInt32(png.count + 8).bigEndian
            withUnsafeBytes(of: &length) { elements.append(contentsOf: $0) }
            elements.append(png)
        }

        var result = Data()
        result.append(contentsOf: Array("icns".utf8))
        var total = UInt32(elements.count + 8).bigEndian
        withUnsafeBytes(of: &total) { result.append(contentsOf: $0) }
        result.append(elements)
        return result
    }

    /// 由 `NSImage` 生成 `.icns` 数据。
    public static func data(from image: NSImage) -> Data {
        data { pixels in
            renderPNG(image: image, pixels: pixels)
        }
    }

    /// 把 `NSImage` 渲染成指定像素边长的 PNG。
    public static func renderPNG(image: NSImage, pixels: Int) -> Data? {
        guard pixels > 0 else { return nil }
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        representation.size = NSSize(width: pixels, height: pixels)

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }
}
