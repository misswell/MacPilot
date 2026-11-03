import Foundation
import Testing

@testable import MacPilot

/// 方案的第八节要求：不能只测「新版本能读旧配置」就宣称双向兼容。
/// 用户装了 Beta 再退回旧版是常事，旧版写回的那份文件之后还得能被新版本正确恢复。
/// 这里覆盖升级、降级、以及 ConfigStore 的分文件落盘。
@MainActor
struct QuickSearchPersistenceTests {
    private static let customized = QuickSearchSettings(
        isEnabled: true,
        hotkey: SmartCaptureShortcutBinding(keyCode: 300, modifiers: [.command, .control]),
        fileScope: .indexedDirectories,
        customDirectoryPaths: ["/Users/me/Documents/项目"],
        panelSize: QuickSearchPanelSize(width: 760, height: 520)
    )

    /// 一个「除快速搜索外都齐全」的配置，用来确认新节不会牵连同行的其它节。
    /// 其它节由真实类型编码而来：手写字典容易编出旧版本根本不写的形状，
    /// 那会让 section() 把它记成「读不出来」，测的就不是快速搜索了。
    private static var enabledClipboard: ClipboardSettings {
        var settings = ClipboardSettings()
        settings.isEnabled = true
        settings.storageLimit = 200
        return settings
    }

    private static func baseObject() throws -> [String: Any] {
        [
            "version": 25,
            "language": "system",
            "enabledFeatures": ["clipboard"],
            "rules": [],
            "isEnforcing": true,
            "clipboard": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.enabledClipboard))
        ]
    }

    private static func decode(_ object: [String: Any]) throws -> MacPilotModel.StoredConfiguration {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: data)
    }

    // MARK: 升级：旧版本写出的文件

    @Test func aFileWrittenBeforeQuickSearchExistedLoadsUnharmed() throws {
        let configuration = try Self.decode(try Self.baseObject())

        // 没有这一节 = 正常演化，用默认值，且不算「读不出来」。
        #expect(configuration.quickSearch == QuickSearchSettings())
        #expect(!configuration.quickSearch.isEnabled)
        #expect(configuration.unreadableSections.isEmpty)
        // 同份文件里的其它节一个都不许被牵动。
        #expect(configuration.clipboard.isEnabled)
        #expect(configuration.clipboard.storageLimit == 200)
        #expect(configuration.enabledFeatures == ["clipboard"])
    }

    @Test func aNewerSectionShapeThatAnOlderBuildCannotReadDegradesOnlyItself() throws {
        var object = try Self.baseObject()
        // 形状对不上：这一节回落到默认值并被登记，其它节照常。
        object["quickSearch"] = "这不是一个对象"

        let configuration = try Self.decode(object)

        #expect(configuration.quickSearch == QuickSearchSettings())
        #expect(configuration.unreadableSections == ["quickSearch"])
        #expect(configuration.clipboard.storageLimit == 200)
        #expect(configuration.enabledFeatures == ["clipboard"])
    }

    @Test func partialQuickSearchSectionsDecodeKeyByKey() throws {
        // 只写了两个字段：其余按默认值补齐，而不是整节作废。
        var object = try Self.baseObject()
        object["quickSearch"] = ["isEnabled": true, "fileScope": "entireMac"]

        let configuration = try Self.decode(object)

        #expect(configuration.quickSearch.isEnabled)
        #expect(configuration.quickSearch.fileScope == .entireMac)
        #expect(configuration.quickSearch.hotkey == QuickSearchSettings.defaultHotkey)
        #expect(configuration.quickSearch.customDirectoryPaths.isEmpty)
        #expect(configuration.unreadableSections.isEmpty)
    }

    @Test func anUnknownFieldInsideTheSectionIsIgnoredInsteadOfRejected() throws {
        var object = try Self.baseObject()
        object["quickSearch"] = [
            "isEnabled": true,
            "fileScope": "home",
            "someFutureField": 42
        ]

        let configuration = try Self.decode(object)

        #expect(configuration.quickSearch.isEnabled)
        #expect(configuration.unreadableSections.isEmpty)
    }

    /// 持久化枚举的未知值（装了更新的一版再降回来）只影响那一个选择，
    /// 绝不能抛错拖垮整节——那正是 v1.1.482-beta.5 清空全部配置的事故家族。
    /// matchScope 与 fileScope 都必须走「未知值 → 默认值、其余键保留」。
    @Test func unknownPersistedEnumValuesFallBackToDefaultsAndKeepTheRestOfTheSection() throws {
        var object = try Self.baseObject()
        var section = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Self.customized)
        ) as! [String: Any]
        section["fileScope"] = "someFutureScope"
        section["matchScope"] = "someFutureMatchScope"
        object["quickSearch"] = section

        let configuration = try Self.decode(object)

        #expect(configuration.quickSearch.fileScope == .home)
        #expect(configuration.quickSearch.matchScope == .nameAndPurpose)
        #expect(configuration.quickSearch.isEnabled)
        #expect(configuration.quickSearch.hotkey == Self.customized.hotkey)
        #expect(configuration.quickSearch.customDirectoryPaths == Self.customized.customDirectoryPaths)
        #expect(configuration.quickSearch.panelSize == Self.customized.panelSize)
        #expect(configuration.unreadableSections.isEmpty)
        // 其它节不受牵连。
        #expect(configuration.clipboard.storageLimit == 200)
    }

    // MARK: 降级：旧版本写回之后再升上来

    /// 旧版本不认识 `quickSearch` 这一节：它解码后重新编码时会把这一节丢掉，
    /// 但 `enabledFeatures` 是字符串数组，里面那个陌生功能名会被原样保留。
    /// 这里用「删掉该节」来模拟旧版写回的产物——真正的历史键集由
    /// ConfigurationSchemaContractTests 的只增不减契约守着。
    @Test func aDowngradeThenUpgradeKeepsTheFeatureSwitchedOn() throws {
        var object = try Self.baseObject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        object["quickSearch"] = try JSONSerialization.jsonObject(
            with: encoder.encode(Self.customized)
        )
        object["enabledFeatures"] = ["clipboard", "quickSearch"]

        let upgraded = try Self.decode(object)
        #expect(upgraded.quickSearch.fileScope == .indexedDirectories)

        // 模拟旧版写回：整节消失，功能名留在首页清单里。
        var byOldRelease = object
        byOldRelease.removeValue(forKey: "quickSearch")
        let afterDowngrade = try Self.decode(byOldRelease)
        // 直接采用解码结果会静默把功能关掉——这正是必须防的那件事。
        #expect(!afterDowngrade.quickSearch.isEnabled)
        #expect(afterDowngrade.enabledFeatures.contains("quickSearch"))
        #expect(afterDowngrade.unreadableSections.isEmpty)

        let aligned = afterDowngrade.aligningHomeControlledSwitches()
        #expect(aligned.quickSearch.isEnabled)
        // 校正只动首页已接管的功能级开关，不碰用户其余选择。
        #expect(aligned.clipboard == afterDowngrade.clipboard)
        #expect(aligned.enabledFeatures == afterDowngrade.enabledFeatures)
    }

    /// 校正只有一个方向：首页开着的功能，详情页不许是关着的。反过来它不会把
    /// 首页没勾选的功能强行打开，也不会替用户改别的字段——启不启动看的是
    /// `enabledFeatures` 这份首页清单，而不是详情页那面镜像开关。
    @Test func aligningHomeSwitchesNeverTurnsAnUnlistedFeatureOn() throws {
        var object = try Self.baseObject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        object["quickSearch"] = try JSONSerialization.jsonObject(with: encoder.encode(Self.customized))

        let decoded = try Self.decode(object)
        #expect(decoded.quickSearch.isEnabled)
        #expect(!decoded.enabledFeatures.contains("quickSearch"))

        let aligned = decoded.aligningHomeControlledSwitches()
        #expect(aligned.enabledFeatures == ["clipboard"])
        #expect(aligned.quickSearch == decoded.quickSearch)
        #expect(aligned.clipboard == decoded.clipboard)
        #expect(aligned.language == decoded.language)
    }

    @Test func encodingKeepsTheSectionRoundTripping() throws {
        var object = try Self.baseObject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        object["quickSearch"] = try JSONSerialization.jsonObject(with: encoder.encode(Self.customized))

        let decoded = try Self.decode(object)
        let reEncoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: reEncoded)

        #expect(again.quickSearch == Self.customized)
        #expect(again.quickSearch.customDirectoryPaths == ["/Users/me/Documents/项目"])
    }

    // MARK: 位置与收藏（新增字段）

    @Test func aSectionWrittenBeforePositionAndFavoritesExistedStillLoads() throws {
        var object = try Self.baseObject()
        object["quickSearch"] = ["isEnabled": true, "fileScope": "home"]

        let configuration = try Self.decode(object)

        // 新字段缺失 = 老配置，按「没拖过、没收藏」处理，不能登记成读不出来。
        #expect(configuration.quickSearch.panelPosition == nil)
        #expect(configuration.quickSearch.panelSize == nil)
        #expect(configuration.quickSearch.favorites.isEmpty)
        #expect(configuration.quickSearch.isEnabled)
        #expect(configuration.unreadableSections.isEmpty)
    }

    @Test func rememberedPositionAndFavoritesRoundTripThroughTheSection() throws {
        var settings = Self.customized
        settings.panelPosition = QuickSearchPanelPosition(x: 180, y: 640)
        settings.favorites = [
            QuickSearchFavorite(
                identity: "bid:com.test.a", path: "/Applications/A.app", kind: .application,
                title: "A", subtitle: "/Applications", bundleIdentifier: "com.test.a",
                addedAt: Date(timeIntervalSince1970: 1_700)
            ),
            QuickSearchFavorite(
                identity: "path:/Users/me/报告.pdf", path: "/Users/me/报告.pdf", kind: .file,
                title: "报告.pdf", subtitle: "/Users/me", addedAt: Date(timeIntervalSince1970: 1_800)
            ),
        ]
        var object = try Self.baseObject()
        object["quickSearch"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))

        let configuration = try Self.decode(object)

        #expect(configuration.quickSearch == settings)
        #expect(configuration.quickSearch.favorites.last?.kind == .file)
        #expect(configuration.unreadableSections.isEmpty)
    }

    @Test func aFavoriteThatOnlyKnowsItsPathStillRendersARow() throws {
        let data = Data(#"""
        {"favorites":[{"path":"/Users/me/报告.pdf"}]}
        """#.utf8)

        let settings = try JSONDecoder().decode(QuickSearchSettings.self, from: data)
        let favorite = try #require(settings.favorites.first)

        // 缺字段逐键回落：名称取自路径、类型当文件、归并键按路径重算。
        #expect(favorite.title == "报告.pdf")
        #expect(favorite.kind == .file)
        #expect(favorite.identity == "path:/Users/me/报告.pdf")
        #expect(settings.isEnabled == false)
    }

    // MARK: 分文件落盘

    @Test func theStoreSplitsQuickSearchSettingsAndItsHotkeyAcrossFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-search-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")

        var object = try Self.baseObject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        object["quickSearch"] = try JSONSerialization.jsonObject(with: encoder.encode(Self.customized))
        let data = try JSONSerialization.data(withJSONObject: object)

        let store = ConfigStore(url: url)
        store.markDirty(data)
        store.finish()

        let features = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: directory.appendingPathComponent("features.json")))
                as? [String: Any]
        )
        let shortcuts = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: directory.appendingPathComponent("shortcuts.json")))
                as? [String: Any]
        )
        let core = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )

        // 设置进 features.json，快捷键进 shortcuts.json，核心文件不再重复存。
        let persistedSection = try #require(features["quickSearch"] as? [String: Any])
        #expect(persistedSection["fileScope"] as? String == "indexedDirectories")
        #expect(persistedSection["customDirectoryPaths"] != nil)
        #expect((persistedSection["panelSize"] as? [String: Any])?["width"] as? Double == 760)
        #expect(persistedSection["hotkey"] == nil)
        let persistedShortcuts = try #require(shortcuts["quickSearch"] as? [String: Any])
        #expect((persistedShortcuts["hotkey"] as? [String: Any])?["keyCode"] as? Int == 300)
        #expect(core["quickSearch"] == nil)

        // 读回来必须还是完整的一份：分文件不能丢字段。
        let merged = try #require(store.load())
        let restored = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: merged)
        #expect(restored.quickSearch == Self.customized)
        #expect(restored.unreadableSections.isEmpty)
    }
}
