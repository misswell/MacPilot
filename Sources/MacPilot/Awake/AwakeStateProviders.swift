import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol AwakeApplicationStateProviding: AnyObject {
    var currentState: ApplicationState { get }
    func startMonitoring(_ handler: @escaping @MainActor () -> Void)
    func stopMonitoring()
    func refreshNow()
}

@MainActor
extension AwakeApplicationStateProviding {
    func refreshNow() {}
}

@MainActor
final class ApplicationStateProvider: AwakeApplicationStateProviding {
    private(set) var currentState = ApplicationState.unknown
    private var notificationTokens: [NSObjectProtocol] = []
    private var handler: (@MainActor () -> Void)?

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        stopMonitoring()
        self.handler = handler
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        notificationTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAndNotify()
                }
            }
        }
        refreshAndNotify(force: true)
    }

    func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
        handler = nil
    }

    func refreshNow() {
        refreshAndNotify(force: true)
    }

    private func refreshAndNotify(force: Bool = false) {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let newState = ApplicationState(
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        let changed = newState != currentState
        currentState = newState
        if force || changed { handler?() }
    }
}

@MainActor
protocol AwakeProcessStateProviding: AnyObject {
    var currentState: ProcessState { get }
    func startMonitoring(_ handler: @escaping @MainActor () -> Void)
    func stopMonitoring()
    func refreshNow()
}

@MainActor
extension AwakeProcessStateProviding {
    func refreshNow() {}
}

@MainActor
final class ProcessStateProvider: AwakeProcessStateProviding {
    typealias SnapshotReader = @Sendable () -> ProcessState

    private(set) var currentState = ProcessState.unknown
    private let snapshotReader: SnapshotReader
    private var handler: (@MainActor () -> Void)?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private let pollInterval: Duration

    init(
        pollInterval: Duration = .seconds(3),
        snapshotReader: @escaping SnapshotReader = ProcessStateProvider.readSystemProcessState
    ) {
        self.pollInterval = pollInterval
        self.snapshotReader = snapshotReader
    }

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        stopMonitoring()
        self.handler = handler
        requestRefresh(force: true)
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.requestRefresh()
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        handler = nil
    }

    func refreshNow() {
        requestRefresh(force: true)
    }

    private func requestRefresh(force: Bool = false) {
        refreshTask?.cancel()
        let snapshotReader = self.snapshotReader
        refreshTask = Task { @MainActor [weak self] in
            let newState = await Task.detached(priority: .utility) {
                snapshotReader()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.apply(newState, force: force)
        }
    }

    private func apply(_ newState: ProcessState, force: Bool) {
        let changed = newState != currentState
        currentState = newState
        if force || changed { handler?() }
    }

    nonisolated private static func readSystemProcessState() -> ProcessState {
        let task = Foundation.Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm="]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else {
                return .unknown
            }
            return Self.parseProcessList(text)
        } catch {
            return .unknown
        }
    }

    nonisolated static func parseProcessList(_ text: String) -> ProcessState {
        var names = Set<String>()
        var paths = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            let executable = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !executable.isEmpty else { continue }
            let path = URL(fileURLWithPath: executable).standardizedFileURL.path
            names.insert(ProcessState.normalizedName(URL(fileURLWithPath: executable).lastPathComponent))
            paths.insert(path)
        }
        return ProcessState(runningNames: names, runningExecutablePaths: paths)
    }
}

@MainActor
protocol AwakeDisplayStateProviding: AnyObject {
    var currentState: DisplayState { get }
    func startMonitoring(_ handler: @escaping @MainActor () -> Void)
    func stopMonitoring()
    func refreshNow()
}

@MainActor
extension AwakeDisplayStateProviding {
    func refreshNow() {}
}

@MainActor
final class DisplayStateProvider: AwakeDisplayStateProviding {
    private(set) var currentState = DisplayState.unknown
    private var handler: (@MainActor () -> Void)?
    private var callbackContext: DisplayCallbackContext?
    private var isRegistered = false

    func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
        stopMonitoring()
        self.handler = handler
        let context = DisplayCallbackContext(owner: self)
        callbackContext = context
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        isRegistered = result == .success
        refreshAndNotify(force: true)
    }

    func stopMonitoring() {
        if isRegistered, let callbackContext {
            _ = CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(callbackContext).toOpaque()
            )
        }
        isRegistered = false
        callbackContext = nil
        handler = nil
    }

    func refreshNow() {
        refreshAndNotify(force: true)
    }

    private func refreshAndNotify(force: Bool = false) {
        let newState = Self.readDisplayState()
        let changed = newState != currentState
        currentState = newState
        if force || changed { handler?() }
    }

    private static func readDisplayState() -> DisplayState {
        let maximumDisplayCount: UInt32 = 32
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maximumDisplayCount))
        var displayCount: UInt32 = 0
        let result = CGGetActiveDisplayList(maximumDisplayCount, &displayIDs, &displayCount)
        guard result == .success else { return .unknown }

        let activeIDs = Array(displayIDs.prefix(Int(displayCount)))
        let displays = activeIDs.map {
            DisplayInfo(id: $0, isBuiltIn: CGDisplayIsBuiltin($0) != 0)
        }
        return DisplayState(
            onlineDisplays: displays,
            externalDisplayCount: displays.count(where: { !$0.isBuiltIn }),
            mirroringActive: activeIDs.contains { CGDisplayIsInMirrorSet($0) != 0 }
        )
    }

    private final class DisplayCallbackContext: @unchecked Sendable {
        weak var owner: DisplayStateProvider?

        init(owner: DisplayStateProvider) {
            self.owner = owner
        }
    }

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, context in
        guard let context else { return }
        let callbackContext = Unmanaged<DisplayCallbackContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            callbackContext.owner?.refreshAndNotify()
        }
    }
}
