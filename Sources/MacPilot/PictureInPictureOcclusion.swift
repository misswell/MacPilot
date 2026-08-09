// PictureInPictureOcclusion.swift
// Keeps Chromium/Electron windows rendering while they are covered.

import AppKit
import Foundation

struct PiPOcclusionApplication: Identifiable, Equatable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL
    let isRunning: Bool
    let isEnabled: Bool

    var id: String { bundleIdentifier }
}

struct PiPOcclusionApplicationDescriptor: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
}

@MainActor
final class PiPOcclusionController: ObservableObject {
    nonisolated static let renderingArgument = "--disable-backgrounding-occluded-windows"

    nonisolated static let supportedApplications: [PiPOcclusionApplicationDescriptor] = [
        .init(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome"),
        .init(bundleIdentifier: "com.google.Chrome.beta", displayName: "Google Chrome Beta"),
        .init(bundleIdentifier: "com.google.Chrome.dev", displayName: "Google Chrome Dev"),
        .init(bundleIdentifier: "com.google.Chrome.canary", displayName: "Google Chrome Canary"),
        .init(bundleIdentifier: "com.microsoft.edgemac", displayName: "Microsoft Edge"),
        .init(bundleIdentifier: "com.microsoft.edgemac.Beta", displayName: "Microsoft Edge Beta"),
        .init(bundleIdentifier: "com.microsoft.edgemac.Dev", displayName: "Microsoft Edge Dev"),
        .init(bundleIdentifier: "com.microsoft.edgemac.Canary", displayName: "Microsoft Edge Canary"),
        .init(bundleIdentifier: "com.brave.Browser", displayName: "Brave Browser"),
        .init(bundleIdentifier: "com.brave.Browser.beta", displayName: "Brave Browser Beta"),
        .init(bundleIdentifier: "com.brave.Browser.nightly", displayName: "Brave Browser Nightly"),
        .init(bundleIdentifier: "com.operasoftware.Opera", displayName: "Opera"),
        .init(bundleIdentifier: "com.operasoftware.OperaGX", displayName: "Opera GX"),
        .init(bundleIdentifier: "com.vivaldi.Vivaldi", displayName: "Vivaldi"),
        .init(bundleIdentifier: "company.thebrowser.Browser", displayName: "Arc"),
        .init(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        .init(bundleIdentifier: "com.spotify.client", displayName: "Spotify"),
        .init(bundleIdentifier: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
        .init(bundleIdentifier: "com.hnc.Discord", displayName: "Discord"),
        .init(bundleIdentifier: "com.anthropic.claudefordesktop", displayName: "Claude")
    ]

    @Published private(set) var applications: [PiPOcclusionApplication] = []
    @Published private(set) var customApplications: [PiPCustomPatchApplication] = []
    @Published private(set) var busyBundleIdentifiers: Set<String> = []
    @Published private(set) var errorMessage: String?

    private var enabledBundleIdentifiers: Set<String> = []
    private var customApplicationPaths: [String: String] = [:]
    private var autoApply = true
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var recentRelaunches: [String: Date] = [:]
    private var autoRelaunchTasks: [String: Task<Void, Never>] = [:]
    private var autoRepatchStream: FSEventStreamRef?
    private var autoRepatchTask: Task<Void, Never>?
    private var patchedApplicationLaunchDates: [String: Date] = [:]
    private var fastQuitCounts: [String: Int] = [:]

    func applySettings(
        enabledBundleIdentifiers: Set<String>,
        autoApply: Bool,
        customApplicationPaths: [String: String]
    ) {
        self.enabledBundleIdentifiers = enabledBundleIdentifiers
        self.autoApply = autoApply
        self.customApplicationPaths = customApplicationPaths
        refresh()
        restartAutoRepatching()
    }

    func activate() {
        guard launchObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.applicationDidLaunch(application)
            }
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.applicationDidTerminate(application) }
        }
        restartAutoRepatching()
        refresh()
    }

    func shutdown() {
        let center = NSWorkspace.shared.notificationCenter
        if let launchObserver { center.removeObserver(launchObserver) }
        if let terminateObserver { center.removeObserver(terminateObserver) }
        launchObserver = nil
        terminateObserver = nil
        for task in autoRelaunchTasks.values { task.cancel() }
        autoRelaunchTasks.removeAll()
        stopAutoRepatching()
    }

    func clearError() {
        errorMessage = nil
    }

    func refresh() {
        let workspace = NSWorkspace.shared
        let runningBundleIdentifiers = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        applications = Self.supportedApplications.compactMap { descriptor in
            guard let url = workspace.urlForApplication(withBundleIdentifier: descriptor.bundleIdentifier) else {
                return nil
            }
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                ?? descriptor.displayName
            return PiPOcclusionApplication(
                bundleIdentifier: descriptor.bundleIdentifier,
                displayName: name,
                applicationURL: url,
                isRunning: runningBundleIdentifiers.contains(descriptor.bundleIdentifier),
                isEnabled: enabledBundleIdentifiers.contains(descriptor.bundleIdentifier)
            )
        }
        var descriptors = PiPOcclusionAppPatchService.supportedApplications.map {
            ($0.bundleIdentifier, $0.displayName, customApplicationPaths[$0.bundleIdentifier] != nil)
        }
        for (bundleIdentifier, path) in customApplicationPaths
            where !descriptors.contains(where: { $0.0 == bundleIdentifier }) {
            let url = URL(fileURLWithPath: path)
            let displayName = PiPOcclusionAppPatchService.applicationIdentity(at: url)?.displayName
                ?? url.deletingPathExtension().lastPathComponent
            descriptors.append((bundleIdentifier, displayName, true))
        }
        customApplications = descriptors.compactMap { bundleIdentifier, fallbackName, isUserSelected in
            let configuredURL = customApplicationPaths[bundleIdentifier].map(URL.init(fileURLWithPath:))
            guard let url = configuredURL ?? workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return nil
            }
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                ?? fallbackName
            return PiPCustomPatchApplication(
                bundleIdentifier: bundleIdentifier,
                displayName: name,
                applicationURL: url,
                isRunning: runningBundleIdentifiers.contains(bundleIdentifier),
                isEnabled: enabledBundleIdentifiers.contains(bundleIdentifier),
                isPatched: (try? PiPOcclusionAppPatchService.isPatched(applicationURL: url)) ?? false,
                hasBackup: PiPOcclusionAppPatchService.hasBackup(bundleIdentifier: bundleIdentifier),
                isUserSelected: isUserSelected
            )
        }
    }

    func patch(_ application: PiPCustomPatchApplication) {
        guard NSRunningApplication.runningApplications(
                withBundleIdentifier: application.bundleIdentifier
              ).isEmpty,
              !busyBundleIdentifiers.contains(application.bundleIdentifier) else { return }
        guard let libraryURL = PiPOcclusionAppPatchService.bundledPatchLibraryURL() else {
            errorMessage = PiPOcclusionAppPatchError.missingPatchLibrary.localizedDescription
            return
        }
        performCustomOperation(bundleIdentifier: application.bundleIdentifier) {
            try PiPOcclusionAppPatchService.patch(
                applicationURL: application.applicationURL,
                expectedBundleIdentifier: application.bundleIdentifier,
                patchLibraryURL: libraryURL
            )
        }
    }

    func restore(_ application: PiPCustomPatchApplication) {
        guard NSRunningApplication.runningApplications(
                withBundleIdentifier: application.bundleIdentifier
              ).isEmpty,
              !busyBundleIdentifiers.contains(application.bundleIdentifier) else { return }
        performCustomOperation(bundleIdentifier: application.bundleIdentifier) {
            try PiPOcclusionAppPatchService.restore(
                applicationURL: application.applicationURL,
                expectedBundleIdentifier: application.bundleIdentifier
            )
        }
    }

    func relaunch(_ application: PiPOcclusionApplication) {
        guard !busyBundleIdentifiers.contains(application.bundleIdentifier) else { return }
        errorMessage = nil
        busyBundleIdentifiers.insert(application.bundleIdentifier)
        recentRelaunches[application.bundleIdentifier] = Date()
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.busyBundleIdentifiers.remove(application.bundleIdentifier)
                self.refresh()
            }
            do {
                try await self.relaunchApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationURL: application.applicationURL
                )
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated static func launchArguments() -> [String] {
        [renderingArgument]
    }

    private func applicationDidLaunch(_ application: NSRunningApplication) {
        refresh()
        if let bundleIdentifier = application.bundleIdentifier,
           customApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier && $0.isPatched }) {
            patchedApplicationLaunchDates[bundleIdentifier] = Date()
        }
        guard autoApply,
              let bundleIdentifier = application.bundleIdentifier,
              enabledBundleIdentifiers.contains(bundleIdentifier),
              !busyBundleIdentifiers.contains(bundleIdentifier),
              let target = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        if let lastRelaunch = recentRelaunches[bundleIdentifier],
           Date().timeIntervalSince(lastRelaunch) < 15 {
            return
        }
        autoRelaunchTasks[bundleIdentifier]?.cancel()
        autoRelaunchTasks[bundleIdentifier] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.relaunch(target)
            self?.autoRelaunchTasks[bundleIdentifier] = nil
        }
    }

    private func applicationDidTerminate(_ application: NSRunningApplication) {
        defer { refresh() }
        guard let bundleIdentifier = application.bundleIdentifier,
              let launchDate = patchedApplicationLaunchDates.removeValue(forKey: bundleIdentifier) else { return }
        guard Date().timeIntervalSince(launchDate) < 8 else {
            fastQuitCounts[bundleIdentifier] = 0
            return
        }
        guard
              let target = customApplications.first(where: {
                  $0.bundleIdentifier == bundleIdentifier && $0.isPatched && $0.hasBackup
              }) else { return }
        let count = (fastQuitCounts[bundleIdentifier] ?? 0) + 1
        fastQuitCounts[bundleIdentifier] = count
        if count >= 3 {
            fastQuitCounts[bundleIdentifier] = 0
            restore(target)
        }
    }

    private func restartAutoRepatching() {
        stopAutoRepatching()
        guard autoApply else { return }
        let paths = customApplications
            .filter { $0.isEnabled && $0.hasBackup }
            .map { $0.applicationURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            pictureInPicturePatchEventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        autoRepatchStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            stopAutoRepatching()
        }
    }

    private func stopAutoRepatching() {
        autoRepatchTask?.cancel()
        autoRepatchTask = nil
        guard let stream = autoRepatchStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        autoRepatchStream = nil
    }

    fileprivate func patchedApplicationBundleDidChange() {
        autoRepatchTask?.cancel()
        autoRepatchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            guard self.autoApply else { return }
            for application in self.customApplications where
                application.isEnabled && !application.isPatched
                && application.hasBackup && !application.isRunning {
                self.patch(application)
            }
            self.restartAutoRepatching()
        }
    }

    private func performCustomOperation(
        bundleIdentifier: String,
        operation: @escaping @Sendable () throws -> Void
    ) {
        errorMessage = nil
        busyBundleIdentifiers.insert(bundleIdentifier)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try operation() }
            }.value
            guard let self else { return }
            self.busyBundleIdentifiers.remove(bundleIdentifier)
            if case .failure(let error) = result { self.errorMessage = error.localizedDescription }
            self.refresh()
            self.restartAutoRepatching()
        }
    }

    private func relaunchApplication(bundleIdentifier: String, applicationURL: URL) async throws {
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        for application in runningApplications { application.terminate() }

        let deadline = Date().addingTimeInterval(8)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            guard Date() < deadline else { throw PiPOcclusionError.applicationDidNotQuit }
            try await Task.sleep(for: .milliseconds(100))
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = Self.launchArguments()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private func pictureInPicturePatchEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let controller = Unmanaged<PiPOcclusionController>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    Task { @MainActor in
        controller.patchedApplicationBundleDidChange()
    }
}

private enum PiPOcclusionError: LocalizedError {
    case applicationDidNotQuit

    var errorDescription: String? {
        switch self {
        case .applicationDidNotQuit:
            "The application did not quit in time. Quit it manually, then try again."
        }
    }
}
