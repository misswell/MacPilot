//
//  DockGroupPaths.swift
//  MacPilotDockGroupsCore
//
//  需求第 5、6、12、15、23 节：所有写操作必须落在
//  ~/Library/Application Support/MacPilot/ 与 ~/Library/Caches/MacPilot/ 之内，
//  第三方 App 路径一律只读。
//
//  本文件是「写路径」的唯一裁判：任何 Service 在写入前必须调用
//  `ManagedPathGuard.requireManaged(_:)`，校验失败即抛错。
//

import Foundation

public enum DockGroupPaths {
    /// 分组数据与 Helper 的根目录。
    public static let managedDirectoryName = "DockGroups"

    /// 由 `~/Library/Application Support/MacPilot/DockGroups/` 提供。
    public static func defaultRootDirectory(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory, fileManager: fileManager)
            .appendingPathComponent("DockGroups", isDirectory: true)
    }

    /// 图标缓存放在 Caches 下（需求第 12 节：缓存删除不影响目标应用）。
    public static func defaultCacheDirectory(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent("MacPilot", isDirectory: true)
            .appendingPathComponent("DockGroups", isDirectory: true)
    }

    public static func applicationSupportDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("MacPilot", isDirectory: true)
    }

    /// 分组配置文件。
    public static func groupsFile(in root: URL) -> URL {
        root.appendingPathComponent("groups.json")
    }

    /// Helper App 路径：`<root>/<GroupName>.app`。
    public static func helperAppURL(in root: URL, groupName: String) -> URL {
        root.appendingPathComponent("\(sanitizedFileName(groupName)).app", isDirectory: true)
    }

    /// 用户自定义图标的存放位置（拷贝自用户选择的图片，原文件只读）。
    public static func customIconURL(in root: URL, fileName: String) -> URL {
        root.appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent(sanitizedFileName(fileName))
    }

    /// 文件名净化：去掉路径分隔符与 `..`，避免路径穿越。
    public static func sanitizedFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        let collapsed = replaced.replacingOccurrences(of: "..", with: "-")
        let result = collapsed.isEmpty ? "DockGroup" : collapsed
        return String(result.prefix(80))
    }
}

// MARK: - 写路径守卫

public enum ManagedPathError: Error, Equatable, LocalizedError {
    /// 目标不在 MacPilot 自己的管理目录内 —— 需求第 15 节要求直接拒绝执行。
    case outsideManagedRoot(path: String, root: String)
    /// 目标是符号链接，可能把写入引到管理目录之外。
    case symbolicLink(path: String)
    /// 目标是不可信根目录（如 `/`、用户主目录）。
    case refusesBroadRoot(path: String)

    public var errorDescription: String? {
        switch self {
        case let .outsideManagedRoot(path, root):
            return "Refusing to write outside MacPilot's managed directory. Path: \(path), managed root: \(root)"
        case let .symbolicLink(path):
            return "Refusing to write through a symbolic link: \(path)"
        case let .refusesBroadRoot(path):
            return "Refusing to treat a broad directory as a managed root: \(path)"
        }
    }
}

/// 需求第 15 节的落地：删除/写入 Helper 之前必须验证目标路径
/// **必须位于** `~/Library/Application Support/MacPilot/DockGroups/`。
public enum ManagedPathGuard {
    /// 校验并返回规范化后的 URL；校验失败抛错，调用方不得继续写入。
    public static func requireManaged(_ url: URL, root: URL) throws -> URL {
        let standardizedRoot = standardized(root)
        try validateRoot(standardizedRoot)

        let standardizedTarget = standardized(url)

        // 符号链接可以指向管理目录之外，直接拒绝而不是尝试解析。
        if isSymbolicLink(url) {
            throw ManagedPathError.symbolicLink(path: standardizedTarget.path)
        }

        let rootPath = standardizedRoot.path
        let targetPath = standardizedTarget.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw ManagedPathError.outsideManagedRoot(path: targetPath, root: rootPath)
        }
        return standardizedTarget
    }

    /// 只做判断，不抛错。
    public static func isManaged(_ url: URL, root: URL) -> Bool {
        (try? requireManaged(url, root: root)) != nil
    }

    /// 管理根目录本身不允许是 `/`、主目录或 `/Applications` 这类宽目录，
    /// 避免一次配置错误就让「只删自己创建的文件」退化成删除用户数据。
    private static func validateRoot(_ root: URL) throws {
        let path = root.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden: Set<String> = [
            "/", home, "/Applications", "/Users", "/Library",
            home + "/Applications", home + "/Library", home + "/Library/Application Support"
        ]
        if forbidden.contains(path) || path == "/Volumes" {
            throw ManagedPathError.refusesBroadRoot(path: path)
        }
    }

    private static func standardized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
