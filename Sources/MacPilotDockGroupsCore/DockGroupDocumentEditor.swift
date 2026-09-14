//
//  DockGroupDocumentEditor.swift
//  MacPilotDockGroupsCore
//
//  分组数据的纯编辑逻辑（增删改排序），与 UI 解耦以便单元测试。
//
//  需求第 11、15、16 节：编辑的永远只是「引用」，
//  不会触碰目标 App 本身；移除 App 只是从分组里去掉一条记录。
//

import Foundation

public enum DockGroupDocumentEditor {
    /// 添加 App 引用；同一 bundleIdentifier（或同一路径）只保留一条。
    @discardableResult
    public static func addApp(_ app: DockGroupApp, to groupID: String, in document: inout DockGroupsDocument) -> Bool {
        guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        if document.groups[index].apps.contains(where: { isSameApp($0, app) }) { return false }
        document.groups[index].apps.append(app)
        document.groups[index].updatedAt = DockGroupTimestamp.now()
        return true
    }

    /// 从分组移除 App（只删引用）。
    @discardableResult
    public static func removeApp(_ appID: UUID, from groupID: String, in document: inout DockGroupsDocument) -> Bool {
        guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let before = document.groups[index].apps.count
        document.groups[index].apps.removeAll { $0.id == appID }
        guard document.groups[index].apps.count != before else { return false }
        document.groups[index].updatedAt = DockGroupTimestamp.now()
        return true
    }

    /// 拖拽排序。
    @discardableResult
    public static func moveApps(in groupID: String, from source: IndexSet, to destination: Int, in document: inout DockGroupsDocument) -> Bool {
        guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        document.groups[index].apps.move(fromOffsets: source, toOffset: destination)
        document.groups[index].updatedAt = DockGroupTimestamp.now()
        return true
    }

    /// 重命名分组，并保证名称唯一（Helper App 文件名由名称推导）。
    @discardableResult
    public static func rename(groupID: String, to rawName: String, in document: inout DockGroupsDocument) -> String? {
        guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let unique = uniqueName(trimmed, excludingGroupID: groupID, in: document)
        document.groups[index].name = unique
        document.groups[index].updatedAt = DockGroupTimestamp.now()
        return unique
    }

    /// 新建分组。
    @discardableResult
    public static func createGroup(named rawName: String, in document: inout DockGroupsDocument) -> DockGroup {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Group" : trimmed
        let name = uniqueName(baseName, excludingGroupID: nil, in: document)
        let id = DockGroupIdentifier.makeID(fromName: name, existing: document.groups.map(\.id))
        let group = DockGroup(id: id, name: name)
        document.groups.append(group)
        return group
    }

    /// 删除分组。
    @discardableResult
    public static func removeGroup(_ groupID: String, in document: inout DockGroupsDocument) -> DockGroup? {
        guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let removed = document.groups.remove(at: index)
        return removed
    }

    /// 「重新定位」：把引用指向用户新选择的位置（只改引用，不动原 App）。
    @discardableResult
    public static func relocateApp(_ appID: UUID, in groupID: String, to newReference: DockGroupApp, in document: inout DockGroupsDocument) -> Bool {
        guard let groupIndex = document.groups.firstIndex(where: { $0.id == groupID }),
              let appIndex = document.groups[groupIndex].apps.firstIndex(where: { $0.id == appID }) else { return false }
        var updated = newReference
        updated.id = appID
        document.groups[groupIndex].apps[appIndex] = updated
        document.groups[groupIndex].updatedAt = DockGroupTimestamp.now()
        return true
    }

    public static func uniqueName(_ name: String, excludingGroupID: String?, in document: DockGroupsDocument) -> String {
        let taken = Set(document.groups.filter { $0.id != excludingGroupID }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var index = 2
        while taken.contains("\(name) \(index)".lowercased()) { index += 1 }
        return "\(name) \(index)"
    }

    /// 需求第 6 节：优先 bundleIdentifier 判断是否同一个 App，路径作为 fallback。
    public static func isSameApp(_ lhs: DockGroupApp, _ rhs: DockGroupApp) -> Bool {
        if let left = lhs.bundleIdentifier, let right = rhs.bundleIdentifier, !left.isEmpty, !right.isEmpty {
            return left == right
        }
        return lhs.path.standardizedPath == rhs.path.standardizedPath && !lhs.path.isEmpty
    }
}

extension String {
    /// 轻量路径标准化（用于比较，不访问磁盘）。
    var standardizedPath: String {
        URL(fileURLWithPath: self).standardizedFileURL.path
    }
}
