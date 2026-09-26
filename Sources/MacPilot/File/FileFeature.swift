import Foundation
import SwiftUI

@MainActor
final class FolderCompressionModel: ObservableObject, ManagedFeature {
    let identifier = "compression"
    var isRunning: Bool { isActive }
    func start() { activateFromConfiguration() }
    func stop() { deactivateFromConfiguration() }
    private enum AutomaticScanScope: Sendable {
        case allFolders
        case folders(Set<String>)
        case dueChanges(FileCompressionDueChanges)
    }

    private enum AutomaticScanOutcome: Sendable {
        case completed(retryablePaths: Set<String>, retryableRoots: Set<String>)
        case scanFailed(AppleFileCompressionError)
    }

    private struct AutomaticScanWork: Sendable {
        var result = FileCompressionOperationResult()
        var folderIssues: [FileCompressionFolderIssue] = []
    }

    @Published private(set) var settings = FolderCompressionSettings()
    @Published private(set) var scan: FileCompressionScan?
    @Published private(set) var lastResult: FileCompressionOperationResult?
    @Published private(set) var lastActionWasRestore = false
    @Published private(set) var isScanning = false
    @Published private(set) var isProcessing = false
    @Published private(set) var error: AppleFileCompressionError?

    var persist: (() -> Void)?
    private var isLoading = false
    private let engine = AppleFileCompressionEngine()
    private let scanner = FileScanner()
    private let eventMonitor = FileCompressionEventMonitor()
    private var pendingChanges = FileCompressionPendingChanges()
    private var pendingDeadlineTask: Task<Void, Never>?
    private var initialScanTask: Task<Void, Never>?
    private var manualScanTask: Task<Void, Never>?
    private var manualOperationTask: Task<FileCompressionOperationResult, Error>?
    private var reconciliationTask: Task<Void, Never>?
    private var monitoringGeneration = UUID()
    private var manualGeneration = UUID()
    private var retryBackoff = FileCompressionRetryBackoff()
    private var isActive = false

    deinit {
        eventMonitor.stop()
        pendingDeadlineTask?.cancel()
        initialScanTask?.cancel()
        manualScanTask?.cancel()
        manualOperationTask?.cancel()
        reconciliationTask?.cancel()
    }

    func applyLoadedSettings(_ settings: FolderCompressionSettings) {
        isLoading = true
        self.settings = settings
        isLoading = false
    }

    func activateFromConfiguration() {
        isActive = true
        updateMonitoring(initialScanRoots: Set(settings.folderPaths))
    }

    func deactivateFromConfiguration() {
        isActive = false
        cancelManualWork()
        stopMonitoring()
    }

    /// Synchronous teardown for app termination: stops the FSEvents stream and
    /// cancels every pending scan task.
    func shutdown() {
        isActive = false
        cancelManualWork()
        stopMonitoring()
    }

    private func cancelManualWork() {
        manualGeneration = UUID()
        manualScanTask?.cancel()
        manualScanTask = nil
        manualOperationTask?.cancel()
        manualOperationTask = nil
        isScanning = false
        isProcessing = false
    }

    func addFolders(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        let previousPaths = settings.folderPaths
        updateSettings {
            $0.folderPaths = FolderCompressionSettings(folderPaths: $0.folderPaths + paths).folderPaths
        }
        scan = nil
        lastResult = nil
        error = nil
        if settings.folderPaths != previousPaths {
            updateMonitoring(
                initialScanRoots: Set(settings.folderPaths).subtracting(previousPaths),
                preservePendingChanges: true
            )
        }
    }

    func removeFolder(path: String) {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let previousPaths = settings.folderPaths
        updateSettings { $0.folderPaths.removeAll { $0 == normalizedPath } }
        scan = nil
        lastResult = nil
        error = nil
        if settings.folderPaths != previousPaths {
            updateMonitoring(initialScanRoots: nil, preservePendingChanges: true)
        }
    }

    func updateExtensions(_ text: String) {
        let values = text.components(separatedBy: CharacterSet(charactersIn: ",;，； \n\t"))
        updateSettings { $0.fileExtensions = FolderCompressionSettings(fileExtensions: values).fileExtensions }
        scan = nil
    }

    func useRecommendedExtensions() {
        updateSettings { $0.fileExtensions = FolderCompressionSettings.recommendedExtensions }
        scan = nil
    }

    func setMinimumFileSize(_ value: Int64) {
        updateSettings { $0.minimumFileSize = value }
        scan = nil
    }

    func setStableSeconds(_ value: TimeInterval) {
        updateSettings { $0.stableSeconds = value }
        scan = nil
        guard settings.automaticallyCompress else { return }
        pendingChanges.rescheduleAll(stableSeconds: value)
        schedulePendingChanges(generation: monitoringGeneration)
    }

    func setMinimumSavingsPercent(_ value: Int) {
        updateSettings { $0.minimumSavingsPercent = value }
    }

    func setAutomaticallyCompress(_ enabled: Bool) {
        updateSettings { $0.automaticallyCompress = enabled }
        updateMonitoring(initialScanRoots: enabled ? Set(settings.folderPaths) : nil)
    }

    func scanNow() async {
        guard !isScanning, !isProcessing else { return }
        isScanning = true
        error = nil
        let currentSettings = settings
        let generation = manualGeneration
        scan = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.manualGeneration == generation {
                    self.isScanning = false
                    self.manualScanTask = nil
                }
            }
            do {
                let scanTask = Task.detached(priority: .userInitiated) { [scanner] in
                    try scanner.scanSummary(settings: currentSettings)
                }
                let summary = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }
                guard !Task.isCancelled, self.manualGeneration == generation else { return }
                self.scan = summary
            } catch is CancellationError {
                if self.manualGeneration == generation { self.scan = nil }
            } catch let compressionError as AppleFileCompressionError {
                guard self.manualGeneration == generation else { return }
                self.scan = nil
                self.error = compressionError
            } catch {
                guard self.manualGeneration == generation else { return }
                self.scan = nil
                self.error = .scanFailed(error.localizedDescription)
            }
        }
        manualScanTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func compressCandidates() async {
        guard !isProcessing else { return }
        if scan == nil { await scanNow() }
        guard let scan, scan.candidateCount > 0 else { return }
        isProcessing = true
        error = nil
        lastActionWasRestore = false
        let currentSettings = settings
        let generation = manualGeneration
        let task = Task.detached(priority: .userInitiated) { [engine] in
            let (result, _) = try engine.scanAndCompress(settings: currentSettings)
            return result
        }
        manualOperationTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard manualGeneration == generation else { return }
            lastResult = result
        } catch is CancellationError {
            // A disabled feature must not publish a partial operation result.
        } catch let compressionError as AppleFileCompressionError {
            if manualGeneration == generation { error = compressionError }
        } catch {
            if manualGeneration == generation { self.error = .scanFailed(error.localizedDescription) }
        }
        guard manualGeneration == generation else { return }
        manualOperationTask = nil
        isProcessing = false
        if isActive { await scanNow() }
    }

    func restoreCompressedFiles() async {
        guard !isProcessing, let scan, scan.compressedCount > 0 else { return }
        isProcessing = true
        error = nil
        lastActionWasRestore = true
        let currentSettings = settings
        let generation = manualGeneration
        let task = Task.detached(priority: .userInitiated) { [engine] in
            try engine.scanAndRestore(settings: currentSettings)
        }
        manualOperationTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard manualGeneration == generation else { return }
            lastResult = result
        } catch is CancellationError {
            // A disabled feature must not publish a partial operation result.
        } catch let compressionError as AppleFileCompressionError {
            if manualGeneration == generation { error = compressionError }
        } catch {
            if manualGeneration == generation { self.error = .scanFailed(error.localizedDescription) }
        }
        guard manualGeneration == generation else { return }
        manualOperationTask = nil
        isProcessing = false
        if isActive { await scanNow() }
    }

    private func updateSettings(_ update: (inout FolderCompressionSettings) -> Void) {
        update(&settings)
        guard !isLoading else { return }
        persist?()
    }

    private func updateMonitoring(
        initialScanRoots: Set<String>?,
        preservePendingChanges: Bool = false
    ) {
        let resumeEventID = preservePendingChanges ? eventMonitor.resumeEventID : nil
        stopMonitoring(clearPendingChanges: !preservePendingChanges)
        if preservePendingChanges {
            pendingChanges.retainPaths(inside: Set(settings.folderPaths))
        }
        guard isActive, settings.automaticallyCompress, !settings.folderPaths.isEmpty else { return }

        let generation = monitoringGeneration
        let started = eventMonitor.start(
            paths: settings.folderPaths,
            sinceWhen: resumeEventID
        ) { [weak self] delivery in
            Task { @MainActor [weak self] in
                guard let self,
                      self.receiveCompressionEvents(
                        delivery.batch,
                        generation: generation
                      ) else { return }
                self.eventMonitor.acknowledge(delivery)
            }
        }
        guard started else {
            error = .monitoringUnavailable
            return
        }
        schedulePendingChanges(generation: generation)

        if let initialScanRoots, !initialScanRoots.isEmpty {
            initialScanTask = Task { [weak self] in
                await self?.waitAndPerformAutomaticScan(
                    .folders(initialScanRoots),
                    generation: generation
                )
            }
        }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
                guard let self else { return }
                await self.waitAndPerformAutomaticScan(.allFolders, generation: generation)
            }
        }
    }

    private func stopMonitoring(clearPendingChanges: Bool = true) {
        monitoringGeneration = UUID()
        eventMonitor.stop()
        pendingDeadlineTask?.cancel()
        initialScanTask?.cancel()
        reconciliationTask?.cancel()
        pendingDeadlineTask = nil
        initialScanTask = nil
        reconciliationTask = nil
        if clearPendingChanges {
            pendingChanges.removeAll()
        }
        retryBackoff.reset()
    }

    private func receiveCompressionEvents(
        _ batch: FileCompressionChangeBatch,
        generation: UUID
    ) -> Bool {
        guard generation == monitoringGeneration, settings.automaticallyCompress else { return false }
        retryBackoff.reset()
        pendingChanges.record(batch, stableSeconds: settings.stableSeconds)
        schedulePendingChanges(generation: generation)
        return true
    }

    private func schedulePendingChanges(
        generation: UUID,
        notBefore: Date? = nil
    ) {
        pendingDeadlineTask?.cancel()
        guard generation == monitoringGeneration, let nextDeadline = pendingChanges.nextDeadline else {
            pendingDeadlineTask = nil
            return
        }
        let deadline = max(nextDeadline, notBefore ?? .distantPast)
        let delay = max(0, deadline.timeIntervalSinceNow)
        pendingDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            await self.processPendingChanges(generation: generation)
        }
    }

    private func processPendingChanges(generation: UUID) async {
        guard generation == monitoringGeneration, settings.automaticallyCompress else { return }
        guard !isScanning, !isProcessing else {
            schedulePendingChanges(
                generation: generation,
                notBefore: Date().addingTimeInterval(2)
            )
            return
        }
        let dueChanges = pendingChanges.takeDue()
        guard !dueChanges.isEmpty else {
            schedulePendingChanges(generation: generation)
            return
        }
        let scope = AutomaticScanScope.dueChanges(dueChanges)
        let outcome = await performAutomaticScan(scope, generation: generation)
        handleAutomaticScanOutcome(outcome, scope: scope, generation: generation)
        schedulePendingChanges(generation: generation)
    }

    private func waitAndPerformAutomaticScan(
        _ scope: AutomaticScanScope,
        generation: UUID
    ) async {
        while !Task.isCancelled, generation == monitoringGeneration, settings.automaticallyCompress {
            if !isScanning, !isProcessing {
                let outcome = await performAutomaticScan(scope, generation: generation)
                handleAutomaticScanOutcome(outcome, scope: scope, generation: generation)
                schedulePendingChanges(generation: generation)
                return
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func performAutomaticScan(
        _ scope: AutomaticScanScope,
        generation: UUID
    ) async -> AutomaticScanOutcome {
        guard generation == monitoringGeneration, !isScanning, !isProcessing else {
            return .scanFailed(.scanFailed("Automatic compression is busy."))
        }
        isScanning = true
        isProcessing = true
        scan = nil
        error = nil
        let currentSettings = settings
        let work: AutomaticScanWork
        do {
            let task = Task.detached(priority: .utility) { [engine] in
                switch scope {
                case .allFolders:
                    let (result, issues) = try engine.scanAndCompress(settings: currentSettings)
                    return AutomaticScanWork(result: result, folderIssues: issues)
                case .folders(let roots):
                    var rootSettings = currentSettings
                    rootSettings.folderPaths = roots.sorted()
                    let (result, issues) = try engine.scanAndCompress(settings: rootSettings)
                    return AutomaticScanWork(result: result, folderIssues: issues)
                case .dueChanges(let changes):
                    var result = try engine.compressChangedPaths(
                        changes.changedPaths,
                        settings: currentSettings
                    )
                    var folderIssues: [FileCompressionFolderIssue] = []
                    if !changes.rootsRequiringFullScan.isEmpty {
                        var rootSettings = currentSettings
                        rootSettings.folderPaths = changes.rootsRequiringFullScan.sorted()
                        let (rootResult, issues) = try engine.scanAndCompress(settings: rootSettings)
                        result.merge(rootResult)
                        folderIssues.append(contentsOf: issues)
                    }
                    return AutomaticScanWork(result: result, folderIssues: folderIssues)
                }
            }
            work = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch let compressionError as AppleFileCompressionError {
            error = compressionError
            isScanning = false
            isProcessing = false
            return .scanFailed(compressionError)
        } catch {
            let scanError = AppleFileCompressionError.scanFailed(error.localizedDescription)
            self.error = scanError
            isScanning = false
            isProcessing = false
            return .scanFailed(scanError)
        }
        isScanning = false
        isProcessing = false
        if let firstIssue = work.folderIssues.first {
            error = firstIssue.error
        }

        let retryableRoots = Set(work.folderIssues.compactMap { issue in
            issue.isRetryableForAutomaticCompression ? issue.folderURL.path : nil
        })

        guard generation == monitoringGeneration, settings.automaticallyCompress else {
            return .completed(retryablePaths: [], retryableRoots: [])
        }
        lastActionWasRestore = false
        lastResult = work.result
        scan = nil
        return .completed(
            retryablePaths: Set(work.result.retryableFiles),
            retryableRoots: retryableRoots
        )
    }

    private func handleAutomaticScanOutcome(
        _ outcome: AutomaticScanOutcome,
        scope: AutomaticScanScope,
        generation: UUID
    ) {
        guard generation == monitoringGeneration, settings.automaticallyCompress else { return }
        let retryChanges: FileCompressionDueChanges
        switch outcome {
        case .completed(let retryablePaths, let retryableRoots):
            guard !retryablePaths.isEmpty || !retryableRoots.isEmpty else {
                retryBackoff.reset()
                return
            }
            retryChanges = FileCompressionDueChanges(
                changedPaths: retryablePaths,
                rootsRequiringFullScan: retryableRoots
            )
        case .scanFailed(let error):
            switch error {
            case .folderNotSelected, .unsupportedFileSystem, .monitoringUnavailable:
                retryBackoff.reset()
                return
            default:
                break
            }
            switch scope {
            case .allFolders:
                retryChanges = FileCompressionDueChanges(
                    rootsRequiringFullScan: Set(settings.folderPaths)
                )
            case .folders(let roots):
                retryChanges = FileCompressionDueChanges(rootsRequiringFullScan: roots)
            case .dueChanges(let changes):
                retryChanges = changes
            }
        }
        guard let retryDelay = retryBackoff.consumeDelay() else { return }
        pendingChanges.requeue(retryChanges, delaySeconds: retryDelay)
    }
}
