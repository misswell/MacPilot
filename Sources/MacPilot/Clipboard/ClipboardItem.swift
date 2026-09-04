//
//  ClipboardItem.swift
//  MacPilot
//
//  剪贴板历史数据模型。
//

import AppKit
import Foundation
import ImageIO

/// 剪贴板历史条目中的一段内容（一种 pasteboard type 及其原始数据）。
///
/// 大数据（图片等）通过 `file` 落盘，`value` 为 nil；展示或粘贴时按需从
/// 磁盘读取，避免把整份内容常驻内存。
struct ClipboardContent: Codable, Hashable, Sendable {
    var type: String
    var value: Data?
    /// 落盘文件名（位于 ClipboardContentStore 目录）；设置时 value 为 nil。
    var file: String?
    /// 原始数据字节数（用于判定与去重）。
    var size: Int

    init(type: String, value: Data? = nil, file: String? = nil, size: Int = 0) {
        self.type = type
        self.value = value
        self.file = file
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        value = try container.decodeIfPresent(Data.self, forKey: .value)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }

    /// 是否为磁盘引用（真实数据不在内存中）。
    var isExternal: Bool { file != nil }
}

/// 一条剪贴板历史记录。使用值语义，便于 SwiftUI 观察与 Codable 持久化。
struct ClipboardItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var application: String?
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var numberOfCopies: Int
    var pin: String?
    var title: String
    var contents: [ClipboardContent]

    init(id: UUID = UUID(), contents: [ClipboardContent]) {
        self.id = id
        self.application = nil
        self.firstCopiedAt = Date.now
        self.lastCopiedAt = Date.now
        self.numberOfCopies = 1
        self.pin = nil
        self.title = ""
        self.contents = contents
    }

    var isPinned: Bool { pin != nil }

    /// 复制时产生的临时类型，不参与相似度判定。
    private static let transientTypes: [String] = [
        NSPasteboard.PasteboardType.modified.rawValue,
        NSPasteboard.PasteboardType.fromMacPilot.rawValue,
        NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
        NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
        NSPasteboard.PasteboardType.source.rawValue,
        NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
        NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
        NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
        NSPasteboard.PasteboardType.notesRichText.rawValue
    ]

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png, .jpeg, .heic]

    /// 新条目是否完全包含既有条目的内容（用于合并重复复制）。
    /// 磁盘引用（value 均为 nil）的内容退化为按 (type, size) 比较：
    /// 大小相同的文件/图片内容会被视为重复合并。
    func supersedes(_ item: ClipboardItem) -> Bool {
        item.contents
            .filter { content in !Self.transientTypes.contains(content.type) }
            .allSatisfy { content in
                contents.contains {
                    $0.type == content.type
                        && $0.size == content.size
                        && $0.value == content.value
                }
            }
    }

    /// 生成用于列表展示的标题。
    func generateTitle() -> String {
        // Do not resolve image data merely to decide whether this is an image.
        // ClipboardMonitor calls this immediately after writing the image to
        // disk, and decoding it here would recreate the memory spike.
        if isImage {
            return ""
        }

        var title = previewableText.shortened(to: 1_000)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title
    }

    /// 用于搜索与展示的纯文本。
    var previewableText: String {
        if !fileURLs.isEmpty {
            return fileURLs
                .compactMap { $0.absoluteString.removingPercentEncoding }
                .joined(separator: "\n")
        } else if let text = text, !text.isEmpty {
            return text
        } else if let rtf = rtf, !rtf.string.isEmpty {
            return rtf.string
        } else if let html = html, !html.string.isEmpty {
            return html.string
        } else {
            return title
        }
    }

    var fileURLs: [URL] {
        allContentData([.fileURL])
            .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
    }

    var htmlData: Data? { contentData([.html]) }
    var html: NSAttributedString? {
        guard let data = htmlData else { return nil }
        return NSAttributedString(html: data, documentAttributes: nil)
    }

    var imageData: Data? { contentData(Self.imageTypes) }
    var image: NSImage? {
        guard let data = imageData else { return nil }
        return NSImage(data: data)
    }

    var isImage: Bool {
        contents.contains { content in
            Self.imageTypes.contains(NSPasteboard.PasteboardType(content.type))
        }
    }

    /// A bounded preview for the clipboard panel. The original image stays
    /// file-backed and is never decoded just to render a 20px row thumbnail.
    var thumbnailImage: NSImage? {
        guard let content = contents.first(where: { content in
            Self.imageTypes.contains(NSPasteboard.PasteboardType(content.type))
        }) else { return nil }

        let source: CGImageSource?
        if let file = content.file {
            source = CGImageSourceCreateWithURL(
                ClipboardContentStore.fileURL(for: file) as CFURL,
                nil
            )
        } else if let value = content.value {
            source = CGImageSourceCreateWithData(value as CFData, nil)
        } else {
            source = nil
        }
        guard let source,
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 80
                  ] as CFDictionary
              ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    var rtfData: Data? { contentData([.rtf]) }
    var rtf: NSAttributedString? {
        guard let data = rtfData else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    var text: String? {
        guard let data = contentData([.string]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 内容里是否带有 MacPilot 自录标记（合并去重时用于保留原始来源应用）。
    var fromMacPilot: Bool { contentData([.fromMacPilot]) != nil }

    private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
        contents.first { types.contains(NSPasteboard.PasteboardType($0.type)) }.flatMap(resolvedData(for:))
    }

    private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
        contents
            .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
            .compactMap(resolvedData(for:))
    }

    /// 返回内容的真实数据：内存内联值优先，磁盘引用则按需读取。
    func resolvedData(for content: ClipboardContent) -> Data? {
        if let value = content.value { return value }
        guard let file = content.file else { return nil }
        return ClipboardContentStore.read(file: file)
    }
}

// MARK: - Pasteboard type helpers

extension NSPasteboard.PasteboardType {
    static let heic = NSPasteboard.PasteboardType(rawValue: "public.heic")
    static let jpeg = NSPasteboard.PasteboardType(rawValue: "public.jpeg")

    // 参见 http://nspasteboard.org
    static let autoGenerated = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.AutoGeneratedType")
    static let concealed = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType")
    static let source = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.source")
    static let transient = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.TransientType")

    static let modified = NSPasteboard.PasteboardType(rawValue: "x.nspasteboard.ModifiedType")

    /// 标记「本次复制来自 MacPilot 剪切板」。
    static let fromMacPilot = NSPasteboard.PasteboardType(rawValue: "com.misswell.macpilot.clipboard")

    static let microsoftObjectLink = NSPasteboard.PasteboardType(rawValue: "com.microsoft.ObjectLink")
    static let microsoftLinkSource = NSPasteboard.PasteboardType(rawValue: "com.microsoft.Link-Source")
    static let linkPresentationMetadata = NSPasteboard.PasteboardType(rawValue: "com.apple.linkpresentation.metadata")
    static let customWebKitPasteboardData = NSPasteboard.PasteboardType(rawValue: "com.apple.WebKit.custom-pasteboard-data")
    static let customChromiumWebData = NSPasteboard.PasteboardType(rawValue: "org.chromium.web-custom-data")
    static let chromiumSourceUrl = NSPasteboard.PasteboardType(rawValue: "org.chromium.source-url")
    static let chromiumSourceToken = NSPasteboard.PasteboardType(rawValue: "org.chromium.internal.source-rfh-token")
    static let notesRichText = NSPasteboard.PasteboardType(rawValue: "com.apple.notes.richtext")
}

// MARK: - Small helpers

extension String {
    /// 截断到最大长度（按字符，不截断多字节字符）。
    func shortened(to maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(self[startIndex..<index(startIndex, offsetBy: maxLength)])
    }
}

extension NSImage {
    var pixelSize: NSSize {
        if let bitmapRep = representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
            return NSSize(width: CGFloat(bitmapRep.pixelsWide), height: CGFloat(bitmapRep.pixelsHigh))
        }
        return size
    }
}
