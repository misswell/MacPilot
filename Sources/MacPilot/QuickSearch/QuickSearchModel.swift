//
//  QuickSearchModel.swift
//  MacPilot
//
//  快速搜索的功能模型：生命周期、设置、全局快捷键、面板控制、应用启动与文件打开。
//
//  三条硬约束：
//  1. 初始化阶段不同步扫盘、不建 UI、不起 Spotlight——都在 start() 之后按需发生；
//  2. 每次搜索带递增 generation，旧查询的结果不能覆盖新结果，面板关闭即失效；
//  3. stop() 必须同步完成清理，`willTerminate` 不会等异步 Task。
//

import AppKit
import Combine
import Foundation
import MacPilotDockGroupsCore
import os

// MARK: - 可注入的外部动作

/// 启动/激活应用。默认实现直接调用 Dock Groups 已有的 `AppLaunchService`，
/// 这里只负责把它的错误翻译成可显示的失败原因。
@MainActor
protocol QuickSearchLaunching: AnyObject {
    /// 成功返回 nil；失败返回原因。
    func open(applicationAt url: URL, name: String) async -> QuickSearchFailure?
}

/// 打开文件与在 Finder 中显示。
@MainActor
protocol QuickSearchFileOpening: AnyObject {
    func open(_ url: URL) -> QuickSearchFailure?
    func revealInFinder(_ url: URL) -> QuickSearchFailure?
}

/// 目标是否还在。打开前先确认，卸载/移动/删除不该表现为「一切正常」。
@MainActor
protocol QuickSearchItemAvailability: AnyObject {
    func exists(at url: URL) -> Bool
}

enum QuickSearchFailure: Equatable, Sendable {
    case applicationMissing(name: String)
    case launchFailed(name: String)
    case itemMissing(name: String)
    case openFailed(name: String)
    case revealFailed(name: String)
    case cloudItemUnavailable(name: String)

    var messageKey: String {
        switch self {
        case .applicationMissing: "quickSearchErrorApplicationMissing"
        case .launchFailed: "quickSearchErrorLaunchFailed"
        case .itemMissing: "quickSearchErrorItemMissing"
        case .openFailed: "quickSearchErrorOpenFailed"
        case .revealFailed: "quickSearchErrorRevealFailed"
        case .cloudItemUnavailable: "quickSearchErrorCloudUnavailable"
        }
    }

    var argument: String {
        switch self {
        case .applicationMissing(let name), .launchFailed(let name), .itemMissing(let name),
             .openFailed(let name), .revealFailed(let name), .cloudItemUnavailable(let name):
            return name
        }
    }
}

/// 悬停选中的闸门：呼出面板时指针若已经停在结果区，面板一出现就会补一条
/// hover 事件；用户还没移动指针，那不是选择意图。记住呼出位置，直到指针真的
/// 离开这里才允许悬停改动选中行。
struct QuickSearchHoverGate {
    private var summonLocation: NSPoint?

    mutating func arm(at location: NSPoint) {
        summonLocation = location
    }

    mutating func disarm() {
        summonLocation = nil
    }

    mutating func allowsSelection(at location: NSPoint) -> Bool {
        guard let summonLocation else { return true }
        guard location != summonLocation else { return false }
        self.summonLocation = nil
        return true
    }
}

// MARK: - 模型

@MainActor
final class QuickSearchModel: ObservableObject, ManagedFeature, FeatureResourceReporting {
    /// 功能本身的运行状态。
    enum RuntimeState: Equatable {
        case disabled
        case starting
        case ready
        case stopping
    }

    /// 面板的显示状态。**与运行状态分开**：功能在跑不代表面板开着，面板开着也不代表
    /// 正在搜索。
    enum Presentation: Equatable {
        case hidden
        case visible
    }

    /// 文件查询的进行状态。
    enum SearchPhase: Equatable {
        case idle
        case debouncing
        case queryingSpotlight
    }

    /// 设置页与诊断要展示的合并视图（AGENTS.md「生命周期状态」一节）。
    enum LifecycleState: Equatable {
        case disabled, starting, ready, presenting, searching, stopping
    }

    let identifier = "quickSearch"
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "QuickSearch")

    @Published private(set) var settings = QuickSearchSettings()
    @Published private(set) var runtimeState: RuntimeState = .disabled
    @Published private(set) var presentation: Presentation = .hidden
    @Published private(set) var searchPhase: SearchPhase = .idle
    @Published private(set) var query = ""
    @Published private(set) var applicationResults: [QuickSearchResult] = []
    @Published private(set) var fileResults: [QuickSearchResult] = []
    @Published private(set) var selectedRowIndex: Int = 0
    /// 只有键盘导航才让列表跟着滚动。悬停也会改选中行，但此时滚到中间会把
    /// 指针下方换成另一行，再触发一次悬停选中——在下半屏会变成来回跳动。
    @Published private(set) var selectionScrollToken = 0
    /// Spotlight 查不了的原因。有值时必须显示出来，不能显示成「没有结果」。
    @Published private(set) var fileSearchIssue: QuickSearchIndexIssue?
    /// 快捷键注册或清理的错误/警告；实际注册状态由 `isHotKeyRegistered` 表示。
    @Published private(set) var hotKeyError: QuickSearchHotKeyError?
    /// 一次性错误提示（面板已关闭后的失败反馈）。
    @Published private(set) var transientNotice: String?
    @Published private(set) var indexState: ApplicationInventory.State = .empty
    @Published private(set) var indexEntryCount = 0

    var language: AppLanguage = .system
    var persist: (() -> Void)?
    /// 由 MacPilotModel 注入：这个组合是否已被 MacPilot 内其它功能占用。
    var shortcutConflictChecker: (@MainActor (SmartCaptureShortcutBinding) -> String?)?
    /// 由测试注入：用不显示真实窗口的替身验证生命周期，避免自动化测试抢占用户焦点。
    var panelFactory: (@MainActor (@escaping () -> Void) -> QuickSearchPanelPresenting)?
    /// 由测试注入：失败提示同样是一个真窗口，测试里不该在用户桌面上闪一下。
    var noticePanelFactory: (@MainActor () -> QuickSearchNoticePresenting)?
    /// 由测试注入：手动放行文件查询防抖。同一进程里其它 @MainActor 套件会把主 Actor
    /// 队列堵上一两分钟，靠墙钟计时的用例在那种环境下只会误报。
    var fileDebounceScheduler: (@MainActor (Duration, @escaping @MainActor () -> Void) -> Void)?
    /// 由测试注入：读取当前指针位置。默认是真实的系统鼠标位置。
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    let inventory: ApplicationInventory
    let icons: QuickSearchIconLoader
    let usage: QuickSearchUsageStore

    private let fileQuery: QuickSearchFileQuerying
    private let scopeProbe: SpotlightScopeProbing
    private let launcher: QuickSearchLaunching
    private let fileOpener: QuickSearchFileOpening
    private let availability: QuickSearchItemAvailability
    private let hotKeyCenter: QuickSearchHotKeyCenter
    private let fileDebounceTask = BackgroundTask()
    private let noticeDismissTask = BackgroundTask()

    private var panel: QuickSearchPanelPresenting?
    private var noticePanel: QuickSearchNoticePresenting?
    private var searchGeneration = 0
    private var hoverGate = QuickSearchHoverGate()

    var isRunning: Bool { runtimeState == .ready || runtimeState == .starting }
    var isPanelVisible: Bool { presentation == .visible }
    /// 快捷键此刻到底注册上了没有。设置页用它说明「能用」还是「不能用」，
    /// 而不是只看有没有报错——注册失败却显示成正常启用是最糟的假状态。
    var isHotKeyRegistered: Bool { hotKeyCenter.isRegistered }

    // MARK: 位置与收藏（设置的只读视图）

    /// 记住的面板左上角。nil 表示用户没拖过（或已回到默认位置）。
    var panelPosition: QuickSearchPanelPosition? { settings.panelPosition }

    /// 记住的面板尺寸。nil 表示用户没拖过边框，高度继续跟着结果行数走。
    var panelSize: QuickSearchPanelSize? { settings.panelSize }

    /// 收藏的归并键。视图据此画星标、决定右键菜单写「添加」还是「移除」。
    /// 只有一份真实来源（`settings.favorites`），这里只是把判断做成集合。
    var favoriteIdentities: Set<String> { Set(settings.favorites.map(\.identity)) }

    func isFavorite(_ result: QuickSearchResult) -> Bool {
        favoriteIdentities.contains(result.favoriteIdentity)
    }

    /// 面板显示的行：应用在前、文件在后。空查询那一屏最多 50 个应用，
    /// 输入关键字之后仍按原上界截断。
    /// 计算属性每次求值顺序一致，选中下标始终指向同一行。
    var results: [QuickSearchResult] {
        let limit = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? QuickSearchLimits.emptyQueryApplications
            : QuickSearchLimits.visibleResults
        return Array((applicationResults + fileResults).prefix(limit))
    }

    var lifecycleState: LifecycleState {
        switch runtimeState {
        case .disabled: return .disabled
        case .starting: return .starting
        case .stopping: return .stopping
        case .ready:
            if searchPhase != .idle { return .searching }
            return presentation == .visible ? .presenting : .ready
        }
    }

    var diagnosticTaskCount: Int {
        (fileDebounceTask.isRunning ? 1 : 0)
            + (noticeDismissTask.isRunning ? 1 : 0)
            + (inventory.isScanning ? 1 : 0)
            + icons.diagnosticTaskCount
    }
    var diagnosticObserverCount: Int { fileQuery.trackedObserverCount }

    init(
        inventory: ApplicationInventory? = nil,
        icons: QuickSearchIconLoader? = nil,
        usage: QuickSearchUsageStore? = nil,
        fileQuery: QuickSearchFileQuerying? = nil,
        scopeProbe: SpotlightScopeProbing? = nil,
        launcher: QuickSearchLaunching? = nil,
        fileOpener: QuickSearchFileOpening? = nil,
        availability: QuickSearchItemAvailability? = nil,
        hotKeyCenter: QuickSearchHotKeyCenter? = nil
    ) {
        let inventory = inventory ?? ApplicationInventory()
        self.inventory = inventory
        self.hotKeyCenter = hotKeyCenter ?? QuickSearchHotKeyCenter()
        self.icons = icons ?? QuickSearchIconLoader()
        self.usage = usage ?? QuickSearchUsageStore()
        let probe = scopeProbe ?? SystemSpotlightScopeProbe()
        self.scopeProbe = probe
        // 默认查询器与探测用同一个 scope 来源，避免两边判断对不上。
        self.fileQuery = fileQuery ?? SpotlightFileSearchController(scopeProbe: probe)
        self.launcher = launcher ?? SystemApplicationLauncher()
        self.fileOpener = fileOpener ?? SystemFileOpener()
        self.availability = availability ?? FileSystemItemAvailability()
        // 后台构建落地时刷新计数，并把当前查询补上：首次呼出时索引往往还在建。
        inventory.onIndexRebuilt = { [weak self] in self?.handleIndexRebuilt() }
    }

    /// 索引构建完成：刷新展示计数；面板开着时按当前输入重跑一次应用搜索。
    private func handleIndexRebuilt() {
        publishIndexState()
        guard presentation == .visible else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showFavoritesAndRecents()
        } else {
            runApplicationSearch()
        }
        trimSelectionIndex()
    }

    // MARK: - ManagedFeature

    func start() {
        guard runtimeState == .disabled || runtimeState == .stopping else { return }
        runtimeState = .starting
        hotKeyCenter.conflictChecker = shortcutConflictChecker
        hotKeyCenter.onToggle = { [weak self] in self?.togglePanel() }
        hotKeyError = hotKeyCenter.updateBinding(settings.hotkey) ?? hotKeyCenter.lastError
        icons.startMemoryPressureHandling()
        inventory.extraDirectories = settings.customDirectoryPaths
        runtimeState = .ready
        indexState = inventory.state
    }

    func stop() { shutdown() }

    /// 同步清理：快捷键、查询、面板、索引缓存、图标缓存全部当场归还。
    func shutdown() {
        guard runtimeState != .disabled else {
            hotKeyCenter.stop()
            hotKeyError = hotKeyCenter.lastError
            closePanel()
            return
        }
        runtimeState = .stopping
        invalidateFileSearch()
        hotKeyCenter.stop()
        hotKeyError = hotKeyCenter.lastError
        closePanel()
        dismissNoticeNow()
        clearResults(keepIndex: false)
        inventory.shutdown()
        icons.stop()
        searchPhase = .idle
        presentation = .hidden
        runtimeState = .disabled
        indexState = inventory.state
        indexEntryCount = 0
    }

    func applyLoadedSettings(_ loaded: QuickSearchSettings, activate: Bool = false) {
        settings = loaded
        inventory.extraDirectories = loaded.customDirectoryPaths
        if activate && loaded.isEnabled { start() }
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    // MARK: - 设置改动

    /// 首页开关的运行时镜像。
    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            start()
        } else {
            shutdown()
        }
        persist?()
    }

    /// 改快捷键。无效或注册失败都保留原绑定并说明原因——不能悄悄改掉用户的选择。
    func setHotkey(_ binding: SmartCaptureShortcutBinding) {
        let bindingChanged = binding != settings.hotkey
        guard bindingChanged || hotKeyError != nil || hotKeyCenter.lastError != nil else { return }
        guard binding.isValid else {
            hotKeyError = .invalidBinding
            return
        }
        if isRunning {
            hotKeyCenter.conflictChecker = shortcutConflictChecker
            let error = hotKeyCenter.updateBinding(binding)
            hotKeyError = error ?? hotKeyCenter.lastError
            guard error == nil else { return }
            if bindingChanged { settings.hotkey = binding }
        } else {
            hotKeyCenter.stop()
            guard !hotKeyCenter.hasUnreleasedHotKeys else {
                hotKeyError = hotKeyCenter.lastError
                return
            }
            if bindingChanged { settings.hotkey = binding }
            hotKeyError = hotKeyCenter.lastError
        }
        if bindingChanged { persist?() }
    }

    func setFileScope(_ scope: QuickSearchFileScope) {
        guard settings.fileScope != scope else { return }
        settings.fileScope = scope
        fileSearchIssue = nil
        persist?()
    }

    /// 匹配范围改完立刻重出当前这屏：还得删一个字才生效的话，用户会以为开关没起作用。
    func setMatchScope(_ scope: QuickSearchMatchScope) {
        guard settings.matchScope != scope else { return }
        settings.matchScope = scope
        persist?()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        runApplicationSearch()
    }

    func addCustomDirectory(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !standardized.isEmpty, !settings.customDirectoryPaths.contains(standardized) else { return }
        var paths = settings.customDirectoryPaths
        paths.append(standardized)
        if paths.count > QuickSearchLimits.customDirectories {
            paths = Array(paths.sorted().prefix(QuickSearchLimits.customDirectories))
        } else {
            paths.sort()
        }
        settings.customDirectoryPaths = paths
        inventory.extraDirectories = paths
        persist?()
    }

    func removeCustomDirectory(path: String) {
        guard settings.customDirectoryPaths.contains(path) else { return }
        settings.customDirectoryPaths.removeAll { $0 == path }
        inventory.extraDirectories = settings.customDirectoryPaths
        persist?()
    }

    /// 手动刷新应用列表。
    func refreshApplicationIndex() {
        guard isRunning else { return }
        inventory.rebuild()
        indexState = inventory.state
    }

    /// 拖动结束后记下左上角。位置没变就不写盘：AppKit 在一次拖布里可能连发多次
    /// `windowDidMove`，每次都改设置会把配置文件刷成噪声。
    func rememberPanelPosition(_ position: QuickSearchPanelPosition) {
        guard position.isFinite, position != settings.panelPosition else { return }
        settings.panelPosition = position
        persist?()
    }

    /// 「回到默认位置」：清掉记录，面板立刻按默认落点重摆一次。
    func resetPanelPosition() {
        guard settings.panelPosition != nil else { return }
        settings.panelPosition = nil
        persist?()
        panel?.applyPlacement()
    }

    /// 拖完边框记下尺寸与左上角。从左边/上边拖会同时移动原点，
    /// 所以两个字段一起提交、只写一次盘；完全没变则不写。
    func rememberPanelFrame(size: QuickSearchPanelSize, position: QuickSearchPanelPosition) {
        guard size.isFinite, position.isFinite else { return }
        guard size != settings.panelSize || position != settings.panelPosition else { return }
        settings.panelSize = size
        settings.panelPosition = position
        persist?()
    }

    /// 「回到默认大小」：清掉记录的尺寸，高度重新跟着结果行数走。
    func resetPanelSize() {
        guard settings.panelSize != nil else { return }
        settings.panelSize = nil
        persist?()
        panel?.applyPlacement()
    }

    /// 右键菜单的收藏开关。加满时挤掉最早钉住的那一条（规则在 `QuickSearchFavorites`）。
    func toggleFavorite(_ result: QuickSearchResult) {
        let identity = result.favoriteIdentity
        if QuickSearchFavorites.contains(identity: identity, in: settings.favorites) {
            settings.favorites = QuickSearchFavorites.remove(identity: identity, from: settings.favorites)
        } else {
            settings.favorites = QuickSearchFavorites.add(
                QuickSearchFavorite(result: result),
                to: settings.favorites,
                limit: QuickSearchLimits.favorites
            )
        }
        persist?()
        // 空查询那一屏的首列就是收藏，增减之后要立刻重排，否则看着像没生效。
        if presentation == .visible, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showFavoritesAndRecents()
        }
    }

    // MARK: - 面板

    func togglePanel() {
        if isPanelVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        guard settings.isEnabled, runtimeState == .ready else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        query = ""
        selectedRowIndex = 0
        fileSearchIssue = nil
        // 上一次没取到的图标在这里重新排队：图标服务短暂失败不该让占位符
        // 赖到整个进程结束。已缓存的图标继续命中，不会重取。
        icons.retryUnresolvedIcons()
        showFavoritesAndRecents()
        inventory.syncRunningState()
        inventory.refreshIfStale()
        publishIndexState()
        // 先记下呼出时指针在哪：面板可能正好落在指针下面，随后补发的悬停
        // 事件不能替用户做选择。指针真的移动之后闸门才放行。
        hoverGate.arm(at: pointerLocation())
        presentation = .visible
        panel.open()
    }

    func closePanel() {
        hoverGate.disarm()
        invalidateFileSearch()
        panel?.close()
        panel = nil
        if presentation == .visible { presentation = .hidden }
        // 面板关掉只收起 UI：轻量应用索引留着，下次呼出直接可用。
        clearResults(keepIndex: true)
        query = ""
        selectedRowIndex = 0
    }

    private func makePanel() -> QuickSearchPanelPresenting {
        let close: () -> Void = { [weak self] in
            guard let self else { return }
            self.handlePanelClosed()
        }
        if let panelFactory { return panelFactory(close) }
        return QuickSearchPanel(model: self, onClose: close)
    }

    private func handlePanelClosed() {
        hoverGate.disarm()
        invalidateFileSearch()
        panel = nil
        if presentation == .visible { presentation = .hidden }
        clearResults(keepIndex: true)
        query = ""
        selectedRowIndex = 0
    }

    // MARK: - 搜索

    /// 输入变化：应用结果立刻出（走内存索引），文件查询进防抖。
    func updateQuery(_ text: String) {
        searchGeneration &+= 1
        query = text
        selectedRowIndex = 0
        fileDebounceTask.stop()
        fileQuery.cancelActiveQuery()
        fileResults = []
        fileSearchIssue = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchPhase = .idle
            showFavoritesAndRecents()
            return
        }
        runApplicationSearch()
        scheduleFileSearch(for: text)
    }

    private func runApplicationSearch() {
        applicationResults = ApplicationSearchProvider.search(
            query: query,
            entries: inventory.entries,
            usage: { [weak self] entry in self?.usage.count(for: entry) ?? 0 },
            includeTags: settings.matchesPurposeTags,
            limit: QuickSearchLimits.applicationResults
        )
    }

    private func showFavoritesAndRecents() {
        let recents = ApplicationSearchProvider.recentApplications(
            entries: inventory.entries,
            recentIdentities: usage.recentIdentities(limit: QuickSearchLimits.emptyQueryApplications),
            limit: QuickSearchLimits.emptyQueryApplications
        )
        applicationResults = QuickSearchFavorites.rows(
            favorites: QuickSearchFavorites.ordered(settings.favorites) {
                usage.count(forIdentity: $0.identity)
            },
            entries: inventory.entries,
            recent: recents,
            favoriteLimit: QuickSearchLimits.favoritesOnEmptyQuery,
            totalLimit: QuickSearchLimits.emptyQueryApplications
        )
        fileResults = []
    }

    private func scheduleFileSearch(for text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        fileDebounceTask.stop()
        guard term.count >= QuickSearchLimits.minimumFileQueryCharacters else {
            // 单字符交给 Spotlight 会是海量结果；直接不给文件结果。
            fileResults = []
            fileSearchIssue = nil
            searchPhase = .idle
            return
        }
        searchPhase = .debouncing
        let generation = searchGeneration
        let delay = Duration.milliseconds(QuickSearchLimits.debounceMilliseconds)
        let work: @MainActor () -> Void = { [weak self] in
            self?.startFileSearch(generation: generation, term: term)
        }
        if let fileDebounceScheduler {
            // 过期generation由 startFileSearch 自己判掉：这里放行的是「登记过的每一次输入」。
            fileDebounceScheduler(delay, work)
            return
        }
        fileDebounceTask.startOnce(after: delay, action: work)
    }

    private func startFileSearch(generation: Int, term: String) {
        guard isRunning, presentation == .visible, generation == searchGeneration else { return }
        let scopes = scopeProbe.scopes(for: settings)
        // 范围不可用时不发起查询：让 Spotlight 自己兜底会悄悄扩大到用户没选的地方，
        // 之后那句「没有匹配的文件」就成了假话。这里直接说明原因。
        guard !scopes.isEmpty else {
            fileResults = []
            fileSearchIssue = .noScopeSelected
            searchPhase = .idle
            return
        }
        searchPhase = .queryingSpotlight
        fileQuery.start(
            generation: generation,
            request: QuickSearchFileQueryRequest(
                term: term,
                scopes: scopes,
                resultLimit: QuickSearchLimits.spotlightResults
            )
        ) { [weak self] returnedGeneration, outcome in
            self?.receive(outcome, generation: returnedGeneration)
        }
    }

    private func receive(_ outcome: QuickSearchFileQueryOutcome, generation: Int) {
        // 只处理当前这一次查询：旧查询晚到的结果不能覆盖新结果。
        guard isRunning, presentation == .visible, generation == searchGeneration else { return }
        switch outcome {
        case .results(let hits, let isFinal, let issue):
            // 先按打开次数提一遍再截断：Spotlight 排在第 60 位但天天开的文件，
            // 不该因为它的默认次序被挤出这一屏。次数相同的保持 Spotlight 的顺序。
            let ordered = QuickSearchFrequencyOrder.ordered(
                hits.map { QuickSearchResult(file: $0) }
            ) {
                usage.count(forIdentity: $0.favoriteIdentity)
            }
            fileResults = Array(ordered.prefix(QuickSearchLimits.visibleResults))
            fileSearchIssue = issue
            searchPhase = isFinal ? .idle : .queryingSpotlight
        case .failed(let issue):
            fileResults = []
            fileSearchIssue = issue
            searchPhase = .idle
        case .cancelled:
            searchPhase = .idle
        }
        trimSelectionIndex()
    }

    private func invalidateFileSearch() {
        searchGeneration &+= 1
        fileDebounceTask.stop()
        fileQuery.cancelActiveQuery()
        searchPhase = .idle
    }

    private func clearResults(keepIndex: Bool) {
        applicationResults = []
        fileResults = []
        fileSearchIssue = nil
        if !keepIndex { indexEntryCount = 0 }
    }

    func publishIndexState() {
        indexState = inventory.state
        indexEntryCount = inventory.entryCount
    }

    // MARK: - 选择与执行

    func moveSelection(by delta: Int) {
        let rows = results.count
        guard rows > 0 else { selectedRowIndex = 0; return }
        selectedRowIndex = min(max(selectedRowIndex + delta, 0), rows - 1)
        selectionScrollToken &+= 1
    }

    /// 鼠标悬停/点击直接指定行。越界下标不改变当前选择。
    /// 指针选中不请求滚动：滚动会改变指针下的行，反过来再选中，形成抖动。
    func selectRow(at index: Int) {
        guard results.indices.contains(index), index != selectedRowIndex else { return }
        selectedRowIndex = index
    }

    /// 悬停选中只认指针真实的移动。呼出面板时指针若正压在结果区，面板出现
    /// 补发的 hover 不该把选中行从第一行挪走；移动之后同一行内的连续悬停
    /// 也照常接管。
    func selectRowByHover(at index: Int) {
        guard hoverGate.allowsSelection(at: pointerLocation()) else { return }
        selectRow(at: index)
    }

    private func trimSelectionIndex() {
        selectedRowIndex = min(selectedRowIndex, max(results.count - 1, 0))
    }

    var currentSelection: QuickSearchResult? {
        guard results.indices.contains(selectedRowIndex) else { return nil }
        return results[selectedRowIndex]
    }

    /// Enter：应用启动/激活，文件打开。
    func performPrimaryAction(on result: QuickSearchResult? = nil) {
        guard let target = result ?? currentSelection else { return }
        let displayName = target.title
        guard availability.exists(at: target.url) else {
            closePanel()
            presentNotice(t("quickSearchErrorItemMissing", displayName))
            return
        }
        // 先收面板，再执行：启动过程不该被一个还悬在前台的搜索框挡住。
        closePanel()
        switch target.kind {
        case .application:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure = await self.launcher.open(applicationAt: target.url, name: displayName) {
                    self.presentNotice(self.t(failure.messageKey, failure.argument))
                    return
                }
                self.recordUsage(of: target)
            }
        case .file, .folder:
            if let failure = fileOpener.open(target.url) {
                presentNotice(t(failure.messageKey, failure.argument))
            } else {
                // 文件也计入使用次数：下次搜同一个词时，打开过的排在前面。
                usage.recordLaunch(
                    identity: target.favoriteIdentity,
                    path: target.url.standardizedFileURL.path
                )
            }
        }
    }

    /// Command + Enter：在 Finder 中显示。
    func revealSelectionInFinder(on result: QuickSearchResult? = nil) {
        guard let target = result ?? currentSelection else { return }
        let displayName = target.title
        guard availability.exists(at: target.url) else {
            closePanel()
            presentNotice(t("quickSearchErrorItemMissing", displayName))
            return
        }
        closePanel()
        if let failure = fileOpener.revealInFinder(target.url) {
            presentNotice(t(failure.messageKey, failure.argument))
        }
    }

    func activate(resultID id: String) {
        guard let target = results.first(where: { $0.id == id }) else { return }
        performPrimaryAction(on: target)
    }

    func reveal(resultID id: String) {
        guard let target = results.first(where: { $0.id == id }) else { return }
        revealSelectionInFinder(on: target)
    }

    private func recordUsage(of result: QuickSearchResult) {
        // 用与收藏同一个归并键：应用按 Bundle ID、其余按路径，搜索来的行和收藏快照的行
        // 因此记到同一条上，不会因为来源不同而分裂成两个计数。
        usage.recordLaunch(
            identity: result.favoriteIdentity,
            path: result.url.standardizedFileURL.path
        )
    }

    // MARK: - 错误提示

    private func presentNotice(_ text: String) {
        noticeDismissTask.stop()
        let panel = noticePanel ?? noticePanelFactory?() ?? QuickSearchNoticePanel()
        noticePanel = panel
        panel.present(text)
        transientNotice = text
        noticeDismissTask.startOnce(after: .seconds(2.6)) { [weak self] in
            self?.dismissNoticeNow()
        }
    }

    private func dismissNoticeNow() {
        noticeDismissTask.stop()
        noticePanel?.dismiss()
        noticePanel = nil
        transientNotice = nil
    }

    // MARK: - 图标

    func icon(for result: QuickSearchResult) -> NSImage? {
        icons.icon(for: result.url, pointSize: 32, key: result.iconKey)
    }

    var iconRevision: Int { icons.revision }
}

// MARK: - 默认实现

/// 复用 Dock Groups 的启动服务：运行中激活、未运行启动，不重复开第二个实例。
@MainActor
final class SystemApplicationLauncher: QuickSearchLaunching {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "QuickSearchLaunch")

    func open(applicationAt url: URL, name: String) async -> QuickSearchFailure? {
        do {
            _ = try await AppLaunchService.open(url: url, name: name)
            return nil
        } catch let error as AppLaunchError {
            switch error {
            case .applicationNotFound: return .applicationMissing(name: name)
            case .launchFailed: return .launchFailed(name: name)
            case .activationFailed: return .launchFailed(name: name)
            }
        } catch {
            Self.logger.notice("QuickSearch launch of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .launchFailed(name: name)
        }
    }
}

@MainActor
final class SystemFileOpener: QuickSearchFileOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open(_ url: URL) -> QuickSearchFailure? {
        let name = url.lastPathComponent
        guard workspace.open(url) else { return .openFailed(name: name) }
        return nil
    }

    func revealInFinder(_ url: URL) -> QuickSearchFailure? {
        workspace.activateFileViewerSelecting([url])
        return nil
    }
}

@MainActor
final class FileSystemItemAvailability: QuickSearchItemAvailability {
    func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
