//
//  DockHelperBundleBuilder.swift
//  MacPilotDockGroupsCore
//
//  需求第 5、14、15、24 节：为每个分组生成一个 MacPilot 自己的 Helper App。
//
//  生成物（完全由 MacPilot 创建与管理）：
//
//    ~/Library/Application Support/MacPilot/DockGroups/Dev.app
//    └── Contents
//        ├── MacOS/MacPilotDockHelper   ← 复用同一个（已签名的）MacPilot binary
//        ├── Resources/AppIcon.icns     ← MacPilot 自己生成
//        └── Info.plist                 ← 只写 Group ID / Bundle ID / 图标 / 名称
//
//  绝不复制、移动、修改任何第三方 App。
//

import AppKit
import Foundation

public enum DockHelperBundleError: Error, Equatable, LocalizedError {
    case helperExecutableMissing(path: String)
    case cannotWriteBundle(path: String, message: String)
    case managedPath(ManagedPathError)

    public var errorDescription: String? {
        switch self {
        case let .helperExecutableMissing(path):
            return "MacPilot's Dock helper executable is missing: \(path)"
        case let .cannotWriteBundle(path, message):
            return "Could not write Dock helper bundle at \(path): \(message)"
        case let .managedPath(error):
            return error.localizedDescription
        }
    }
}

public struct DockHelperBundleBuilder {
    /// 生成的 Helper 里可执行文件的固定名称。
    public static let helperExecutableName = "MacPilotDockHelper"
    public static let helperIconName = "AppIcon.icns"

    public let rootDirectory: URL
    /// MacPilot.app 内随包分发的 Helper 可执行文件。
    public let helperExecutableURL: URL

    public init(
        rootDirectory: URL = DockGroupPaths.defaultRootDirectory(),
        helperExecutableURL: URL = DockHelperBundleBuilder.bundledHelperExecutableURL()
    ) {
        self.rootDirectory = rootDirectory
        self.helperExecutableURL = helperExecutableURL
    }

    /// MacPilot.app/Contents/MacOS/MacPilotDockHelper。
    public static func bundledHelperExecutableURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(helperExecutableName)
    }

    /// 生成（或刷新）分组对应的 Helper App，返回 App Bundle 的 URL。
    ///
    /// 标注 `@MainActor` 是因为图标渲染（AppKit 绘制）必须在主线程进行。
    @MainActor
    @discardableResult
    public func build(
        group: DockGroup,
        memberIconURLs: [URL],
        version: String,
        build: String
    ) throws -> URL {
        let appURL = try ManagedPathGuard.requireManaged(
            DockGroupPaths.helperAppURL(in: rootDirectory, groupName: group.name),
            root: rootDirectory
        )
        try TargetAppAccessPolicy.requireWrite(.write, at: appURL, managedRoot: rootDirectory)

        guard FileManager.default.isExecutableFile(atPath: helperExecutableURL.path) else {
            throw DockHelperBundleError.helperExecutableMissing(path: helperExecutableURL.path)
        }

        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        do {
            // 重建目录：只删除 MacPilot 自己管理目录内的旧 Helper。
            if FileManager.default.fileExists(atPath: appURL.path) {
                try FileManager.default.removeItem(at: appURL)
            }
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

            let executable = macOS.appendingPathComponent(Self.helperExecutableName)
            try FileManager.default.copyItem(at: helperExecutableURL, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let icon = DockGroupIconRenderer.image(for: group, size: 1024, memberIconURLs: memberIconURLs)
            let iconData = ICNSWriter.data(from: icon)
            try iconData.write(to: resources.appendingPathComponent(Self.helperIconName), options: .atomic)

            let info = Self.infoDictionary(group: group, version: version, build: build)
            let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

            try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"), options: .atomic)
        } catch let error as DockHelperBundleError {
            throw error
        } catch {
            throw DockHelperBundleError.cannotWriteBundle(path: appURL.path, message: error.localizedDescription)
        }

        // 签名放在最后：内容写完再签，签名才代表最终产物。
        _ = adHocSignGeneratedBundle(at: appURL)

        return appURL
    }

    /// 需求第 24 节：Helper 由 MacPilot 自己签名。
    ///
    /// 为什么必须单独签一次：MacPilot.app 内部的可执行文件是用 **MacPilot 自己的
    /// Bundle ID** 签名的（`codesign` 在 bundle 内会忽略 `--identifier`），
    /// 而生成出来的 `<Group>.app` 用的是 `com.misswell.macpilot.dockgroup.<id>`。
    /// 只拷贝二进制会让「签名里的标识符」和「Info.plist 里的 Bundle ID」对不上；
    /// 这里对**我们自己的**产物做一次 ad-hoc 重签，使它成为自洽、可通过
    /// `codesign --verify` 校验、在任何机器上都能正常启动的 App。
    ///
    /// 安全性：
    /// - 只调用 Apple 自带的 `/usr/bin/codesign`（不是第三方脚本，不经过 shell）；
    /// - 目标路径已经过 `ManagedPathGuard` + `TargetAppAccessPolicy` 校验，
    ///   永远不可能落在第三方 App 上（需求第 2、23 节）。
    @discardableResult
    private func adHocSignGeneratedBundle(at url: URL) -> Bool {
        guard TargetAppAccessPolicy.decide(.sign, for: url, managedRoot: rootDirectory) == .allowedManagedArtifact else {
            return false
        }

        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else { return false }

        let process = Process()
        process.executableURL = codesign
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // 签名失败不阻塞功能：App 仍然存在，未签名的本地 App 也能启动。
            return false
        }
    }

    /// 删除某个分组的 Helper App（需求第 15 节：只允许删除 MacPilot 自己创建的 App）。
    public func remove(group: DockGroup) throws {
        try removeHelperApp(at: DockGroupPaths.helperAppURL(in: rootDirectory, groupName: group.name))
    }

    /// 按路径删除 Helper；路径必须先通过管理目录校验。
    public func removeHelperApp(at url: URL) throws {
        let target = try ManagedPathGuard.requireManaged(url, root: rootDirectory)
        try TargetAppAccessPolicy.requireWrite(.replace, at: target, managedRoot: rootDirectory)

        guard target.pathExtension == "app" else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        guard isOurHelper(at: target) else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// 需求第 15 节的第二道保险：
    /// 只有带 Dock Group Bundle ID 的 App（或写了一半、没有 Info.plist 的残留）
    /// 才允许删除；任何无法确认归属的 .app 都原样保留。
    private func isOurHelper(at appURL: URL) -> Bool {
        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist) else { return true }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String else {
            return false
        }
        return DockGroupIdentifier.groupID(fromHelperBundleIdentifier: identifier) != nil
    }

    /// 清理管理目录内所有非当前分组的 Helper（重命名 / 删除后的收尾）。
    public func removeStaleHelperApps(keepingGroupNames names: Set<String>) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let keep = Set(names.map { DockGroupPaths.sanitizedFileName($0) })
        for entry in entries where entry.pathExtension == "app" {
            let baseName = entry.deletingPathExtension().lastPathComponent
            guard !keep.contains(baseName) else { continue }
            try? removeHelperApp(at: entry)
        }
    }

    // MARK: - Info.plist

    static func infoDictionary(group: DockGroup, version: String, build: String) -> [String: Any] {
        [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "APPL",
            "CFBundleName": group.name,
            "CFBundleDisplayName": group.name,
            "CFBundleExecutable": helperExecutableName,
            "CFBundleIdentifier": group.helperBundleIdentifier,
            "CFBundleIconFile": helperIconName,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            // 需求第 7 节：Helper 不打开普通主窗口，运行时自行切换为 accessory，
            // 因此这里刻意不写 LSUIElement，Dock 中仍可固定该 App 图标。
            "LSUIElement": false,
            "MacPilotDockGroupID": group.id
        ]
    }
}
