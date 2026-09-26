//
//  InstalledAppResolver.swift
//  MacPilotDockGroupsCore
//
//  需求第 2、6、9、11、16 节：
//  对第三方 App **只读**地读取 Bundle URL / Bundle Identifier / App Name /
//  App Icon / Version / Executable URL / Running State。
//
//  解析优先级（需求第 6 节）：
//  1. bundleIdentifier（App 更新或移动后仍能命中）
//  2. path（fallback）
//  找不到时返回 isInstalled == false，由 UI 显示「应用未找到」。
//

import AppKit
import Foundation

/// 一次解析的结果。只承载只读信息。
public struct ResolvedInstalledApp: Equatable, Sendable {
    /// 分组里保存的原始引用。
    public var reference: DockGroupApp
    /// 解析到的 Bundle URL；未找到时为 nil。
    public var url: URL?
    public var bundleIdentifier: String?
    public var name: String
    public var version: String?
    public var executableURL: URL?
    public var isRunning: Bool

    /// 需求第 16 节：App 被删除时不要报错崩溃，显示「应用未找到」。
    public var isInstalled: Bool { url != nil }

    public var displayName: String {
        name.isEmpty ? (reference.name.isEmpty ? (url?.deletingPathExtension().lastPathComponent ?? "") : reference.name) : name
    }

    public var runningStateSymbol: String { isRunning ? "●" : "○" }
}

public enum InstalledAppResolver {
    /// 需求第 9 节：用 NSWorkspace.runningApplications 按 bundleIdentifier 匹配。
    /// 绝不注入、读取内存或修改目标进程。
    public static func runningBundleIdentifiers(workspace: NSWorkspace = .shared) -> Set<String> {
        Set(workspace.runningApplications.compactMap { $0.bundleIdentifier })
    }

    public static func resolve(
        _ reference: DockGroupApp,
        runningBundleIdentifiers running: Set<String> = InstalledAppResolver.runningBundleIdentifiers(),
        workspace: NSWorkspace = .shared
    ) -> ResolvedInstalledApp {
        let url = resolveURL(reference, workspace: workspace)
        let bundle = url.flatMap { Bundle(url: $0) }
        let bundleIdentifier = bundle?.bundleIdentifier ?? reference.bundleIdentifier
        let name = bundle.map { displayName(of: $0, fallback: reference.name) } ?? reference.name
        // 需求第 12、17 节：版本号必须**当场读盘**，不能走 `Bundle` 的进程内缓存。
        // 否则第三方 App 原地升级后，同一次运行里的 MacPilot 会一直看到旧版本号，
        // 连带图标缓存的键也失效不了（旧图标会一直显示）。
        let version = url.flatMap { freshVersion(of: $0) }
        let isRunning = bundleIdentifier.map { running.contains($0) } ?? false

        return ResolvedInstalledApp(
            reference: reference,
            url: url,
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            executableURL: bundle?.executableURL,
            isRunning: isRunning
        )
    }

    /// 解析单个引用对应的 Bundle URL。
    public static func resolveURL(_ reference: DockGroupApp, workspace: NSWorkspace = .shared) -> URL? {
        if let bundleIdentifier = reference.bundleIdentifier, !bundleIdentifier.isEmpty,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let path = reference.path
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// 需求第 11 节：从拖入的 `.app` 生成只读引用，不复制、不移动、不修改。
    public static func makeReference(from url: URL) -> DockGroupApp? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let bundle = Bundle(url: url)
        let name = bundle.map { displayName(of: $0, fallback: url.deletingPathExtension().lastPathComponent) }
            ?? url.deletingPathExtension().lastPathComponent
        return DockGroupApp(
            bundleIdentifier: bundle?.bundleIdentifier,
            path: url.standardizedFileURL.path,
            name: name
        )
    }

    /// 需求第 12、17 节：当场读取 `Info.plist` 里的版本号（只读，不缓存）。
    ///
    /// `Bundle.object(forInfoDictionaryKey:)` 会把结果缓存在进程内，第三方 App
    /// 原地升级后同一次运行里读到的仍是旧值；这里直接解析 plist 避开该缓存。
    /// 读不到就返回 nil（不影响解析，只是图标缓存键退化为「未知版本」）。
    public static func freshVersion(of appURL: URL) -> String? {
        let infoPlist = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    // MARK: - App 图标（只读）

    /// 需求第 12 节：图标直接读取系统 App Icon，不写入目标 Resources。
    ///
    /// 返回的是**按目标尺寸重绘过的小图**，而不是系统给的多表示原图：
    /// 原图的 `size` 只是显示尺寸，底层仍是 1024×1024，任何一次
    /// `tiffRepresentation` / 上屏都会物化出几十 MB 的位图。
    public static func icon(for url: URL, size: CGFloat = 64) -> NSImage? {
        autoreleasepool {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return DockGroupIconThumbnail.image(
                from: icon,
                pointSize: size,
                pixelSize: DockGroupIconThumbnail.pixelSize(forPoints: size)
            )
        }
    }

    // MARK: - 安装目录扫描（供 App Picker 使用）

    /// 常用安装位置。只做浅层扫描（最多两层），避免遍历整个磁盘。
    public static func defaultSearchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// 扫描已安装的 App（只读）。
    public static func scanInstalledApps(
        in directories: [URL] = defaultSearchDirectories(),
        maximumDepth: Int = 2
    ) -> [DockGroupApp] {
        let fileManager = FileManager.default
        var results: [DockGroupApp] = []
        var seenPaths = Set<String>()

        for directory in directories {
            if Task.isCancelled { return [] }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled { return [] }
                let depth = url.pathComponents.count - directory.pathComponents.count
                if depth > maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let standardized = url.standardizedFileURL.path
                guard seenPaths.insert(standardized).inserted else { continue }
                if let reference = makeReference(from: url) {
                    results.append(reference)
                }
            }
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func displayName(of bundle: Bundle, fallback: String) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fallback
    }
}
