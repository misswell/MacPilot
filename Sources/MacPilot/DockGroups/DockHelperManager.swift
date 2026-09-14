//
//  DockHelperManager.swift
//  MacPilot
//
//  需求第 5、14、15、24、25 节：
//  管理 MacPilot 自己生成的 Helper App（生成 / 刷新 / 删除 / 定位）。
//
//  所有写入都被限制在
//  ~/Library/Application Support/MacPilot/DockGroups/ 之内；
//  删除前会再次校验目标必须是自己生成的 Helper。
//  Helper 崩溃不影响 MacPilot；本管理器出错也不会触碰第三方 App。
//

import AppKit
import Foundation
import MacPilotDockGroupsCore

@MainActor
final class DockHelperManager {
    let rootDirectory: URL
    private let builder: DockHelperBundleBuilder

    init(
        rootDirectory: URL = DockGroupPaths.defaultRootDirectory(),
        helperExecutableURL: URL = DockHelperBundleBuilder.bundledHelperExecutableURL()
    ) {
        self.rootDirectory = rootDirectory
        builder = DockHelperBundleBuilder(
            rootDirectory: rootDirectory,
            helperExecutableURL: helperExecutableURL
        )
    }

    /// 随包的 Helper 可执行文件是否存在。开发期直接 `swift run MacPilot`
    /// 时它不存在，此时只提示、不报错。
    var isHelperExecutableAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: builder.helperExecutableURL.path)
    }

    var helperExecutableURL: URL { builder.helperExecutableURL }

    func helperAppURL(for group: DockGroup) -> URL {
        DockGroupPaths.helperAppURL(in: rootDirectory, groupName: group.name)
    }

    func helperExists(for group: DockGroup) -> Bool {
        FileManager.default.fileExists(atPath: helperAppURL(for: group).path)
    }

    /// 生成或刷新分组对应的 Helper App。
    @discardableResult
    func ensureHelper(for group: DockGroup, memberIconURLs: [URL]) -> URL? {
        guard isHelperExecutableAvailable else {
            DiagnosticLog.write("DockGroups", "Helper executable missing at \(builder.helperExecutableURL.path); skipping helper generation.")
            return nil
        }
        do {
            let version = AppVersionInfo.current()
            let url = try builder.build(
                group: group,
                memberIconURLs: memberIconURLs,
                version: version.version,
                build: version.build
            )
            DiagnosticLog.write("DockGroups", "Generated Dock helper for group \(group.id) at \(url.path)")
            return url
        } catch {
            DiagnosticLog.write("DockGroups", "Failed to generate Dock helper for \(group.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// 需求第 15 节：删除分组时只删除 MacPilot 自己创建的 Helper。
    func removeHelper(for group: DockGroup) {
        do {
            try builder.remove(group: group)
            DiagnosticLog.write("DockGroups", "Removed Dock helper for group \(group.id)")
        } catch {
            DiagnosticLog.write("DockGroups", "Refused to remove Dock helper for \(group.id): \(error.localizedDescription)")
        }
    }

    /// 重命名 / 删除后的收尾：清理管理目录里已不属于任何分组的 Helper。
    func removeStaleHelpers(keeping groups: [DockGroup]) {
        let names = Set(groups.map(\.name))
        builder.removeStaleHelperApps(keepingGroupNames: names)
    }

    /// 需求第 14 节：第一版不直接改 com.apple.dock.plist，
    /// 只提供「在访达中显示」并由用户拖入 Dock。
    func revealInFinder(for group: DockGroup) {
        let url = helperAppURL(for: group)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealGroupsFolder() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([rootDirectory])
    }
}
