//
//  QuickSearchTests.swift
//  MacPilot
//
//  快速搜索的功能面：应用索引的构建与失效、名称/拼音/模糊匹配与排序、
//  Spotlight 查询计划与范围判断、双语提示文案。
//
//  这里不碰真实磁盘、不启动真实 Spotlight、不打开任何窗口——扫描与查询
//  都走注入的假实现，所以不会读到用户的应用和文件。
//

import AppKit
import Foundation
import Testing

@testable import MacPilot

// MARK: - 测试数据

private func makeEntry(_ name: String, at path: String, bundleID: String? = nil) -> QuickSearchApplicationEntry {
    QuickSearchApplicationEntry(url: URL(fileURLWithPath: path), name: name, bundleIdentifier: bundleID)
}

private func makeEntries(_ names: [String]) -> [QuickSearchApplicationEntry] {
    names.enumerated().map { index, name in
        makeEntry(name, at: "/Applications/App\(index).app", bundleID: "com.test.app\(index)")
    }
}

/// 用假扫描器构建的清单：`entries` 就是它「扫到」的内容。
@MainActor
private func inventory(
    scanning entries: [QuickSearchApplicationEntry],
    running: [QuickSearchRunningApplication] = []
) -> ApplicationInventory {
    ApplicationInventory(
        scanner: { _ in entries },
        runningApplicationsProvider: { running },
        baseDirectoriesProvider: { [URL(fileURLWithPath: "/Applications")] }
    )
}

/// 扫描返回值可切换的假扫描器。扫描闭包会在后台线程执行，所以状态用锁保护，
/// 而不是挂在主 Actor 上。
private final class SwitchableScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [QuickSearchApplicationEntry]
    private var storedCalls = 0

    init(_ entries: [QuickSearchApplicationEntry]) { storedEntries = entries }

    var entries: [QuickSearchApplicationEntry] {
        get { lock.withLock { storedEntries } }
        set { lock.withLock { storedEntries = newValue } }
    }

    var calls: Int { lock.withLock { storedCalls } }

    @MainActor
    func inventory(running: [QuickSearchRunningApplication] = []) -> ApplicationInventory {
        ApplicationInventory(
            scanner: { [weak self] _ in
                guard let self else { return [] }
                return self.lock.withLock {
                    self.storedCalls += 1
                    return self.storedEntries
                }
            },
            runningApplicationsProvider: { running },
            baseDirectoriesProvider: { [URL(fileURLWithPath: "/Applications")] }
        )
    }
}

/// 等一次扫描落地。用清单自己的完成回调，而不是墙钟轮询——同进程其它
/// @MainActor 套件会把主 Actor 队列堵上一两分钟。
@MainActor
private func settle(_ target: ApplicationInventory) async {
    await withCheckedContinuation { continuation in
        target.onIndexRebuilt = { continuation.resume() }
        target.rebuild()
    }
}

private func searched(
    _ query: String,
    among entries: [QuickSearchApplicationEntry],
    usage: (QuickSearchApplicationEntry) -> Int = { _ in 0 }
) -> [String] {
    ApplicationSearchProvider.search(query: query, entries: entries, usage: usage, includeTags: false, limit: 20).map(\.title)
}

// MARK: - 匹配与排序

struct QuickSearchMatchingTests {
    @Test func matchesLatinNamesCaseInsensitively() {
        let entries = makeEntries(["Safari", "Notes", "Music"])

        #expect(searched("saf", among: entries) == ["Safari"])
        #expect(searched("SAF", among: entries) == ["Safari"])
        #expect(searched("NOTE", among: entries) == ["Notes"])
    }

    @Test func matchesChineseNamesByTheirOwnCharacters() {
        let entries = [
            makeEntry("计算器", at: "/Applications/Calculator.app", bundleID: "com.test.calc"),
            makeEntry("文字编辑", at: "/Applications/Editor.app", bundleID: "com.test.edit"),
        ]

        #expect(searched("计算", among: entries) == ["计算器"])
        #expect(searched("编辑", among: entries) == ["文字编辑"])
    }

    @Test func indexesFullPinyinAndInitialsAtBuildTime() {
        let fields = QuickSearchSearchFields(title: "计算器")

        #expect(fields.pinyinFull == "jisuanqi")
        #expect(fields.pinyinInitials == "jsq")
    }

    @Test func matchesChineseNameByFullPinyin() {
        let entries = [makeEntry("计算器", at: "/Applications/Calculator.app")]

        #expect(searched("jisuan", among: entries) == ["计算器"])
        #expect(searched("jisuanqi", among: entries) == ["计算器"])
    }

    @Test func matchesChineseNameByPinyinInitials() {
        let entries = [
            makeEntry("计算器", at: "/Applications/Calculator.app", bundleID: "com.test.calc"),
            makeEntry("音乐", at: "/Applications/Music.app", bundleID: "com.test.music"),
        ]

        #expect(searched("jsq", among: entries) == ["计算器"])
    }

    @Test func ordersByMatchQualityFromExactToLooseFuzzy() {
        // 一个查询同时命中五个等级：完全 > 前缀 > 词首 > 包含 > 模糊。
        let entries = [
            makeEntry("Nootle East", at: "/Applications/f.app"),
            makeEntry("Subnote", at: "/Applications/e.app"),
            makeEntry("My Notes", at: "/Applications/a.app"),
            makeEntry("Notes", at: "/Applications/b.app"),
            makeEntry("Note", at: "/Applications/c.app"),
        ]

        #expect(
            searched("note", among: entries)
                == ["Note", "Notes", "My Notes", "Subnote", "Nootle East"]
        )
    }

    @Test func boundsFuzzyMatchingBySpanInsteadOfEditDistance() {
        // 模糊只看「字符按序出现且足够紧凑」：跨度超过查询长度的 3 倍就不算命中。
        // 这里不做全量编辑距离，候选也只在索引好的名称上比一次。
        let fields = QuickSearchSearchFields(title: "Superlonghostname")

        #expect(QuickSearchMatcher.match(query: "sln", fields: fields, includeTags: false)?.tier == .fuzzy)
        #expect(QuickSearchMatcher.match(query: "sh", fields: fields, includeTags: false) == nil)
        #expect(QuickSearchMatcher.match(query: "hostname", fields: fields, includeTags: false)?.tier == .contains)

        let entries = [makeEntry("Superlonghostname", at: "/Applications/a.app")]
        #expect(searched("sln", among: entries) == ["Superlonghostname"])
        #expect(searched("sh", among: entries).isEmpty)
    }

    @Test func ordersSameNameCandidatesByHowOftenTheyWereOpened() {
        let a = makeEntry("Mail", at: "/Applications/A.app", bundleID: "com.test.a")
        let b = makeEntry("Mail", at: "/Applications/B.app", bundleID: "com.test.b")
        let usage: (QuickSearchApplicationEntry) -> Int = { $0.path == "/Applications/B.app" ? 9 : 1 }

        #expect(searched("mail", among: [a, b], usage: usage) == ["Mail", "Mail"])
        let ranked = ApplicationSearchProvider.search(query: "mail", entries: [a, b], usage: usage, includeTags: false, limit: 20)
        #expect(ranked.first?.url.path == "/Applications/B.app")
    }

    @Test func aNameMatchOutranksAFrequentlyOpenedWeakerMatch() {
        // 名字命中是首要依据：搜 abc 时精确命中的 Abc 永远排在只是模糊对上的
        // AB Converter 前面，即使后者被反复打开。使用次数只在同一匹配等级内生效。
        let exact = makeEntry("Abc", at: "/Applications/Exact.app", bundleID: "com.test.exact")
        let opened = makeEntry("AB Converter", at: "/Applications/Open.app", bundleID: "com.test.open")
        let usage: (QuickSearchApplicationEntry) -> Int = { $0.path == "/Applications/Open.app" ? 40 : 0 }

        let ranked = ApplicationSearchProvider.search(query: "abc", entries: [exact, opened], usage: usage, includeTags: false, limit: 20)
        #expect(ranked.map(\.title) == ["Abc", "AB Converter"])

        // 同一等级内仍然按打开次数排：两个都精确命中时，常打开的在前。
        let frequent = makeEntry("Abc", at: "/Applications/Frequent.app", bundleID: "com.test.frequent")
        let sameTierUsage: (QuickSearchApplicationEntry) -> Int = { $0.path == "/Applications/Frequent.app" ? 40 : 0 }
        let sameTier = ApplicationSearchProvider.search(query: "abc", entries: [exact, frequent], usage: sameTierUsage, includeTags: false, limit: 20)
        #expect(sameTier.first?.url.path == "/Applications/Frequent.app")
    }

    @Test func openedFilesRiseToTheTopButOtherwiseKeepSpotlightsOrder() {
        // 文件行没有名称分级可比，Spotlight 回来的次序就是它的判断。
        // 这里只把「打开过」的提上来，次数相同的维持原序，谁也不去重排 Spotlight。
        let rows = ["/Users/me/a.pdf", "/Users/me/b.pdf", "/Users/me/c.pdf", "/Users/me/d.pdf"].map {
            QuickSearchResult(kind: .file, title: ($0 as NSString).lastPathComponent, subtitle: "/Users/me", url: URL(fileURLWithPath: $0))
        }
        let counts: [String: Int] = ["path:/Users/me/b.pdf": 3, "path:/Users/me/c.pdf": 3]

        let ordered = QuickSearchFrequencyOrder.ordered(rows) { counts[$0.favoriteIdentity] ?? 0 }
        #expect(ordered.map(\.title) == ["b.pdf", "c.pdf", "a.pdf", "d.pdf"])
    }

    @Test func breaksTiesByNameThenPathSoTheOrderIsStable() {
        let entries = [
            makeEntry("Zoom", at: "/Applications/Z/Z.app", bundleID: "com.test.z"),
            makeEntry("Zoom", at: "/Applications/Y/Z.app", bundleID: "com.test.z2"),
        ]

        let first = ApplicationSearchProvider.search(query: "zoom", entries: entries, includeTags: false, limit: 20).first
        let second = ApplicationSearchProvider.search(query: "zoom", entries: entries.reversed(), includeTags: false, limit: 20).first

        #expect(first?.url.path == second?.url.path)
        #expect(first?.url.path == "/Applications/Y/Z.app")
    }

    @Test func emptyQueryMatchesNothingSoThePanelShowsRecentsInstead() {
        let entries = makeEntries(["Safari", "Notes"])

        #expect(ApplicationSearchProvider.search(query: "  ", entries: entries, includeTags: false, limit: 20).isEmpty)
    }

    @Test func emptyQueryScreenFillsWithTheIndexAlphabeticallyUpToItsLimit() {
        let hidden = makeEntry(".Backup", at: "/Applications/.Backup.app")
        let entries = [hidden] + (0..<60).map {
            makeEntry(String(format: "App%02d", $0), at: "/Applications/A\($0).app")
        }

        let rows = QuickSearchFavorites.rows(
            favorites: [],
            entries: entries,
            recent: [],
            favoriteLimit: QuickSearchLimits.favoritesOnEmptyQuery,
            totalLimit: QuickSearchLimits.emptyQueryApplications
        )

        #expect(rows.count == 50)
        #expect(rows.map(\.title) == (0..<50).map { String(format: "App%02d", $0) })
        #expect(!rows.contains { $0.title == ".Backup" })
    }

    @Test func capsTheReturnedRows() {
        let entries = (0..<50).map { makeEntry("App\($0)", at: "/Applications/A\($0).app") }

        #expect(ApplicationSearchProvider.search(query: "app", entries: entries, includeTags: false, limit: 20).count == 20)
    }

    @MainActor
    @Test func recentApplicationsFollowLastUseAndDropUninstalledApps() throws {
        let installed = makeEntries(["Safari", "Notes"])
        let suiteName = "MacPilotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let usage = QuickSearchUsageStore(defaults: defaults)
        usage.recordLaunch(of: installed[1])
        usage.recordLaunch(of: installed[0])

        let recents = ApplicationSearchProvider.recentApplications(
            entries: installed,
            recentIdentities: usage.recentIdentities(limit: 8),
            limit: 8
        )
        // 最近使用：后记录的 Safari 在前。
        #expect(recents.map(\.title) == ["Safari", "Notes"])

        // 卸载后不再出现在最近里。
        let remaining = [installed[0]]
        #expect(ApplicationSearchProvider.recentApplications(
            entries: remaining,
            recentIdentities: usage.recentIdentities(limit: 8),
            limit: 8
        ).map(\.title) == ["Safari"])
    }
}

// MARK: - 应用清单

struct QuickSearchInventoryTests {
    @MainActor
    @Test func initializationDoesNotTouchTheDisk() {
        // 模型/清单构造阶段绝不扫盘：只有显式 rebuild 才起任务。
        let target = ApplicationInventory(
            scanner: { _ in Issue.record("scanner ran during init"); return [] },
            runningApplicationsProvider: { [] },
            baseDirectoriesProvider: { [] }
        )

        #expect(target.state == .empty)
        #expect(!target.isScanning)
        #expect(target.entryCount == 0)
    }

    @MainActor
    func deduplicatesRepeatedPathsButKeepsSameBundleIdentifierApart() async {
        let samePathTwice = makeEntry("Safari", at: "/Applications/Safari.app", bundleID: "com.test.safari")
        let otherCopy = makeEntry("Safari", at: "/Users/me/Downloads/Safari.app", bundleID: "com.test.safari")

        let target = inventory(scanning: [samePathTwice, samePathTwice, otherCopy])
        await settle(target)

        // 同一路径去重；同一个 Bundle ID 的两份真实安装不能合并（否则用户丢版本）。
        #expect(target.entryCount == 2)
        #expect(target.entries.map(\.path).sorted() == ["/Applications/Safari.app", "/Users/me/Downloads/Safari.app"])
        #expect(target.entries.allSatisfy { $0.bundleIdentifier == "com.test.safari" })
    }

    @MainActor
    func addsRunningAppsThatLiveOutsideTheScannedDirectories() async {
        let runningOutside = QuickSearchRunningApplication(
            url: URL(fileURLWithPath: "/Volumes/External/Tool.app"),
            bundleIdentifier: "com.test.tool",
            name: "Tool"
        )
        let target = ApplicationInventory(
            scanner: { _ in [] },
            runningApplicationsProvider: { [runningOutside] },
            baseDirectoriesProvider: { [URL(fileURLWithPath: "/Applications")] }
        )
        await settle(target)

        #expect(target.entries.map(\.path) == ["/Volumes/External/Tool.app"])
        #expect(target.isRunning(target.entries[0]))
    }

    @MainActor
    func keepsTheOldIndexWhenAScanComesBackEmpty() async {
        let scanner = SwitchableScanner(makeEntries(["Safari"]))
        let target = scanner.inventory()
        await settle(target)
        scanner.entries = []
        await settle(target)

        // 目录暂时读不到时保留索引，而不是清空成「没装任何应用」。
        #expect(target.entryCount == 1)
        #expect(target.lastFailure == .directoriesUnreadable)
        #expect(target.state == .ready)
        #expect(scanner.calls == 2)
    }

    @MainActor
    func invalidatesAnEntryWhenTheAppIsGone() async {
        let target = inventory(scanning: makeEntries(["Safari", "Notes"]))
        await settle(target)
        let id = "/Applications/App0.app"

        target.invalidate(entryID: id)

        #expect(target.entries.map(\.path) == ["/Applications/App1.app"])
        #expect(target.state == .stale)
        target.invalidate(entryID: id)
        #expect(target.entryCount == 1)
    }

    @MainActor
    func invalidatingTheLastEntryLeavesTheIndexEmptyRatherThanStale() async {
        let target = inventory(scanning: makeEntries(["Safari"]))
        await settle(target)
        target.invalidate(entryID: "/Applications/App0.app")

        #expect(target.state == .empty)
        #expect(target.isExpired)
    }

    @MainActor
    func customDirectoriesJoinTheScanListWithoutDuplicates() async {
        let target = inventory(scanning: [])
        target.extraDirectories = ["/Users/me/Tools", "/Users/me/Tools/", ""]

        #expect(target.searchDirectories().map(\.path) == ["/Applications", "/Users/me/Tools"])
    }

    @MainActor
    func changingCustomDirectoriesMarksAReadyIndexStale() async {
        let target = inventory(scanning: makeEntries(["Safari"]))
        await settle(target)
        #expect(target.state == .ready)

        target.extraDirectories = ["/Users/me/Tools"]

        #expect(target.state == .stale)
    }

    @MainActor
    func refreshAfterBuildCompletesOnlyWhenExpired() async {
        let target = inventory(scanning: makeEntries(["Safari"]))
        await settle(target)

        // 没过期：不重新扫盘。过期检查只在面板打开时发生，没有定时器。
        target.freshnessInterval = .greatestFiniteMagnitude
        target.refreshIfStale()
        #expect(!target.isScanning)

        target.freshnessInterval = 0
        target.refreshIfStale()
        #expect(target.isScanning)
        #expect(target.state == .building)
    }

    @MainActor
    func shutdownReleasesTheIndexSynchronously() async {
        let target = inventory(scanning: makeEntries(["Safari"]))
        await settle(target)

        target.shutdown()

        #expect(target.entryCount == 0)
        #expect(target.state == .empty)
        #expect(!target.isScanning)
        #expect(target.runningBundleIdentifiers.isEmpty)
    }
}

// MARK: - Spotlight 查询计划与范围

struct QuickSearchSpotlightPlanTests {
    @Test func searchesBothTheDisplayNameAndTheRealFileName() {
        let predicate = SpotlightQueryPlan.queryPredicate(matching: "pdf")

        #expect(predicate.evaluate(with: ["kMDItemDisplayName": "report.pdf", "kMDItemFSName": ""]))
        #expect(predicate.evaluate(with: ["kMDItemDisplayName": "", "kMDItemFSName": "annual report.pdf"]))
        #expect(!predicate.evaluate(with: ["kMDItemDisplayName": "notes.txt", "kMDItemFSName": "notes.txt"]))
    }

    @Test func treatsQuotedInputAsTextRatherThanAPredicateFragment() {
        // 注入尝试：把输入当成字面量，不能因此放宽匹配。
        let predicate = SpotlightQueryPlan.queryPredicate(matching: "\" or \"kMDItemDisplayName\" LIKE \"*")

        #expect(!predicate.evaluate(with: ["kMDItemDisplayName": "unrelated.txt", "kMDItemFSName": "unrelated.txt"]))
    }

    @Test func theProbePredicateOnlyAsksWhetherAnythingIsIndexed() {
        let predicate = SpotlightQueryPlan.anyIndexedItemPredicate()

        #expect(predicate.evaluate(with: ["kMDItemDisplayName": "anything", "kMDItemFSName": ""]))
    }

    @Test func carriesTheFieldsThePanelShowsAndNothingElse() {
        let file = QuickSearchFileHit(
            url: URL(fileURLWithPath: "/Users/me/Desktop/Report.PDF"),
            isFolder: false,
            contentTypeIdentifier: "com.adobe.pdf",
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let folder = QuickSearchFileHit(url: URL(fileURLWithPath: "/Users/me/Desktop/Projects"), isFolder: true)
        let fileResult = QuickSearchResult(file: file)
        let folderResult = QuickSearchResult(file: folder)

        #expect(fileResult.kind == .file)
        #expect(fileResult.title == "Report.PDF")
        #expect(fileResult.subtitle == "Desktop")
        #expect(fileResult.contentTypeIdentifier == "com.adobe.pdf")
        #expect(fileResult.modificationDate == Date(timeIntervalSince1970: 1_000))
        #expect(folderResult.kind == .folder)
        #expect(folderResult.isFolder)
        #expect(folderResult.bundleIdentifier == nil)
    }

    @Test func passesApplesOfficialScopeConstantsThroughUnchanged() {
        #expect(SpotlightScopeResolver.resolve(requested: [NSMetadataQueryUserHomeScope]).usableScopes
            == [NSMetadataQueryUserHomeScope])
        #expect(SpotlightScopeResolver.resolve(requested: [NSMetadataQueryIndexedLocalComputerScope]).usableScopes
            == [NSMetadataQueryIndexedLocalComputerScope])
    }

    @Test func reportsWhichSelectedDirectoriesAreNotIndexed() {
        let resolution = SpotlightScopeResolver.resolve(
            requested: ["/Users/me/Nope"],
            isUsableDirectory: { _ in false }
        )

        #expect(resolution == .unusable(.selectedScopeNotIndexed(["/Users/me/Nope"])))
    }

    @Test func distinguishesNoScopeFromAnUnindexedScope() {
        #expect(SpotlightScopeResolver.resolve(requested: [], isUsableDirectory: { _ in true })
            == .unusable(.noScopeSelected))
        #expect(SpotlightScopeResolver.resolve(requested: ["", "/"], isUsableDirectory: { _ in false })
            == .unusable(.selectedScopeNotIndexed(["/"])))
    }

    @Test func keepsTheUsableDirectoriesAndDropsTheMissingOnes() {
        let resolution = SpotlightScopeResolver.resolve(
            requested: ["/Users/me/Gone", "/Users/me/Here", "/Users/me/Here"],
            isUsableDirectory: { $0.hasPrefix("/Users/me/Here") }
        )

        #expect(resolution.usableScopes == ["/Users/me/Here"])
    }

    @MainActor
    @Test func mapsEachSettingToExactlyOneScopeSource() {
        let probe = SystemSpotlightScopeProbe()

        #expect(probe.scopes(for: QuickSearchSettings(fileScope: .home)) == [NSMetadataQueryUserHomeScope])
        #expect(probe.scopes(for: QuickSearchSettings(fileScope: .entireMac))
            == [NSMetadataQueryIndexedLocalComputerScope])
        #expect(probe.scopes(for: QuickSearchSettings(fileScope: .indexedDirectories, customDirectoryPaths: ["/Users/me/Documents"]))
            == ["/Users/me/Documents"])
        #expect(probe.scopes(for: QuickSearchSettings(fileScope: .indexedDirectories)).isEmpty)
    }

    @Test func explainsWhyFileResultsCannotBeConfirmedInBothLanguages() {
        for issue in [
            QuickSearchIndexIssue.spotlightDisabled,
            .selectedScopeNotIndexed(["/Users/me/Nope"]),
            .noScopeSelected,
            .queryUnavailable,
        ] {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let text = AppText.value(issue.messageKey, language: language)
                #expect(!text.isEmpty)
                #expect(text != issue.messageKey)
            }
        }
        // 「查不了」的提示必须把范围说出来，不能是一句「没有文件」。
        let chinese = AppText.value(
            QuickSearchIndexIssue.selectedScopeNotIndexed(["/Users/me/Nope"]).messageKey,
            language: .simplifiedChinese
        )
        #expect(chinese.contains("Spotlight"))
    }
}

private extension SpotlightScopeResolution {
    var usableScopes: [String] {
        switch self {
        case .usable(let scopes): return scopes
        case .unusable: return []
        }
    }
}

// MARK: - 图标重试

private final class LoadAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    @discardableResult
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// 图标服务会短暂失败：一次失败不该让那一行在整个进程生命周期里停在占位符。
@MainActor
struct QuickSearchIconLoaderTests {
    @Test func aFailedIconIsRetriedOnceThePanelReopens() async throws {
        let attempts = LoadAttempts()
        let png = try #require(Self.solidPNG())
        let loader = QuickSearchIconLoader(imageLoader: { _, _ in
            attempts.next() == 1 ? nil : png
        })
        defer { loader.stop() }
        let url = URL(fileURLWithPath: "/tmp/quick-search-retry-\(UUID().uuidString).png")

        // 第一次取图失败：这一行先落到占位符。
        #expect(loader.icon(for: url, pointSize: 24) == nil)
        await Self.waitUntil { loader.pendingRequestCount == 0 }
        // 失败被记住之后，同一次会话里不再重复请求。
        #expect(loader.icon(for: url, pointSize: 24) == nil)
        #expect(loader.pendingRequestCount == 0)

        // 再次呼出面板：失败记录被清掉，同一行重新取图并显示图标。
        loader.retryUnresolvedIcons()
        #expect(loader.icon(for: url, pointSize: 24) == nil)
        await Self.waitUntil { loader.icon(for: url, pointSize: 24) != nil }
        #expect(loader.icon(for: url, pointSize: 24) != nil)
    }

    /// 轮询到条件成立为止。这是等待异步状态落地，不是测墙钟预算，所以上限给得宽。
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func solidPNG() -> Data? {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - 图标落盘缓存

/// 图标只向系统要一次，之后读缓存目录里的小 PNG；应用升级或超过刷新周期后重建。
/// 全部用临时目录，绝不读写用户的真实缓存。
@MainActor
struct QuickSearchIconDiskCacheTests {
    private struct Sandbox {
        let root: URL
        let cacheDirectory: URL
        let appURL: URL
    }

    private static func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSearchIconCache-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let appURL = apps.appendingPathComponent("Sample.app")
        try Data("app bundle".utf8).write(to: appURL)
        return Sandbox(
            root: root,
            cacheDirectory: root.appendingPathComponent("Icons", isDirectory: true),
            appURL: appURL
        )
    }

    private static func png(_ color: NSColor) -> Data? {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aStoredIconIsReadBackWithoutAskingTheIconService() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let png = try #require(Self.png(.systemBlue))

        cache.store(png, for: sandbox.appURL, pointSize: 24)

        let entry = try #require(cache.entry(for: sandbox.appURL, pointSize: 24))
        #expect(entry.png == png)
        #expect(!entry.isStale)
    }

    /// 应用包被替换后修改时间变化，旧图标不能再命中。
    @Test func replacingTheAppInvalidatesItsCachedIcon() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let png = try #require(Self.png(.systemBlue))
        cache.store(png, for: sandbox.appURL, pointSize: 24)

        try Self.setModificationDate(Date().addingTimeInterval(60), of: sandbox.appURL)

        #expect(cache.entry(for: sandbox.appURL, pointSize: 24) == nil)
    }

    @Test func aFreshEntryBecomesStaleAfterTheRefreshInterval() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let png = try #require(Self.png(.systemBlue))
        cache.store(png, for: sandbox.appURL, pointSize: 24)
        try Self.setModificationDate(
            Date().addingTimeInterval(-QuickSearchIconDiskCache.refreshInterval - 60),
            of: cache.cacheFileURL(for: sandbox.appURL, pointSize: 24)
        )

        let entry = try #require(cache.entry(for: sandbox.appURL, pointSize: 24))
        #expect(entry.png == png)
        #expect(entry.isStale)
    }

    @Test func anOversizedCacheFileIsDiscarded() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let file = cache.cacheFileURL(for: sandbox.appURL, pointSize: 24)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: QuickSearchIconDiskCache.maximumEntryBytes + 1).write(to: file)

        #expect(cache.entry(for: sandbox.appURL, pointSize: 24) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func pruneRemovesOnlyEntriesPastRetention() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let png = try #require(Self.png(.systemBlue))
        cache.store(png, for: sandbox.appURL, pointSize: 24)
        let oldURL = sandbox.root.appendingPathComponent("Old.app")
        try Data("old app".utf8).write(to: oldURL)
        cache.store(png, for: oldURL, pointSize: 24)
        try Self.setModificationDate(
            Date().addingTimeInterval(-QuickSearchIconDiskCache.retentionInterval - 60),
            of: cache.cacheFileURL(for: oldURL, pointSize: 24)
        )

        #expect(cache.prune() == 1)
        #expect(cache.entry(for: sandbox.appURL, pointSize: 24) != nil)
        #expect(cache.entry(for: oldURL, pointSize: 24) == nil)
    }

    @Test func aCachedIconAppearsSynchronouslyWithoutCallingTheLoader() throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let png = try #require(Self.png(.systemBlue))
        cache.store(png, for: sandbox.appURL, pointSize: 24)
        let attempts = LoadAttempts()
        let loader = QuickSearchIconLoader(
            imageLoader: { _, _ in
                _ = attempts.next()
                return nil
            },
            diskCache: cache
        )
        defer { loader.stop() }

        let image = try #require(loader.icon(for: sandbox.appURL, pointSize: 24))
        #expect(image.size == NSSize(width: 24, height: 24))
        #expect(attempts.count == 0)
    }

    @Test func aStaleCachedIconShowsImmediatelyAndRefreshesInTheBackground() async throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let oldPNG = try #require(Self.png(.systemBlue))
        let newPNG = try #require(Self.png(.systemRed))
        cache.store(oldPNG, for: sandbox.appURL, pointSize: 24)
        try Self.setModificationDate(
            Date().addingTimeInterval(-QuickSearchIconDiskCache.refreshInterval - 60),
            of: cache.cacheFileURL(for: sandbox.appURL, pointSize: 24)
        )
        let attempts = LoadAttempts()
        let loader = QuickSearchIconLoader(
            imageLoader: { _, _ in attempts.next() == 1 ? newPNG : nil },
            diskCache: cache
        )
        defer { loader.stop() }

        #expect(loader.icon(for: sandbox.appURL, pointSize: 24) != nil)
        await Self.waitUntil { attempts.count == 1 && loader.pendingRequestCount == 0 }

        let entry = try #require(cache.entry(for: sandbox.appURL, pointSize: 24))
        #expect(entry.png == newPNG)
        #expect(!entry.isStale)
    }

    @Test func aLoadedIconIsWrittenThroughToDiskAndReusedByTheNextLoader() async throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let png = try #require(Self.png(.systemBlue))
        let firstAttempts = LoadAttempts()
        let first = QuickSearchIconLoader(
            imageLoader: { _, _ in firstAttempts.next(); return png },
            diskCache: cache
        )
        defer { first.stop() }

        #expect(first.icon(for: sandbox.appURL, pointSize: 24) == nil)
        await Self.waitUntil { first.icon(for: sandbox.appURL, pointSize: 24) != nil }
        #expect(firstAttempts.count == 1)
        let entry = try #require(cache.entry(for: sandbox.appURL, pointSize: 24))
        #expect(entry.png == png)

        let secondAttempts = LoadAttempts()
        let second = QuickSearchIconLoader(
            imageLoader: { _, _ in secondAttempts.next(); return nil },
            diskCache: cache
        )
        defer { second.stop() }
        #expect(second.icon(for: sandbox.appURL, pointSize: 24) != nil)
        #expect(secondAttempts.count == 0)
    }

    @Test func aCorruptCacheFileIsDiscardedAndReloaded() async throws {
        let sandbox = try Self.makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let cache = QuickSearchIconDiskCache(directory: sandbox.cacheDirectory)
        let corrupt = Data("not a png".utf8)
        cache.store(corrupt, for: sandbox.appURL, pointSize: 24)
        let png = try #require(Self.png(.systemBlue))
        let loader = QuickSearchIconLoader(
            imageLoader: { _, _ in png },
            diskCache: cache
        )
        defer { loader.stop() }

        #expect(loader.icon(for: sandbox.appURL, pointSize: 24) == nil)
        await Self.waitUntil { loader.icon(for: sandbox.appURL, pointSize: 24) != nil }
        let entry = try #require(cache.entry(for: sandbox.appURL, pointSize: 24))
        #expect(entry.png == png)
    }
}
