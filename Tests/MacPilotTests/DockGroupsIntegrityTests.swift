import AppKit
import Foundation
import MacPilotDockGroupsCore
import Testing
@testable import MacPilot

/// 需求第 29、30 节：第三方 App 完整性测试。
///
/// 这是本功能最重要的自动化测试：
/// 在「创建分组 → 启动/解析 App → 生成 Helper → 删除分组」前后，
/// 第三方 App 的目录元数据、主可执行文件 SHA-256、Info.plist SHA-256
/// 与代码签名身份必须完全一致（`before == after`）。
///
/// 测试用的是临时目录里的**仿真**第三方 App（结构与真实 .app 相同），
/// 因此测试本身也绝不会触碰 /Applications 下的真实应用。
@MainActor
struct ThirdPartyAppIntegrityTests {

    // MARK: - 需求第 30 节

    @Test func dockGroupLifecycleNeverModifiesThirdPartyApp() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let thirdPartyApp = try workspace.makeThirdPartyApp(name: "Zed", bundleIdentifier: "dev.zed.Zed")
        let before = ThirdPartyAppIntegrityReader.snapshot(of: thirdPartyApp)

        let model = workspace.makeModel()
        model.setEnabled(true)

        // 创建分组并加入第三方 App（需求第 11 节：只保存引用）。
        let group = model.createGroup(named: "Dev")
        let reference = try #require(InstalledAppResolver.makeReference(from: thirdPartyApp))
        #expect(model.addApp(reference, to: group.id))

        // 生成 Helper App（需求第 5 节）。
        #expect(model.helperExists(for: group))

        // 解析与运行状态查询（需求第 9 节）—— 只读。
        let resolved = model.resolvedApp(reference)
        #expect(resolved.isInstalled)
        #expect(resolved.bundleIdentifier == "dev.zed.Zed")
        #expect(resolved.name == "Zed")

        // 拖拽排序、重命名、换图标，最后删除分组。
        model.moveApps(in: group.id, from: IndexSet(integer: 0), to: 0)
        model.renameGroup(group.id, to: "Dev Tools")
        model.setIcon(DockGroupIcon(source: .symbol, value: "hammer"), for: group.id)
        model.deleteGroup(group.id)

        let after = ThirdPartyAppIntegrityReader.snapshot(of: thirdPartyApp)
        #expect(
            before.differences(from: after).isEmpty,
            "MacPilot modified a third-party app: \(before.differences(from: after))"
        )
        // 更直白地断言关键字段，便于失败时定位。
        #expect(before.executableSHA256 == after.executableSHA256)
        #expect(before.infoPlistSHA256 == after.infoPlistSHA256)
        #expect(before.modificationDate == after.modificationDate)
        #expect(before.codeSignature == after.codeSignature)
        #expect(before.directoryEntryNames == after.directoryEntryNames)
    }

    @Test func creatingAndDeletingManyGroupsLeavesTheAppUntouched() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let thirdPartyApp = try workspace.makeThirdPartyApp(name: "OrbStack", bundleIdentifier: "dev.kdrag0n.MacVirt")
        let before = ThirdPartyAppIntegrityReader.snapshot(of: thirdPartyApp)
        let reference = try #require(InstalledAppResolver.makeReference(from: thirdPartyApp))

        let model = workspace.makeModel()
        model.setEnabled(true)

        for index in 0..<3 {
            let group = model.createGroup(named: "Group \(index)")
            model.addApp(reference, to: group.id)
            model.removeApp(reference.id, from: group.id)
            model.deleteGroup(group.id)
        }
        // 多个分组引用同一个 App（需求第 29 节）。
        let first = model.createGroup(named: "A")
        let second = model.createGroup(named: "B")
        model.addApp(reference, to: first.id)
        model.addApp(reference, to: second.id)
        model.regenerateAllHelpers()

        let after = ThirdPartyAppIntegrityReader.snapshot(of: thirdPartyApp)
        #expect(before.differences(from: after).isEmpty)
    }

    // MARK: - Helper 只删除自己的产物

    @Test func removingAHelperRefusesToTouchATargetApp() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let thirdPartyApp = try workspace.makeThirdPartyApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
        let manager = workspace.makeHelperManager()

        // 需求第 15 节：目标不在 MacPilot 管理目录内 → 直接拒绝执行。
        #expect(throws: (any Error).self) {
            try manager.removeHelperAppForTesting(at: thirdPartyApp)
        }
        #expect(FileManager.default.fileExists(atPath: thirdPartyApp.path))

        let before = ThirdPartyAppIntegrityReader.snapshot(of: thirdPartyApp)
        manager.removeStaleHelpers(keeping: [])
        let after = ThirdPartyAppIntegrityReader.snapshot(of: thirdPartyApp)
        #expect(before.differences(from: after).isEmpty)
    }

    @Test func removingAHelperIgnoresForeignAppsInsideTheManagedFolder() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        // 即使数据库/配置异常把别人的 App 放进了管理目录，也不能删。
        let foreign = try workspace.makeThirdPartyApp(
            name: "NotOurs",
            bundleIdentifier: "com.example.notours",
            insideManagedRoot: true
        )
        let manager = workspace.makeHelperManager()
        try? manager.removeHelperAppForTesting(at: foreign)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: - 生成的 Helper 结构

    @Test func generatedHelperIsSelfContainedAndHasTheExpectedStructure() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")

        let helperApp = model.helperAppURL(for: group)
        let contents = helperApp.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/MacPilotDockHelper")
        let infoPlist = contents.appendingPathComponent("Info.plist")
        let icon = contents.appendingPathComponent("Resources/AppIcon.icns")

        #expect(FileManager.default.fileExists(atPath: helperApp.path))
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        #expect(FileManager.default.fileExists(atPath: infoPlist.path))
        #expect(FileManager.default.fileExists(atPath: icon.path))
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("PkgInfo").path))

        // 需求第 5、24 节：生成的 Helper 只包含 MacPilot 自己的东西，
        // 没有 Frameworks / PlugIns / 外部 dylib，也没有任何第三方内容。
        let contentsEntries = try FileManager.default.contentsOfDirectory(atPath: contents.path).sorted()
        #expect(contentsEntries == ["Info.plist", "MacOS", "PkgInfo", "Resources", "_CodeSignature"])
        let macOSEntries = try FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent("MacOS").path)
        #expect(macOSEntries == ["MacPilotDockHelper"])

        let plist = try #require(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoPlist),
                format: nil
            ) as? [String: Any]
        )
        #expect(plist["CFBundleIdentifier"] as? String == "com.misswell.macpilot.dockgroup.dev")
        #expect(plist["CFBundleName"] as? String == "Dev")
        #expect(plist["CFBundleExecutable"] as? String == "MacPilotDockHelper")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon.icns")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["MacPilotDockGroupID"] as? String == "dev")
        // 没有 Hardened Runtime 之外的沙盒 / 特殊权限要求。
        #expect(plist["LSUIElement"] as? Bool == false)

        // 图标必须是真实可解析的 ICNS。
        let iconData = try Data(contentsOf: icon)
        #expect(iconData.count > 1000)
        #expect(String(data: iconData.prefix(4), encoding: .ascii) == "icns")
    }

    /// 生成 Helper 的过程中，MacPilot 自己随包分发的可执行文件也必须零修改
    /// —— 与第三方 App 的完整性要求使用同一套度量方式。
    @Test func generatingHelpersNeverModifiesMacPilotsOwnBundledHelper() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let before = ThirdPartyAppIntegrityReader.snapshot(of: workspace.macPilotApp)
        let model = workspace.makeModel()
        model.setEnabled(true)

        for index in 0..<3 {
            let group = model.createGroup(named: "Group \(index)")
            model.addApp(
                DockGroupApp(bundleIdentifier: "com.example.app\(index)", path: "/Applications/App\(index).app", name: "App \(index)"),
                to: group.id
            )
            model.regenerateAllHelpers()
            model.deleteGroup(group.id)
        }

        let after = ThirdPartyAppIntegrityReader.snapshot(of: workspace.macPilotApp)
        #expect(before.differences(from: after).isEmpty)
    }

    @Test func generatedHelperIsSignedWithItsOwnGroupIdentifier() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")

        // 需求第 24 节：Helper 由 MacPilot 签名；签名身份必须与自己的
        // Bundle ID 一致，否则拷出去的 App 会因为签名与 Info.plist 不符而无法通过校验。
        let signature = ThirdPartyAppIntegrityReader.snapshot(of: model.helperAppURL(for: group)).codeSignature
        #expect(signature.identifier == "com.misswell.macpilot.dockgroup.dev")
        #expect(signature.isValid)
    }

    @Test func helperAppIsDeletedWithItsGroupOnly() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        model.setEnabled(true)
        let dev = model.createGroup(named: "Dev")
        let ai = model.createGroup(named: "AI")
        let devURL = model.helperAppURL(for: dev)
        let aiURL = model.helperAppURL(for: ai)
        #expect(FileManager.default.fileExists(atPath: devURL.path))
        #expect(FileManager.default.fileExists(atPath: aiURL.path))

        model.deleteGroup(dev.id)

        #expect(!FileManager.default.fileExists(atPath: devURL.path))
        #expect(FileManager.default.fileExists(atPath: aiURL.path))
        #expect(model.groups.map(\.name) == ["AI"])
    }

    @Test func staleHelperIsRemovedAfterRenaming() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")
        _ = group
        let oldURL = DockGroupPaths.helperAppURL(in: workspace.root, groupName: "Dev")

        model.renameGroup(group.id, to: "Dev Tools")
        let newURL = DockGroupPaths.helperAppURL(in: workspace.root, groupName: "Dev Tools")

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
    }

    // MARK: - 功能关闭 / App 消失

    @Test func disabledFeatureDoesNoWorkAndWritesNoHelpers() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        // 默认关闭（需求第 22 节）。
        #expect(!model.settings.isEnabled)
        model.activateFromConfiguration()
        let group = model.createGroup(named: "Dev")

        #expect(!model.helperExists(for: group))
        #expect(model.runningBundleIdentifiers.isEmpty)
    }

    @Test func missingAppIsReportedInsteadOfCrashing() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")
        let ghost = DockGroupApp(
            bundleIdentifier: "com.example.does-not-exist-\(UUID().uuidString)",
            path: "/Applications/DoesNotExist.app",
            name: "Ghost"
        )
        model.addApp(ghost, to: group.id)

        let resolved = model.resolvedApp(ghost)
        #expect(!resolved.isInstalled)
        #expect(resolved.displayName == "Ghost")

        // 重新定位到真实存在的 App 后应恢复。
        let thirdPartyApp = try workspace.makeThirdPartyApp(name: "Zed", bundleIdentifier: "dev.zed.Zed")
        #expect(model.relocateApp(ghost.id, in: group.id, to: thirdPartyApp))
        let relocated = try #require(model.groups.first(where: { $0.id == group.id })?.apps.first)
        #expect(model.resolvedApp(relocated).isInstalled)
    }

    // MARK: - 图标与 ICNS

    @Test func iconRendererProducesValidICNSForEverySource() throws {
        for icon in [
            DockGroupIcon(source: .composite, value: ""),
            DockGroupIcon(source: .symbol, value: "hammer"),
            DockGroupIcon(source: .emoji, value: "🛠")
        ] {
            let group = DockGroup(id: "dev", name: "Dev", icon: icon)
            let image = DockGroupIconRenderer.image(for: group, size: 256)
            let data = ICNSWriter.data(from: image)
            #expect(data.count > 1000, "\(icon.source) produced an empty icns")
            #expect(String(data: data.prefix(4), encoding: .ascii) == "icns")
        }
    }
}

// MARK: - 测试夹具

/// 一个隔离的临时工作区：管理目录、仿真第三方 App、可用的 Helper binary。
@MainActor
struct TestAppWorkspace {
    let base: URL
    let root: URL
    /// 仿真「MacPilot.app 内随包分发的 Helper 可执行文件」。
    let macPilotApp: URL
    let helperExecutable: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotDockGroups-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("MacPilot/DockGroups", isDirectory: true)
        macPilotApp = base.appendingPathComponent("MacPilot.app", isDirectory: true)
        helperExecutable = macPilotApp.appendingPathComponent("Contents/MacOS/MacPilotDockHelper")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 用系统 binary 当 Helper：只需要是一个可执行文件即可。
        try FileManager.default.createDirectory(
            at: helperExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: helperExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperExecutable.path)

        let plist: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleName": "MacPilot",
            "CFBundleExecutable": "MacPilotDockHelper",
            "CFBundleIdentifier": "com.misswell.macpilot",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: macPilotApp.appendingPathComponent("Contents/Info.plist"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }

    func makeHelperManager() -> DockHelperManager {
        DockHelperManager(rootDirectory: root, helperExecutableURL: helperExecutable)
    }

    func makeModel() -> DockGroupsModel {
        DockGroupsModel(
            store: DockGroupStore(rootDirectory: root),
            helperManager: makeHelperManager()
        )
    }

    /// 构造一个结构完整的仿真第三方 App（可选用 ad-hoc 签名，让签名身份也参与比对）。
    @discardableResult
    func makeThirdPartyApp(
        name: String,
        bundleIdentifier: String,
        insideManagedRoot: Bool = false
    ) throws -> URL {
        let container = insideManagedRoot
            ? root
            : base.appendingPathComponent("ThirdParty", isDirectory: true)
        let app = container.appendingPathComponent("\(name).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let plist: [String: Any] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "APPL",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))

        adHocSign(app)
        return app
    }

    /// 尽力做 ad-hoc 签名；失败也不影响测试（快照仍会比较 cdHash 是否存在）。
    private func adHocSign(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

private extension DockHelperManager {
    /// 测试用：直接调用内部删除逻辑（生产代码只通过 `removeHelper(for:)` 调用）。
    func removeHelperAppForTesting(at url: URL) throws {
        try DockHelperBundleBuilder(
            rootDirectory: rootDirectory,
            helperExecutableURL: helperExecutableURL
        ).removeHelperApp(at: url)
    }
}
