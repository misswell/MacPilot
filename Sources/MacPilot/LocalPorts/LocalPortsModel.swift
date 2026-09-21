import Foundation
import MacPilotLocalPortsCore
import SwiftUI

/// Main-actor coordinator for the visible Local Ports page.
///
/// The model owns only UI lifecycle state.  Every lsof/ps scan and every
/// close verification runs in the utility executor through the Core target.
@MainActor
final class LocalPortsModel: ObservableObject {
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
    private var autoRefreshTask: Task<Void, Never>?
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

        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refreshIfVisible()
            }
        }
    }

    func stopVisibleSession() {
        guard isVisible || refreshTask != nil || autoRefreshTask != nil else { return }
        isVisible = false
        invalidateVisibleWork()
    }

    func shutdown() {
        isVisible = false
        invalidateVisibleWork()
        lastCloseResult = nil
    }

    private func invalidateVisibleWork() {
        generation &+= 1
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        isPreparingClose = false
        isClosing = false
        pendingClosePlan = nil
        selectedActivityID = nil
    }

    func refreshNow() {
        refresh()
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

        Task { [weak self] in
            do {
                let plan = try await Task.detached(priority: .utility) {
                    try LocalPortCloseService.prepare(
                        port: port,
                        pid: pid,
                        environment: environment
                    )
                }.value
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

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await LocalPortCloseService.execute(plan, environment: environment)
                }.value
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseResult = result
                self.pendingClosePlan = nil
                self.isClosing = false
                self.refresh()
            } catch let error as LocalPortCloseError {
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseError = error
                self.pendingClosePlan = nil
                self.isClosing = false
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.lastCloseError = .verificationFailed
                self.pendingClosePlan = nil
                self.isClosing = false
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
        isRefreshing = true
        lastScanError = nil
        let requestGeneration = generation
        let environment = closeEnvironment

        let task = Task { [weak self] in
            do {
                let value = try await Task.detached(priority: .utility) {
                    try environment.scan()
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.isVisible,
                      self.generation == requestGeneration else { return }
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
        }
        refreshTask = task
    }
}
