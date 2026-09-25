import Foundation
import MacPilotLocalPortsCore
import SwiftUI

/// Main-actor coordinator for the visible Local Ports page.
///
/// The model owns only UI lifecycle state.  Every lsof/ps scan and every
/// close verification runs in the utility executor through the Core target.
@MainActor
final class LocalPortsModel: ObservableObject, ManagedFeature {
    let identifier = "localPorts"
    var isRunning: Bool { isVisible }
    func start() { startVisibleSession() }
    func stop() { stopVisibleSession() }
    /// 菜单栏子菜单的补扫有效期：与页面可见时的自动刷新同频，
    /// 让一次菜单开合最多起一轮 lsof/ps。
    static let menuRefreshInterval: TimeInterval = 10

    @Published private(set) var snapshot: LocalPortSnapshot = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPreparingClose = false
    @Published private(set) var isClosing = false
    @Published private(set) var lastRefresh: Date?
    @Published var query = ""
    @Published var pendingClosePlan: LocalPortClosePlan?
    @Published var selectedActivityID: String?
    @Published private(set) var lastScanError: LocalPortScanError?
    @Published private(set) var lastCloseError: LocalPortCloseError?
    @Published private(set) var lastCloseResult: LocalPortCloseResult?

    private var refreshTask: Task<Void, Never>?
    private var scanWorker: Task<LocalPortSnapshot, Error>?
    private var prepareWorker: Task<LocalPortClosePlan, Error>?
    private var closeWorker: Task<LocalPortCloseResult, Error>?
    private let autoRefreshTask = BackgroundTask()
    private var generation: UInt64 = 0
    private var isVisible = false
    private let closeEnvironment: LocalPortCloseEnvironment

    init(environment: LocalPortCloseEnvironment = .live) {
        closeEnvironment = environment
    }

    func startVisibleSession() {
        guard !isVisible else { return }
        isVisible = true
        generation &+= 1
        refresh()

        autoRefreshTask.start(interval: .seconds(10)) { [weak self] in
            self?.refreshIfVisible()
        }
    }

    func stopVisibleSession() {
        guard isVisible || refreshTask != nil || autoRefreshTask.isRunning else { return }
        isVisible = false
        invalidateVisibleWork()
        Task { await LocalPortFaviconFetcher.shared.clear() }
    }

    func shutdown() {
        isVisible = false
        invalidateVisibleWork()
        lastCloseResult = nil
        Task { await LocalPortFaviconFetcher.shared.clear() }
    }

    private func invalidateVisibleWork() {
        generation &+= 1
        autoRefreshTask.stop()
        refreshTask?.cancel()
        refreshTask = nil
        scanWorker?.cancel()
        scanWorker = nil
        prepareWorker?.cancel()
        prepareWorker = nil
        closeWorker?.cancel()
        closeWorker = nil
        isRefreshing = false
        isPreparingClose = false
        isClosing = false
        pendingClosePlan = nil
        selectedActivityID = nil
    }

    func refreshNow() {
        refresh()
    }

    /// Asks for a scan on behalf of the menu-bar submenu, which has data even
    /// while its page is closed.
    ///
    /// A scan spawns subprocesses, so it cannot return synchronously the way the
    /// memory and CPU menus do: this call only promises to refresh stale data,
    /// and the submenu shows the previous snapshot until the scan lands. The hop
    /// to the next run-loop turn keeps the `@Published` writes out of the menu's
    /// own view update.
    func refreshForMenu(maxAge: TimeInterval = LocalPortsModel.menuRefreshInterval) {
        Task { [weak self] in
            guard let self, !self.isRefreshing else { return }
            if let lastRefresh = self.lastRefresh,
               Date().timeIntervalSince(lastRefresh) < maxAge { return }
            self.startScan(appliesWhileHidden: true)
        }
    }

    func prepareClose(for activity: LocalPortActivity) {
        guard !isPreparingClose, !isClosing else { return }
        guard isVisible else { return }

        isPreparingClose = true
        lastCloseError = nil
        lastCloseResult = nil
        pendingClosePlan = nil
        let requestGeneration = generation
        let port = activity.listener.port
        let pid = activity.process.pid
        let environment = closeEnvironment

        let worker = Task.detached(priority: .utility) {
            try LocalPortCloseService.prepare(
                port: port,
                pid: pid,
                environment: environment
            )
        }
        prepareWorker = worker

        Task { [weak self] in
            do {
                let plan = try await worker.value
                guard let self,
                      self.isVisible,
                      self.generation == requestGeneration,
                      !Task.isCancelled else { return }
                self.pendingClosePlan = plan
            } catch let error as LocalPortCloseError {
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseError = error
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseError = .verificationFailed
            }
            guard let self, self.generation == requestGeneration else { return }
            self.isPreparingClose = false
            self.prepareWorker = nil
        }
    }

    func cancelPendingClose() {
        pendingClosePlan = nil
    }

    func confirmClose() {
        guard let plan = pendingClosePlan, !isClosing, isVisible else { return }
        isClosing = true
        lastCloseError = nil
        let requestGeneration = generation
        let environment = closeEnvironment

        let worker = Task.detached(priority: .utility) {
            try await LocalPortCloseService.execute(plan, environment: environment)
        }
        closeWorker = worker

        Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseResult = result
                self.pendingClosePlan = nil
                self.isClosing = false
                self.closeWorker = nil
                self.refresh()
            } catch let error as LocalPortCloseError {
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseError = error
                self.pendingClosePlan = nil
                self.isClosing = false
                self.closeWorker = nil
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseError = .verificationFailed
                self.pendingClosePlan = nil
                self.isClosing = false
                self.closeWorker = nil
            }
        }
    }

    func clearScanError() {
        lastScanError = nil
    }

    func clearCloseFeedback() {
        lastCloseError = nil
        lastCloseResult = nil
    }

    func matchesQuery(_ activity: LocalPortActivity) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let searchable = [
            String(activity.listener.port),
            String(activity.process.pid),
            activity.listener.command,
            activity.process.command,
            activity.process.user ?? "",
            activity.process.cwd ?? "",
            activity.process.executablePath ?? "",
            activity.process.arguments ?? "",
            activity.owner.label,
            activity.listener.addresses.joined(separator: " "),
        ]
        return searchable.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private func refreshIfVisible() {
        guard isVisible else { return }
        refresh()
    }

    private func refresh() {
        guard isVisible, !isRefreshing else { return }
        startScan(appliesWhileHidden: false)
    }

    /// One scan at a time, and a result only lands while the caller still wants
    /// it: `generation` moves whenever the visible session is torn down, and a
    /// menu-driven scan outlives the page being closed on purpose.
    private func startScan(appliesWhileHidden: Bool) {
        isRefreshing = true
        lastScanError = nil
        let requestGeneration = generation
        let environment = closeEnvironment

        let worker = Task.detached(priority: .utility) {
            try environment.scan()
        }
        scanWorker = worker

        let task = Task { [weak self] in
            do {
                let value = try await worker.value
                guard let self,
                      !Task.isCancelled,
                      self.generation == requestGeneration else { return }
                if !appliesWhileHidden, !self.isVisible { return }
                self.snapshot = value
                self.lastRefresh = Date()
            } catch let error as LocalPortScanError {
                guard let self, self.generation == requestGeneration else { return }
                self.lastScanError = error
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.lastScanError = .commandFailed(command: "lsof", status: -1)
            }

            guard let self, self.generation == requestGeneration else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            self.scanWorker = nil
        }
        refreshTask = task
    }
}
