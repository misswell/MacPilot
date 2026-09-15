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
        #expect(resolved.bundleIdentifier == reference.bundleIdentifier)
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
        // 浮层关掉之后 Helper 会待命一段时间，这两个键让系统能按内存压力 / 注销回收它。
        #expect(plist["NSSupportsAutomaticTermination"] as? Bool == true)
        #expect(plist["NSSupportsSuddenTermination"] as? Bool == true)

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

    // MARK: - 需求第 29 节：真实安装的第三方 App

    /// 需求第 29 节点名的应用清单。机器上装了就一定测，没装就跳过。
    ///
    /// 这里**只读**快照，绝不启动这些真实应用（启动路径由
    /// `launchingAnAppThroughTheWorkspaceDoesNotTouchItsBundle` 用仿真 App 覆盖），
    /// 以免测试打断正在使用电脑的人。
    struct KnownApp: Sendable, CustomStringConvertible {
        let name: String
        let paths: [String]

        var description: String { name }

        var installedURL: URL? {
            paths.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }

        static let specList: [KnownApp] = [
            KnownApp(name: "Visual Studio Code", paths: ["/Applications/Visual Studio Code.app"]),
            KnownApp(name: "Zed", paths: ["/Applications/Zed.app"]),
            KnownApp(name: "Xcode", paths: ["/Applications/Xcode.app"]),
            KnownApp(name: "IntelliJ IDEA", paths: [
                "/Applications/IntelliJ IDEA.app",
                "/Applications/IntelliJ IDEA CE.app",
                "/Applications/IntelliJ IDEA Ultimate.app"
            ]),
            KnownApp(name: "Google Chrome", paths: ["/Applications/Google Chrome.app"]),
            KnownApp(name: "Safari", paths: ["/Applications/Safari.app", "/System/Applications/Safari.app"]),
            KnownApp(name: "ChatGPT", paths: ["/Applications/ChatGPT.app"]),
            KnownApp(name: "Claude", paths: ["/Applications/Claude.app"]),
            KnownApp(name: "OrbStack", paths: ["/Applications/OrbStack.app"]),
            KnownApp(name: "DBeaver", paths: ["/Applications/DBeaver.app", "/Applications/DBeaverEE.app"])
        ]
    }

    /// 需求第 29、30 节：对真实装在机器上的第三方 App 跑完整的
    /// 「创建分组 → 解析 → 生成 Helper → 改名换图标排序 → 删除分组」流程，
    /// 结束后必须 `before == after`。
    @Test(arguments: KnownApp.specList)
    func installedThirdPartyAppSurvivesTheWholeDockGroupLifecycle(_ known: KnownApp) throws {
        // 没装的直接跳过（例如 CI 机器上只有系统自带的 Safari）。
        guard let app = known.installedURL else { return }

        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let before = ThirdPartyAppIntegrityReader.snapshot(of: app)
        // Safari 这类系统 App 也必须有可读的签名身份，否则说明快照本身失效了。
        #expect(before.codeSignature.cdHash != nil, "\(known.name) 的签名快照不可读")

        let model = workspace.makeModel()
        model.setEnabled(true)

        let group = model.createGroup(named: known.name)
        let reference = try #require(
            InstalledAppResolver.makeReference(from: app),
            "\(known.name) 的引用无法生成"
        )
        #expect(model.addApp(reference, to: group.id))
        #expect(model.helperExists(for: group))

        // 只读地解析它（含运行状态查询，走 NSWorkspace.runningApplications）。
        let resolved = model.resolvedApp(reference)
        #expect(resolved.isInstalled, "\(known.name) 应该能被解析到")
        #expect(resolved.bundleIdentifier == before.bundleIdentifier)
        #expect(resolved.version != nil, "\(known.name) 的版本应可读（用于图标缓存键）")
        _ = model.icon(for: resolved, size: 32)

        // 改名、换图标、改布局、重新生成 Helper。
        model.renameGroup(group.id, to: "\(known.name) Group")
        model.setIcon(DockGroupIcon(source: .symbol, value: "hammer"), for: group.id)
        model.setLayout(.list, for: group.id)
        model.regenerateAllHelpers()
        #expect(model.removeAllGroupData(), "清理应只涉及 MacPilot 自己的产物")

        let after = ThirdPartyAppIntegrityReader.snapshot(of: app)
        let differences = before.differences(from: after)
        #expect(
            differences.isEmpty,
            "\(known.name) 在 Dock Groups 全流程后被修改了：\(differences.joined(separator: ", "))"
        )
        // 需求第 29 节逐项确认。
        #expect(before.executableSHA256 == after.executableSHA256)
        #expect(before.infoPlistSHA256 == after.infoPlistSHA256)
        #expect(before.modificationDate == after.modificationDate)
        #expect(before.directoryEntryNames == after.directoryEntryNames)
        #expect(before.codeSignature == after.codeSignature)
        #expect(before.codeSignature.entitlements == after.codeSignature.entitlements)
    }

    /// 需求第 30 节新增项：Entitlements 与 Hardened Runtime 必须真的被读出来，
    /// 否则「Entitlements 没变」就是一句空话。
    @Test func snapshotReadsEntitlementsAndHardenedRuntimeFromRealApps() throws {
        // 本机装了带 Hardened Runtime 的应用时，快照必须能读出它的 entitlements。
        let hardened = KnownApp.specList.compactMap(\.installedURL).first { url in
            ThirdPartyAppIntegrityReader.snapshot(of: url).codeSignature.hasHardenedRuntime
        }
        guard let hardened else { return }

        let signature = ThirdPartyAppIntegrityReader.snapshot(of: hardened).codeSignature
        #expect(signature.isValid)
        #expect(!signature.entitlements.isEmpty, "\(hardened.lastPathComponent) 的 entitlements 应可读")
        #expect(signature.entitlements == signature.entitlements.sorted(), "entitlements 必须稳定排序")
    }

    /// 需求第 11、25 节：真正通过 `NSWorkspace` 启动一次 App，
    /// 启动行为本身也不得触碰对方 Bundle（用的是仿真 App，不动用户应用）。
    @Test func launchingAnAppThroughTheWorkspaceDoesNotTouchItsBundle() async throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let app = try workspace.makeThirdPartyApp(name: "OrbStack", bundleIdentifier: "com.example.orbstack")
        let reference = try #require(InstalledAppResolver.makeReference(from: app))
        let before = ThirdPartyAppIntegrityReader.snapshot(of: app)

        // 用公开的 Workspace API 启动（需求第 2 节）。
        try await AppLaunchService.open(reference)
        // 再调一次：已运行应走激活分支，不产生第二个实例、不改 Bundle。
        try await AppLaunchService.open(reference)

        let after = ThirdPartyAppIntegrityReader.snapshot(of: app)
        #expect(before.differences(from: after).isEmpty)
    }

    // MARK: - 需求第 29 节的其余状态

    /// 需求第 17 节：App 原地升级（版本号变化、签名不变）后，
    /// 引用按 bundleIdentifier 照样命中，不需要任何「重新 patch」。
    @Test func inPlaceAppUpdateIsPickedUpWithoutTouchingTheApp() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let app = try workspace.makeThirdPartyApp(name: "Zed", bundleIdentifier: "dev.zed.Zed")
        let reference = try #require(InstalledAppResolver.makeReference(from: app))
        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")
        model.addApp(reference, to: group.id)

        #expect(model.resolvedApp(reference).version == "1.0")
        #expect(model.resolvedApp(reference).bundleIdentifier == reference.bundleIdentifier)

        // 模拟应用自更新：改版本号与可执行文件内容（由「应用自己」改，不是 MacPilot）。
        try workspace.bumpVersion(of: app, to: "1.1")
        let after = ThirdPartyAppIntegrityReader.snapshot(of: app)
        #expect(after.codeSignature.isValid)

        let resolved = model.resolvedApp(reference)
        #expect(resolved.isInstalled)
        #expect(resolved.version == "1.1")
        #expect(resolved.bundleIdentifier == reference.bundleIdentifier)
    }

    /// 需求第 6、16、17 节：引用里保存的 path 已经失效（App 被移动过），
    /// 但 bundleIdentifier 仍然命中当前安装位置 —— 这正是「App 更新或移动后
    /// 不会轻易失效」的实现方式，靠的是 LaunchServices 而不是 MacPilot 去改 App。
    ///
    /// 这个用例刻意使用**真实安装**的 App（只读），因为只有真实 App 才会被
    /// LaunchServices 按 Bundle ID 登记过。机器上一个都没有就跳过。
    @Test func stalePathStillResolvesThroughBundleIdentifier() throws {
        guard let installed = KnownApp.specList.compactMap(\.installedURL).first,
              let identifier = Bundle(url: installed)?.bundleIdentifier
        else { return }

        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        // 引用里的路径故意写成已经不存在的旧位置。
        let staleReference = DockGroupApp(
            bundleIdentifier: identifier,
            path: "/Applications/Definitely-Moved-Away/App.app",
            name: "Moved"
        )
        #expect(!FileManager.default.fileExists(atPath: staleReference.path))

        let resolved = workspace.makeModel().resolvedApp(staleReference)
        #expect(resolved.isInstalled, "Bundle ID 仍然有效时应能解析到")
        #expect(resolved.bundleIdentifier == identifier)
        #expect(
            resolved.url?.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path,
            "应解析到 LaunchServices 登记的当前路径，而不是引用里那个失效的旧路径"
        )
    }

    /// 需求第 16 节：连 path 和 bundleIdentifier 都找不到时，安静地报「应用未找到」，
    /// 不崩溃、不自动替换成同名 App。
    @Test func unresolvedAppIsReportedAsMissingInsteadOfGuessed() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        // 夹具放在原路径，但引用指向别处且 Bundle ID 也没被登记过。
        let fixture = try workspace.makeThirdPartyApp(name: "Ghost", bundleIdentifier: "com.example.ghost")
        let reference = DockGroupApp(
            bundleIdentifier: TestAppWorkspace.uniqueIdentifier(for: "com.example.ghost"),
            path: fixture.appendingPathComponent("nope").path,
            name: "Ghost"
        )
        let resolved = workspace.makeModel().resolvedApp(reference)
        #expect(!resolved.isInstalled)
        #expect(resolved.displayName == "Ghost")
    }

    /// 需求第 29 节：Helper 被用户手动删除后，MacPilot 不能崩，
    /// 并且下一次需要时能重新生成。
    @Test func deletedHelperIsRegeneratedAndNeverBreaksMacPilot() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")
        #expect(model.helperExists(for: group))

        // 用户直接把 Helper App 拖进废纸篓。
        try FileManager.default.removeItem(at: model.helperAppURL(for: group))
        #expect(!model.helperExists(for: group))

        // MacPilot 侧一切照旧，并且可以重新生成。
        model.regenerateAllHelpers()
        #expect(model.helperExists(for: group))
    }

    /// 需求第 29 节：MacPilot 重启（重新加载配置）后分组与 Helper 都还在。
    @Test func restartingMacPilotReloadsGroupsFromDisk() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let app = try workspace.makeThirdPartyApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
        let reference = try #require(InstalledAppResolver.makeReference(from: app))

        do {
            let first = workspace.makeModel()
            first.setEnabled(true)
            let group = first.createGroup(named: "Dev")
            first.addApp(reference, to: group.id)
            first.renameGroup(group.id, to: "Development")
            first.shutdown()
        }

        // 新进程：从 groups.json 重新加载。
        let second = workspace.makeModel()
        second.applyLoadedSettings(DockGroupsSettings(isEnabled: true))
        let restored = try #require(second.groups.first)
        #expect(restored.name == "Development")
        #expect(restored.apps.count == 1)
        #expect(second.resolvedApp(restored.apps[0]).bundleIdentifier == reference.bundleIdentifier)
        second.shutdown()
    }

    /// 需求第 29 节：多个分组引用同一个 App，删除其中一个分组不影响另一个，
    /// 更不影响那个 App 本身。
    @Test func multipleGroupsCanShareOneAppAndDeleteIndependently() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let app = try workspace.makeThirdPartyApp(name: "Chrome", bundleIdentifier: "com.google.Chrome")
        let before = ThirdPartyAppIntegrityReader.snapshot(of: app)
        let reference = try #require(InstalledAppResolver.makeReference(from: app))

        let model = workspace.makeModel()
        model.setEnabled(true)
        let first = model.createGroup(named: "Browsers")
        let second = model.createGroup(named: "Work")
        #expect(model.addApp(reference, to: first.id))
        #expect(model.addApp(reference, to: second.id))

        model.deleteGroup(first.id)
        let survivor = try #require(model.groups.first)
        #expect(survivor.id == second.id)
        #expect(survivor.apps.count == 1)
        #expect(model.resolvedApp(survivor.apps[0]).isInstalled)
        #expect(!FileManager.default.fileExists(atPath: model.helperAppURL(for: first).path))
        #expect(before.differences(from: ThirdPartyAppIntegrityReader.snapshot(of: app)).isEmpty)
    }

    // MARK: - 需求第 12、26 节：图标缓存与清理

    /// 需求第 12 节：图标缓存只写 MacPilot 自己的缓存目录，
    /// 不写目标 App，且缓存被整个删掉也不影响目标 App。
    @Test func iconCacheOnlyWritesInsideTheCacheDirectory() async throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let app = try workspace.makeThirdPartyApp(name: "Calculator", bundleIdentifier: "com.apple.calculator")
        let before = ThirdPartyAppIntegrityReader.snapshot(of: app)

        let cacheDirectory = workspace.base.appendingPathComponent("Caches/DockGroups", isDirectory: true)
        let cache = DockGroupIconCache(directory: cacheDirectory)
        let key = DockGroupIconCacheKey(bundleIdentifier: "com.apple.calculator", version: "1.0", size: 32)
        let image = try #require(InstalledAppResolver.icon(for: app, size: 32))
        cache.store(image, for: key)

        let cached = try #require(cache.image(for: key))
        #expect(cached.size.width > 0)
        #expect(FileManager.default.fileExists(atPath: cache.cacheFileURL(for: key).path))

        // 缓存文件必须落在缓存目录里，且文件名不含路径分隔符。
        let fileName = cache.cacheFileURL(for: key).lastPathComponent
        #expect(!fileName.contains("/"))
        #expect(fileName.hasSuffix(".png"))
        #expect(cache.cacheFileURL(for: key).path.hasPrefix(cacheDirectory.path))

        // 删掉整个缓存：目标 App 一动不动。
        #expect(cache.removeAll())
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
        #expect(before.differences(from: ThirdPartyAppIntegrityReader.snapshot(of: app)).isEmpty)
    }

    /// 需求第 12 节：缓存键带 App 版本，App 升级后不会一直显示旧图标。
    @Test func iconCacheKeyChangesWithTheAppVersion() {
        let key1 = DockGroupIconCacheKey(bundleIdentifier: "dev.zed.Zed", version: "1.0", size: 64)
        let key2 = DockGroupIconCacheKey(bundleIdentifier: "dev.zed.Zed", version: "1.1", size: 64)
        let key3 = DockGroupIconCacheKey(bundleIdentifier: "dev.zed.Zed", version: "1.0", size: 128)
        #expect(key1 != key2)
        #expect(key1 != key3)
        #expect(key1.fileName != key2.fileName)
        #expect(key1.fileName.hasSuffix("@64.png"))
    }

    /// 需求第 26 节：清理只删除 MacPilot 自己的产物。
    @Test func cleanupRemovesOnlyMacPilotOwnedArtifacts() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let app = try workspace.makeThirdPartyApp(name: "VS Code", bundleIdentifier: "com.microsoft.VSCode")
        let before = ThirdPartyAppIntegrityReader.snapshot(of: app)
        let reference = try #require(InstalledAppResolver.makeReference(from: app))

        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")
        model.addApp(reference, to: group.id)
        #expect(model.helperExists(for: group))

        // 往管理目录里塞一个「不属于任何分组」的第三方 App，清理时必须原样保留。
        let foreign = try workspace.makeThirdPartyApp(
            name: "Foreign",
            bundleIdentifier: "com.example.foreign",
            insideManagedRoot: true
        )
        let foreignBefore = ThirdPartyAppIntegrityReader.snapshot(of: foreign)

        // 管理目录里还有归属不明的 .app，所以清理会如实返回 false
        // （宁可不报「已清空」，也绝不误删不是自己生成的东西）。
        #expect(!model.removeAllGroupData())

        // MacPilot 自己的东西都没了。
        #expect(model.groups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DockGroupPaths.groupsFile(in: workspace.root).path))
        #expect(!FileManager.default.fileExists(atPath: model.helperAppURL(for: group).path))
        // 归属无法确认的 .app 被保留，绝不误删。
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(foreignBefore.differences(from: ThirdPartyAppIntegrityReader.snapshot(of: foreign)).isEmpty)
        // 被管理的第三方 App 完全不受影响。
        #expect(before.differences(from: ThirdPartyAppIntegrityReader.snapshot(of: app)).isEmpty)
    }

    /// 需求第 22 节：功能关闭时，模型不做任何后台工作，也不会因为有分组就写盘。
    @Test func disabledFeatureNeverTouchesTheManagedDirectory() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }

        let model = workspace.makeModel()
        // 默认关闭（settings.isEnabled == false）。
        #expect(!model.settings.isEnabled)
        model.startMonitoring()
        model.regenerateAllHelpers()
        model.refreshRunningState()

        let entries = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
        #expect(entries.isEmpty, "关闭状态下管理目录必须保持为空，实际有：\(entries)")
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

    // MARK: - 深色模式

    /// 深色模式必须真的换掉底色，而不是继续沿用浅色版的白色背景。
    @Test func darkAppearancePaintsADarkBackground() throws {
        for icon in [
            DockGroupIcon(source: .composite, value: ""),
            DockGroupIcon(source: .emoji, value: "🛠")
        ] {
            let group = DockGroup(id: "dev", name: "Dev", icon: icon)

            let light = try #require(backgroundBrightness(
                of: DockGroupIconRenderer.image(for: group, size: 256, appearance: .light)
            ))
            let dark = try #require(backgroundBrightness(
                of: DockGroupIconRenderer.image(for: group, size: 256, appearance: .dark)
            ))

            #expect(light > 2.0, "\(icon.source) 浅色版底色不是浅色（亮度 \(light)）")
            #expect(dark < 1.2, "\(icon.source) 深色版底色不够深（亮度 \(dark)）")
        }
    }

    @Test func lightAndDarkIconsAreDifferentImages() throws {
        let group = DockGroup(id: "dev", name: "Dev", icon: DockGroupIcon(source: .composite, value: ""))
        let light = DockGroupIconRenderer.image(for: group, size: 256, appearance: .light)
        let dark = DockGroupIconRenderer.image(for: group, size: 256, appearance: .dark)

        #expect(light.tiffRepresentation != dark.tiffRepresentation)
    }

    /// Helper 的 Dock 图标必须固定浅色：`.icns` 没有外观变体，跟随生成时的外观
    /// 会让图标在用户切换外观后变得不一致。这里把 App 外观真的切成深色再生成，
    /// 产出的 `.icns` 仍必须逐字节等于浅色渲染。
    ///
    /// 注意 `NSApp?.appearance = …`：测试进程里 `NSApp` 起初是 nil，可选链赋值会
    /// 静默失效、用例随「深色渲染」一起通过——必须先用 `NSApplication.shared`
    /// 把 App 建出来，再用一个前置断言确认环境真的变深色了。
    @Test @MainActor func generatedHelperIconFollowsTheGroupsIconStyle() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        application.appearance = NSAppearance(named: .darkAqua)
        defer { application.appearance = previousAppearance }
        #expect(DockGroupIconAppearance.current() == .dark, "前提不成立：环境没有处于深色外观")

        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }
        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")

        // 默认「跟随系统」：深色系统下必须出深色版本
        // （以前这里固定出浅色，于是深色 Dock 上是一块刺眼的白）。
        model.regenerateAllHelpers()
        #expect(try helperIconData(model: model, groupID: group.id) == renderedIcon(for: group, appearance: .dark))
        #expect(try recordedAppearance(model: model, groupID: group.id) == "dark")

        // 固定浅色：即使系统处于深色也要出浅色版本。
        model.setIconStyle(.light, for: group.id)
        #expect(try helperIconData(model: model, groupID: group.id) == renderedIcon(for: group, appearance: .light))
        #expect(try recordedAppearance(model: model, groupID: group.id) == "light")
    }

    /// 「跟随系统」的分组，一旦系统外观变了就必须被判定为「需要重建」——
    /// `.icns` 没有外观变体，Dock 图标只能靠重建 Helper 跟上。
    @Test @MainActor func themeChangeMarksSystemStyleHelpersForRegeneration() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        application.appearance = NSAppearance(named: .aqua)
        defer { application.appearance = previousAppearance }

        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }
        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")
        model.regenerateAllHelpers()
        #expect(try recordedAppearance(model: model, groupID: group.id) == "light")
        #expect(!model.helperManager.helperNeedsRegeneration(for: try #require(model.groups.first)))

        // 系统切到深色：同一个分组（内容没变）现在必须重建。
        application.appearance = NSAppearance(named: .darkAqua)
        #expect(DockGroupIconAppearance.current() == .dark, "前提不成立：环境没有切到深色")
        #expect(model.helperManager.helperNeedsRegeneration(for: try #require(model.groups.first)))

        // 而「固定浅色」的分组不受系统外观影响。
        model.setIconStyle(.light, for: group.id)
        #expect(!model.helperManager.helperNeedsRegeneration(for: try #require(model.groups.first)))
    }

    /// 读 Helper 里生成的 `.icns`。
    private func helperIconData(model: DockGroupsModel, groupID: String) throws -> Data {
        try Data(contentsOf: helperIconURL(model: model, groupID: groupID))
    }

    private func helperIconURL(model: DockGroupsModel, groupID: String) -> URL {
        helperAppURL(model: model, groupID: groupID)
            .appendingPathComponent("Contents/Resources/\(DockHelperBundleBuilder.helperIconName)")
    }

    /// 读 Helper 的 Info.plist 里记录的那套绘制外观。
    private func recordedAppearance(model: DockGroupsModel, groupID: String) throws -> String? {
        let plistURL = helperAppURL(model: model, groupID: groupID)
            .appendingPathComponent("Contents/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL),
            format: nil
        ) as? [String: Any]
        return plist?["MacPilotDockGroupIconAppearance"] as? String
    }

    private func helperAppURL(model: DockGroupsModel, groupID: String) -> URL {
        let group = model.groups.first { $0.id == groupID }
        guard let group else { return URL(fileURLWithPath: "/dev/null") }
        return model.helperAppURL(for: group)
    }

    private func renderedIcon(for group: DockGroup, appearance: DockGroupIconAppearance) -> Data {
        ICNSWriter.data(from: DockGroupIconRenderer.image(
            for: group,
            size: 1024,
            memberIconURLs: [],
            appearance: appearance
        ))
    }

    /// 彩色符号图标在深色模式下要压暗，否则在暗色界面上过于刺眼；色相必须保持，
    /// 否则同一个分组在两种外观下会变成两种颜色。
    @Test func symbolIconDimsForDarkAppearance() throws {
        let group = DockGroup(id: "dev", name: "Dev", icon: DockGroupIcon(source: .symbol, value: "hammer"))
        let light = DockGroupIconRenderer.image(for: group, size: 256, appearance: .light)
        let dark = DockGroupIconRenderer.image(for: group, size: 256, appearance: .dark)

        let lightSample = try #require(backgroundColor(of: light, at: [0.3, 0.7]))
        let darkSample = try #require(backgroundColor(of: dark, at: [0.3, 0.7]))

        let lightBrightness = lightSample.redComponent + lightSample.greenComponent + lightSample.blueComponent
        let darkBrightness = darkSample.redComponent + darkSample.greenComponent + darkSample.blueComponent
        #expect(darkBrightness < lightBrightness)

        // 色相稳定（容差取一个色阶，取色空间转换会有极小误差）。
        #expect(abs(darkSample.hueComponent - lightSample.hueComponent) < 0.02)
    }

    /// 图标缓存必须按外观分开，否则切换深色模式会拿到上一次渲染的结果。
    @Test func iconCacheKeepsBothAppearances() throws {
        let workspace = try TestAppWorkspace()
        defer { workspace.cleanUp() }
        let model = workspace.makeModel()
        model.setEnabled(true)
        let group = model.createGroup(named: "Dev")

        let light = model.groupIcon(for: group, size: 72, appearance: .light)
        let dark = model.groupIcon(for: group, size: 72, appearance: .dark)
        #expect(light !== dark, "两种外观返回了同一个缓存对象")

        // 再取一次仍然各自命中自己的缓存，而不是互相覆盖。
        #expect(model.groupIcon(for: group, size: 72, appearance: .light) === light)
        #expect(model.groupIcon(for: group, size: 72, appearance: .dark) === dark)
    }

    /// 取几个偏离中心的采样点的平均亮度。中心是成员图标或 Emoji 字形，
    /// 这几个点落在只有底色的区域，因此亮度反映的就是背景色。
    private func backgroundBrightness(of image: NSImage) -> CGFloat? {
        var samples: [NSColor] = []
        for x in [0.25, 0.75] as [CGFloat] {
            for y in [0.25, 0.75] as [CGFloat] {
                if let color = backgroundColor(of: image, at: [x, y]) { samples.append(color) }
            }
        }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.redComponent + $1.greenComponent + $1.blueComponent } / CGFloat(samples.count)
    }

    private func backgroundColor(of image: NSImage, at point: [CGFloat]) -> NSColor? {
        guard point.count == 2,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        let x = Int(CGFloat(rep.pixelsWide) * point[0])
        // NSImage 原点在左下，位图行号自上而下，需要翻转 y。
        let y = rep.pixelsHigh - 1 - Int(CGFloat(rep.pixelsHigh) * point[1])
        guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
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

    /// 真实机器上很可能装着同 Bundle ID 的应用（`dev.zed.Zed`、`com.apple.dt.Xcode`…），
    /// 那样 LaunchServices 会把解析导向**真实**应用，仿真夹具就失去意义了。
    /// 因此夹具统一加唯一后缀，保证解析只会命中本测试自己的对象。
    static func uniqueIdentifier(for base: String) -> String {
        "\(base).fixture-\(UUID().uuidString.prefix(8))"
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
            "CFBundleIdentifier": Self.uniqueIdentifier(for: bundleIdentifier),
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

    /// 模拟「应用自己完成了一次原地升级」：只改版本号，签名保持有效。
    func bumpVersion(of app: URL, to version: String) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        var plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        plist["CFBundleShortVersionString"] = version
        plist["CFBundleVersion"] = version
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: plistURL)
        adHocSign(app)
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
