//
//  DockGroupStore.swift
//  MacPilotDockGroupsCore
//
//  需求第 6、15、23 节：
//  - 配置统一保存在 `~/Library/Application Support/MacPilot/DockGroups/groups.json`；
//  - Helper 只通过 groupId 读取自己那一组，不复制完整配置；
//  - 所有写操作先经过 ManagedPathGuard，绝不触碰第三方 App。
//
//  主程序与 Helper 共用本类型（主程序写、Helper 读）。
//

import Foundation

public enum DockGroupStoreError: Error, Equatable, LocalizedError {
    case managedPath(ManagedPathError)

    public var errorDescription: String? {
        switch self {
        case let .managedPath(error): error.localizedDescription
        }
    }
}

public enum DockGroupLoadResult: Equatable {
    case loaded(DockGroupsDocument)
    /// 首次使用：文件尚不存在。
    case missing
    /// 配置损坏：保留损坏文件，返回空文档，让 UI 提示用户而不是崩溃。
    case corrupt(message: String)

    public var document: DockGroupsDocument {
        switch self {
        case let .loaded(document): document
        case .missing, .corrupt: DockGroupsDocument()
        }
    }
}

public struct DockGroupStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL = DockGroupPaths.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    public var groupsFileURL: URL {
        DockGroupPaths.groupsFile(in: rootDirectory)
    }

    /// 读取但不抛错：区分「还没有配置」与「配置损坏」，便于 UI 展示（需求第 16 节的不崩溃原则）。
    public func load() -> DockGroupLoadResult {
        let url = groupsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder.dockGroups.decode(DockGroupsDocument.self, from: data)
            return .loaded(document)
        } catch {
            return .corrupt(message: error.localizedDescription)
        }
    }

    /// 写入分组配置。目标路径必须位于管理目录内，否则抛错。
    public func save(_ document: DockGroupsDocument) throws {
        let target = try ManagedPathGuard.requireManaged(groupsFileURL, root: rootDirectory)
        try TargetAppAccessPolicy.requireWrite(.write, at: target, managedRoot: rootDirectory)

        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 时间戳统一为秒级精度（见 DockGroupTimestamp），
        // 因此 ISO8601 也能精确往返，配置文件保持人类可读。
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: target, options: .atomic)
    }

    public func group(withID id: String) -> DockGroup? {
        load().document.group(withID: id)
    }

    /// 需求第 26 节：卸载 / 清理时删除 MacPilot 自己的分组配置。
    /// 目标路径同样必须先通过管理目录校验。
    ///
    /// 校验放在「文件是否存在」之前：管理根目录配错时必须如实返回失败，
    /// 而不是因为「本来就没东西可删」就报成功。
    @discardableResult
    public func removeGroupsFile() -> Bool {
        guard let target = try? ManagedPathGuard.requireManaged(groupsFileURL, root: rootDirectory) else {
            return false
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path) else { return true }
        do {
            try fileManager.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// 需求第 26 节：删除 MacPilot 自己拷贝进来的自定义分组图标。
    @discardableResult
    public func removeCustomIcons() -> Bool {
        let icons = rootDirectory.appendingPathComponent("Icons", isDirectory: true)
        guard let target = try? ManagedPathGuard.requireManaged(icons, root: rootDirectory) else {
            return false
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path) else { return true }
        do {
            try fileManager.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// Helper 侧只读入口：拿不到配置时返回 nil（由 Helper 显示未找到提示）。
    public static func group(forHelperBundleIdentifier identifier: String?, rootDirectory: URL = DockGroupPaths.defaultRootDirectory()) -> DockGroup? {
        guard let groupID = DockGroupIdentifier.groupID(fromHelperBundleIdentifier: identifier) else { return nil }
        return DockGroupStore(rootDirectory: rootDirectory).group(withID: groupID)
    }
}

extension JSONDecoder {
    /// groups.json 使用 ISO8601 时间戳（配合 DockGroupTimestamp 的秒级精度）。
    public static var dockGroups: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
