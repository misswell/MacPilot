// ScreenCapture.swift
// Periodic screenshot capture with busy/idle scheduling and high-efficiency HEIC encoding.

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Image Format

enum ScreenCaptureImageFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case heic
    case jpeg
    case png

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .heic: return .heic
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: return "heic"
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    var supportsQuality: Bool { self != .png }
}

// MARK: - Settings

struct ScreenCaptureSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var outputFolder: String
    var busyStartHour: Int
    var busyEndHour: Int
    var busyIntervalMinutes: Int
    var idleIntervalMinutes: Int
    var imageFormat: ScreenCaptureImageFormat
    var quality: Double
    var maxRetentionDays: Int
    var captureAllDisplays: Bool
    var showsCursor: Bool
    var smartCaptureEnabled: Bool
    var pinSmartCaptures: Bool
    var smartCaptureShortcut: SmartCaptureShortcutBinding

    init(
        isEnabled: Bool = false,
        outputFolder: String = "",
        busyStartHour: Int = 9,
        busyEndHour: Int = 18,
        busyIntervalMinutes: Int = 10,
        idleIntervalMinutes: Int = 30,
        imageFormat: ScreenCaptureImageFormat = .heic,
        quality: Double = 0.7,
        maxRetentionDays: Int = 30,
        captureAllDisplays: Bool = false,
        showsCursor: Bool = true,
        smartCaptureEnabled: Bool = true,
        pinSmartCaptures: Bool = true,
        smartCaptureShortcut: SmartCaptureShortcutBinding = .default
    ) {
        self.isEnabled = isEnabled
        self.outputFolder = outputFolder
        self.busyStartHour = max(0, min(23, busyStartHour))
        self.busyEndHour = max(0, min(23, busyEndHour))
        self.busyIntervalMinutes = max(1, busyIntervalMinutes)
        self.idleIntervalMinutes = max(1, idleIntervalMinutes)
        self.imageFormat = imageFormat
        self.quality = max(0.05, min(1.0, quality))
        self.maxRetentionDays = max(0, maxRetentionDays)
        self.captureAllDisplays = captureAllDisplays
        self.showsCursor = showsCursor
        self.smartCaptureEnabled = smartCaptureEnabled
        self.pinSmartCaptures = pinSmartCaptures
        self.smartCaptureShortcut = smartCaptureShortcut.isValid ? smartCaptureShortcut : .default
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, outputFolder, busyStartHour, busyEndHour
        case busyIntervalMinutes, idleIntervalMinutes, imageFormat, quality
        case maxRetentionDays, captureAllDisplays, showsCursor, smartCaptureEnabled, pinSmartCaptures, smartCaptureShortcut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            outputFolder: try c.decodeIfPresent(String.self, forKey: .outputFolder) ?? "",
            busyStartHour: try c.decodeIfPresent(Int.self, forKey: .busyStartHour) ?? 9,
            busyEndHour: try c.decodeIfPresent(Int.self, forKey: .busyEndHour) ?? 18,
            busyIntervalMinutes: try c.decodeIfPresent(Int.self, forKey: .busyIntervalMinutes) ?? 10,
            idleIntervalMinutes: try c.decodeIfPresent(Int.self, forKey: .idleIntervalMinutes) ?? 30,
            imageFormat: try c.decodeIfPresent(ScreenCaptureImageFormat.self, forKey: .imageFormat) ?? .heic,
            quality: try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.7,
            maxRetentionDays: try c.decodeIfPresent(Int.self, forKey: .maxRetentionDays) ?? 30,
            captureAllDisplays: try c.decodeIfPresent(Bool.self, forKey: .captureAllDisplays) ?? false,
            showsCursor: try c.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true,
            smartCaptureEnabled: try c.decodeIfPresent(Bool.self, forKey: .smartCaptureEnabled) ?? true,
            pinSmartCaptures: try c.decodeIfPresent(Bool.self, forKey: .pinSmartCaptures) ?? true,
            smartCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .smartCaptureShortcut) ?? .default
        )
    }

    /// Whether the given hour (0–23) falls within the busy period.
    func isBusyHour(_ hour: Int) -> Bool {
        if busyStartHour == busyEndHour { return false }
        if busyStartHour < busyEndHour {
            return hour >= busyStartHour && hour < busyEndHour
        }
        // Wraps past midnight, e.g. 22 -> 6.
        return hour >= busyStartHour || hour < busyEndHour
    }

    /// Interval in minutes for the current time.
    func currentIntervalMinutes(at date: Date = Date()) -> Int {
        let hour = Calendar.current.component(.hour, from: date)
        return isBusyHour(hour) ? busyIntervalMinutes : idleIntervalMinutes
    }

    var isOutputFolderValid: Bool {
        let trimmed = outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - Errors

enum ScreenCaptureError: LocalizedError {
    case noOutputFolder
    case outputFolderUnavailable
    case noDisplayFound
    case permissionRequired
    case captureFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noOutputFolder: return "No output folder selected."
        case .outputFolderUnavailable: return "The output folder is unavailable."
        case .noDisplayFound: return "No display was found to capture."
        case .permissionRequired: return "Screen Recording permission is required to capture the screen."
        case .captureFailed(let detail): return "Screen capture failed: \(detail)"
        case .encodingFailed: return "Failed to encode the screenshot image."
        }
    }
}

private struct SendableScreenCaptureImage: @unchecked Sendable {
    let value: CGImage
}

private struct ScreenCaptureSaveConfiguration: Sendable {
    let outputFolder: String
    let imageFormat: ScreenCaptureImageFormat
    let quality: Double
}

private struct ScreenCaptureSavedImage: Sendable {
    let url: URL
    let size: Int64
}

private struct ScreenCaptureStorageStatistics: Sendable {
    var bytes: Int64 = 0
    var count = 0
}

private enum ScreenCaptureStorage {
    private static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]

    static func save(
        image: SendableScreenCaptureImage,
        displayIndex: Int?,
        date: Date,
        configuration: ScreenCaptureSaveConfiguration
    ) throws -> ScreenCaptureSavedImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.outputFolder,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ScreenCaptureError.outputFolderUnavailable
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        let dayURL = URL(fileURLWithPath: configuration.outputFolder)
            .appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fileFormatter.locale = Locale(identifier: "en_US_POSIX")
        fileFormatter.timeZone = .current
        var baseName = "MacPilot_\(fileFormatter.string(from: date))"
        if let displayIndex { baseName += "_display\(displayIndex + 1)" }
        let fileURL = uniqueFileURL(
            in: dayURL,
            baseName: baseName,
            fileExtension: configuration.imageFormat.fileExtension
        )

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            configuration.imageFormat.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureError.encodingFailed
        }
        if configuration.imageFormat.supportsQuality {
            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: configuration.quality
            ]
            CGImageDestinationAddImage(destination, image.value, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image.value, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCaptureError.encodingFailed
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return ScreenCaptureSavedImage(
            url: fileURL,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        )
    }

    private static func uniqueFileURL(in directory: URL, baseName: String, fileExtension: String) -> URL {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "_\(index)"
            let candidate = directory.appendingPathComponent("\(baseName)\(suffix).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    static func replace(
        image: SendableScreenCaptureImage,
        at url: URL,
        configuration: ScreenCaptureSaveConfiguration
    ) throws -> Int64 {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".MacPilot-edit-\(UUID().uuidString).\(configuration.imageFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            configuration.imageFormat.utType.identifier as CFString,
            1,
            nil
        ) else { throw ScreenCaptureError.encodingFailed }
        if configuration.imageFormat.supportsQuality {
            CGImageDestinationAddImage(destination, image.value, [
                kCGImageDestinationLossyCompressionQuality: configuration.quality
            ] as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image.value, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureError.encodingFailed }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func statistics(at folderURL: URL) -> ScreenCaptureStorageStatistics {
        var statistics = ScreenCaptureStorageStatistics()
        let folder = folderURL.path
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else {
            return statistics
        }

        while let path = enumerator.nextObject() as? String {
            autoreleasepool {
                guard imageExtensions.contains((path as NSString).pathExtension.lowercased()) else {
                    return
                }
                let fullPath = (folder as NSString).appendingPathComponent(path)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath),
                      let fileType = attributes[.type] as? FileAttributeType,
                      fileType == .typeRegular else { return }
                statistics.bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                statistics.count += 1
            }
        }
        return statistics
    }

    static func cleanup(
        folder: String,
        maximumAgeInDays: Int,
        now: Date = Date()
    ) -> ScreenCaptureStorageStatistics {
        var deleted = ScreenCaptureStorageStatistics()
        let folderURL = URL(fileURLWithPath: folder)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        guard let dayURLs = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return deleted }

        for dayURL in dayURLs {
            let values = try? dayURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  let dayDate = formatter.date(from: dayURL.lastPathComponent) else { continue }
            let daysOld = calendar.dateComponents([.day], from: dayDate, to: now).day ?? 0
            guard daysOld > maximumAgeInDays else { continue }
            let directoryStatistics = statistics(at: dayURL)
            do {
                try FileManager.default.removeItem(at: dayURL)
                deleted.bytes += directoryStatistics.bytes
                deleted.count += directoryStatistics.count
            } catch {
                continue
            }
        }
        return deleted
    }
}

private final class LegacyDisplayCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var finished = false

    init(continuation: CheckedContinuation<CGImage, Error>) {
        self.continuation = continuation
    }

    func attach(stream: SCStream) {
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            finish(.failure(ScreenCaptureError.captureFailed("ScreenCaptureKit returned an invalid frame.")))
            return
        }
        finish(.success(cgImage))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        switch result {
        case .success(let image): continuation?.resume(returning: image)
        case .failure(let error): continuation?.resume(throwing: error)
        }
        if let stream {
            Task { try? await stream.stopCapture() }
        }
    }
}

struct ScreenCaptureResetCommand: Sendable {
    let bundleIdentifier: String

    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/tccutil") }
    var arguments: [String] { ["reset", "ScreenCapture", bundleIdentifier] }

    @discardableResult
    func run() throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum ScreenCaptureResetExecution: Sendable {
    case success(Int32)
    case failure(String)
}

// MARK: - Model

@MainActor
final class ScreenCaptureModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.misswell.macpilot", category: "SmartCapture")
    @Published private(set) var settings = ScreenCaptureSettings()
    @Published private(set) var isCapturing = false
    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var lastCaptureSize: Int64 = 0
    @Published private(set) var captureCount: Int = 0
    @Published private(set) var totalDiskUsage: Int64 = 0
    @Published private(set) var screenshotCount: Int = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPermissionError = false
    @Published private(set) var hasScreenPermission = false
    @Published private(set) var nextCaptureDate: Date?
    @Published private(set) var isLoopRunning = false
    var language: AppLanguage = .system

    var persist: (() -> Void)?
    private var isLoading = false
    private var captureTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var diskUsageRevision = 0
    private let lastAreaDefaultsKey = "MacPilot.smartCapture.lastArea"
    private lazy var smartCapture = SmartScreenshotController(
        language: { [weak self] in self?.language ?? .system },
        onCapture: { [weak self] image in self?.handleSmartCapture(image) },
        onError: { [weak self] error in
            Self.logger.error("Region capture failed: \(error.localizedDescription, privacy: .public)")
            guard let self else { return }
            if let shortcutError = error as? SmartCaptureShortcutError {
                self.errorMessage = AppText.value(shortcutError.messageKey, language: self.language)
            } else {
                self.errorMessage = error.localizedDescription
            }
        },
        onSelectionRect: { [weak self] rect in self?.storeLastSmartCaptureArea(rect) },
        shortcutBinding: settings.smartCaptureShortcut
    )

    @MainActor
    deinit {
        captureTask?.cancel()
        permissionPollTask?.cancel()
        smartCapture.stop()
    }

    func shutdown() {
        captureTask?.cancel()
        captureTask = nil
        permissionPollTask?.cancel()
        permissionPollTask = nil
        smartCapture.stop()
    }

    // MARK: - Configuration lifecycle

    func applyLoadedSettings(_ newSettings: ScreenCaptureSettings) {
        isLoading = true
        settings = newSettings
        smartCapture.updateShortcutBinding(newSettings.smartCaptureShortcut)
        diskUsageRevision += 1
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        isPermissionError = false
        isLoading = false
    }

    func activateFromConfiguration() {
        Task { await refreshDiskUsage() }
        updateSmartCaptureRuntime()
        if settings.isEnabled {
            checkAndStartCapture()
        }
    }

    // MARK: - Settings mutations

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        updateSettings { $0.isEnabled = enabled }
        if enabled {
            checkAndStartCapture()
        } else {
            stopCaptureLoop()
        }
    }

    func setOutputFolder(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        updateSettings { $0.outputFolder = path }
        diskUsageRevision += 1
        totalDiskUsage = 0
        screenshotCount = 0
        Task { await refreshDiskUsage() }
    }

    func setBusyStartHour(_ hour: Int) {
        updateSettings { $0.busyStartHour = max(0, min(23, hour)) }
        restartLoopIfRunning()
    }

    func setBusyEndHour(_ hour: Int) {
        updateSettings { $0.busyEndHour = max(0, min(23, hour)) }
        restartLoopIfRunning()
    }

    func setBusyIntervalMinutes(_ minutes: Int) {
        updateSettings { $0.busyIntervalMinutes = max(1, minutes) }
        restartLoopIfRunning()
    }

    func setIdleIntervalMinutes(_ minutes: Int) {
        updateSettings { $0.idleIntervalMinutes = max(1, minutes) }
        restartLoopIfRunning()
    }

    func setImageFormat(_ format: ScreenCaptureImageFormat) {
        updateSettings { $0.imageFormat = format }
    }

    func setQuality(_ quality: Double) {
        updateSettings { $0.quality = max(0.05, min(1.0, quality)) }
    }

    func setMaxRetentionDays(_ days: Int) {
        updateSettings { $0.maxRetentionDays = max(0, days) }
    }

    func setCaptureAllDisplays(_ value: Bool) {
        updateSettings { $0.captureAllDisplays = value }
    }

    func setShowsCursor(_ value: Bool) {
        updateSettings { $0.showsCursor = value }
    }

    func setSmartCaptureEnabled(_ value: Bool) {
        updateSettings { $0.smartCaptureEnabled = value }
        updateSmartCaptureRuntime()
    }

    @discardableResult
    func setSmartCaptureShortcut(_ binding: SmartCaptureShortcutBinding) -> Bool {
        guard let error = smartCapture.updateShortcutBindingReturningError(binding) else {
            updateSettings { $0.smartCaptureShortcut = binding }
            errorMessage = nil
            return true
        }
        errorMessage = AppText.value(error.messageKey, language: language)
        return false
    }

    func suspendSmartCaptureShortcut() {
        smartCapture.suspendShortcut()
    }

    func resumeSmartCaptureShortcut() {
        smartCapture.resumeShortcut()
        if settings.smartCaptureEnabled {
            smartCapture.start()
        }
    }

    func setPinSmartCaptures(_ value: Bool) {
        updateSettings { $0.pinSmartCaptures = value }
    }

    func startSmartCapture() {
        guard ensureCapturePermissions() else { return }
        smartCapture.startSelection()
    }

    func repeatSmartCapture() {
        guard ensureCapturePermissions(), let stored = loadLastSmartCaptureArea(), stored.isValid else {
            errorMessage = AppText.value("scNoLastArea", language: language)
            return
        }
        smartCapture.captureStoredRect(stored.rect)
    }

    private func storeLastSmartCaptureArea(_ rect: CGRect) {
        guard let data = try? JSONEncoder().encode(SmartCaptureStoredRect(rect)) else { return }
        UserDefaults.standard.set(data, forKey: lastAreaDefaultsKey)
    }

    private func loadLastSmartCaptureArea() -> SmartCaptureStoredRect? {
        guard let data = UserDefaults.standard.data(forKey: lastAreaDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SmartCaptureStoredRect.self, from: data)
    }

    private func updateSmartCaptureRuntime() {
        if settings.smartCaptureEnabled {
            smartCapture.start()
        } else {
            smartCapture.stop()
        }
    }

    private func ensureCapturePermissions() -> Bool {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        guard hasScreenPermission else {
            isPermissionError = true
            errorMessage = ScreenCaptureError.permissionRequired.errorDescription
            return false
        }
        return true
    }

    private func handleSmartCapture(_ image: CGImage) {
        SmartCaptureClipboard.copy(image: image)
        let configuration = ScreenCaptureSaveConfiguration(
            outputFolder: smartCaptureOutputFolder(),
            imageFormat: settings.imageFormat,
            quality: settings.quality
        )
        let sendableImage = SendableScreenCaptureImage(value: image)
        Task { [weak self] in
            do {
                let saved = try await Task.detached(priority: .utility) {
                    try autoreleasepool {
                        try ScreenCaptureStorage.save(
                            image: sendableImage,
                            displayIndex: nil,
                            date: Date(),
                            configuration: configuration
                        )
                    }
                }.value
                guard let self else { return }
                self.lastCaptureDate = Date()
                self.lastCaptureSize = saved.size
                self.captureCount += 1
                self.screenshotCount += 1
                self.totalDiskUsage += saved.size
                self.diskUsageRevision += 1
                self.errorMessage = nil
                self.smartCapture.showQuickAccess(
                    image: image,
                    savedURL: saved.url,
                    onSave: { [weak self] image, url in
                        self?.saveEditedSmartCapture(image: image, at: url, configuration: configuration)
                    },
                    onDelete: { [weak self] url in self?.deleteSmartCapture(at: url, size: saved.size) }
                )
            } catch {
                Self.logger.error("Smart capture save failed: \(error.localizedDescription, privacy: .public)")
                self?.errorMessage = error.localizedDescription
                self?.smartCapture.showQuickAccess(image: image, savedURL: nil, onSave: nil, onDelete: nil)
            }
        }
    }

    private func saveEditedSmartCapture(
        image: CGImage,
        at url: URL?,
        configuration: ScreenCaptureSaveConfiguration
    ) {
        guard let url else { return }
        let sendableImage = SendableScreenCaptureImage(value: image)
        Task { [weak self] in
            do {
                let size = try await Task.detached(priority: .utility) {
                    try ScreenCaptureStorage.replace(
                        image: sendableImage,
                        at: url,
                        configuration: configuration
                    )
                }.value
                guard let self else { return }
                self.lastCaptureSize = size
                SmartCaptureClipboard.copy(image: image)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteSmartCapture(at url: URL?, size: Int64) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
            screenshotCount = max(0, screenshotCount - 1)
            totalDiskUsage = max(0, totalDiskUsage - size)
            diskUsageRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func smartCaptureOutputFolder() -> String {
        if settings.isOutputFolderValid { return settings.outputFolder }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let folder = pictures.appendingPathComponent("MacPilot Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    private func updateSettings(_ mutate: (inout ScreenCaptureSettings) -> Void) {
        guard !isLoading else { return }
        mutate(&settings)
        persist?()
    }

    // MARK: - Permission

    func requestScreenPermission() {
        if CGPreflightScreenCaptureAccess() {
            hasScreenPermission = true
            return
        }
        // Opens System Settings -> Screen Recording. Permission takes effect after app restart.
        _ = CGRequestScreenCaptureAccess()
        startPermissionPoll()
    }

    private func startPermissionPoll() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                let granted = CGPreflightScreenCaptureAccess()
                await MainActor.run {
                    self.hasScreenPermission = granted
                    if granted {
                        self.isPermissionError = false
                        self.errorMessage = nil
                    }
                }
                if granted { break }
            }
        }
    }

    // MARK: - Capture loop

    func checkAndStartCapture() {
        guard settings.isEnabled else { stopCaptureLoop(); return }
        guard settings.isOutputFolderValid else {
            errorMessage = ScreenCaptureError.noOutputFolder.errorDescription
            return
        }
        if !hasScreenPermission {
            hasScreenPermission = CGPreflightScreenCaptureAccess()
        }
        if !hasScreenPermission {
            isPermissionError = true
            errorMessage = ScreenCaptureError.permissionRequired.errorDescription
            return
        }
        startCaptureLoop()
    }

    private func startCaptureLoop() {
        captureTask?.cancel()
        isLoopRunning = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            // Immediate first capture when the loop starts.
            await self.performCapture()
            while !Task.isCancelled {
                let interval = await MainActor.run { self.settings.currentIntervalMinutes() }
                let next = Date().addingTimeInterval(TimeInterval(interval * 60))
                await MainActor.run { self.nextCaptureDate = next }
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.performCapture()
            }
        }
    }

    private func stopCaptureLoop() {
        captureTask?.cancel()
        captureTask = nil
        isLoopRunning = false
        nextCaptureDate = nil
    }

    private func restartLoopIfRunning() {
        guard isLoopRunning else { return }
        startCaptureLoop()
    }

    // MARK: - Manual capture

    func captureNow() {
        guard !isCapturing else { return }
        if !hasScreenPermission {
            hasScreenPermission = CGPreflightScreenCaptureAccess()
            if !hasScreenPermission {
                isPermissionError = true
                errorMessage = ScreenCaptureError.permissionRequired.errorDescription
                return
            }
            isPermissionError = false
        }
        Task { await performCapture() }
    }

    // MARK: - Capture execution

    private func performCapture() async {
        guard !isCapturing else { return }
        guard settings.isOutputFolderValid else {
            errorMessage = ScreenCaptureError.noOutputFolder.errorDescription
            return
        }
        // Skip when the display is asleep to avoid blank screenshots.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }

        isCapturing = true
        defer { isCapturing = false }

        do {
            let saved = try await captureAndSaveAllDisplays()
            if !saved.isEmpty {
                lastCaptureDate = Date()
                let savedBytes = saved.reduce(Int64(0)) { $0 + $1.size }
                lastCaptureSize = savedBytes
                captureCount += 1
                screenshotCount += saved.count
                totalDiskUsage += savedBytes
                diskUsageRevision += 1
                errorMessage = nil
                isPermissionError = false
            }
            await cleanupOldScreenshots()
        } catch {
            isPermissionError = false
            errorMessage = error.localizedDescription
        }
    }

    private func captureAndSaveAllDisplays() async throws -> [ScreenCaptureSavedImage] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        let displays: [SCDisplay]
        if settings.captureAllDisplays {
            displays = content.displays
        } else {
            displays = [content.displays.first].compactMap { $0 }
        }

        guard !displays.isEmpty else {
            throw ScreenCaptureError.noDisplayFound
        }

        let saveConfiguration = ScreenCaptureSaveConfiguration(
            outputFolder: settings.outputFolder,
            imageFormat: settings.imageFormat,
            quality: settings.quality
        )
        let showsCursor = settings.showsCursor
        var results: [ScreenCaptureSavedImage] = []
        let multiDisplay = displays.count > 1
        for (index, display) in displays.enumerated() {
            guard let image = try? await captureDisplay(display, showsCursor: showsCursor) else { continue }
            let sendableImage = SendableScreenCaptureImage(value: image)
            let displayIndex = multiDisplay ? index : nil
            let date = Date()
            let saved = try autoreleasepool {
                try ScreenCaptureStorage.save(
                    image: sendableImage,
                    displayIndex: displayIndex,
                    date: date,
                    configuration: saveConfiguration
                )
            }
            results.append(saved)
        }
        return results
    }

    private func captureDisplay(_ display: SCDisplay, showsCursor: Bool) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = true
        let (width, height) = pixelSize(for: display)
        configuration.width = width
        configuration.height = height
        if #available(macOS 14.2, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } else {
            return try await captureDisplayWithStream(filter: filter, configuration: configuration)
        }
    }

    private func captureDisplayWithStream(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let output = LegacyDisplayCaptureOutput(continuation: continuation)
            do {
                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                output.attach(stream: stream)
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "com.misswell.macpilot.screen-capture-fallback")
                )
                Task {
                    do {
                        try await stream.startCapture()
                    } catch {
                        // startCapture can fail before any frame is delivered.
                        // The output object guarantees the continuation resumes once.
                        output.fail(error)
                    }
                }
            } catch {
                output.fail(error)
            }
        }
    }

    /// Returns pixel dimensions for the given display, honouring the backing scale factor.
    private func pixelSize(for display: SCDisplay) -> (width: Int, height: Int) {
        for screen in NSScreen.screens {
            let frame = screen.frame
            if abs(frame.width - CGFloat(display.width)) < 2 && abs(frame.height - CGFloat(display.height)) < 2 {
                let scale = screen.backingScaleFactor
                return (Int(frame.width * scale), Int(frame.height * scale))
            }
        }
        // Fallback: assume retina.
        return (display.width * 2, display.height * 2)
    }

    // MARK: - Disk usage & cleanup

    func refreshDiskUsage() async {
        while !Task.isCancelled {
            guard settings.isOutputFolderValid else {
                totalDiskUsage = 0
                screenshotCount = 0
                return
            }
            let folder = settings.outputFolder
            let revision = diskUsageRevision
            let statistics = await Task.detached(priority: .utility) {
                ScreenCaptureStorage.statistics(at: URL(fileURLWithPath: folder))
            }.value
            guard settings.outputFolder == folder else { continue }
            guard diskUsageRevision == revision else { continue }
            totalDiskUsage = statistics.bytes
            screenshotCount = statistics.count
            diskUsageRevision += 1
            return
        }
    }

    func cleanupOldScreenshots() async {
        guard settings.maxRetentionDays > 0, settings.isOutputFolderValid else { return }
        let folder = settings.outputFolder
        let cutoff = settings.maxRetentionDays
        let revision = diskUsageRevision
        let deleted = await Task.detached(priority: .utility) {
            ScreenCaptureStorage.cleanup(folder: folder, maximumAgeInDays: cutoff)
        }.value
        guard settings.outputFolder == folder, deleted.count > 0 else { return }
        guard diskUsageRevision == revision else {
            await refreshDiskUsage()
            return
        }
        totalDiskUsage = max(0, totalDiskUsage - deleted.bytes)
        screenshotCount = max(0, screenshotCount - deleted.count)
        diskUsageRevision += 1
    }

    // MARK: - Helpers

    func formattedDiskUsage() -> String {
        ByteCountFormatter.string(fromByteCount: totalDiskUsage, countStyle: .file)
    }

    func formattedLastCaptureSize() -> String {
        ByteCountFormatter.string(fromByteCount: lastCaptureSize, countStyle: .file)
    }
}

// MARK: - View

struct ScreenCaptureView: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @ObservedObject var capture: ScreenCaptureModel
    @State private var showingFolderPicker = false
    @State private var showingSmartShortcutEditor = false
    @State private var resetFailureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("screenCapture"))
                    .font(.system(size: 30, weight: .bold))
                Text(t("screenCaptureSubtitle"))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 22)

            ScrollView {
                VStack(spacing: 16) {
                    smartCaptureCard
                    outputCard
                    scheduleCard
                    qualityCard
                    statusCard
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 30)
            }
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                capture.setOutputFolder(url)
            }
        }
        .sheet(isPresented: $showingSmartShortcutEditor) {
            SmartCaptureShortcutEditor(capture: capture)
        }
    }

    private func t(_ key: String, _ args: CVarArg...) -> String {
        AppText.value(key, language: appModel.language, arguments: args)
    }

    // MARK: - Output folder card

    private var smartCaptureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(Color.blue.opacity(0.13))
                    Image(systemName: "viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(t("scSmartCapture")).font(.headline)
                    Text(t("scSmartCaptureHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(capture.settings.smartCaptureShortcut.displayName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(t("scChangeShortcut")) {
                    showingSmartShortcutEditor = true
                }
                .buttonStyle(.bordered)
                Button(t("scRepeatArea")) { capture.repeatSmartCapture() }
                    .buttonStyle(.bordered)
                Button(t("scSmartCaptureNow")) { capture.startSmartCapture() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            Toggle(t("scEnableSmartCapture"), isOn: Binding(
                get: { capture.settings.smartCaptureEnabled },
                set: { capture.setSmartCaptureEnabled($0) }
            ))
            Text(t("scQuickAccessHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(t("scSmartCaptureResources"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Output folder card

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.purple.opacity(0.13))
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(t("scOutputFolder"))
                        .font(.headline)
                    Text(capture.settings.outputFolder.isEmpty
                         ? t("scNoFolder")
                         : capture.settings.outputFolder)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(t("scChooseFolder"), action: { showingFolderPicker = true })
                    .buttonStyle(.bordered)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { capture.settings.captureAllDisplays },
                set: { capture.setCaptureAllDisplays($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("scCaptureAllDisplays"))
                    Text(t("scCaptureAllDisplaysHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: Binding(
                get: { capture.settings.showsCursor },
                set: { capture.setShowsCursor($0) }
            )) {
                Text(t("scShowCursor"))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Schedule card

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("scSchedule"))
                .font(.headline)

            HStack {
                Toggle(isOn: Binding(
                    get: { capture.settings.isEnabled },
                    set: { capture.setEnabled($0) }
                )) {
                    Text(t("scEnableCapture"))
                        .font(.headline)
                }
                Spacer()
                Button(t("scCaptureNow")) { capture.captureNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(capture.isCapturing || !capture.settings.isOutputFolderValid)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(t("scBusyHours"))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 16) {
                    hourPicker(label: t("scStart"), value: Binding(
                        get: { capture.settings.busyStartHour },
                        set: { capture.setBusyStartHour($0) }
                    ))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    hourPicker(label: t("scEnd"), value: Binding(
                        get: { capture.settings.busyEndHour },
                        set: { capture.setBusyEndHour($0) }
                    ))
                    Spacer()
                }
                Text(t("scBusyHoursHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            intervalRow(
                label: t("scBusyInterval"),
                value: capture.settings.busyIntervalMinutes,
                onSet: { capture.setBusyIntervalMinutes($0) }
            )

            intervalRow(
                label: t("scIdleInterval"),
                value: capture.settings.idleIntervalMinutes,
                onSet: { capture.setIdleIntervalMinutes($0) }
            )

            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(t("scCurrentInterval", capture.settings.currentIntervalMinutes()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func intervalRow(label: String, value: Int, onSet: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Stepper(value: Binding(get: { value }, set: { onSet($0) }), in: 1...480, step: 1) {
                Text(t("scMinutesValue", value))
            }
        }
    }

    private func hourPicker(label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(label, selection: value) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
    }

    // MARK: - Quality card

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("scQuality"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(t("scFormat"))
                Picker(t("scFormat"), selection: Binding(
                    get: { capture.settings.imageFormat },
                    set: { capture.setImageFormat($0) }
                )) {
                    ForEach(ScreenCaptureImageFormat.allCases) { format in
                        Text(formatLabel(format)).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if capture.settings.imageFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(t("scCompressionQuality"))
                        Spacer()
                        Text(String(format: "%d%%", Int(capture.settings.quality * 100)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { capture.settings.quality },
                        set: { capture.setQuality($0) }
                    ), in: 0.1...1.0, step: 0.05)
                    Text(t("scQualityHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(t("scRetention"))
                HStack {
                    Stepper(value: Binding(
                        get: { capture.settings.maxRetentionDays },
                        set: { capture.setMaxRetentionDays($0) }
                    ), in: 0...365, step: 1) {
                        Text(capture.settings.maxRetentionDays == 0
                             ? t("scRetentionDisabled")
                             : t("scRetentionDays", capture.settings.maxRetentionDays))
                    }
                    Spacer()
                }
                Text(t("scRetentionHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func formatLabel(_ format: ScreenCaptureImageFormat) -> String {
        switch format {
        case .heic: return t("scFormatHEIC")
        case .jpeg: return t("scFormatJPEG")
        case .png: return t("scFormatPNG")
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("scStatus"))
                .font(.headline)

            if !capture.hasScreenPermission {
                Label(t("scPermissionRequired"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button(t("scGrantPermission")) { capture.requestScreenPermission() }
                        .buttonStyle(.bordered)
                    Button(appModel.isResettingScreenCapture ? t("scResettingPermission") : t("scResetPermission"), role: .destructive) {
                        Task {
                            resetFailureMessage = await appModel.resetScreenCapturePermission(presentFailureAlert: false)
                            guard resetFailureMessage == nil else { return }
                            appModel.terminateAfterSheetsClose()
                        }
                    }
                    .disabled(appModel.isResettingScreenCapture)
                }
                Label(t("scPermissionRecoveryHint"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetFailureMessage {
                    Text(resetFailureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if capture.isPermissionError {
                Label(t("scPermissionRestartHint"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if let error = capture.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack(spacing: 24) {
                statusItem(t("scStatusRunning"), value: capture.isLoopRunning ? t("scYes") : t("scNo"))
                statusItem(t("scCaptureCount"), value: "\(capture.captureCount)")
                statusItem(t("scScreenshotCount"), value: "\(capture.screenshotCount)")
            }

            HStack(spacing: 24) {
                statusItem(t("scDiskUsage"), value: capture.formattedDiskUsage())
                if let lastDate = capture.lastCaptureDate {
                    statusItem(t("scLastCapture"), value: lastDate.formatted(.dateTime.hour().minute().month().day().locale(appModel.language.locale)))
                }
                if capture.lastCaptureSize > 0 {
                    statusItem(t("scLastSize"), value: capture.formattedLastCaptureSize())
                }
            }

            if let nextDate = capture.nextCaptureDate, capture.isLoopRunning {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(t("scNextCapture", nextDate.formatted(.dateTime.hour().minute().locale(appModel.language.locale))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func statusItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}

private struct SmartCaptureShortcutEditor: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var capture: ScreenCaptureModel
    @State private var recordedKeyCode: UInt16?
    @State private var recordedModifiers: InputSourceShortcutModifiers
    @State private var validationMessage: String?

    init(capture: ScreenCaptureModel) {
        self.capture = capture
        _recordedKeyCode = State(initialValue: capture.settings.smartCaptureShortcut.keyCode)
        _recordedModifiers = State(initialValue: capture.settings.smartCaptureShortcut.modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppText.value("scChangeShortcut", language: appModel.language))
                .font(.title2.bold())
            Text(AppText.value("scShortcutHint", language: appModel.language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SmartCaptureShortcutRecorder(
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                placeholder: AppText.value("scRecordShortcut", language: appModel.language)
            )
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button(AppText.value("scResetShortcut", language: appModel.language)) {
                    recordedKeyCode = SmartCaptureShortcutBinding.default.keyCode
                    recordedModifiers = SmartCaptureShortcutBinding.default.modifiers
                }
                Spacer()
                Button(AppText.value("cancel", language: appModel.language), role: .cancel) { dismiss() }
                Button(AppText.value("save", language: appModel.language)) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(recordedKeyCode == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { capture.suspendSmartCaptureShortcut() }
        .onDisappear { capture.resumeSmartCaptureShortcut() }
    }

    private func save() {
        guard let recordedKeyCode else { return }
        let didSave = capture.setSmartCaptureShortcut(SmartCaptureShortcutBinding(
            keyCode: recordedKeyCode,
            modifiers: recordedModifiers
        ))
        if didSave { dismiss() }
        else { validationMessage = capture.errorMessage }
    }
}

private struct SmartCaptureShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16?
    @Binding var modifiers: InputSourceShortcutModifiers
    let placeholder: String

    func makeNSView(context: Context) -> SmartCaptureShortcutRecorderNSView {
        let view = SmartCaptureShortcutRecorderNSView()
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.placeholder = placeholder
        view.onCapture = { keyCode, modifiers in
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
        return view
    }

    func updateNSView(_ nsView: SmartCaptureShortcutRecorderNSView, context: Context) {
        nsView.keyCode = keyCode
        nsView.modifiers = modifiers
        nsView.placeholder = placeholder
        nsView.needsDisplay = true
    }
}

@MainActor
private final class SmartCaptureShortcutRecorderNSView: NSView {
    var keyCode: UInt16?
    var modifiers: InputSourceShortcutModifiers = []
    var placeholder = ""
    var onCapture: ((UInt16, InputSourceShortcutModifiers) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        let modifierKeys: Set<UInt16> = [
            UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), UInt16(kVK_RightCommand)
        ]
        guard !modifierKeys.contains(event.keyCode), event.keyCode != UInt16(kVK_Escape) else { return }
        let modifiers = InputSourceShortcutModifiers(event.modifierFlags)
        let isFunctionKey = SmartCaptureShortcutBinding(
            keyCode: event.keyCode,
            modifiers: []
        ).validationError == nil
        guard isFunctionKey || !modifiers.isEmpty else { return }
        onCapture?(event.keyCode, modifiers)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let title = keyCode.map { modifiers.symbolDescription + MacPilotKeyCode.displayName(for: $0) } ?? placeholder
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: keyCode == nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
    }
}
