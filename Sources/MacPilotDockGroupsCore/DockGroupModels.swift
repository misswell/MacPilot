//
//  DockGroupModels.swift
//  MacPilotDockGroupsCore
//
//  Dock Groups（Dock 分组）的纯数据模型。
//
//  设计约束（见需求文档第 2、5、6 节）：
//  - 本文件只描述数据，不触碰任何第三方 App。
//  - `groups.json` 是 Helper 与 MacPilot 之间的唯一配置载体，
//    因此模型类型必须同时被主程序与 Helper 复用（放在共享 target 里）。
//

import Foundation

// MARK: - 时间戳

/// 分组配置里的时间戳统一取秒级精度。
///
/// 这样 `groups.json` 可以用人类可读的 ISO8601 保存，
/// 同时保证「保存 → 读取」后数据完全一致（同秒内不会因为小数位丢失而不相等）。
public enum DockGroupTimestamp {
    public static func now() -> Date {
        normalized(Date())
    }

    public static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }
}

// MARK: - 布局

/// Dock Group 二级列表的布局方式。
public enum DockGroupLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    public var id: String { rawValue }

    /// 需求第 8 节：默认 Grid。
    public static let fallback: DockGroupLayout = .grid
}

// MARK: - 图标

/// 分组图标的来源。
public enum DockGroupIconSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// SF Symbol 名称。
    case symbol
    /// Emoji 文本（如 `🛠`）。
    case emoji
    /// 组合前若干个成员 App 图标的 2×2 Folder Preview（默认推荐）。
    case composite
    /// 用户自定义图片（拷贝到 MacPilot 自己的目录，不触碰原图）。
    case customImage

    public var id: String { rawValue }
}

/// 分组图标描述。
public struct DockGroupIcon: Codable, Equatable, Sendable {
    public var source: DockGroupIconSource
    /// `symbol` 时为 SF Symbol 名；`emoji` 时为 Emoji；`customImage` 时为 MacPilot 目录内的相对文件名。
    public var value: String

    public init(source: DockGroupIconSource = .composite, value: String = "") {
        self.source = source
        self.value = value
    }

    /// 默认图标：组合成员 App 图标。
    public static let `default` = DockGroupIcon(source: .composite, value: "")

    /// 可选的 SF Symbol 图标目录（需求第 13 节：SF Symbol / Emoji / 自定义 / 组合）。
    public static let symbolChoices = [
        "hammer", "chevron.left.forwardslash.chevron.right", "cpu", "terminal",
        "brain", "sparkles", "paintbrush", "camera", "film", "music.note",
        "globe", "bubble.left.and.bubble.right", "gamecontroller", "wrench.and.screwdriver",
        "shippingbox", "briefcase", "graduationcap", "chart.bar"
    ]

    /// 可选的 Emoji 图标目录。
    public static let emojiChoices = ["🛠", "💻", "🤖", "🎨", "🎬", "🎵", "🌐", "💬", "🎮", "📦", "📊", "🚀"]
}

// MARK: - 成员 App

/// 分组中的一个第三方 App 引用。
///
/// 需求第 2、11、15、16 节：
/// - 只保存引用（bundleId + path），**绝不复制、移动或修改**目标 App；
/// - `bundleIdentifier` 是首选解析依据，`path` 只作为 fallback，
///   这样 App 升级或移动后不会轻易失效。
public struct DockGroupApp: Codable, Identifiable, Equatable, Sendable {
    /// 稳定的引用 ID（与 App 自身身份无关，仅用于 SwiftUI 列表与排序）。
    public var id: UUID
    /// 首选解析依据。
    public var bundleIdentifier: String?
    /// fallback 路径（例如 `/Applications/Visual Studio Code.app`）。
    public var path: String
    /// 展示名（缓存自上次解析；App 改名后以实时解析为准）。
    public var name: String
    /// 添加时间（用于稳定排序的兜底）。
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String?,
        path: String,
        name: String,
        addedAt: Date = DockGroupTimestamp.now()
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.name = name
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, path, name, addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        addedAt = DockGroupTimestamp.normalized(try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date())
    }
}

// MARK: - 分组

/// 一个 Dock 分组。
public struct DockGroup: Codable, Identifiable, Equatable, Sendable {
    /// 分组 ID。用于派生 Helper 的 Bundle ID：`com.misswell.macpilot.dockgroup.<id>`。
    public var id: String
    /// 用户自定义名称。
    public var name: String
    /// 分组图标。
    public var icon: DockGroupIcon
    /// Grid / List。
    public var layout: DockGroupLayout
    /// 成员 App（顺序即展示顺序，支持拖拽排序）。
    public var apps: [DockGroupApp]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        icon: DockGroupIcon = .default,
        layout: DockGroupLayout = .fallback,
        apps: [DockGroupApp] = [],
        createdAt: Date = DockGroupTimestamp.now(),
        updatedAt: Date = DockGroupTimestamp.now()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.layout = layout
        self.apps = apps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, layout, apps, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        icon = try container.decodeIfPresent(DockGroupIcon.self, forKey: .icon) ?? .default
        layout = try container.decodeIfPresent(DockGroupLayout.self, forKey: .layout) ?? .fallback
        apps = try container.decodeIfPresent([DockGroupApp].self, forKey: .apps) ?? []
        createdAt = DockGroupTimestamp.normalized(try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date())
        updatedAt = DockGroupTimestamp.normalized(try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date())
    }

    /// Helper 的 Bundle ID（需求第 5 节）。
    public var helperBundleIdentifier: String {
        DockGroupIdentifier.helperBundleIdentifier(forGroupID: id)
    }
}

// MARK: - Bundle ID 规则

/// 分组 ID 与 Helper Bundle ID / 文件名的唯一换算入口。
public enum DockGroupIdentifier {
    /// MacPilot 自己的 Bundle ID 前缀。Helper 使用 `com.misswell.macpilot.dockgroup.<id>`。
    public static let helperBundleIdentifierPrefix = "com.misswell.macpilot.dockgroup."

    /// 分组 ID 只允许小写字母、数字和 `-`，避免生成非法 Bundle ID 或路径穿越。
    public static func sanitizedID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var result = ""
        var lastWasDash = false
        for character in lowered {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "group" : String(result.prefix(64))
    }

    public static func helperBundleIdentifier(forGroupID id: String) -> String {
        helperBundleIdentifierPrefix + sanitizedID(id)
    }

    /// 从 Helper 的 Bundle ID 还原分组 ID；非本功能生成的 Bundle ID 返回 nil。
    public static func groupID(fromHelperBundleIdentifier identifier: String?) -> String? {
        guard let identifier, identifier.hasPrefix(helperBundleIdentifierPrefix) else { return nil }
        let groupID = String(identifier.dropFirst(helperBundleIdentifierPrefix.count))
        return groupID.isEmpty ? nil : groupID
    }

    /// 由名称推导唯一分组 ID（冲突时追加序号）。
    public static func makeID(fromName name: String, existing: [String]) -> String {
        let base = sanitizedID(name)
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}

// MARK: - groups.json

/// `~/Library/Application Support/MacPilot/DockGroups/groups.json` 的根结构。
///
/// 注意：这里刻意只保存分组数据（需求第 6 节），
/// 功能开关等 MacPilot 自身设置仍保存在 `config.json`。
public struct DockGroupsDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var groups: [DockGroup]

    public init(groups: [DockGroup] = [], version: Int = DockGroupsDocument.currentVersion) {
        self.version = version
        self.groups = groups
    }

    public static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version, groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = try container.decodeIfPresent([DockGroup].self, forKey: .groups) ?? []
    }

    /// Helper 只关心自己那一组。找不到时返回 nil，由调用方显示「未找到」而不是崩溃。
    public func group(withID id: String) -> DockGroup? {
        groups.first { $0.id == id }
    }
}

// MARK: - Grid 列数

/// Grid 布局的列数计算（需求第 8 节：默认 Grid，推荐 4 列，按数量自适应）。
public enum DockGroupGridMetrics {
    public static let maximumColumns = 4
    public static let minimumColumns = 2

    /// 尽量接近正方形，最多 4 列。
    public static func columns(forAppCount count: Int) -> Int {
        guard count > minimumColumns else { return max(1, count) }
        var columns = minimumColumns
        while columns < maximumColumns, columns * columns < count {
            columns += 1
        }
        return columns
    }
}
