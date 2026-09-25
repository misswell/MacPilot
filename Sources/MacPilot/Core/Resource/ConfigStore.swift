import Foundation

/// Persists independent configuration domains. Existing single-file installs
/// are read unchanged and migrate only after all three sidecars are written.
@MainActor
final class ConfigStore {
    private static let splitVersionKey = "splitConfigurationVersion"
    private static let featureKeys: Set<String> = [
        "enabledFeatures", "bleUnlock", "fileCompression", "screenCapture",
        "screenRecording", "pictureInPicture", "inputSources", "smoothScrolling",
        "clipboard", "awake", "awakeTriggers", "remoteControl", "dockGroups"
    ]
    private static let shortcutKeys: [String: Set<String>] = [
        "screenCapture": [
            "smartCaptureShortcut", "areaCaptureShortcut", "repeatAreaCaptureShortcut",
            "delayedAreaCaptureShortcut", "applicationWindowCaptureShortcut",
            "fullscreenCaptureShortcut", "activeWindowCaptureShortcut",
            "areaAnnotateShortcut", "ocrShortcut", "scrollingCaptureShortcut",
            "objectCutoutShortcut", "pinCaptureShortcut", "postSelectionPinShortcut"
        ],
        "clipboard": ["hotkey"],
        "inputSources": ["shortcuts", "globalShortcutEnabled"]
    ]

    private let url: URL
    private let writeQueue = DispatchQueue(label: "com.misswell.macpilot.configuration-write", qos: .utility)
    private var lastQueuedData: Data?
    private var requiresMigration: Bool
    private var pendingData: Data?
    private var pendingTask: Task<Void, Never>?
    var onError: ((Error) -> Void)?

    init(url: URL) {
        self.url = url
        let core = Self.readObject(at: url)
        requiresMigration = core?[Self.splitVersionKey] == nil || !Self.sidecarsAreReadable(at: url)
        lastQueuedData = Self.loadMergedData(at: url)
    }

    var isDirty: Bool { pendingData != nil }

    func load() -> Data? { Self.loadMergedData(at: url) }

    func markDirty(_ data: Data) {
        if pendingData == data || (pendingData == nil && lastQueuedData == data && !requiresMigration) { return }
        pendingData = data
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            self?.flush()
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let data = pendingData else { return }
        let parts: [String: Data]
        do { parts = try Self.partition(data) }
        catch {
            onError?(error)
            return
        }
        pendingData = nil
        lastQueuedData = data
        requiresMigration = false
        let directory = url.deletingLastPathComponent()
        let originalData = data
        writeQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let coreURL = directory.appendingPathComponent("config.json")
                if Self.readObject(at: coreURL)?[Self.splitVersionKey] == nil {
                    try originalData.write(
                        to: directory.appendingPathComponent("config-legacy.json"), options: .atomic
                    )
                }
                // The core manifest is last. A crash during migration leaves
                // the old single-file config valid and ignores any sidecars.
                for name in ["features.json", "shortcuts.json", "window.json", "config.json"] {
                    guard let contents = parts[name] else { continue }
                    let destination = directory.appendingPathComponent(name)
                    if (try? Data(contentsOf: destination)) != contents {
                        try contents.write(to: destination, options: .atomic)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastQueuedData = nil
                    self?.requiresMigration = true
                    self?.onError?(error)
                }
            }
        }
    }

    func finish() {
        flush()
        writeQueue.sync {}
    }

    private static func partition(_ data: Data) throws -> [String: Data] {
        guard var core = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var features: [String: Any] = [:]
        var shortcuts: [String: Any] = [:]
        var window: [String: Any] = [:]

        for key in featureKeys {
            if let value = core.removeValue(forKey: key) { features[key] = value }
        }
        if let value = core.removeValue(forKey: "windowSwitcher") { window["windowSwitcher"] = value }
        for (featureKey, keys) in shortcutKeys {
            guard var feature = features[featureKey] as? [String: Any] else { continue }
            var extracted: [String: Any] = [:]
            for key in keys {
                if let value = feature.removeValue(forKey: key) { extracted[key] = value }
            }
            features[featureKey] = feature
            if !extracted.isEmpty { shortcuts[featureKey] = extracted }
        }
        core[splitVersionKey] = 1
        return try [
            "config.json": core,
            "features.json": features,
            "shortcuts.json": shortcuts,
            "window.json": window
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
    }

    private static func loadMergedData(at url: URL) -> Data? {
        guard var core = readObject(at: url) else { return nil }
        guard core[splitVersionKey] != nil else { return try? Data(contentsOf: url) }
        let directory = url.deletingLastPathComponent()
        for name in ["features.json", "window.json"] {
            guard let fields = readObject(at: directory.appendingPathComponent(name)) else {
                return try? Data(contentsOf: directory.appendingPathComponent("config-legacy.json"))
            }
            core.merge(fields) { _, sidecar in sidecar }
        }
        guard let shortcuts = readObject(at: directory.appendingPathComponent("shortcuts.json")) else {
            return try? Data(contentsOf: directory.appendingPathComponent("config-legacy.json"))
        }
        for (featureKey, value) in shortcuts {
            guard let overrides = value as? [String: Any] else { continue }
            var feature = core[featureKey] as? [String: Any] ?? [:]
            feature.merge(overrides) { _, sidecar in sidecar }
            core[featureKey] = feature
        }
        core.removeValue(forKey: splitVersionKey)
        return try? JSONSerialization.data(withJSONObject: core, options: [.prettyPrinted, .sortedKeys])
    }

    nonisolated private static func readObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func sidecarsAreReadable(at url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        return ["features.json", "shortcuts.json", "window.json"].allSatisfy {
            readObject(at: directory.appendingPathComponent($0)) != nil
        }
    }
}
