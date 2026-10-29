//
//  QuickSearchLifecycleTests.swift
//  MacPilot
//
//  快速搜索的生命周期与并发面：面板可见性 vs 功能运行状态、查询代次、
//  快捷键注册结果、开关与停止后的残留、Spotlight 查不了时的诚实提示、
//  输入法按键分流。
//
//  全部走注入替身：不启动用户的应用、不碰用户真实文件、不显示真实窗口，
//  也不向系统注入任何按键。
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import MacPilot

// MARK: - 等待工具

/// 主 Actor 之间互相让位，等到条件成立。
///
/// 不用墙钟轮询做断言：同进程其它 @MainActor 套件会把主 Actor 队列堵上一两分钟。
/// 这里先纯让位；`NSMetadataQuery` 的通知是按 `.main` 队列派发的，那种投递
/// 可能要等一拍 runloop，所以让位不够时再补极短的睡眠（总量上限仍是 100ms 量级）。
@MainActor
private func yieldUntil(
    _ condition: @MainActor () -> Bool,
    yieldTurns: Int = 200,
    sleepTurns: Int = 50
) async -> Bool {
    for _ in 0..<yieldTurns {
        if condition() { return true }
        await Task.yield()
    }
    if condition() { return true }
    for _ in 0..<sleepTurns {
        try? await Task.sleep(for: .milliseconds(2))
        if condition() { return true }
    }
    return condition()
}

/// 等到条件成立，并把这件事直接说成一条断言。
///
/// 通知是按 `.main` 队列投递的，测试里必须给主队列一拍；写成 helper 而不是
/// `#expect(await ...)`，失败信息才落在调用这一行。
@MainActor
private func expectEventually(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let settled = await yieldUntil(condition)
    #expect(settled, "等待的条件始终没有成立", sourceLocation: sourceLocation)
}

/// 逃逸闭包要写的地方：Swift 6 不允许在逃逸闭包中改动局部可变变量。
@MainActor
private final class OutcomeBox {
    private(set) var received: [(generation: Int, outcome: QuickSearchFileQueryOutcome)] = []
    var last: QuickSearchFileQueryOutcome? { received.last?.outcome }
    var count: Int { received.count }
    var isEmpty: Bool { received.isEmpty }
    func append(generation: Int, outcome: QuickSearchFileQueryOutcome) {
        received.append((generation, outcome))
    }
}

// MARK: - 替身

/// 记录「谁在什么时候发生了什么」，用来验证先后顺序而不是只看最终状态。
@MainActor
private final class Ledger {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func reset() { events = [] }
}

/// 应用清单的数据源。扫描闭包在后台线程执行，所以状态用锁保护。
private final class ScanState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [QuickSearchApplicationEntry] = []
    private var storedRunning: [QuickSearchRunningApplication] = []
    private var storedCalls = 0

    var entries: [QuickSearchApplicationEntry] {
        get { lock.withLock { storedEntries } }
        set { lock.withLock { storedEntries = newValue } }
    }
    var running: [QuickSearchRunningApplication] {
        get { lock.withLock { storedRunning } }
        set { lock.withLock { storedRunning = newValue } }
    }
    var calls: Int { lock.withLock { storedCalls } }

    func snapshot() -> [QuickSearchApplicationEntry] {
        lock.withLock {
            storedCalls += 1
            return storedEntries
        }
    }
}

@MainActor
private final class FakeLauncher: QuickSearchLaunching {
    private(set) var calls: [(url: URL, name: String)] = []
    var failure: QuickSearchFailure?
    var onLaunch: (() -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var expected = 0

    func open(applicationAt url: URL, name: String) async -> QuickSearchFailure? {
        calls.append((url, name))
        onLaunch?()
        if calls.count >= expected {
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }
        return failure
    }

    func wait(forCalls count: Int) async {
        expected = max(expected, count)
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class FakeFileOpener: QuickSearchFileOpening {
    var ledger: Ledger?
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    var failure: QuickSearchFailure?

    func open(_ url: URL) -> QuickSearchFailure? {
        ledger?.record("openFile")
        opened.append(url)
        return failure
    }

    func revealInFinder(_ url: URL) -> QuickSearchFailure? {
        ledger?.record("reveal")
        revealed.append(url)
        return failure
    }
}

@MainActor
private final class FakeAvailability: QuickSearchItemAvailability {
    /// nil 表示「一切都在」；给出集合时只有集合里的路径存在。
    var existingPaths: Set<String>?
    var ledger: Ledger?

    func exists(at url: URL) -> Bool {
        ledger?.record("exists")
        guard let existingPaths else { return true }
        return existingPaths.contains(url.standardizedFileURL.path)
    }
}

@MainActor
private final class FakeFileQuery: QuickSearchFileQuerying {
    struct Start {
        let generation: Int
        let request: QuickSearchFileQueryRequest
        let completion: @MainActor (Int, QuickSearchFileQueryOutcome) -> Void
    }

    private(set) var starts: [Start] = []
    private(set) var cancelCount = 0
    private(set) var isTerminated = true
    var observerCount = 0

    var hasActiveQuery: Bool { !isTerminated }
    var trackedObserverCount: Int { observerCount }
    var terms: [String] { starts.map(\.request.term) }
    var generations: [Int] { starts.map(\.generation) }

    func start(
        generation: Int,
        request: QuickSearchFileQueryRequest,
        completion: @escaping @MainActor (Int, QuickSearchFileQueryOutcome) -> Void
    ) {
        // 真实实现会先把上一个查询停干净，这里保持同样的语义。
        if !isTerminated { cancelCount += 1 }
        starts.append(Start(generation: generation, request: request, completion: completion))
        isTerminated = false
        observerCount = 2
    }

    func cancelActiveQuery() {
        guard !isTerminated else { return }
        cancelCount += 1
        isTerminated = true
        observerCount = 0
    }

    /// 用第 n 次查询的身份回调一个结果，模拟迟到或回流。
    func deliver(fromStart index: Int, _ outcome: QuickSearchFileQueryOutcome) {
        let start = starts[index]
        // 只有终态才算查询收摊：增量更新之后查询还在跑，关闭时必须能停到它。
        let isTerminating: Bool
        switch outcome {
        case .results(_, let isFinal, _): isTerminating = isFinal
        case .failed, .cancelled: isTerminating = true
        }
        if isTerminating {
            isTerminated = true
            observerCount = 0
        }
        start.completion(start.generation, outcome)
    }

    func deliverLatest(_ outcome: QuickSearchFileQueryOutcome) {
        deliver(fromStart: starts.count - 1, outcome)
    }
}

@MainActor
private final class FakeScopeProbe: SpotlightScopeProbing {
    var tokens: [String] = [NSMetadataQueryUserHomeScope]
    var resolution: SpotlightScopeResolution?

    func scopes(for settings: QuickSearchSettings) -> [String] { tokens }

    func resolve(requested: [String]) -> SpotlightScopeResolution {
        resolution ?? SpotlightScopeResolver.resolve(requested: requested, isUsableDirectory: { _ in true })
    }
}

@MainActor
private final class FakeEmptyResultProber: SpotlightEmptyResultProbing {
    var verdict: Bool?
    private(set) var probeCount = 0
    private(set) var cancelCount = 0
    private(set) var probedScopes: [[String]] = []
    var trackedObserverCount: Int { 0 }

    func probe(scopes: [String], completion: @escaping @MainActor (Bool?) -> Void) {
        probeCount += 1
        probedScopes.append(scopes)
        completion(verdict)
    }

    func cancelProbe() { cancelCount += 1 }
}

/// 假的 `NSMetadataQuery`：不接真实的元数据服务，由测试自己决定何时回流。
/// 「空结果到底是没索引还是没有文件」这条判断链只有换掉真查询才测得到。
private final class FakeMetadataQuery: NSMetadataQuery {
    var startShouldSucceed = true
    private(set) var stopCount = 0
    private(set) var disableUpdatesCount = 0
    private(set) var enableUpdatesCount = 0
    private var storedHits: [Any] = []

    override func start() -> Bool { startShouldSucceed }
    override func stop() { stopCount += 1 }
    override func disableUpdates() { disableUpdatesCount += 1 }
    override func enableUpdates() { enableUpdatesCount += 1 }
    override var results: [Any] { storedHits }
    override var resultCount: Int { storedHits.count }

    func load(hits: [QuickSearchFileHit]) {
        storedHits = hits.compactMap { FakeMetadataItem(hit: $0) }
    }

    func signalDidUpdate() {
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: self)
    }

    func signalFinishGathering() {
        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: self)
    }
}

/// 假的元数据条目：属性直接由测试给，不依赖任何真实文件的索引内容。
private final class FakeMetadataItem: NSMetadataItem {
    /// `NSMetadataItem(url:)` 只接受真实存在的路径，而测试里的命中都是假路径：
    /// 载体用一定存在的根目录，属性全部由下面这份字典回答。
    private let storedAttributes: [String: Any]

    init?(hit: QuickSearchFileHit) {
        var attributes: [String: Any] = [
            SpotlightQueryPlan.Attribute.path: hit.url.path,
            SpotlightQueryPlan.Attribute.filesystemName: hit.name,
            SpotlightQueryPlan.Attribute.displayName: hit.name,
            // 目录判定走 contentTypeTree；文件类型属性缺失时保持缺失，
            // 不能补一个假值，否则读回的属性就对不上账。
            SpotlightQueryPlan.Attribute.contentTypeTree: hit.isFolder
                ? ["public.folder", "public.directory"]
                : [hit.contentTypeIdentifier ?? "public.item"]
        ]
        if let contentTypeIdentifier = hit.contentTypeIdentifier {
            attributes[SpotlightQueryPlan.Attribute.contentType] = contentTypeIdentifier
        }
        if let modificationDate = hit.modificationDate {
            attributes[SpotlightQueryPlan.Attribute.contentModificationDate] = modificationDate
        }
        storedAttributes = attributes
        // 载体用根目录：假路径会让 `NSMetadataItem(url:)` 直接返回 nil，
        // 而查询侧读到的路径完全来自下面的属性表。
        super.init(url: URL(fileURLWithPath: "/"))
    }

    override func value(forAttribute attribute: String) -> Any? { storedAttributes[attribute] }
}

/// 不显示真实窗口的面板替身：记录同时在世的窗口数，泄漏在这里无处藏。
@MainActor
private final class PanelLedger {
    private(set) var created = 0
    private(set) var live = 0
    private(set) var peakLive = 0
    private(set) var closed = 0

    func born() {
        created += 1
        live += 1
        peakLive = max(peakLive, live)
    }

    func died() {
        live -= 1
        closed += 1
    }
}

@MainActor
private final class FakePanel: QuickSearchPanelPresenting {
    private let ledger: PanelLedger
    private let onClose: () -> Void
    private var hasClosed = false
    private(set) var isPresented = false
    private(set) var openCount = 0
    private(set) var placementCount = 0

    init(ledger: PanelLedger, onClose: @escaping () -> Void) {
        self.ledger = ledger
        self.onClose = onClose
        ledger.born()
    }

    func open() {
        isPresented = true
        openCount += 1
    }

    func applyPlacement() {
        placementCount += 1
    }

    func close() {
        // 真实窗口也允许重复 close；替身必须只记一次离场，否则计数会跑负。
        guard !hasClosed else { return }
        hasClosed = true
        isPresented = false
        ledger.died()
        onClose()
    }
}

/// 失败提示的替身：真窗口会在用户的桌面上闪一下，测试不该那样做。
@MainActor
private final class FakeNoticePanel: QuickSearchNoticePresenting {
    private(set) var presented: [String] = []
    private(set) var dismissCount = 0

    func present(_ text: String) { presented.append(text) }
    func dismiss() { dismissCount += 1 }
}

/// 手动放行的防抖时钟：断言只依赖「放行了没有」，不依赖墙钟。
@MainActor
private final class ManualDebounceClock {
    private var pending: [@MainActor () -> Void] = []
    private(set) var delays: [Duration] = []

    func schedule(_ delay: Duration, _ work: @escaping @MainActor () -> Void) {
        delays.append(delay)
        pending.append(work)
    }

    var pendingCount: Int { pending.count }

    /// 按登记顺序放行全部延时（过期的代次由模型自己判掉）。
    func fireAll() {
        let works = pending
        pending.removeAll()
        for work in works { work() }
    }
}

// MARK: - 装配

@MainActor
private final class Harness {
    let scan = ScanState()
    let panels = PanelLedger()
    let clock = ManualDebounceClock()
    let ledger = Ledger()
    let fileQuery = FakeFileQuery()
    let scopeProbe = FakeScopeProbe()
    let launcher = FakeLauncher()
    let fileOpener = FakeFileOpener()
    let availability = FakeAvailability()
    let notice = FakeNoticePanel()
    let inventory: ApplicationInventory
    let model: QuickSearchModel
    let suiteName: String
    private(set) var lastPanel: FakePanel?

    init(
        enabled: Bool = true,
        existingPaths: Set<String>? = nil,
        hotkey: SmartCaptureShortcutBinding = Harness.quietHotkey,
        hotKeyCenter: QuickSearchHotKeyCenter? = nil
    ) {
        suiteName = "MacPilotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        inventory = ApplicationInventory(
            scanner: { [scan] _ in scan.snapshot() },
            runningApplicationsProvider: { [scan] in scan.running },
            baseDirectoriesProvider: { [URL(fileURLWithPath: "/Applications")] }
        )
        model = QuickSearchModel(
            inventory: inventory,
            icons: QuickSearchIconLoader(imageLoader: { _, _ in nil }),
            usage: QuickSearchUsageStore(defaults: defaults, limit: 10),
            fileQuery: fileQuery,
            scopeProbe: scopeProbe,
            launcher: launcher,
            fileOpener: fileOpener,
            availability: availability,
            hotKeyCenter: hotKeyCenter
        )
        fileOpener.ledger = ledger
        availability.ledger = ledger
        model.panelFactory = { [panels, weak self] onClose in
            let panel = FakePanel(ledger: panels, onClose: onClose)
            self?.lastPanel = panel
            return panel
        }
        model.noticePanelFactory = { [notice] in notice }
        model.fileDebounceScheduler = { [clock] delay, work in clock.schedule(delay, work) }
        model.language = .simplifiedChinese
        availability.existingPaths = existingPaths
        if enabled {
            model.applyLoadedSettings(
                QuickSearchSettings(isEnabled: true, hotkey: hotkey),
                activate: true
            )
        }
    }

    /// 启用并等索引落地。索引只来自注入的假扫描器，不读用户的应用目录。
    func enable(entries: [QuickSearchApplicationEntry] = []) async {
        scan.entries = entries
        if !entries.isEmpty { await settleIndex(inventory) }
    }

    /// 不用 Option+Space：那是用户自己的组合，测试不去抢注。
    static let safeHotkey = SmartCaptureShortcutBinding(
        keyCode: UInt16(kVK_F13),
        modifiers: [.command, .control, .option, .shift]
    )
    /// 装配默认用一个**根本不合法**的组合：校验在申请 Carbon 之前就把它挡下，
    /// 于是这些用例既不会碰用户机器上的快捷键，也不会和别的套件抢同一个注册位
    /// （Carbon 的注册是进程级的，并行时后注册的只会拿到「已存在」）。
    /// 真正要验注册行为的 QuickSearchHotKeyTests 显式传 `safeHotkey`。
    static let quietHotkey = SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])
}

/// 等一次扫描落地，同时**串上**已有的回调：模型自己也挂在这里，
/// 直接覆盖会让「索引落地后刷新面板」这条路径失去被测对象。
@MainActor
private func settleIndex(_ target: ApplicationInventory) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let existing = target.onIndexRebuilt
        var resumed = false
        target.onIndexRebuilt = {
            existing?()
            if !resumed {
                resumed = true
                continuation.resume()
            }
        }
        target.rebuild()
    }
}

private let sampleApps: [QuickSearchApplicationEntry] = [
    QuickSearchApplicationEntry(
        url: URL(fileURLWithPath: "/Applications/Safari.app"),
        name: "Safari",
        bundleIdentifier: "com.test.safari"
    ),
    QuickSearchApplicationEntry(
        url: URL(fileURLWithPath: "/Applications/计算器.app"),
        name: "计算器",
        bundleIdentifier: "com.test.calc"
    ),
]

private func fileHit(_ path: String, isFolder: Bool = false) -> QuickSearchFileHit {
    QuickSearchFileHit(url: URL(fileURLWithPath: path), isFolder: isFolder)
}

private func queryRequest(_ term: String, scopes: [String] = [NSMetadataQueryUserHomeScope]) -> QuickSearchFileQueryRequest {
    QuickSearchFileQueryRequest(term: term, scopes: scopes, resultLimit: 10)
}

@MainActor
private func makeSpotlightController(
    query fake: FakeMetadataQuery,
    prober: FakeEmptyResultProber,
    scopes: [String] = [NSMetadataQueryUserHomeScope]
) -> SpotlightFileSearchController {
    let probe = FakeScopeProbe()
    probe.tokens = scopes
    return SpotlightFileSearchController(scopeProbe: probe, emptyResultProber: prober) { fake }
}

// MARK: - 生命周期状态

@MainActor
struct QuickSearchLifecycleStateTests {
    @Test func nothingRunsUntilTheFeatureIsEnabled() {
        let harness = Harness(enabled: false)
        defer { harness.model.shutdown() }

        // 模型构造阶段：不扫盘、不建 UI、不起 Spotlight。
        #expect(harness.model.runtimeState == .disabled)
        #expect(harness.model.lifecycleState == .disabled)
        #expect(!harness.model.isPanelVisible)
        #expect(!harness.inventory.isScanning)
        #expect(harness.inventory.state == .empty)
        #expect(harness.scan.calls == 0)
        #expect(harness.fileQuery.starts.isEmpty)
        #expect(harness.panels.created == 0)
        #expect(harness.model.diagnosticObserverCount == 0)
        #expect(harness.model.diagnosticTaskCount == 0)
    }

    @Test func enablingThenDisablingReturnsEveryResourceItTook() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("safari")
        harness.clock.fireAll()
        #expect(harness.fileQuery.hasActiveQuery)

        harness.model.shutdown()

        #expect(harness.model.runtimeState == .disabled)
        #expect(!harness.model.isPanelVisible)
        #expect(!harness.fileQuery.hasActiveQuery)
        #expect(harness.fileQuery.observerCount == 0)
        #expect(harness.model.diagnosticObserverCount == 0)
        #expect(harness.model.diagnosticTaskCount == 0)
        #expect(harness.inventory.entryCount == 0)
        #expect(harness.panels.live == 0)
    }

    @Test func panelVisibilityIsTrackedSeparatelyFromTheRunningFeature() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)

        #expect(harness.model.runtimeState == .ready)
        #expect(harness.model.lifecycleState == .ready)

        harness.model.openPanel()
        #expect(harness.model.isPanelVisible)
        #expect(harness.model.lifecycleState == .presenting)
        #expect(harness.model.runtimeState == .ready)

        harness.model.updateQuery("safari")
        #expect(harness.model.lifecycleState == .searching)

        harness.model.closePanel()
        // 面板收起，功能仍在运行——这两件事不能混成一个状态。
        #expect(!harness.model.isPanelVisible)
        #expect(harness.model.runtimeState == .ready)
        #expect(harness.model.lifecycleState == .ready)
    }

    @Test func closingThePanelKeepsTheLightweightAppIndex() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("safari")
        #expect(harness.model.applicationResults.count == 1)

        harness.model.closePanel()

        #expect(harness.model.applicationResults.isEmpty)
        #expect(harness.inventory.hasIndex)
        #expect(harness.model.indexEntryCount == sampleApps.count)
    }

    @Test func summoningThePanelBuildsOnlyThePanel() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)

        harness.model.openPanel()

        // 呼出搜索只创建一个面板对象；主设置界面不由模型持有，也不会被顺带拉起。
        #expect(harness.panels.created == 1)
        #expect(harness.panels.live == 1)
    }

    @Test func disabledFeatureCannotOpenThePanel() {
        let harness = Harness(enabled: false)
        defer { harness.model.shutdown() }

        harness.model.openPanel()

        #expect(!harness.model.isPanelVisible)
        #expect(harness.panels.created == 0)
    }

    @Test func stoppingKeepsThePanelFromReappearingAndLeavesNoWindow() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()

        harness.model.shutdown()
        harness.model.openPanel()

        #expect(harness.model.runtimeState == .disabled)
        #expect(!harness.model.isPanelVisible)
        #expect(harness.panels.live == 0)
        // stop 之后重新呼出必须重建一个新面板，而不是复用已经收起的那个。
        #expect(harness.panels.created == 1)
    }
}

// MARK: - 查询代次与并发

@MainActor
struct QuickSearchQueryConcurrencyTests {
    @Test func rapidTypingStartsOnlyTheNewestQuery() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()

        harness.model.updateQuery("a")
        harness.model.updateQuery("ab")
        harness.model.updateQuery("abc")
        harness.clock.fireAll()

        // 三次输入里只有达到最小长度的两次进了防抖，放行后只有最新一代真的起查询。
        let expectedDelays: [Duration] = [.milliseconds(150), .milliseconds(150)]
        #expect(harness.clock.delays == expectedDelays)
        #expect(harness.fileQuery.starts.count == 1)
        #expect(harness.fileQuery.terms == ["abc"])
    }

    @Test func resultsFromAnOlderQueryCannotOverwriteTheNewestOnes() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()

        harness.model.updateQuery("report")
        harness.clock.fireAll()
        let olderGeneration = harness.fileQuery.generations[0]
        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/old-report.pdf")], isFinal: true, issue: nil))
        #expect(harness.model.fileResults.map(\.title) == ["old-report.pdf"])

        harness.model.updateQuery("report final")
        // Old rows disappear before the new debounce fires, and cannot be selected.
        #expect(harness.model.fileResults.isEmpty)
        #expect(!harness.model.results.contains { $0.title == "old-report.pdf" })
        #expect(!harness.fileQuery.hasActiveQuery)
        harness.fileQuery.deliver(fromStart: 0, .results(hits: [fileHit("/Users/me/Desktop/late.pdf")], isFinal: true, issue: nil))
        #expect(harness.model.fileResults.isEmpty)
        harness.clock.fireAll()
        let newerGeneration = harness.fileQuery.generations[1]
        #expect(newerGeneration != olderGeneration)

        // 旧查询迟到回流：必须被丢掉。
        harness.fileQuery.deliver(fromStart: 0, .results(hits: [fileHit("/Users/me/Desktop/stale.txt")], isFinal: true, issue: nil))
        #expect(harness.model.fileResults.map(\.title) != ["stale.txt"])

        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/report final.docx")], isFinal: true, issue: nil))
        #expect(harness.model.fileResults.map(\.title) == ["report final.docx"])
    }

    @Test func closingThePanelTerminatesTheQueryAndDropsItsResults() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("notes")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/notes.txt")], isFinal: false, issue: nil))
        #expect(!harness.model.fileResults.isEmpty)

        harness.model.closePanel()

        #expect(harness.fileQuery.cancelCount >= 1)
        #expect(!harness.fileQuery.hasActiveQuery)
        #expect(harness.model.diagnosticObserverCount == 0)
        #expect(harness.model.fileResults.isEmpty)
        #expect(harness.model.searchPhase == .idle)
        #expect(harness.model.query.isEmpty)

        // 已经飞出去的结果不能在面板关闭后把内容塞回来。
        harness.fileQuery.deliver(fromStart: 0, .results(hits: [fileHit("/Users/me/Desktop/late.txt")], isFinal: true, issue: nil))
        #expect(harness.model.fileResults.isEmpty)
    }

    @Test func emptyQueryCancelsTheFileSearchAndShowsRecentApplications() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("abc")
        harness.clock.fireAll()
        #expect(harness.fileQuery.hasActiveQuery)

        harness.model.updateQuery("   ")

        #expect(!harness.fileQuery.hasActiveQuery)
        #expect(harness.model.fileResults.isEmpty)
        #expect(harness.model.searchPhase == .idle)
        #expect(harness.clock.pendingCount == 0)
        let applications = harness.model.applicationResults.map(\.title)
        harness.fileQuery.deliver(fromStart: 0, .results(hits: [fileHit("/Users/me/Desktop/late.txt")], isFinal: true, issue: nil))
        #expect(harness.model.fileResults.isEmpty)
        #expect(harness.model.applicationResults.map(\.title) == applications)
    }

    @Test func singleCharacterQueriesNeverReachSpotlight() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()

        harness.model.updateQuery("计")
        harness.clock.fireAll()

        #expect(harness.fileQuery.starts.isEmpty)
        #expect(harness.model.fileResults.isEmpty)
        #expect(harness.model.searchPhase == .idle)
        // 应用搜索照常工作：短查询只是不查文件，不是整个搜索失效。
        #expect(harness.model.applicationResults.map(\.title) == ["计算器"])
    }

    @Test func incrementalResultsKeepComingUntilTheQueryIsFinal() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("doc")
        harness.clock.fireAll()

        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/a.doc")], isFinal: false, issue: nil))
        #expect(harness.model.searchPhase == .queryingSpotlight)
        harness.fileQuery.deliverLatest(.results(
            hits: [fileHit("/Users/me/Desktop/a.doc"), fileHit("/Users/me/Desktop/b.doc")],
            isFinal: true,
            issue: nil
        ))

        #expect(harness.model.fileResults.count == 2)
        #expect(harness.model.searchPhase == .idle)
        #expect(harness.model.fileSearchIssue == nil)
    }

    @Test func capsCombinedRowsWithApplicationsAheadOfFiles() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("app")
        harness.clock.fireAll()

        harness.fileQuery.deliverLatest(.results(
            hits: (0..<120).map { fileHit("/Users/me/Documents/f\($0).txt") },
            isFinal: true,
            issue: nil
        ))

        #expect(harness.model.fileResults.count == QuickSearchLimits.visibleResults)
        #expect(harness.model.results.count == QuickSearchLimits.visibleResults)
        #expect(harness.model.selectedRowIndex < harness.model.results.count)
    }

    @Test func aStoppedFeatureIgnoresScheduledFileSearches() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("abc")

        harness.model.shutdown()
        harness.clock.fireAll()

        // 面板已经关了，延时任务放行也不该再起新查询。
        #expect(harness.fileQuery.starts.isEmpty)
    }
}

// MARK: - Spotlight 查不了时必须说原因

@MainActor
struct QuickSearchSpotlightHonestyTests {
    @Test func emptyResultsWithNoIndexReportTheReasonInsteadOfClaimingNoFiles() async {
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        prober.verdict = false
        let controller = makeSpotlightController(query: fake, prober: prober)
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()

        await expectEventually { !box.isEmpty }
        #expect(box.received.first?.outcome
            == .results(hits: [], isFinal: true, issue: .spotlightDisabled))
        #expect(prober.probeCount == 1)
        #expect(controller.trackedObserverCount == 0)
        #expect(!controller.hasActiveQuery)
        // 「索引关了」和「确定没有文件」是两句话，提示文案也必须说清前者。
        let message = AppText.value(
            QuickSearchIndexIssue.spotlightDisabled.messageKey,
            language: .simplifiedChinese
        )
        #expect(message.contains("Spotlight"))
    }

    @Test func anIndexedScopeWithEmptyResultsIsAllowedToSayNoMatches() async {
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        prober.verdict = true
        let controller = makeSpotlightController(query: fake, prober: prober)
        let box = OutcomeBox()

        controller.start(generation: 3, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()

        await expectEventually { !box.isEmpty }
        #expect(box.last == .results(hits: [], isFinal: true, issue: nil))
    }

    @Test func anInconclusiveProbeNeverBlamesSpotlight() async {
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        prober.verdict = nil
        let controller = makeSpotlightController(query: fake, prober: prober)
        let box = OutcomeBox()

        controller.start(generation: 4, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()

        await expectEventually { !box.isEmpty }
        // 探测没结论时不下断言：宁可只说「没有匹配」，也不冤枉系统索引。
        #expect(box.last == .results(hits: [], isFinal: true, issue: nil))
    }

    @Test func theProbeAsksAboutTheSameScopesTheQueryUsed() async {
        let scopes = [NSMetadataQueryUserHomeScope, "/Users/me/Documents"]
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        prober.verdict = true
        let controller = makeSpotlightController(query: fake, prober: prober, scopes: scopes)
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("zzz", scopes: scopes)) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()

        await expectEventually { !box.isEmpty }
        #expect(prober.probedScopes == [scopes])
    }

    @Test func theVerdictIsProbedOnceAndReusedForTheSameScope() async {
        let scopes = [NSMetadataQueryUserHomeScope]
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        prober.verdict = false
        let controller = makeSpotlightController(query: fake, prober: prober, scopes: scopes)
        let box = OutcomeBox()
        // 第二条查询换了范围：结论不能跨范围复用。
        let otherScopes = ["/Users/me/Movies"]

        controller.start(generation: 1, request: queryRequest("zzz", scopes: scopes)) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()
        await expectEventually { box.count == 1 }

        controller.start(generation: 2, request: queryRequest("yyy", scopes: scopes)) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()
        await expectEventually { box.count == 2 }

        controller.start(generation: 3, request: queryRequest("xxx", scopes: otherScopes)) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()
        await expectEventually { box.count == 3 }

        #expect(prober.probeCount == 2)
        #expect(box.received.allSatisfy { $0.outcome
            == .results(hits: [], isFinal: true, issue: .spotlightDisabled) })
    }

    @Test func aQueryThatRefusesToStartSaysSoInsteadOfReturningEmptyResults() async {
        let fake = FakeMetadataQuery()
        fake.startShouldSucceed = false
        let prober = FakeEmptyResultProber()
        let controller = makeSpotlightController(query: fake, prober: prober)
        let box = OutcomeBox()

        controller.start(generation: 9, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }

        #expect(box.received.first?.generation == 9)
        #expect(box.last == .failed(.queryUnavailable))
        #expect(!controller.hasActiveQuery)
        #expect(controller.trackedObserverCount == 0)
        // 查询根本没跑起来，就不该再去探测「这片范围有没有索引」。
        #expect(prober.probeCount == 0)
    }

    @Test func hitsAreReadFromTheQueryAttributes() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let hits = [
            QuickSearchFileHit(
                url: URL(fileURLWithPath: "/Users/me/Desktop/报告.pdf"),
                isFolder: false,
                contentTypeIdentifier: "com.adobe.pdf",
                modificationDate: date
            ),
            QuickSearchFileHit(
                url: URL(fileURLWithPath: "/Users/me/Documents/项目"),
                isFolder: true
            ),
        ]
        let fake = FakeMetadataQuery()
        fake.load(hits: hits)
        let controller = makeSpotlightController(query: fake, prober: FakeEmptyResultProber())
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("报告")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()

        await expectEventually { !box.isEmpty }
        guard case .results(let returned, let isFinal, let issue)? = box.last else {
            Issue.record("期望 .results，实际是 \(String(describing: box.last))")
            return
        }
        #expect(isFinal)
        #expect(issue == nil)
        #expect(returned.map(\.name) == ["报告.pdf", "项目"])
        #expect(returned.map(\.isFolder) == [false, true])
        let first = try #require(returned.first)
        #expect(first.contentTypeIdentifier == "com.adobe.pdf")
        #expect(first.modificationDate == date)
        #expect(first.url.path == "/Users/me/Desktop/报告.pdf")
        // 目录由 contentTypeTree 判定，而不是靠扩展名猜。
        #expect(returned.last?.isFolder == true)
    }

    @Test func updatesThenFinishDeliverBothPassesAndReleaseTheQuery() async {
        let fake = FakeMetadataQuery()
        let controller = makeSpotlightController(query: fake, prober: FakeEmptyResultProber())
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("doc")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.load(hits: [fileHit("/Users/me/Desktop/a.doc")])
        fake.signalDidUpdate()
        await expectEventually { box.count == 1 }
        #expect(box.last == .results(hits: [fileHit("/Users/me/Desktop/a.doc")], isFinal: false, issue: nil))

        fake.load(hits: [fileHit("/Users/me/Desktop/a.doc"), fileHit("/Users/me/Desktop/b.doc")])
        fake.signalFinishGathering()
        await expectEventually { box.count == 2 }

        #expect(box.last == .results(
            hits: [fileHit("/Users/me/Desktop/a.doc"), fileHit("/Users/me/Desktop/b.doc")],
            isFinal: true,
            issue: nil
        ))
        #expect(fake.disableUpdatesCount == 2)
        #expect(fake.enableUpdatesCount == 1)
        #expect(fake.stopCount == 1)
        #expect(controller.trackedObserverCount == 0)
        #expect(!controller.hasActiveQuery)
    }

    @Test func aNewQueryTerminatesThePreviousOneAndItsObservers() async {
        let first = FakeMetadataQuery()
        let second = FakeMetadataQuery()
        var issued = 0
        let prober = FakeEmptyResultProber()
        let probe = FakeScopeProbe()
        let controller = SpotlightFileSearchController(scopeProbe: probe, emptyResultProber: prober) {
            issued += 1
            return issued == 1 ? first : second
        }
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("aaa")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        #expect(controller.trackedObserverCount == 2)
        #expect(first.stopCount == 0)

        controller.start(generation: 2, request: queryRequest("bbb")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }

        // 旧查询被停掉、观察者被摘干净，新查询才有位置。
        #expect(first.stopCount == 1)
        #expect(prober.cancelCount >= 1)
        #expect(controller.trackedObserverCount == 2)
        #expect(controller.hasActiveQuery)

        // 旧查询即使迟迟回流也不能再触达调用方。
        first.signalFinishGathering()
        await expectEventually { box.isEmpty }

        second.signalFinishGathering()
        await expectEventually { !box.isEmpty }
        #expect(box.received.first?.generation == 2)
    }

    @Test func closingThePanelShutsTheQueryDownAndDropsItsProbe() async {
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        let controller = makeSpotlightController(query: fake, prober: prober)
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        // 关闭后必须连探测一起收掉：只数增量，不假设「一次查询只 cancel 一次」，
        // 因为每次 start 也会先把上一次的探测清干净。
        let cancelsBeforeClose = prober.cancelCount
        controller.cancelActiveQuery()

        #expect(box.last == .cancelled)
        #expect(fake.stopCount == 1)
        #expect(prober.cancelCount == cancelsBeforeClose + 1)
        #expect(controller.trackedObserverCount == 0)
        #expect(!controller.hasActiveQuery)

        // 关闭后迟到的通知必须被忽略。
        fake.signalFinishGathering()
        await Task.yield()
        #expect(box.count == 1)
    }

    @Test func refusesToQueryAnUnusableScopeAndExplainsWhy() {
        let probe = FakeScopeProbe()
        probe.tokens = ["/Users/me/Gone"]
        probe.resolution = .unusable(.selectedScopeNotIndexed(["/Users/me/Gone"]))
        let controller = SpotlightFileSearchController(
            scopeProbe: probe,
            emptyResultProber: FakeEmptyResultProber()
        ) { FakeMetadataQuery() }
        let box = OutcomeBox()

        controller.start(generation: 7, request: queryRequest("abc", scopes: probe.tokens)) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }

        #expect(box.received.map(\.generation) == [7])
        #expect(box.last == .failed(.selectedScopeNotIndexed(["/Users/me/Gone"])))
        #expect(!controller.hasActiveQuery)
        #expect(controller.trackedObserverCount == 0)
    }

    @Test func anEmptyTermFinishesImmediatelyWithoutAQuery() {
        let fake = FakeMetadataQuery()
        let controller = makeSpotlightController(query: fake, prober: FakeEmptyResultProber())
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("")) { _, outcome in
            box.append(generation: 1, outcome: outcome)
        }

        #expect(box.received.map(\.generation) == [1])
        #expect(box.last == .results(hits: [], isFinal: true, issue: nil))
        #expect(!controller.hasActiveQuery)
        #expect(fake.stopCount == 0)
    }

    @Test func shutdownClearsCachedVerdictsAndActiveState() async {
        let fake = FakeMetadataQuery()
        let prober = FakeEmptyResultProber()
        prober.verdict = false
        let controller = makeSpotlightController(query: fake, prober: prober)
        let box = OutcomeBox()

        controller.start(generation: 1, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()
        await expectEventually { !box.isEmpty }

        controller.shutdown()
        controller.start(generation: 2, request: queryRequest("zzz")) { generation, outcome in
            box.append(generation: generation, outcome: outcome)
        }
        fake.signalFinishGathering()
        await expectEventually { box.count == 2 }

        // 停机后旧结论作废：重新启用要重新问一次。
        #expect(prober.probeCount == 2)
    }

    @Test func theModelShowsTheReasonInsteadOfAnEmptyFileList() async throws {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("invoice")
        harness.clock.fireAll()

        harness.fileQuery.deliverLatest(.failed(.spotlightDisabled))

        #expect(harness.model.fileSearchIssue == .spotlightDisabled)
        #expect(harness.model.fileResults.isEmpty)
        // 提示的是「查不了」的原因，而不是「确定没有文件」。
        let issue = try #require(harness.model.fileSearchIssue)
        let message = AppText.value(issue.messageKey, language: .simplifiedChinese)
        #expect(message.contains("Spotlight"))

        harness.model.updateQuery("invoice again")
        #expect(harness.model.fileSearchIssue == nil)
    }

    @Test func theModelKeepsAppResultsWhenTheFileQueryFails() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("safari")
        harness.clock.fireAll()

        harness.fileQuery.deliverLatest(.failed(.queryUnavailable))

        #expect(harness.model.fileSearchIssue == .queryUnavailable)
        #expect(harness.model.applicationResults.map(\.title) == ["Safari"])
        #expect(harness.model.searchPhase == .idle)
    }

    @Test func anUnusableScopeFromSettingsReachesThePanelAsAReason() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.scopeProbe.tokens = []
        harness.scopeProbe.resolution = .unusable(.noScopeSelected)
        harness.model.openPanel()
        harness.model.updateQuery("invoice")
        harness.clock.fireAll()

        #expect(harness.fileQuery.starts.isEmpty)
        #expect(harness.model.fileSearchIssue == .noScopeSelected)
        #expect(harness.model.searchPhase == .idle)
        // 两个语言都得说清「没选范围」，不能是一句空文案。
        for language in [AppLanguage.simplifiedChinese, AppLanguage.english] {
            let message = AppText.value(QuickSearchIndexIssue.noScopeSelected.messageKey, language: language)
            #expect(!message.isEmpty)
            #expect(message != QuickSearchIndexIssue.noScopeSelected.messageKey)
        }
    }
}

// MARK: - 启动、打开与显示

@MainActor
struct QuickSearchActionTests {
    @Test func validatesThenClosesThePanelThenLaunches() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.launcher.onLaunch = { harness.ledger.record("launch") }
        harness.model.openPanel()
        harness.model.updateQuery("safari")
        harness.ledger.reset()

        harness.model.performPrimaryAction()
        await harness.launcher.wait(forCalls: 1)

        #expect(harness.ledger.events == ["exists", "launch"])
        #expect(!harness.model.isPanelVisible)
        #expect(harness.launcher.calls.first?.url.path == "/Applications/Safari.app")
        #expect(harness.launcher.calls.first?.name == "Safari")
    }

    @Test func doesNotLaunchOrPretendSuccessWhenTheAppIsGone() async {
        let harness = Harness(existingPaths: [])
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("safari")

        harness.model.performPrimaryAction()
        defer { harness.model.shutdown() }

        #expect(harness.launcher.calls.isEmpty)
        #expect(harness.notice.presented.count == 1)
        #expect(harness.notice.presented.first?.contains("Safari") == true)
        #expect(harness.model.transientNotice != nil)
        #expect(!harness.model.isPanelVisible)
    }

    @Test func recordsUsageOnlyWhenTheLaunchSucceeded() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        let entry = sampleApps[0]

        harness.model.openPanel()
        harness.model.updateQuery("safari")
        harness.model.performPrimaryAction()
        await harness.launcher.wait(forCalls: 1)
        // 记账发生在启动返回之后，等它落地而不是睡一觉。
        await expectEventually { harness.model.usage.count(for: entry) == 1 }

        harness.model.openPanel()
        harness.model.updateQuery("safari")
        harness.launcher.failure = .launchFailed(name: "Safari")
        harness.model.performPrimaryAction()
        await harness.launcher.wait(forCalls: 2)
        let delivered = await yieldUntil { harness.notice.presented.count == 1 }
        defer { harness.model.shutdown() }

        #expect(delivered)
        // 失败不记账，也不留「已启动」的假象。
        #expect(harness.model.usage.count(for: entry) == 1)
        #expect(harness.notice.presented.first?.contains("Safari") == true)
    }

    @Test func activationFailureNeverReopensTheSearchPanel() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.launcher.failure = .launchFailed(name: "Safari")
        harness.model.openPanel()
        harness.model.updateQuery("safari")

        harness.model.performPrimaryAction()
        await harness.launcher.wait(forCalls: 1)
        let delivered = await yieldUntil { harness.notice.presented.count == 1 }
        defer { harness.model.shutdown() }

        // 反馈是一行轻提示；面板收起，且没有再开任何搜索窗口。
        #expect(delivered)
        #expect(!harness.model.isPanelVisible)
        #expect(harness.panels.live == 0)
        #expect(harness.panels.created == 1)
        #expect(harness.notice.dismissCount == 0)
    }

    @Test func commandEnterRevealsTheSelectionInFinder() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("invoice")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/invoice.pdf")], isFinal: true, issue: nil))

        harness.model.revealSelectionInFinder()

        #expect(harness.fileOpener.revealed.map(\.path) == ["/Users/me/Desktop/invoice.pdf"])
        #expect(harness.fileOpener.opened.isEmpty)
        #expect(!harness.model.isPanelVisible)
        #expect(harness.ledger.events.contains("reveal"))
    }

    @Test func revealingAMissingItemReportsItInsteadOfOpeningFinder() async {
        let harness = Harness(existingPaths: [])
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("invoice")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/invoice.pdf")], isFinal: true, issue: nil))
        harness.ledger.reset()

        harness.model.revealSelectionInFinder()

        #expect(harness.fileOpener.revealed.isEmpty)
        #expect(harness.notice.presented.first?.contains("invoice.pdf") == true)
        harness.model.shutdown()
    }

    @Test func openingAFolderAndAFileBothGoThroughTheWorkspace() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("proj")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(
            hits: [fileHit("/Users/me/Documents/Projects", isFolder: true), fileHit("/Users/me/Documents/project.txt")],
            isFinal: true,
            issue: nil
        ))
        #expect(harness.model.results.map(\.kind) == [.folder, .file])

        harness.model.activate(resultID: harness.model.results[0].id)

        #expect(harness.fileOpener.opened.map(\.path) == ["/Users/me/Documents/Projects"])
        #expect(harness.launcher.calls.isEmpty)
    }

    @Test func cloudOrMovedItemsReportTheirRealReason() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("key")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/iCloud/missing.pdf")], isFinal: true, issue: nil))
        harness.fileOpener.failure = .cloudItemUnavailable(name: "missing.pdf")

        harness.model.performPrimaryAction()

        #expect(harness.notice.presented == [AppText.value(
            "quickSearchErrorCloudUnavailable",
            language: .simplifiedChinese,
            arguments: ["missing.pdf"]
        )])
        harness.model.shutdown()
    }

    @Test func anUnknownResultIDDoesNothingAtAll() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("safari")

        harness.model.activate(resultID: "application:/Applications/Notes.app")
        harness.model.reveal(resultID: "file:/Users/me/nope.txt")

        #expect(harness.launcher.calls.isEmpty)
        #expect(harness.fileOpener.opened.isEmpty)
        #expect(harness.fileOpener.revealed.isEmpty)
        // 对不上的 ID 只是不动，连面板都不该被收掉。
        #expect(harness.model.isPanelVisible)
        harness.model.shutdown()
    }

    @Test func navigationStaysInsideTheRowList() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("a")

        #expect(harness.model.selectedRowIndex == 0)
        harness.model.moveSelection(by: -1)
        #expect(harness.model.selectedRowIndex == 0)
        harness.model.moveSelection(by: 1)
        harness.model.moveSelection(by: 1)
        #expect(harness.model.selectedRowIndex <= max(harness.model.results.count - 1, 0))

        harness.model.selectRow(at: 999)
        #expect(harness.model.selectedRowIndex <= max(harness.model.results.count - 1, 0))
    }

    @Test func aPointerThatHasNotMovedSinceSummonKeepsTheFirstRow() async {
        let harness = Harness()
        let entries = [
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/Alpha.app"),
                name: "Alpha",
                bundleIdentifier: "com.test.alpha"
            ),
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/Beta.app"),
                name: "Beta",
                bundleIdentifier: "com.test.beta"
            )
        ]
        await harness.enable(entries: entries)
        var pointer = NSPoint(x: 420, y: 360)
        harness.model.pointerLocation = { pointer }

        harness.model.openPanel()
        harness.model.updateQuery("a")
        #expect(harness.model.results.count == 2)

        // 面板正好落在指针下：补发的悬停事件不能替用户把选中行挪走。
        harness.model.selectRowByHover(at: 1)
        #expect(harness.model.selectedRowIndex == 0)

        // 指针真的移动之后，悬停照常接管。
        pointer.x += 2
        harness.model.selectRowByHover(at: 1)
        #expect(harness.model.selectedRowIndex == 1)

        // 重新呼出会重新上闸：新一次打开同样从第一行开始。
        harness.model.closePanel()
        harness.model.openPanel()
        harness.model.updateQuery("a")
        harness.model.selectRowByHover(at: 1)
        #expect(harness.model.selectedRowIndex == 0)
        harness.model.shutdown()
    }

    @Test func pointerSelectionDoesNotScrollTheListButKeyboardNavigationDoes() async {
        let harness = Harness()
        await harness.enable(entries: [
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/Safari.app"),
                name: "Safari",
                bundleIdentifier: "com.test.safari"
            ),
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/Slack.app"),
                name: "Slack",
                bundleIdentifier: "com.test.slack"
            ),
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/Alfred.app"),
                name: "Alfred",
                bundleIdentifier: "com.test.alfred"
            )
        ])
        harness.model.openPanel()
        harness.model.updateQuery("a")
        #expect(harness.model.results.count == 3)

        let token = harness.model.selectionScrollToken
        // 悬停只挪选中行，不请求滚动：滚动会把指针下的行换掉，再触发新的悬停。
        harness.model.selectRow(at: 2)
        #expect(harness.model.selectedRowIndex == 2)
        #expect(harness.model.selectionScrollToken == token)

        // 键盘导航才让列表跟着走。
        harness.model.moveSelection(by: -1)
        #expect(harness.model.selectedRowIndex == 1)
        #expect(harness.model.selectionScrollToken == token + 1)
        harness.model.shutdown()
    }

    @Test func opensThePanelWhileTheIndexIsStillBuilding() async {
        let harness = Harness()
        await harness.enable()
        harness.scan.entries = sampleApps

        harness.model.openPanel()
        // 扫描还在后台跑：此刻主 Actor 还没拿到结果，面板已经能呼出来。
        #expect(harness.model.isPanelVisible)
        #expect(harness.inventory.state == .building)
        #expect(harness.model.indexEntryCount == 0)

        await settleIndex(harness.inventory)

        #expect(harness.model.indexEntryCount == sampleApps.count)
        #expect(harness.model.indexState == .ready)
    }

    @Test func anIndexThatLandsAfterTheFirstSearchRefillsTheResults() async {
        let harness = Harness()
        await harness.enable()

        harness.model.openPanel()
        harness.model.updateQuery("safari")
        #expect(harness.model.applicationResults.isEmpty)

        harness.scan.entries = sampleApps
        await settleIndex(harness.inventory)

        // 首次呼出时索引常常还没建完；落地后必须把当前这一行补上，而不是让用户重打。
        #expect(harness.model.applicationResults.map(\.title) == ["Safari"])
        #expect(harness.model.selectedRowIndex == 0)
    }

    @Test func anIndexThatLandsWithAnEmptyQueryShowsRecentApplications() async {
        let harness = Harness()
        // 先记一次真实启动，「最近使用」才有内容可显示。
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("safari")
        harness.model.performPrimaryAction()
        await harness.launcher.wait(forCalls: 1)
        await expectEventually { harness.model.usage.count(for: sampleApps[0]) == 1 }

        // 索引清空后再呼出：这一拍面板里确实什么都还没有。
        harness.inventory.shutdown()
        harness.model.openPanel()
        #expect(harness.model.applicationResults.isEmpty)

        // 空查询上索引落地：先给出最近使用，其余按名称补齐，而不是继续空着。
        await settleIndex(harness.inventory)
        #expect(harness.model.query.isEmpty)
        #expect(harness.model.applicationResults.map(\.title) == ["Safari", "计算器"])
        harness.model.shutdown()
    }

    @Test func runningApplicationsOutsideTheScannedDirectoriesAreStillSearchable() async {
        let harness = Harness()
        harness.scan.running = [
            QuickSearchRunningApplication(
                url: URL(fileURLWithPath: "/Users/me/Downloads/Beta.app"),
                bundleIdentifier: "com.test.beta",
                name: "Beta App"
            )
        ]
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("beta")

        #expect(harness.model.applicationResults.map(\.title) == ["Beta App"])
    }
}

// MARK: - 快捷键

@MainActor
private final class FakeQuickSearchHotKeyDriver: QuickSearchHotKeyDriver {
    enum RegistrationPlan {
        case succeed
        case handlerFailure(Int)
        case registrationFailure(Int)
        case registrationFailureWithCleanupFailure(Int, Int)
    }

    enum UnregistrationPlan {
        case released
        case stillRegistered(Int)
        case releasedWithCleanupFailure(Int)
    }

    private struct Registration {
        let binding: SmartCaptureShortcutBinding
        let eventIdentifier: QuickSearchHotKeyEventIdentifier
        let onEvent: @MainActor () -> Void
        var hotKeyActive = true
    }

    var registrationPlans: [RegistrationPlan] = []
    var unregistrationStatuses: [OSStatus] = []
    var unregistrationPlans: [UnregistrationPlan] = []
    private var active: [QuickSearchHotKeyRegistrationToken: Registration] = [:]
    private(set) var latestToken: QuickSearchHotKeyRegistrationToken?

    var activeBindings: [SmartCaptureShortcutBinding] { active.values.filter(\.hotKeyActive).map(\.binding) }
    var retainedHandlerCount: Int { active.count }

    func eventIdentifier(for token: QuickSearchHotKeyRegistrationToken) -> QuickSearchHotKeyEventIdentifier? {
        active[token]?.eventIdentifier
    }

    func register(
        _ binding: SmartCaptureShortcutBinding,
        eventIdentifier: QuickSearchHotKeyEventIdentifier,
        onEvent: @escaping @MainActor () -> Void
    ) -> QuickSearchHotKeyDriverResult {
        let plan = registrationPlans.isEmpty ? .succeed : registrationPlans.removeFirst()
        switch plan {
        case .succeed:
            let token = QuickSearchHotKeyRegistrationToken()
            let registration = Registration(binding: binding, eventIdentifier: eventIdentifier, onEvent: onEvent)
            active[token] = registration
            latestToken = token
            return .installed(token: token, status: Int(noErr))
        case .handlerFailure(let status):
            return .handlerInstallFailed(status: status)
        case .registrationFailure(let status):
            return .registrationFailed(status: status, cleanupToken: nil)
        case .registrationFailureWithCleanupFailure(let registrationStatus, _):
            let token = QuickSearchHotKeyRegistrationToken()
            active[token] = Registration(
                binding: binding,
                eventIdentifier: eventIdentifier,
                onEvent: onEvent,
                hotKeyActive: false
            )
            latestToken = token
            return .registrationFailed(status: registrationStatus, cleanupToken: token)
        }
    }

    func unregister(_ token: QuickSearchHotKeyRegistrationToken) -> QuickSearchHotKeyUnregistrationResult {
        if !unregistrationPlans.isEmpty {
            switch unregistrationPlans.removeFirst() {
            case .released:
                active[token] = nil
                return .keyReleased(handlerCleanupStatus: nil)
            case .stillRegistered(let status):
                return .stillRegistered(status: status)
            case .releasedWithCleanupFailure(let status):
                if var registration = active[token] {
                    registration.hotKeyActive = false
                    active[token] = registration
                }
                return .keyReleased(handlerCleanupStatus: status)
            }
        }
        let status = unregistrationStatuses.isEmpty ? noErr : unregistrationStatuses.removeFirst()
        if status == noErr {
            active[token] = nil
            return .keyReleased(handlerCleanupStatus: nil)
        }
        return .stillRegistered(status: Int(status))
    }

    /// Models Carbon delivering an event. The callback is queued like the production driver,
    /// so a replacement/stop can invalidate it before it reaches the main actor.
    func enqueueEvent(
        for token: QuickSearchHotKeyRegistrationToken,
        received: QuickSearchHotKeyEventIdentifier,
        status: OSStatus = noErr
    ) -> OSStatus {
        guard let registration = active[token], registration.hotKeyActive else { return OSStatus(eventNotHandledErr) }
        let disposition = quickSearchHotKeyEventDisposition(
            status: status,
            received: status == noErr ? received : nil,
            expected: registration.eventIdentifier
        )
        guard disposition == noErr, received == registration.eventIdentifier else { return disposition }
        let onEvent = registration.onEvent
        Task { @MainActor in onEvent() }
        return noErr
    }
}

/// Carbon 的注册是**进程级**的：同一台机器上同一个组合只能被本进程注册一次，
/// 并行跑会互相抢注，先跑的那个还没收干净就会让后面的用例报 -9878。
/// 所以这个套件串行，且每个用例结束时必须注销。
@MainActor
@Suite(.serialized)
struct QuickSearchHotKeyTests {
    @Test func aRejectedBindingKeepsThePreviouslyValidConfiguration() {
        let harness = Harness(hotkey: Harness.safeHotkey)
        defer { harness.model.shutdown() }
        let original = harness.model.settings.hotkey
        var persisted = 0
        harness.model.persist = { persisted += 1 }

        harness.model.setHotkey(SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: []))

        #expect(harness.model.hotKeyError == .invalidBinding)
        #expect(harness.model.settings.hotkey == original)
        #expect(persisted == 0)
    }

    @Test func aBindingOwnedByAnotherFeatureIsRefusedWithItsName() {
        let harness = Harness(hotkey: Harness.safeHotkey)
        let originalBinding = harness.model.settings.hotkey
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }
        harness.model.shortcutConflictChecker = { _ in MainSection.clipboard.titleKey }

        harness.model.setHotkey(SmartCaptureShortcutBinding(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .option]))
        defer { harness.model.shutdown() }

        let conflict = QuickSearchHotKeyError.conflictsWithOtherFeature(sectionTitleKey: MainSection.clipboard.titleKey)
        #expect(harness.model.hotKeyError == conflict)
        #expect(harness.model.settings.hotkey == originalBinding)
        #expect(persistCount == 0)
        // 冲突时不会留下「界面说已启用、实际按不动」的半注册状态。
        #expect(harness.model.isHotKeyRegistered)
        for language in [AppLanguage.simplifiedChinese, AppLanguage.english] {
            let conflictingName = AppText.value(MainSection.clipboard.titleKey, language: language)
            let message = AppText.value(conflict.messageKey, language: language, arguments: [conflictingName])
            #expect(message != conflict.messageKey)
            // 提示里必须点名是哪一个功能占用了这个组合，用户才知道去哪儿改。
            #expect(message.contains(conflictingName))
        }
    }

    @Test func aCarbonRegistrationFailureKeepsThePreviousBindingAndDoesNotPersist() {
        let driver = FakeQuickSearchHotKeyDriver()
        driver.registrationPlans = [.succeed, .registrationFailure(-9878)]
        let center = QuickSearchHotKeyCenter(driver: driver)
        let harness = Harness(hotkey: Harness.safeHotkey, hotKeyCenter: center)
        defer { harness.model.shutdown() }
        let originalBinding = harness.model.settings.hotkey
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )

        harness.model.setHotkey(replacement)

        #expect(harness.model.hotKeyError == .registrationFailed(status: -9878))
        #expect(harness.model.settings.hotkey == originalBinding)
        #expect(persistCount == 0)
        #expect(harness.model.isHotKeyRegistered)
        #expect(driver.activeBindings == [originalBinding])
    }

    @Test func aReleasedOldHotKeyCommitsTheReplacementWhenHandlerCleanupIsPending() {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        let harness = Harness(hotkey: Harness.safeHotkey, hotKeyCenter: center)
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }
        driver.unregistrationPlans = [.releasedWithCleanupFailure(-9878)]

        harness.model.setHotkey(replacement)

        #expect(harness.model.settings.hotkey == replacement)
        #expect(persistCount == 1)
        #expect(harness.model.hotKeyError != nil)
        #expect(center.registeredBinding == replacement)
        #expect(center.lastRegistrationStatus == Int(noErr))
        #expect(driver.activeBindings == [replacement])
        #expect(driver.retainedHandlerCount == 2)

        // Re-selecting the committed binding retries stale Carbon handler cleanup without
        // writing the same preference again.
        harness.model.setHotkey(replacement)
        #expect(harness.model.hotKeyError == nil)
        #expect(persistCount == 1)
        #expect(center.lastRegistrationStatus == Int(noErr))
        #expect(driver.retainedHandlerCount == 1)
        harness.model.shutdown()
    }

    @Test func carbonCallbackContextStaysRetainedUntilHandlerRemovalIsConfirmed() {
        var context: QuickSearchHotKeyContext? = QuickSearchHotKeyContext(
            eventIdentifier: QuickSearchHotKeyEventIdentifier(signature: 1, identifier: 2),
            onEvent: {}
        )
        weak let weakContext = context
        let lease = QuickSearchHotKeyContextLease(context!)

        context = nil
        #expect(weakContext != nil)
        #expect(lease.opaquePointer != nil)

        lease.release()

        #expect(lease.opaquePointer == nil)
        #expect(weakContext == nil)
        lease.release() // Removal retries cannot over-release the callback context.
    }

    @Test func failedRegistrationRetainsItsHandlerContextUntilCleanupRetries() {
        let driver = FakeQuickSearchHotKeyDriver()
        driver.registrationPlans = [.registrationFailureWithCleanupFailure(-9878, -9879)]
        driver.unregistrationPlans = [.releasedWithCleanupFailure(-9879), .released]
        let center = QuickSearchHotKeyCenter(driver: driver)

        #expect(center.updateBinding(Harness.safeHotkey) == .registrationFailed(status: -9878))
        #expect(!center.isRegistered)
        #expect(center.hasOutstandingRegistrations)
        #expect(driver.retainedHandlerCount == 1)

        center.stop()
        #expect(center.hasOutstandingRegistrations)
        #expect(driver.retainedHandlerCount == 1)

        center.stop()
        #expect(!center.hasOutstandingRegistrations)
        #expect(driver.retainedHandlerCount == 0)
    }

    @Test func stoppingAfterKeyReleaseClearsBindingAndRetriesHandlerCleanup() {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        #expect(center.updateBinding(Harness.safeHotkey) == nil)
        driver.unregistrationPlans = [.releasedWithCleanupFailure(-9878), .released]

        center.stop()

        #expect(!center.isRegistered)
        #expect(center.registeredBinding == nil)
        #expect(center.lastError == .cleanupPending(status: -9878))
        #expect(!driver.activeBindings.contains(Harness.safeHotkey))
        #expect(center.hasOutstandingRegistrations)
        #expect(driver.retainedHandlerCount == 1)

        center.stop()

        #expect(!center.hasOutstandingRegistrations)
        #expect(center.lastError == nil)
        #expect(driver.retainedHandlerCount == 0)
    }

    @Test func anUnregistrationFailureIsReportedWithoutDiscardingTheOldRegistration() {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        let original = Harness.safeHotkey
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )
        #expect(center.updateBinding(original) == nil)
        driver.unregistrationStatuses = [-9878]

        let error = center.updateBinding(replacement)

        #expect(error != nil)
        #expect(center.lastError == error)
        #expect(center.lastRegistrationStatus == -9878)
        #expect(center.registeredBinding == original)
        #expect(center.isRegistered)
        #expect(driver.activeBindings == [original])
        center.stop()
    }

    @Test func retryingTheExistingBindingCleansUpAFailedReplacementRollback() {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        defer { center.stop() }
        let original = Harness.safeHotkey
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )
        #expect(center.updateBinding(original) == nil)
        driver.unregistrationStatuses = [-9878, -9877]

        #expect(center.updateBinding(replacement) == .unregistrationFailed(status: -9878))
        #expect(center.registeredBinding == original)
        #expect(driver.activeBindings.count == 2)

        #expect(center.updateBinding(original) == nil)

        #expect(center.registeredBinding == original)
        #expect(driver.activeBindings == [original])
    }

    @Test func stopKeepsARegistrationWhenCarbonCannotUnregisterIt() {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        let binding = Harness.safeHotkey
        #expect(center.updateBinding(binding) == nil)
        driver.unregistrationStatuses = [-9878, noErr]

        center.stop()

        #expect(center.isRegistered)
        #expect(center.registeredBinding == binding)
        #expect(center.lastRegistrationStatus == -9878)
        #expect(center.lastError != nil)
        #expect(driver.activeBindings == [binding])

        center.stop()
        #expect(!center.isRegistered)
        #expect(center.registeredBinding == nil)
        #expect(driver.activeBindings.isEmpty)
    }

    @Test func shutdownReportsAndRetriesAHotKeyCleanupFailure() {
        let driver = FakeQuickSearchHotKeyDriver()
        driver.unregistrationStatuses = [-9878, noErr]
        let center = QuickSearchHotKeyCenter(driver: driver)
        let harness = Harness(hotkey: Harness.safeHotkey, hotKeyCenter: center)

        harness.model.shutdown()

        #expect(harness.model.hotKeyError == .unregistrationFailed(status: -9878))
        #expect(harness.model.isHotKeyRegistered)
        #expect(driver.activeBindings == [Harness.safeHotkey])

        harness.model.shutdown()

        #expect(harness.model.hotKeyError == nil)
        #expect(!harness.model.isHotKeyRegistered)
        #expect(driver.activeBindings.isEmpty)
    }

    @Test func unknownCarbonEventIDsArePassedToTheNextHandler() {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        let binding = Harness.safeHotkey
        #expect(center.updateBinding(binding) == nil)
        guard let token = driver.latestToken else {
            #expect(Bool(false), "Registration did not produce a test token")
            return
        }
        guard let registeredEvent = driver.eventIdentifier(for: token) else {
            #expect(Bool(false), "Registration did not produce an event identifier")
            return
        }
        var toggleCount = 0
        center.onToggle = { toggleCount += 1 }
        let status = driver.enqueueEvent(
            for: token,
            received: QuickSearchHotKeyEventIdentifier(
                signature: registeredEvent.signature,
                identifier: registeredEvent.identifier == UInt32.max ? 0 : registeredEvent.identifier + 1
            )
        )

        #expect(status == OSStatus(eventNotHandledErr))
        #expect(toggleCount == 0)
        center.stop()
    }

    @Test func aCallbackQueuedBeforeReplacementIsIgnored() async {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        var toggleCount = 0
        center.onToggle = { toggleCount += 1 }
        let original = Harness.safeHotkey
        #expect(center.updateBinding(original) == nil)
        guard let oldToken = driver.latestToken else {
            #expect(Bool(false), "Registration did not produce a test token")
            return
        }
        guard let oldEvent = driver.eventIdentifier(for: oldToken) else {
            #expect(Bool(false), "Registration did not produce an event identifier")
            return
        }
        let queuedStatus = driver.enqueueEvent(
            for: oldToken,
            received: oldEvent
        )
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )

        #expect(queuedStatus == noErr)
        #expect(center.updateBinding(replacement) == nil)
        await Task.yield()

        #expect(toggleCount == 0)
        center.stop()
    }

    @Test func aCallbackQueuedBeforeStopIsIgnored() async {
        let driver = FakeQuickSearchHotKeyDriver()
        let center = QuickSearchHotKeyCenter(driver: driver)
        var toggleCount = 0
        center.onToggle = { toggleCount += 1 }
        #expect(center.updateBinding(Harness.safeHotkey) == nil)
        guard let token = driver.latestToken else {
            #expect(Bool(false), "Registration did not produce a test token")
            return
        }
        guard let eventIdentifier = driver.eventIdentifier(for: token) else {
            #expect(Bool(false), "Registration did not produce an event identifier")
            return
        }

        #expect(driver.enqueueEvent(
            for: token,
            received: eventIdentifier
        ) == noErr)
        center.stop()
        await Task.yield()

        #expect(toggleCount == 0)
    }

    @Test func aSuccessfulCarbonReplacementReleasesTheOldBinding() {
        let center = QuickSearchHotKeyCenter()
        let probe = QuickSearchHotKeyCenter()
        defer {
            probe.stop()
            center.stop()
        }
        let original = Harness.safeHotkey
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )

        let originalError = center.updateBinding(original)
        #expect(originalError == nil)
        guard originalError == nil else { return }
        let replacementError = center.updateBinding(replacement)
        #expect(replacementError == nil)
        guard replacementError == nil else { return }

        #expect(probe.updateBinding(original) == nil)
    }

    @Test func aValidBindingIsSavedAndPersisted() {
        let harness = Harness(hotkey: Harness.safeHotkey)
        var persisted = 0
        harness.model.persist = { persisted += 1 }
        let replacement = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_F14),
            modifiers: [.command, .control, .option, .shift]
        )

        harness.model.setHotkey(replacement)
        defer { harness.model.shutdown() }

        #expect(harness.model.settings.hotkey == replacement)
        #expect(persisted == 1)
        // 说法与事实一致：报成功就是真注册上了，报失败就是注册失败的原因。
        #expect(harness.model.isHotKeyRegistered == (harness.model.hotKeyError == nil))
        if let error = harness.model.hotKeyError {
            #expect(error.messageKey == "quickSearchHotkeyRegistrationFailed")
        }
    }

    @Test func settingTheSameBindingAgainChangesNothing() {
        let harness = Harness(hotkey: Harness.safeHotkey)
        defer { harness.model.shutdown() }
        var persisted = 0
        harness.model.persist = { persisted += 1 }
        let errorBefore = harness.model.hotKeyError
        let registeredBefore = harness.model.isHotKeyRegistered

        harness.model.setHotkey(harness.model.settings.hotkey)

        #expect(persisted == 0)
        // 重复保存同一个组合不能改变任何状态：已经在工作的那份不动，
        // 本机占用导致注册失败的也保持原样，而不是每次写设置都去抢一次。
        #expect(harness.model.hotKeyError == errorBefore)
        #expect(harness.model.isHotKeyRegistered == registeredBefore)
    }

    @Test func registrationStatusMatchesWhetherTheHotKeyActuallyWorks() {
        // 用真实 Carbon 注册一个足够冷门的组合，检查的是「状态与说法一致」，
        // 不是「一定注册成功」——机器上被占用时也必须如实说失败。
        let center = QuickSearchHotKeyCenter()
        let binding = Harness.safeHotkey
        let error = center.updateBinding(binding)

        #expect(center.isRegistered == (error == nil))
        #expect(center.lastRegistrationStatus != nil)
        #expect(center.registeredBinding == (center.isRegistered ? binding : nil))
        #expect(center.lastError == error)

        center.stop()
        #expect(!center.isRegistered)
        #expect(center.lastError == nil)
        #expect(center.registeredBinding == nil)
    }

    @Test func aRejectedRegistrationLeavesNoHalfRegisteredState() {
        let center = QuickSearchHotKeyCenter()
        // Escape 不是合法组合：必须拒绝注册，而不是「注册上了但界面说失败」。
        let error = center.updateBinding(SmartCaptureShortcutBinding(keyCode: UInt16(kVK_Escape), modifiers: [.command]))

        #expect(error == .invalidBinding)
        #expect(!center.isRegistered)
        #expect(center.registeredBinding == nil)
    }

    @Test func disablingTheFeatureRemovesTheHotKeyAndTheSummonPath() async {
        let harness = Harness(hotkey: Harness.safeHotkey)
        await harness.enable(entries: sampleApps)
        #expect(!harness.model.isPanelVisible)

        harness.model.togglePanel()
        #expect(harness.model.isPanelVisible)

        harness.model.setEnabled(false)

        #expect(harness.model.runtimeState == .disabled)
        #expect(harness.panels.live == 0)
        // 快捷键路径已断：再按也只会走到这里，而这里什么都不做。
        harness.model.togglePanel()
        #expect(!harness.model.isPanelVisible)
        #expect(harness.panels.created == 1)
    }

    @Test func reEnablingRestoresSummoningAndSearch() async {
        let harness = Harness(hotkey: Harness.safeHotkey)
        defer { harness.model.shutdown() }
        await harness.enable(entries: sampleApps)
        harness.model.setEnabled(false)

        harness.model.setEnabled(true)
        harness.model.openPanel()
        // 关闭功能时内存索引被丢弃了：重新启用后要等它落回来，搜索才该有结果。
        await settleIndex(harness.inventory)
        harness.model.updateQuery("safari")

        #expect(harness.model.isPanelVisible)
        #expect(harness.model.applicationResults.map(\.title) == ["Safari"])
    }

    @Test func thePanelCannotBeSummonedBeforeTheFeatureIsReady() {
        let harness = Harness(enabled: false)
        defer { harness.model.shutdown() }
        // 配置已加载但还没 start()：设置已生效，面板仍然呼不出来。
        harness.model.applyLoadedSettings(
            QuickSearchSettings(isEnabled: true, hotkey: Harness.safeHotkey),
            activate: false
        )

        #expect(harness.model.settings.isEnabled)
        #expect(harness.model.runtimeState == .disabled)
        harness.model.openPanel()

        #expect(!harness.model.isPanelVisible)
        #expect(harness.panels.created == 0)
    }
}

// MARK: - 面板反复开关

@MainActor
struct QuickSearchPanelLeakTests {
    @Test func aHundredOpenAndCloseCyclesLeaveNoLivePanelAndNoObservers() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)

        for _ in 0..<100 {
            harness.model.openPanel()
            harness.model.updateQuery("safari")
            harness.clock.fireAll()
            harness.model.closePanel()
        }

        #expect(harness.panels.live == 0)
        #expect(harness.panels.closed == harness.panels.created)
        #expect(harness.model.diagnosticObserverCount == 0)
        #expect(!harness.fileQuery.hasActiveQuery)
        #expect(harness.model.presentation == .hidden)
        #expect(harness.model.runtimeState == .ready)
        // 索引是留着复用的，不是每次开关都重建。
        #expect(harness.inventory.hasIndex)
        #expect(harness.scan.calls == 1)
    }

    @Test func rapidHotKeyTapsNeverShowTwoPanelsAtOnce() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)

        for _ in 0..<20 { harness.model.togglePanel() }

        #expect(harness.panels.peakLive == 1)
        #expect(harness.panels.live == (harness.model.isPanelVisible ? 1 : 0))
    }

    @Test func aPanelThatClosesItselfReportsBackExactlyOnce() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        let liveBefore = harness.panels.live
        guard let panel = harness.lastPanel else {
            Issue.record("面板没有被创建")
            return
        }

        // 模拟用户点了别处：窗口自己 close()（Esc / 点外都是这条路径）。
        let closedBefore = harness.panels.closed
        panel.close()
        panel.close()

        #expect(harness.panels.live == liveBefore - 1)
        // 连着两次自我关闭只算一次：重复 close 不该再回报第二遍。
        #expect(harness.panels.closed == closedBefore + 1)
        #expect(!harness.model.isPanelVisible)
    }

    @Test func aPanelClosingItselfWhileSearchingTerminatesTheQuery() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("abc")
        harness.clock.fireAll()
        #expect(harness.fileQuery.hasActiveQuery)

        harness.lastPanel?.close()

        #expect(!harness.model.isPanelVisible)
        #expect(!harness.fileQuery.hasActiveQuery)
        #expect(harness.model.diagnosticObserverCount == 0)
        #expect(harness.model.fileResults.isEmpty)
    }

    @Test func shutdownWhileThePanelIsOpenReleasesIt() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()

        harness.model.shutdown()

        #expect(harness.panels.live == 0)
        #expect(harness.model.presentation == .hidden)
        #expect(harness.model.runtimeState == .disabled)
    }

    @Test func repeatedShutdownAndRestartCyclesStayClean() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)

        for _ in 0..<10 {
            harness.model.setEnabled(true)
            harness.model.openPanel()
            harness.model.updateQuery("abc")
            harness.clock.fireAll()
            harness.model.setEnabled(false)
        }

        #expect(harness.panels.live == 0)
        #expect(harness.model.diagnosticObserverCount == 0)
        #expect(harness.model.diagnosticTaskCount == 0)
        #expect(harness.model.runtimeState == .disabled)
    }
}

// MARK: - 输入法与按键分流

struct QuickSearchKeyRoutingTests {
    @Test func enterDuringIMECompositionIsLeftToTheInputMethod() {
        let returnKey = UInt16(kVK_Return)

        #expect(QuickSearchKeyRouter.action(
            keyCode: returnKey, commandHeld: false, controlHeld: false, isComposingText: true
        ) == .passThrough)
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_Escape), commandHeld: false, controlHeld: false, isComposingText: true
        ) == .passThrough)
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_UpArrow), commandHeld: false, controlHeld: false, isComposingText: true
        ) == .passThrough)
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_DownArrow), commandHeld: false, controlHeld: false, isComposingText: true
        ) == .passThrough)

        // 没有组词时才由启动器接管。
        #expect(QuickSearchKeyRouter.action(
            keyCode: returnKey, commandHeld: false, controlHeld: false, isComposingText: false
        ) == .openSelection)
    }

    @Test func commandEnterRevealsAndPlainEnterOpens() {
        for keyCode in [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)] {
            #expect(QuickSearchKeyRouter.action(
                keyCode: keyCode, commandHeld: true, controlHeld: false, isComposingText: false
            ) == .revealInFinder)
            #expect(QuickSearchKeyRouter.action(
                keyCode: keyCode, commandHeld: false, controlHeld: false, isComposingText: false
            ) == .openSelection)
        }
    }

    @Test func nativeEditingShortcutsStillReachTheTextField() {
        // Cmd+A / Cmd+C / Cmd+V / 左右方向键 等原生编辑按键一律放行。
        for keyCode in [UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_V), UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow)] {
            #expect(QuickSearchKeyRouter.action(
                keyCode: keyCode, commandHeld: true, controlHeld: false, isComposingText: false
            ) == .passThrough)
        }
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_LeftArrow), commandHeld: false, controlHeld: false, isComposingText: false
        ) == .passThrough)
    }

    @Test func arrowsNavigateOnlyWithoutModifiers() {
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_UpArrow), commandHeld: false, controlHeld: false, isComposingText: false
        ) == .moveSelection(-1))
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_DownArrow), commandHeld: false, controlHeld: false, isComposingText: false
        ) == .moveSelection(1))
        #expect(QuickSearchKeyRouter.action(
            keyCode: UInt16(kVK_DownArrow), commandHeld: false, controlHeld: true, isComposingText: false
        ) == .passThrough)
    }
}

// MARK: - 原生输入框命令

@MainActor
struct QuickSearchNativeInputTests {
    @Test func returnFromTheFieldEditorOpensTheSelectedApplicationOnce() async throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        let applications = sampleApps.map {
            QuickSearchApplicationEntry(url: $0.url, name: "Demo \($0.name)", bundleIdentifier: $0.bundleIdentifier)
        }
        await harness.enable(entries: applications)
        harness.model.openPanel()
        harness.model.updateQuery("demo")
        try #require(harness.model.results.count > 1)
        harness.model.moveSelection(by: 1)
        let selected = harness.model.results[1]
        let field = QuickSearchQueryTextField()
        field.onCommand = { harness.model.handleSearchKeyAction($0) }
        harness.launcher.onLaunch = { harness.ledger.record("launch") }
        harness.ledger.reset()

        let handled = field.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("insertNewline:"))
        #expect(handled)
        if handled { await harness.launcher.wait(forCalls: 1) }
        #expect(harness.launcher.calls.count == 1)
        #expect(harness.launcher.calls.first?.url == selected.url)
        #expect(!harness.model.isPanelVisible)
        #expect(harness.ledger.events == ["exists", "launch"])
    }

    @Test func escapeFromTheFieldEditorClosesWithoutLaunching() async {
        let harness = Harness()
        defer { harness.model.shutdown() }
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        let field = QuickSearchQueryTextField()
        field.onCommand = { harness.model.handleSearchKeyAction($0) }

        #expect(field.control(field, textView: NSTextView(), doCommandBy: NSSelectorFromString("cancelOperation:")))
        #expect(!harness.model.isPanelVisible)
        #expect(harness.launcher.calls.isEmpty)
    }

    @Test func nativeEditorCommandsNavigateButKeepEditingCommandsNative() {
        let field = QuickSearchQueryTextField()
        let editor = NSTextView()
        var actions: [QuickSearchKeyAction] = []
        field.onCommand = { actions.append($0) }

        #expect(field.control(field, textView: editor, doCommandBy: NSSelectorFromString("moveDown:")))
        #expect(field.control(field, textView: editor, doCommandBy: NSSelectorFromString("moveUp:")))
        #expect(!field.control(field, textView: editor, doCommandBy: NSSelectorFromString("deleteBackward:")))
        #expect(actions == [.moveSelection(1), .moveSelection(-1)])
    }

    @Test func markedTextKeepsReturnEscapeAndNavigationInTheInputMethod() {
        let field = QuickSearchQueryTextField()
        let editor = QuickSearchMarkedEditor()
        var actions: [QuickSearchKeyAction] = []
        field.onCommand = { actions.append($0) }
        for command in ["insertNewline:", "cancelOperation:", "moveUp:", "moveDown:"] {
            #expect(!field.control(field, textView: editor, doCommandBy: NSSelectorFromString(command)))
        }
        #expect(actions.isEmpty)
    }

    @Test func committingMarkedTextDoesNotAlsoLaunchOrCloseThePanel() {
        let field = QuickSearchQueryTextField()
        let editor = NSTextView()
        var actions: [QuickSearchKeyAction] = []
        field.onCommand = { actions.append($0) }
        // Some input methods clear marked text before forwarding the same event's command.
        field.compositionAtEventStart = { true }
        for command in ["insertNewline:", "cancelOperation:", "moveUp:", "moveDown:"] {
            #expect(!field.control(field, textView: editor, doCommandBy: NSSelectorFromString(command)))
        }
        #expect(actions.isEmpty)
        field.compositionAtEventStart = { false }
        #expect(field.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")))
        #expect(actions == [.openSelection])
    }

    @Test func nativeTextChangesUpdateTheSearchQuery() {
        let field = QuickSearchQueryTextField()
        var changes: [String] = []
        field.onQueryChange = { changes.append($0) }
        field.stringValue = "Safari"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.stringValue = ""
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(changes == ["Safari", ""])
    }
}

@MainActor
private final class QuickSearchMarkedEditor: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

// Exercise the real panel's event-start composition snapshot, not only the delegate.
@MainActor
struct QuickSearchPanelInputTests {
    @Test func zeroLengthMarkedRangeDoesNotBlockEscape() async throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        harness.model.openPanel()
        let fixture = QuickSearchPanelInputFixture(model: harness.model)
        defer { fixture.panel.close() }
        #expect(fixture.editor.markedRange().location != NSNotFound)
        #expect(!fixture.editor.hasMarkedText())

        fixture.panel.sendEvent(try fixture.event(keyCode: UInt16(kVK_Escape), characters: "\u{1b}"))

        #expect(!harness.model.isPanelVisible)
        #expect(harness.launcher.calls.isEmpty)
        #expect(!fixture.panel.isVisible)
    }

    @Test func zeroLengthMarkedRangeDoesNotBlockOpeningTheSelectedApp() async throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        await harness.enable(entries: sampleApps)
        harness.model.openPanel()
        harness.model.updateQuery("计算器")
        let selected = try #require(harness.model.results.first)
        let fixture = QuickSearchPanelInputFixture(model: harness.model)
        defer { fixture.panel.close() }

        fixture.panel.sendEvent(try fixture.event(keyCode: UInt16(kVK_Return), characters: "\r"))

        try #require(fixture.commands == [.openSelection])
        await harness.launcher.wait(forCalls: 1)
        #expect(harness.launcher.calls.count == 1)
        #expect(harness.launcher.calls.first?.url == selected.url)
        #expect(!harness.model.isPanelVisible)
        #expect(!fixture.panel.isVisible)
    }

    @Test func actualMarkedTextKeepsReturnAndEscapeInTheEditor() async throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        harness.model.openPanel()
        let fixture = QuickSearchPanelInputFixture(model: harness.model)
        defer { fixture.panel.close() }
        fixture.editor.composing = true

        fixture.panel.sendEvent(try fixture.event(keyCode: UInt16(kVK_Return), characters: "\r"))
        fixture.panel.sendEvent(try fixture.event(keyCode: UInt16(kVK_Escape), characters: "\u{1b}"))

        #expect(harness.model.isPanelVisible)
        #expect(harness.launcher.calls.isEmpty)
        #expect(!fixture.panel.isVisible)
    }
}

@MainActor
private final class QuickSearchPanelInputFixture: NSObject, NSWindowDelegate {
    let panel: QuickSearchPanel
    let field = QuickSearchQueryTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
    let editor = QuickSearchZeroLengthMarkedEditor()
    var commands: [QuickSearchKeyAction] = []

    init(model: QuickSearchModel) {
        panel = QuickSearchPanel(model: model, onClose: {})
        super.init()
        editor.isFieldEditor = true
        panel.delegate = self
        panel.contentView = field
        field.onCommand = { [weak self, weak model] in
            self?.commands.append($0)
            model?.handleSearchKeyAction($0)
        }
        // Do not order the panel front or register a real shortcut.
        precondition(panel.makeFirstResponder(field))
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }

    func event(keyCode: UInt16, characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }
}

@MainActor
private final class QuickSearchZeroLengthMarkedEditor: NSTextView {
    var composing = false
    override func markedRange() -> NSRange { NSRange(location: 0, length: composing ? 1 : 0) }
    override func hasMarkedText() -> Bool { composing }
}

// MARK: - 性能实测

/// 写 stderr：`swift test` 会原样带出来，且不影响通过/失败判定。
/// 方案的第十节要的是实测分布，不是「应该很快」的说法。
@MainActor
private func reportMeasurement(_ line: String) {
    FileHandle.standardError.write(Data(("测量｜" + line + "\n").utf8))
}

@MainActor
private func percentile(_ samples: [Duration], at p: Double) -> Duration {
    guard !samples.isEmpty else { return .zero }
    let sorted = samples.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func ms(_ duration: Duration) -> String {
    String(format: "%.2f", milliseconds(duration))
}

/// 造一个「够大但不真实」的索引：400 条含中文名，走完整拼音/首字母归一化。
private func syntheticIndex(count: Int) -> [QuickSearchApplicationEntry] {
    (0..<count).map { index in
        QuickSearchApplicationEntry(
            url: URL(fileURLWithPath: "/Applications/\(index).app"),
            name: index.isMultiple(of: 2) ? "应用\(index)号" : "Tool\(index)",
            bundleIdentifier: "com.test.app\(index)"
        )
    }
}

@MainActor
@Suite(.serialized)
struct QuickSearchPerformanceTests {
    /// 缓存命中后的应用搜索：纯内存，不碰磁盘，P95 目标 50ms。
    @Test func cachedApplicationSearchStaysInsideItsBudget() {
        let entries = syntheticIndex(count: 400)
        let terms = ["应用", "safari", "工具", "t1", "计算器", "a", "号", "17", "app", "x9"]
        var samples: [Duration] = []
        samples.reserveCapacity(400)
        let clock = ContinuousClock()

        for _ in 0..<40 {
            for term in terms {
                let start = clock.now
                let results = ApplicationSearchProvider.search(
                    query: term,
                    entries: entries,
                    usage: { _ in 0 },
                    includeTags: false,
                    limit: QuickSearchLimits.applicationResults
                )
                samples.append(clock.now - start)
                _ = results.count
            }
        }
        let p95 = milliseconds(percentile(samples, at: 0.95))
        reportMeasurement("应用搜索（400 条索引）P50 \(ms(percentile(samples, at: 0.50)))ms P95 \(ms(percentile(samples, at: 0.95)))ms 最大 \(ms(samples.max() ?? .zero))ms")
        #expect(p95 <= 50)
    }

    /// 面板侧成本：真实 `QuickSearchPanel` 的构建 + 首帧布局。
    /// 只创建不下单（不调用 `open()`），所以不会在用户桌面上闪出窗口。
    @Test func panelConstructionAndFirstLayoutStayInsideTheirBudget() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var samples: [Duration] = []
        let clock = ContinuousClock()

        for _ in 0..<30 {
            let start = clock.now
            let panel = QuickSearchPanel(model: harness.model) {}
            panel.contentView?.layoutSubtreeIfNeeded()
            _ = panel.frame
            samples.append(clock.now - start)
            panel.close()
        }
        let p95 = milliseconds(percentile(samples, at: 0.95))
        reportMeasurement("面板构建+首帧布局（真实 NSPanel，不 order-front）P95 \(ms(percentile(samples, at: 0.95)))ms 最大 \(ms(samples.max() ?? .zero))ms")
        #expect(p95 <= 100)
    }

    /// 呼出/收起的模型侧循环：走完整状态机，但用替身面板。
    @Test func warmOpenAndCloseCyclesStayInsideTheirBudget() async {
        let harness = Harness()
        await harness.enable(entries: syntheticIndex(count: 400))
        defer { harness.model.shutdown() }
        var samples: [Duration] = []
        let clock = ContinuousClock()

        for _ in 0..<100 {
            let start = clock.now
            harness.model.openPanel()
            harness.model.updateQuery("应用")
            samples.append(clock.now - start)
            harness.model.closePanel()
        }
        let p95 = milliseconds(percentile(samples, at: 0.95))
        reportMeasurement("呼出+填结果（400 条索引，模型侧）P95 \(ms(percentile(samples, at: 0.95)))ms")
        #expect(p95 <= 100)
    }

    /// 扫描必须在主线程之外：主线程只负责把任务派出去，不能被磁盘枚举卡住。
    @Test func indexBuildLeavesTheMainThreadAlone() async {
        let sawMainThread = LockedFlag()
        let inventory = ApplicationInventory(
            scanner: { _ in
                sawMainThread.set(Thread.isMainThread)
                Thread.sleep(forTimeInterval: 0.05)
                return syntheticIndex(count: 400)
            },
            runningApplicationsProvider: { [] },
            baseDirectoriesProvider: { [] }
        )
        let clock = ContinuousClock()
        let start = clock.now
        inventory.rebuild()
        let returnedAfter = clock.now - start
        await settleIndex(inventory)

        reportMeasurement("索引构建（400 条）主线程阻塞 \(ms(returnedAfter))ms，总耗时 \(ms(clock.now - start))ms")
        #expect(!sawMainThread.value, "扫描跑到了主线程上")
        #expect(milliseconds(returnedAfter) < 5)
    }

    /// 关闭面板后不留活的查询——这条是资源验收，不是计时。
    @Test func noSpotlightQuerySurvivesClosingThePanel() {
        let harness = Harness()
        for _ in 0..<50 {
            harness.model.openPanel()
            harness.model.updateQuery("报告")
            harness.clock.fireAll()
            harness.model.closePanel()
        }
        #expect(harness.fileQuery.starts.count > 0)
        #expect(!harness.fileQuery.hasActiveQuery)
        #expect(harness.model.diagnosticObserverCount == 0)
        reportMeasurement("50 次开关后：发起 \(harness.fileQuery.starts.count) 次，终止 \(harness.fileQuery.cancelCount) 次，残留查询 0")
    }

    /// 模块自身的驻留成本：真实进程的 RSS 与物理足迹读数，开启前后、100 次开关峰值、停止之后。
    @Test func moduleMemoryFootprintStaysInsideItsBudget() async {
        let idle = processMemory()
        let harness = Harness()
        await harness.enable(entries: syntheticIndex(count: 400))
        let enabled = processMemory()

        var peakRSS = enabled.rssMB
        var peakFootprint = enabled.footprintMB
        for _ in 0..<100 {
            harness.model.openPanel()
            harness.model.updateQuery("应用")
            harness.clock.fireAll()
            harness.model.closePanel()
            let now = processMemory()
            peakRSS = max(peakRSS, now.rssMB)
            peakFootprint = max(peakFootprint, now.footprintMB)
        }
        harness.model.shutdown()
        let stopped = processMemory()

        reportMeasurement(String(format: """
            内存｜开启前 RSS %.1f/足迹 %.1f MB → 开启后 RSS %.1f/足迹 %.1f MB → \
            100 次开关峰值 RSS %.1f/足迹 %.1f MB → 停止后 RSS %.1f/足迹 %.1f MB
            """, idle.rssMB, idle.footprintMB, enabled.rssMB, enabled.footprintMB,
            peakRSS, peakFootprint, stopped.rssMB, stopped.footprintMB))
        #expect(peakRSS - enabled.rssMB <= 32)
        #expect(peakFootprint - enabled.footprintMB <= 32)
    }
}

/// `task_info` 的两个读数：常驻集大小与 Activity Monitor 口径的物理足迹。
struct ProcessMemory {
    let rssMB: Double
    let footprintMB: Double
}

private func processMemory() -> ProcessMemory {
    var rss: UInt64 = 0
    var footprint: UInt64 = 0

    var basic = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)
        / UInt32(MemoryLayout<integer_t>.size)
    withUnsafeMutablePointer(to: &basic) { raw in
        _ = raw.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
        }
    }
    rss = UInt64(basic.resident_size)

    var vm = task_vm_info()
    var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size)
        / UInt32(MemoryLayout<integer_t>.size)
    withUnsafeMutablePointer(to: &vm) { raw in
        _ = raw.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
        }
    }
    footprint = vm.phys_footprint

    return ProcessMemory(
        rssMB: Double(rss) / 1_048_576,
        footprintMB: Double(footprint) / 1_048_576
    )
}


/// 跨线程传一个 Bool，只为确认扫描器实际落在哪个线程。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}

// MARK: - 面板位置

@MainActor
struct QuickSearchPanelPositionTests {
    @Test func aDraggedPanelRemembersItsSpotAndWritesItOnce() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }

        harness.model.rememberPanelPosition(QuickSearchPanelPosition(x: 120, y: 700))
        #expect(harness.model.panelPosition == QuickSearchPanelPosition(x: 120, y: 700))
        #expect(persistCount == 1)

        // 一次拖布里 AppKit 会连发多次移动通知：同一点不该反复写配置。
        harness.model.rememberPanelPosition(QuickSearchPanelPosition(x: 120, y: 700))
        #expect(persistCount == 1)

        harness.model.rememberPanelPosition(QuickSearchPanelPosition(x: 140, y: 700))
        #expect(persistCount == 2)
    }

    @Test func anUnusablePositionIsRefusedInsteadOfStored() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }

        harness.model.rememberPanelPosition(QuickSearchPanelPosition(x: .nan, y: 700))

        #expect(harness.model.panelPosition == nil)
        #expect(persistCount == 0)
    }

    @Test func resettingClearsTheRecordAndReplacesTheOpenPanel() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        harness.model.openPanel()
        harness.model.rememberPanelPosition(QuickSearchPanelPosition(x: 120, y: 700))
        guard let panel = harness.lastPanel else {
            Issue.record("面板没有被创建")
            return
        }
        let placementsBefore = panel.placementCount

        harness.model.resetPanelPosition()

        #expect(harness.model.panelPosition == nil)
        // 用户点「回到默认位置」要立刻看到面板挪回去，而不是下次呼出生效。
        #expect(panel.placementCount == placementsBefore + 1)
    }

    @Test func resettingWithoutARememberedPositionChangesNothing() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }

        harness.model.resetPanelPosition()

        #expect(persistCount == 0)
    }
}

// MARK: - 面板尺寸

@MainActor
struct QuickSearchPanelSizeTests {
    @Test func aResizedPanelRemembersSizeAndPositionInOneWrite() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }

        harness.model.rememberPanelFrame(
            size: QuickSearchPanelSize(width: 760, height: 520),
            position: QuickSearchPanelPosition(x: 120, y: 700)
        )
        #expect(harness.model.panelSize == QuickSearchPanelSize(width: 760, height: 520))
        #expect(harness.model.panelPosition == QuickSearchPanelPosition(x: 120, y: 700))
        // 从左边/上边拖会同时改尺寸与原点：两个字段只写一次盘。
        #expect(persistCount == 1)

        harness.model.rememberPanelFrame(
            size: QuickSearchPanelSize(width: 760, height: 520),
            position: QuickSearchPanelPosition(x: 120, y: 700)
        )
        #expect(persistCount == 1)
    }

    @Test func anUnusableSizeIsRefusedInsteadOfStored() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }

        harness.model.rememberPanelFrame(
            size: QuickSearchPanelSize(width: .nan, height: 520),
            position: QuickSearchPanelPosition(x: 120, y: 700)
        )

        #expect(harness.model.panelSize == nil)
        #expect(harness.model.panelPosition == nil)
        #expect(persistCount == 0)
    }

    @Test func resettingTheSizeLeavesThePositionAndReplacesTheOpenPanel() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        harness.model.openPanel()
        harness.model.rememberPanelFrame(
            size: QuickSearchPanelSize(width: 760, height: 520),
            position: QuickSearchPanelPosition(x: 120, y: 700)
        )
        guard let panel = harness.lastPanel else {
            Issue.record("面板没有被创建")
            return
        }
        let placementsBefore = panel.placementCount

        harness.model.resetPanelSize()

        #expect(harness.model.panelSize == nil)
        // 只清尺寸：用户拖出来的位置还在。
        #expect(harness.model.panelPosition != nil)
        #expect(panel.placementCount == placementsBefore + 1)
    }

    @Test func resettingWithoutARememberedSizeChangesNothing() {
        let harness = Harness()
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }

        harness.model.resetPanelSize()

        #expect(persistCount == 0)
    }
}

// MARK: - 收藏与空查询那一屏

@MainActor
struct QuickSearchFavoritesModelTests {
    @Test func emptyQueryListsFavoritesBeforeRecentlyUsedApps() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        harness.model.usage.recordLaunch(of: sampleApps[1])
        harness.model.toggleFavorite(QuickSearchResult(application: sampleApps[0]))

        harness.model.openPanel()

        // 钉住的 Safari 排第一，「计算器」作为最近使用跟在后面。
        #expect(harness.model.results.map(\.title) == ["Safari", "计算器"])
        #expect(harness.model.isFavorite(harness.model.results[0]))
        #expect(!harness.model.isFavorite(harness.model.results[1]))
    }

    @Test func openingEmptyQueryDoesNotAddNewRunningApplicationsAsRows() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        harness.model.usage.recordLaunch(of: sampleApps[1])
        harness.model.toggleFavorite(QuickSearchResult(application: sampleApps[0]))
        // This app appears only after the initial index has settled.
        harness.scan.running = [QuickSearchRunningApplication(
            url: URL(fileURLWithPath: "/Users/me/Downloads/Beta.app"),
            bundleIdentifier: "com.test.beta",
            name: "Beta App"
        )]

        harness.model.openPanel()

        #expect(harness.model.applicationResults.map(\.title) == ["Safari", "计算器"])
        #expect(harness.inventory.entries.contains { $0.name == "Beta App" })
    }

    @Test func emptyQueryShowsFavoritesRecentsAndThenTheRestOfTheIndexUpToFifty() async {
        let apps = (0..<60).map { index in
            QuickSearchApplicationEntry(
                url: URL(fileURLWithPath: "/Applications/App\(index).app"),
                name: String(format: "App%02d", index),
                bundleIdentifier: "com.test.app\(index)"
            )
        }
        let harness = Harness()
        await harness.enable(entries: apps)
        defer { harness.model.shutdown() }
        harness.model.usage.recordLaunch(of: apps[59])
        harness.model.toggleFavorite(QuickSearchResult(application: apps[58]))

        harness.model.openPanel()

        let titles = harness.model.results.map(\.title)
        #expect(titles.count == QuickSearchLimits.emptyQueryApplications)
        // 收藏 → 最近使用 → 其余按索引名称顺序，且同一条不重复。
        #expect(Array(titles.prefix(3)) == ["App58", "App59", "App00"])
        #expect(titles.filter { $0 == "App58" }.count == 1)
        #expect(titles.last == "App47")
    }

    @Test func togglingFavoriteRedrawsTheEmptyQueryScreenThatIsAlreadyOpen() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        harness.model.openPanel()
        let target = QuickSearchResult(application: sampleApps[0])

        harness.model.toggleFavorite(target)
        // 收藏钉在最前，其余索引里的应用按名称补齐空查询那一屏。
        #expect(harness.model.results.map(\.title) == ["Safari", "计算器"])
        #expect(harness.model.settings.favorites.count == 1)

        harness.model.toggleFavorite(target)
        // 索引按系统 locale 排序，中英文混排的前后顺序随语言变化；这里只断言两条都在。
        #expect(harness.model.results.map(\.title).sorted() == ["Safari", "计算器"].sorted())
        #expect(harness.model.settings.favorites.isEmpty)
    }

    @Test func favoritingAResultRowRemembersItUnderItsOwnIdentity() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        var persistCount = 0
        harness.model.persist = { persistCount += 1 }
        harness.model.openPanel()
        harness.model.updateQuery("safari")
        guard let row = harness.model.results.first else {
            Issue.record("搜索 safari 没有结果")
            return
        }

        harness.model.toggleFavorite(row)

        #expect(harness.model.favoriteIdentities == [row.favoriteIdentity])
        #expect(harness.model.settings.favorites.first?.title == "Safari")
        #expect(persistCount == 1)
        // 右键收藏之后，这一行还在原位：不能因为重排把选中行弄丢。
        #expect(harness.model.results.first?.title == "Safari")
    }

    @Test func favoritesSurviveASettingsReload() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }
        let favorite = QuickSearchFavorite(result: QuickSearchResult(application: sampleApps[0]))

        harness.model.applyLoadedSettings(
            QuickSearchSettings(isEnabled: true, hotkey: Harness.quietHotkey, favorites: [favorite])
        )
        harness.model.openPanel()

        // 钉住的 Safari 排第一，其余索引里的应用按名称补齐。
        #expect(harness.model.results.map(\.title) == ["Safari", "计算器"])
    }

    @Test func openingAFileCountsAsOneUseAndSortsAheadNextTime() async {
        let harness = Harness()
        await harness.enable(entries: [])
        defer { harness.model.shutdown() }
        let hits = [fileHit("/Users/me/Desktop/a-报告.pdf"), fileHit("/Users/me/Desktop/b-报告.pdf")]

        harness.model.openPanel()
        harness.model.updateQuery("报告")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: hits, isFinal: true, issue: nil))
        let second = harness.model.fileResults.first(where: { $0.url.lastPathComponent.hasPrefix("b") })
        guard let target = second else {
            Issue.record("文件结果里没有 b-报告.pdf")
            return
        }

        harness.model.performPrimaryAction(on: target)
        #expect(harness.fileOpener.opened.map(\.lastPathComponent) == ["b-报告.pdf"])
        #expect(harness.model.usage.count(forIdentity: target.favoriteIdentity) == 1)

        // 下一次同样的查询，Spotlight 回来的顺序没变，但打开过的那条提到最前。
        harness.model.openPanel()
        harness.model.updateQuery("报告")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: hits, isFinal: true, issue: nil))
        #expect(harness.model.fileResults.first?.url.lastPathComponent == "b-报告.pdf")
    }

    @Test func aFailedFileOpenDoesNotCountAsAUse() async {
        let harness = Harness()
        await harness.enable(entries: [])
        defer { harness.model.shutdown() }
        harness.fileOpener.failure = .openFailed(name: "a-报告.pdf")

        harness.model.openPanel()
        harness.model.updateQuery("报告")
        harness.clock.fireAll()
        harness.fileQuery.deliverLatest(.results(hits: [fileHit("/Users/me/Desktop/a-报告.pdf")], isFinal: true, issue: nil))
        harness.model.performPrimaryAction(on: harness.model.fileResults.first)

        #expect(harness.model.usage.recordCount == 0)
        #expect(harness.notice.presented.count == 1)
    }
}

// MARK: - 真实窗口的落位

@MainActor
struct QuickSearchRealPanelPlacementTests {
    /// 只创建窗口、不 order-front：与性能套件同一做法，不会在用户桌面上闪出面板。
    /// 纯函数那边已经证明算得对，这里要证的是真的窗口按算出来的 frame 落了位。
    @Test func theWindowLandsOnTheRememberedSpotAndComesBackAfterAReset() throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        let panel = QuickSearchPanel(model: harness.model, onClose: {})
        defer { panel.close() }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            throw MissingScreenError()
        }

        // 钉在可见区里、离边 40pt 的一个点：不管用户的屏幕多大都放得下。
        let saved = QuickSearchPanelPosition(x: visible.minX + 40, y: visible.maxY - 40)
        harness.model.rememberPanelPosition(saved)
        panel.applyPlacement()

        #expect(abs(panel.frame.minX - saved.x) < 1)
        // 存的是左上角，还原之后上沿必须还是那个上沿。
        #expect(abs(panel.frame.maxY - saved.y) < 1)

        harness.model.resetPanelPosition()
        panel.applyPlacement()

        #expect(harness.model.panelPosition == nil)
        // 回到默认位置：整块面板必须仍在可见区内，不靠具体的居中数值。
        let screen = try #require((panel.screen ?? NSScreen.main)?.visibleFrame)
        #expect(screen.insetBy(dx: -1, dy: -1).contains(panel.frame))
    }

    @Test func theWindowTakesTheRememberedSizeAndReturnsToTheRowHeightAfterAReset() throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        let panel = QuickSearchPanel(model: harness.model, onClose: {})
        defer { panel.close() }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            throw MissingScreenError()
        }

        let savedSize = QuickSearchPanelSize(width: 760, height: 520)
        let savedPosition = QuickSearchPanelPosition(x: visible.minX + 40, y: visible.maxY - 40)
        harness.model.rememberPanelFrame(size: savedSize, position: savedPosition)
        panel.applyPlacement()

        let expected = QuickSearchPanelLayout.size(rowCount: 0, savedSize: savedSize, visibleFrame: visible)
        #expect(abs(panel.frame.width - expected.width) < 1)
        #expect(abs(panel.frame.height - expected.height) < 1)
        #expect(abs(panel.frame.maxY - savedPosition.y) < 1)

        harness.model.resetPanelSize()
        panel.applyPlacement()

        #expect(harness.model.panelSize == nil)
        // 尺寸清掉之后高度重新跟着结果行数走。
        let rowDrivenHeight = QuickSearchPanelLayout.size(rowCount: 0, visibleFrame: visible).height
        #expect(abs(panel.frame.height - rowDrivenHeight) < 1)
    }

    @Test func draggingTheRightBorderResizesAndSavesTheSize() throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        let panel = QuickSearchPanel(model: harness.model, onClose: {})
        defer { panel.close() }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            throw MissingScreenError()
        }

        harness.model.rememberPanelFrame(
            size: QuickSearchPanelSize(width: 620, height: 420),
            position: QuickSearchPanelPosition(x: visible.minX + 40, y: visible.maxY - 40)
        )
        panel.applyPlacement()
        panel.contentView?.layoutSubtreeIfNeeded()

        // 直接用 SwiftUI 覆盖层里的那一个，顺带证明它真的挂进了面板、铺满了内容区。
        let handle = try #require(firstResizeView(in: panel.contentView))
        #expect(abs(handle.frame.width - panel.contentLayoutRect.width) < 1)
        #expect(abs(handle.frame.height - panel.contentLayoutRect.height) < 1)

        // 中间的内容区照常穿透，只有边框带接住鼠标。
        #expect(handle.hitTest(NSPoint(x: handle.frame.midX, y: handle.frame.midY)) == nil)
        #expect(handle.hitTest(NSPoint(x: handle.frame.maxX - 1, y: handle.frame.midY)) === handle)

        let startFrame = panel.frame
        let edgePoint = NSPoint(x: startFrame.width - 1, y: startFrame.height / 2)
        let dragPoint = NSPoint(x: edgePoint.x + 60, y: edgePoint.y)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: edgePoint, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        handle.mouseDown(with: down)
        let drag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: dragPoint, modifierFlags: [],
            timestamp: 0.1, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1
        ))
        handle.mouseDragged(with: drag)
        #expect(abs(panel.frame.width - (startFrame.width + 60)) < 1)

        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: dragPoint, modifierFlags: [],
            timestamp: 0.2, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 3, clickCount: 1, pressure: 0
        ))
        handle.mouseUp(with: up)

        // 松手才落盘，且拖右边不改左沿。
        #expect(abs((harness.model.panelSize?.width ?? 0) - Double(panel.frame.width)) < 1)
        #expect(abs(panel.frame.minX - startFrame.minX) < 1)
    }

    /// 抓手必须真的挂在顶部搜索行里。以前它独占一条 16pt 顶栏，输入框上方
    /// 空出一条明显的「大额头」；这条测试把面板上沿的留白钉在 10pt。
    @Test func theDragGripSitsInTheTopSearchRow() throws {
        let harness = Harness()
        defer { harness.model.shutdown() }
        let panel = QuickSearchPanel(model: harness.model, onClose: {})
        defer { panel.close() }
        panel.applyPlacement()
        panel.contentView?.layoutSubtreeIfNeeded()

        let contentView = try #require(panel.contentView)
        let grip = try #require(firstDragHandle(in: contentView))
        let frame = grip.convert(grip.bounds, to: contentView)
        // NSHostingView 是翻转坐标系（原点在左上），上沿距离就是 minY。
        let topInset = contentView.isFlipped
            ? frame.minY
            : contentView.bounds.height - frame.maxY

        #expect(abs(topInset - QuickSearchPanelLayout.searchRowTopPadding) < 1)
        #expect(abs(frame.height - QuickSearchPanelLayout.searchRowHeight) < 1)
        #expect(frame.minX < 80)
    }

    private func firstResizeView(in view: NSView?) -> QuickSearchPanelResizeView? {
        guard let view else { return nil }
        if let match = view as? QuickSearchPanelResizeView { return match }
        for subview in view.subviews {
            if let match = firstResizeView(in: subview) { return match }
        }
        return nil
    }

    private func firstDragHandle(in view: NSView?) -> QuickSearchDragHandleView? {
        guard let view else { return nil }
        if let match = view as? QuickSearchDragHandleView { return match }
        for subview in view.subviews {
            if let match = firstDragHandle(in: subview) { return match }
        }
        return nil
    }

    private struct MissingScreenError: Error {}
}

// MARK: - 匹配范围

/// 「只匹配名称 / 名称 + 用途」这一档设置在面板上的实际效果。
/// 索引仍然来自注入的假扫描器，不读用户的 /Applications。
@MainActor
struct QuickSearchMatchScopeModelTests {
    @Test func switchingTheMatchScopeReappliesTheQueryAlreadyOnScreen() async {
        let harness = Harness()
        let downloader = QuickSearchApplicationEntry(
            url: URL(fileURLWithPath: "/Applications/Motrix.app"),
            name: "Motrix",
            bundleIdentifier: "com.test.motrix",
            tags: ["下载", "download"]
        )
        await harness.enable(entries: [downloader] + sampleApps)
        defer { harness.model.shutdown() }

        harness.model.openPanel()
        harness.model.updateQuery("下载")
        harness.clock.fireAll()
        #expect(harness.model.results.map(\.title) == ["Motrix"])

        // 关掉用途匹配：这一条得当场消失，而不是等用户重打一遍。
        harness.model.setMatchScope(.nameOnly)
        #expect(harness.model.results.isEmpty)
        #expect(harness.model.settings.matchScope == .nameOnly)

        harness.model.setMatchScope(.nameAndPurpose)
        #expect(harness.model.results.map(\.title) == ["Motrix"])
    }

    @Test func anEmptyQueryIsNotReRunWhenTheMatchScopeChanges() async {
        let harness = Harness()
        await harness.enable(entries: sampleApps)
        defer { harness.model.shutdown() }

        harness.model.usage.recordLaunch(of: sampleApps[0])
        harness.model.openPanel()
        harness.model.setMatchScope(.nameOnly)

        // 空查询那一屏是收藏、最近使用与索引补齐，跟匹配范围无关，不该被改成空白。
        #expect(harness.model.results.map(\.title) == ["Safari", "计算器"])
    }
}
