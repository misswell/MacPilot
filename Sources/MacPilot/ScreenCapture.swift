// ScreenCapture.swift
// Periodic screenshot capture with busy/idle scheduling and high-efficiency HEIC encoding.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

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
    var smartCaptureShortcut: SmartCaptureShortcutBinding
    var areaCaptureShortcut: SmartCaptureShortcutBinding
    var repeatAreaCaptureShortcut: SmartCaptureShortcutBinding
    var applicationWindowCaptureShortcut: SmartCaptureShortcutBinding
    var fullscreenCaptureShortcut: SmartCaptureShortcutBinding
    var activeWindowCaptureShortcut: SmartCaptureShortcutBinding
    var areaAnnotateShortcut: SmartCaptureShortcutBinding
    var ocrShortcut: SmartCaptureShortcutBinding
    var scrollingCaptureShortcut: SmartCaptureShortcutBinding
    var objectCutoutShortcut: SmartCaptureShortcutBinding
    var copyAfterCapture: Bool
    var showQuickAccess: Bool
    var pinAfterCapture: Bool

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
        smartCaptureShortcut: SmartCaptureShortcutBinding = .default,
        areaCaptureShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.area.defaultBinding,
        repeatAreaCaptureShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.repeatArea.defaultBinding,
        applicationWindowCaptureShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.applicationWindow.defaultBinding,
        fullscreenCaptureShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.fullscreen.defaultBinding,
        activeWindowCaptureShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.activeWindow.defaultBinding,
        areaAnnotateShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.areaAnnotate.defaultBinding,
        ocrShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.ocr.defaultBinding,
        scrollingCaptureShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.scrolling.defaultBinding,
        objectCutoutShortcut: SmartCaptureShortcutBinding = ScreenCaptureShortcutKind.objectCutout.defaultBinding,
        copyAfterCapture: Bool = true,
        showQuickAccess: Bool = true,
        pinAfterCapture: Bool = false,
        migrateLegacyScreenshotShortcuts: Bool = false
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
        self.smartCaptureShortcut = smartCaptureShortcut.isValid ? smartCaptureShortcut : .default
        let safeAreaShortcut = areaCaptureShortcut.isValid ? areaCaptureShortcut : ScreenCaptureShortcutKind.area.defaultBinding
        let safeRepeatAreaShortcut = repeatAreaCaptureShortcut.isValid ? repeatAreaCaptureShortcut : ScreenCaptureShortcutKind.repeatArea.defaultBinding
        let safeFullscreenShortcut = fullscreenCaptureShortcut.isValid ? fullscreenCaptureShortcut : ScreenCaptureShortcutKind.fullscreen.defaultBinding
        self.areaCaptureShortcut = migrateLegacyScreenshotShortcuts
            ? ScreenCaptureShortcutKind.area.migratedBinding(safeAreaShortcut)
            : safeAreaShortcut
        self.repeatAreaCaptureShortcut = migrateLegacyScreenshotShortcuts
            ? ScreenCaptureShortcutKind.repeatArea.migratedBinding(safeRepeatAreaShortcut)
            : safeRepeatAreaShortcut
        self.applicationWindowCaptureShortcut = applicationWindowCaptureShortcut.isValid ? applicationWindowCaptureShortcut : ScreenCaptureShortcutKind.applicationWindow.defaultBinding
        self.fullscreenCaptureShortcut = migrateLegacyScreenshotShortcuts
            ? ScreenCaptureShortcutKind.fullscreen.migratedBinding(safeFullscreenShortcut)
            : safeFullscreenShortcut
        self.activeWindowCaptureShortcut = activeWindowCaptureShortcut.isValid ? activeWindowCaptureShortcut : ScreenCaptureShortcutKind.activeWindow.defaultBinding
        self.areaAnnotateShortcut = areaAnnotateShortcut.isValid ? areaAnnotateShortcut : ScreenCaptureShortcutKind.areaAnnotate.defaultBinding
        self.ocrShortcut = ocrShortcut.isValid ? ocrShortcut : ScreenCaptureShortcutKind.ocr.defaultBinding
        self.scrollingCaptureShortcut = scrollingCaptureShortcut.isValid ? scrollingCaptureShortcut : ScreenCaptureShortcutKind.scrolling.defaultBinding
        self.objectCutoutShortcut = objectCutoutShortcut.isValid ? objectCutoutShortcut : ScreenCaptureShortcutKind.objectCutout.defaultBinding
        self.copyAfterCapture = copyAfterCapture
        self.showQuickAccess = showQuickAccess
        self.pinAfterCapture = pinAfterCapture
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, outputFolder, busyStartHour, busyEndHour
        case busyIntervalMinutes, idleIntervalMinutes, imageFormat, quality
        case maxRetentionDays, captureAllDisplays, showsCursor, smartCaptureEnabled
        case smartCaptureShortcut, areaCaptureShortcut, repeatAreaCaptureShortcut, applicationWindowCaptureShortcut, fullscreenCaptureShortcut, activeWindowCaptureShortcut, areaAnnotateShortcut, ocrShortcut, scrollingCaptureShortcut, objectCutoutShortcut
        case copyAfterCapture, showQuickAccess, pinAfterCapture
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
            smartCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .smartCaptureShortcut) ?? .default,
            areaCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .areaCaptureShortcut) ?? ScreenCaptureShortcutKind.area.defaultBinding,
            repeatAreaCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .repeatAreaCaptureShortcut) ?? ScreenCaptureShortcutKind.repeatArea.defaultBinding,
            applicationWindowCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .applicationWindowCaptureShortcut) ?? ScreenCaptureShortcutKind.applicationWindow.defaultBinding,
            fullscreenCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .fullscreenCaptureShortcut) ?? ScreenCaptureShortcutKind.fullscreen.defaultBinding,
            activeWindowCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .activeWindowCaptureShortcut) ?? ScreenCaptureShortcutKind.activeWindow.defaultBinding,
            areaAnnotateShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .areaAnnotateShortcut) ?? ScreenCaptureShortcutKind.areaAnnotate.defaultBinding,
            ocrShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .ocrShortcut) ?? ScreenCaptureShortcutKind.ocr.defaultBinding,
            scrollingCaptureShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .scrollingCaptureShortcut) ?? ScreenCaptureShortcutKind.scrolling.defaultBinding,
            objectCutoutShortcut: try c.decodeIfPresent(SmartCaptureShortcutBinding.self, forKey: .objectCutoutShortcut) ?? ScreenCaptureShortcutKind.objectCutout.defaultBinding,
            copyAfterCapture: try c.decodeIfPresent(Bool.self, forKey: .copyAfterCapture) ?? true,
            showQuickAccess: try c.decodeIfPresent(Bool.self, forKey: .showQuickAccess) ?? true,
            pinAfterCapture: try c.decodeIfPresent(Bool.self, forKey: .pinAfterCapture) ?? false,
            migrateLegacyScreenshotShortcuts: true
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

struct SendableScreenCaptureImage: @unchecked Sendable {
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

private struct ScreenCaptureMediaMetadata: Sendable {
    let width: Int
    let height: Int
    let duration: TimeInterval?
    let byteCount: Int64
    let kind: SmartCaptureHistoryKind
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
    @Published private(set) var captureHistory: [SmartCaptureHistoryItem] = []
    var language: AppLanguage = .system

    var persist: (() -> Void)?
    /// Receives the Quartz-space rectangle selected by the shared overlay
    /// when a recording starts in area/application mode.
    var onRecordingSelection: ((CGRect, ScreenRecordingCaptureMode) -> Void)?
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
            if let captureError = error as? ScreenCaptureError,
               case .permissionRequired = captureError {
                self.hasScreenPermission = false
                self.isPermissionError = true
                self.errorMessage = AppText.value("scPermissionRequired", language: self.language)
                return
            }
            if let shortcutError = error as? SmartCaptureShortcutError {
                self.errorMessage = AppText.value(shortcutError.messageKey, language: self.language)
            } else {
                self.errorMessage = error.localizedDescription
            }
        },
        onSelectionRect: { [weak self] rect in self?.storeLastSmartCaptureArea(rect) },
        onRecordingSelection: { [weak self] rect, mode in
            guard let self else { return }
            let recordingMode: ScreenRecordingCaptureMode =
                mode == .recordingApplication ? .application : .area
            guard let quartzRect = SmartCaptureCoordinateConversion.quartzRect(fromAppKitRect: rect) else {
                self.errorMessage = AppText.value("scCaptureCoordinateUnavailable", language: self.language)
                return
            }
            self.onRecordingSelection?(quartzRect, recordingMode)
        },
        onRepeatLastArea: { [weak self] in self?.repeatSmartCapture() },
        shortcutBinding: settings.smartCaptureShortcut,
        additionalShortcutBindings: [
            .area: settings.areaCaptureShortcut,
            .repeatArea: settings.repeatAreaCaptureShortcut,
            .applicationWindow: settings.applicationWindowCaptureShortcut,
            .fullscreen: settings.fullscreenCaptureShortcut,
            .activeWindow: settings.activeWindowCaptureShortcut,
            .areaAnnotate: settings.areaAnnotateShortcut,
            .ocr: settings.ocrShortcut,
            .scrolling: settings.scrollingCaptureShortcut,
            .objectCutout: settings.objectCutoutShortcut
        ],
        onFullscreenCapture: { [weak self] in self?.captureFullscreen() },
        onActiveWindowCapture: { [weak self] in self?.captureActiveWindow() },
        onAreaAnnotateCapture: { [weak self] image in self?.presentAreaAnnotation(image) },
        onOCRCapture: { [weak self] image in self?.handleOCRCapture(image) },
        onScrollingCapture: { [weak self] image in self?.handleSmartCapture(image) },
        onObjectCutoutCapture: { [weak self] image in self?.handleObjectCutout(image) }
    )

    deinit {
        captureTask?.cancel()
        permissionPollTask?.cancel()
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
        smartCapture.updateAdditionalShortcutBindings([
            .area: newSettings.areaCaptureShortcut,
            .repeatArea: newSettings.repeatAreaCaptureShortcut,
            .applicationWindow: newSettings.applicationWindowCaptureShortcut,
            .fullscreen: newSettings.fullscreenCaptureShortcut,
            .activeWindow: newSettings.activeWindowCaptureShortcut,
            .areaAnnotate: newSettings.areaAnnotateShortcut,
            .ocr: newSettings.ocrShortcut,
            .scrolling: newSettings.scrollingCaptureShortcut,
            .objectCutout: newSettings.objectCutoutShortcut
        ])
        diskUsageRevision += 1
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        isPermissionError = false
        isLoading = false
    }

    func activateFromConfiguration() {
        captureHistory = SmartCaptureHistoryStore.load()
        Task { await refreshDiskUsage() }
        updateSmartCaptureRuntime()
        // Snapzy QuickAccess preview: clean orphaned temp captures from earlier
        // sessions, and route the card's "标注" action to the annotation editor.
        TempCaptureManager.shared.cleanupOrphanedFiles()
        AnnotateManager.shared.onOpenAnnotation = { [weak self] item in
            self?.smartCapture.presentQuickAccessAnnotation(for: item)
        }
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

    func setCopyAfterCapture(_ value: Bool) {
        updateSettings { $0.copyAfterCapture = value }
    }

    func setShowQuickAccess(_ value: Bool) {
        updateSettings { $0.showQuickAccess = value }
    }

    func setPinAfterCapture(_ value: Bool) {
        updateSettings { $0.pinAfterCapture = value }
    }

    func setSmartCaptureEnabled(_ value: Bool) {
        updateSettings { $0.smartCaptureEnabled = value }
        updateSmartCaptureRuntime()
    }

    @discardableResult
    func setShortcut(_ kind: ScreenCaptureShortcutKind, binding: SmartCaptureShortcutBinding) -> Bool {
        var updated = settings
        switch kind {
        case .smartElement: updated.smartCaptureShortcut = binding
        case .area: updated.areaCaptureShortcut = binding
        case .repeatArea: updated.repeatAreaCaptureShortcut = binding
        case .applicationWindow: updated.applicationWindowCaptureShortcut = binding
        case .fullscreen: updated.fullscreenCaptureShortcut = binding
        case .activeWindow: updated.activeWindowCaptureShortcut = binding
        case .areaAnnotate: updated.areaAnnotateShortcut = binding
        case .ocr: updated.ocrShortcut = binding
        case .scrolling: updated.scrollingCaptureShortcut = binding
        case .objectCutout: updated.objectCutoutShortcut = binding
        }
        guard binding.isValid else {
            errorMessage = AppText.value(binding.validationError?.messageKey ?? "scShortcutRegistrationFailed", language: language)
            return false
        }
        if kind != .smartElement, binding == updated.smartCaptureShortcut {
            errorMessage = AppText.value("scShortcutRegistrationFailed", language: language)
            return false
        }
        if kind != .smartElement {
            let others = [updated.areaCaptureShortcut, updated.repeatAreaCaptureShortcut, updated.applicationWindowCaptureShortcut, updated.fullscreenCaptureShortcut, updated.activeWindowCaptureShortcut, updated.areaAnnotateShortcut, updated.ocrShortcut, updated.scrollingCaptureShortcut, updated.objectCutoutShortcut]
            if others.filter({ $0 == binding }).count > 1 {
                errorMessage = AppText.value("scShortcutRegistrationFailed", language: language)
                return false
            }
        }
        let bindings: [ScreenCaptureShortcutKind: SmartCaptureShortcutBinding] = [
            .area: updated.areaCaptureShortcut,
            .repeatArea: updated.repeatAreaCaptureShortcut,
            .applicationWindow: updated.applicationWindowCaptureShortcut,
            .fullscreen: updated.fullscreenCaptureShortcut,
            .activeWindow: updated.activeWindowCaptureShortcut,
            .areaAnnotate: updated.areaAnnotateShortcut,
            .ocr: updated.ocrShortcut,
            .scrolling: updated.scrollingCaptureShortcut,
            .objectCutout: updated.objectCutoutShortcut
        ]
        if kind == .smartElement {
            guard setSmartCaptureShortcut(binding) else { return false }
        } else {
            if let error = smartCapture.updateAdditionalShortcutBindingsReturningError(bindings, requiredKind: kind) {
                errorMessage = AppText.value(error.messageKey, language: language)
                return false
            }
            updateSettings {
                $0.areaCaptureShortcut = updated.areaCaptureShortcut
                $0.repeatAreaCaptureShortcut = updated.repeatAreaCaptureShortcut
                $0.applicationWindowCaptureShortcut = updated.applicationWindowCaptureShortcut
                $0.fullscreenCaptureShortcut = updated.fullscreenCaptureShortcut
                $0.activeWindowCaptureShortcut = updated.activeWindowCaptureShortcut
                $0.areaAnnotateShortcut = updated.areaAnnotateShortcut
                $0.ocrShortcut = updated.ocrShortcut
                $0.scrollingCaptureShortcut = updated.scrollingCaptureShortcut
                $0.objectCutoutShortcut = updated.objectCutoutShortcut
            }
            errorMessage = nil
        }
        return true
    }

    func shortcutBinding(for kind: ScreenCaptureShortcutKind) -> SmartCaptureShortcutBinding {
        switch kind {
        case .smartElement: return settings.smartCaptureShortcut
        case .area: return settings.areaCaptureShortcut
        case .repeatArea: return settings.repeatAreaCaptureShortcut
        case .applicationWindow: return settings.applicationWindowCaptureShortcut
        case .fullscreen: return settings.fullscreenCaptureShortcut
        case .activeWindow: return settings.activeWindowCaptureShortcut
        case .areaAnnotate: return settings.areaAnnotateShortcut
        case .ocr: return settings.ocrShortcut
        case .scrolling: return settings.scrollingCaptureShortcut
        case .objectCutout: return settings.objectCutoutShortcut
        }
    }

    @discardableResult
    func setSmartCaptureShortcut(_ binding: SmartCaptureShortcutBinding) -> Bool {
        if [settings.areaCaptureShortcut, settings.repeatAreaCaptureShortcut, settings.applicationWindowCaptureShortcut, settings.fullscreenCaptureShortcut, settings.activeWindowCaptureShortcut, settings.areaAnnotateShortcut, settings.ocrShortcut, settings.scrollingCaptureShortcut, settings.objectCutoutShortcut].contains(binding) {
            errorMessage = AppText.value("scShortcutRegistrationFailed", language: language)
            return false
        }
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
        smartCapture.resumeShortcut(register: settings.smartCaptureEnabled)
    }

    func startSmartCapture() {
        startSelection(mode: .smartElement)
    }

    func startAreaCapture() {
        startSelection(mode: .manualArea)
    }

    func startRecordingSelection(mode: ScreenRecordingCaptureMode) {
        guard mode != .fullscreen else { return }
        startSelection(mode: mode == .application ? .recordingApplication : .recordingArea)
    }

    func startApplicationWindowCapture() {
        startSelection(mode: .applicationWindow)
    }

    func captureFullscreen() {
        guard ensureCapturePermissions() else { return }
        Task { await captureFullscreenAndHandleResult() }
    }

    func captureActiveWindow() {
        guard ensureCapturePermissions() else { return }
        Task { await captureActiveWindowAndHandleResult() }
    }

    func startOCRCapture() {
        startSelection(mode: .ocr)
    }

    func startAreaAnnotateCapture() {
        startSelection(mode: .areaAnnotate)
    }

    func startScrollingCapture() {
        startSelection(mode: .scrolling)
    }

    func startObjectCutoutCapture() {
        startSelection(mode: .objectCutout)
    }

    private func handleObjectCutout(_ image: CGImage) {
        Task { [weak self] in
            do {
                let cutout = try await ScreenCaptureObjectCutout.removeBackground(from: image)
                await MainActor.run { self?.handleCapturedImage(cutout, imageFormat: .png) }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    let detail: String
                    if let cutoutError = error as? ScreenCaptureObjectCutout.Error {
                        switch cutoutError {
                        case .noForegroundObject:
                            detail = AppText.value("scObjectCutoutNoForeground", language: self.language)
                        case .maskRenderFailed:
                            detail = AppText.value("scObjectCutoutMaskFailed", language: self.language)
                        }
                    } else {
                        detail = error.localizedDescription
                    }
                    self.errorMessage = AppText.value(
                        "scObjectCutoutFailed",
                        language: self.language,
                        arguments: [detail]
                    )
                }
            }
        }
    }

    /// Starts an interactive capture after the user explicitly requested it.
    /// When Screen Recording is not yet granted, report the state and leave
    /// the explicit permission request to the settings-page grant button.
    /// Global shortcuts must never trigger a fresh TCC prompt implicitly.
    private func startSelection(mode: SmartCaptureSelectionMode) {
        guard ensureCapturePermissions() else {
            // This path is used by explicit menu/deep-link actions. Opening
            // the exact System Settings pane makes the missing permission
            // actionable without prompting from a background hotkey.
            openScreenCaptureSettings()
            return
        }
        smartCapture.startSelection(mode: mode)
    }

    private func presentAreaAnnotation(_ image: CGImage) {
        smartCapture.presentInlineAnnotation(for: image)
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
        handleCapturedImage(image)
    }

    func showRecordingQuickAccess(url: URL) {
        recordMediaHistory(url)
        smartCapture.showQuickAccess(mediaURL: url)
    }

    /// Adds a finished video or GIF to the same persistent history used by
    /// screenshots. Metadata work runs off-main so recording completion never
    /// waits on AVFoundation's track inspection.
    func recordMediaHistory(_ url: URL) {
        let sourceURL = url
        Task { [weak self] in
            let metadata = await Task.detached(priority: .utility) {
                await Self.mediaMetadata(for: sourceURL)
            }.value
            guard let self else { return }
            let item = SmartCaptureHistoryItem(
                url: sourceURL,
                width: metadata.width,
                height: metadata.height,
                byteCount: metadata.byteCount,
                kind: metadata.kind,
                duration: metadata.duration
            )
            self.captureHistory.removeAll { $0.url == sourceURL }
            self.captureHistory.insert(item, at: 0)
            self.captureHistory = Array(self.captureHistory.prefix(60))
            SmartCaptureHistoryStore.save(self.captureHistory)
        }
    }

    func editHistoryItem(_ item: SmartCaptureHistoryItem) {
        guard item.kind.isMedia else {
            revealHistoryItem(item)
            return
        }
        smartCapture.openMediaEditor(url: item.url)
    }

    private nonisolated static func mediaMetadata(for url: URL) async -> ScreenCaptureMediaMetadata {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let kind: SmartCaptureHistoryKind = url.pathExtension.lowercased() == "gif" ? .gif : .video
        guard kind == .video else {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let properties = source.flatMap {
                CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
            }
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            return ScreenCaptureMediaMetadata(width: width, height: height, duration: nil, byteCount: byteCount, kind: kind)
        }
        let asset = AVURLAsset(url: url)
        let track = (try? await asset.loadTracks(withMediaType: .video))?.first
        let naturalSize = (try? await track?.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await track?.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let duration = seconds.isFinite && seconds > 0 ? seconds : nil
        return ScreenCaptureMediaMetadata(width: width, height: height, duration: duration, byteCount: byteCount, kind: kind)
    }

    private func handleCapturedImage(
        _ image: CGImage,
        displayIndex: Int? = nil,
        imageFormat: ScreenCaptureImageFormat? = nil
    ) {
        if settings.copyAfterCapture {
            SmartCaptureClipboard.copy(image: image)
        }
        let configuration = ScreenCaptureSaveConfiguration(
            outputFolder: smartCaptureOutputFolder(),
            imageFormat: imageFormat ?? settings.imageFormat,
            quality: settings.quality
        )
        let sendableImage = SendableScreenCaptureImage(value: image)
        let quickAccessPreviewID: UUID?
        if settings.showQuickAccess {
            let tempURL = TempCaptureManager.shared.makeScreenshotURL()
            let thumbnail = QuickAccessManager.cgImageThumbnail(image)
            if let item = QuickAccessManager.shared.addScreenshot(url: tempURL, thumbnail: thumbnail) {
                let itemID = item.id
                quickAccessPreviewID = itemID
                Task.detached(priority: .utility) {
                    let didWrite = TempCaptureManager.writeScreenshot(sendableImage, to: tempURL)
                    if !didWrite {
                        await QuickAccessManager.shared.removeScreenshot(id: itemID)
                    }
                }
            } else {
                quickAccessPreviewID = nil
            }
        } else {
            quickAccessPreviewID = nil
        }
        Task { [weak self] in
            do {
                let saved = try await Task.detached(priority: .utility) {
                    try autoreleasepool {
                        try ScreenCaptureStorage.save(
                            image: sendableImage,
                            displayIndex: displayIndex,
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
                self.captureHistory.removeAll { $0.url == saved.url }
                self.captureHistory.insert(
                    SmartCaptureHistoryItem(
                        url: saved.url,
                        width: image.width,
                        height: image.height,
                        byteCount: saved.size
                    ),
                    at: 0
                )
                self.captureHistory = Array(self.captureHistory.prefix(60))
                SmartCaptureHistoryStore.save(self.captureHistory)
                self.errorMessage = nil
                if self.settings.pinAfterCapture {
                    _ = await QuickAccessManager.shared.pinScreenshot(url: saved.url)
                }
            } catch {
                Self.logger.error("Smart capture save failed: \(error.localizedDescription, privacy: .public)")
                self?.errorMessage = error.localizedDescription
                if self?.settings.showQuickAccess == true, quickAccessPreviewID == nil {
                    if let tempURL = TempCaptureManager.shared.saveScreenshot(image) {
                        await QuickAccessManager.shared.addScreenshot(url: tempURL)
                    }
                }
            }
        }
    }

    private func handleOCRCapture(_ image: CGImage) {
        let sendableImage = SendableScreenCaptureImage(value: image)
        Task.detached(priority: .userInitiated) {
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                let handler = VNImageRequestHandler(cgImage: sendableImage.value, options: [:])
                try handler.perform([request])
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                let qrCodes = (try? ScreenCaptureQRCode.detect(in: sendableImage.value)) ?? []
                let combined = (qrCodes + (text.isEmpty ? [] : [text])).joined(separator: "\n")
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(combined, forType: .string)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func captureFullscreenAndHandleResult() async {
        do {
            let image: CGImage
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = activeDisplay(from: content.displays) else {
                    throw ScreenCaptureError.noDisplayFound
                }
                image = try await captureDisplay(display, showsCursor: settings.showsCursor)
            } catch {
                guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
                      let displayID = screen.displayID,
                      let snapshot = SmartDisplaySnapshotCapture.capture(displayID: displayID) else {
                    throw error
                }
                image = snapshot
            }
            handleCapturedImage(image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func captureActiveWindowAndHandleResult() async {
        do {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let pid, pid != getpid() else {
                throw ScreenCaptureError.captureFailed(AppText.value("scActiveWindowUnavailable", language: language))
            }
            let image: CGImage
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = preferredCaptureWindow(from: content.windows, processID: pid) else {
                    throw ScreenCaptureError.captureFailed(AppText.value("scActiveWindowUnavailable", language: language))
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.scalesToFit = true
                configuration.showsCursor = false
                configuration.width = max(1, window.frame.width > 0 ? Int(window.frame.width * 2) : 1)
                configuration.height = max(1, window.frame.height > 0 ? Int(window.frame.height * 2) : 1)
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                guard let windowID = SmartWindowSnapshotCapture.frontmostWindowID(processID: pid),
                      let fallback = SmartWindowSnapshotCapture.capture(windowID: windowID) else {
                    throw error
                }
                image = fallback
            }
            handleCapturedImage(image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preferredCaptureWindow(from windows: [SCWindow], processID: pid_t) -> SCWindow? {
        let candidates = windows.filter {
            $0.owningApplication?.processID == processID && $0.isOnScreen && $0.windowID != 0
                && $0.frame.width >= 80 && $0.frame.height >= 60
        }
        let titled = candidates.filter { !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return titled.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private func activeDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            return displays.max { lhs, rhs in
                let lhsDistance = abs(CGFloat(lhs.width) - screen.frame.width) + abs(CGFloat(lhs.height) - screen.frame.height)
                let rhsDistance = abs(CGFloat(rhs.width) - screen.frame.width) + abs(CGFloat(rhs.height) - screen.frame.height)
                return lhsDistance > rhsDistance
            }
        }
        return displays.first
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
                if self.settings.copyAfterCapture {
                    SmartCaptureClipboard.copy(image: image)
                }
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
            if let item = captureHistory.first(where: { $0.url == url }) {
                captureHistory = SmartCaptureHistoryStore.remove(item.id, from: captureHistory)
                SmartCaptureHistoryStore.save(captureHistory)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteHistoryItem(_ item: SmartCaptureHistoryItem) {
        if FileManager.default.fileExists(atPath: item.path) {
            try? FileManager.default.removeItem(at: item.url)
        }
        captureHistory = SmartCaptureHistoryStore.remove(item.id, from: captureHistory)
        SmartCaptureHistoryStore.save(captureHistory)
        Task { await refreshDiskUsage() }
    }

    func revealHistoryItem(_ item: SmartCaptureHistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
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
        // Permission is requested only by this explicit settings action. All
        // capture shortcuts and menu entries remain side-effect free.
        _ = CGRequestScreenCaptureAccess()
        startPermissionPoll()
    }

    func openScreenCaptureSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.ScreenCapture-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
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
        let saveConfiguration = ScreenCaptureSaveConfiguration(
            outputFolder: settings.outputFolder,
            imageFormat: settings.imageFormat,
            quality: settings.quality
        )
        let showsCursor = settings.showsCursor
        var capturedImages: [(image: CGImage, displayIndex: Int?)] = []
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            let displays = settings.captureAllDisplays ? content.displays : [content.displays.first].compactMap { $0 }
            let multiDisplay = displays.count > 1
            for (index, display) in displays.enumerated() {
                guard let image = try? await captureDisplay(display, showsCursor: showsCursor) else { continue }
                capturedImages.append((image, multiDisplay ? index : nil))
            }
        }

        if capturedImages.isEmpty {
            let screens = settings.captureAllDisplays ? NSScreen.screens : [NSScreen.main].compactMap { $0 }
            let multiDisplay = screens.count > 1
            for (index, screen) in screens.enumerated() {
                guard let displayID = screen.displayID,
                      let image = SmartDisplaySnapshotCapture.capture(displayID: displayID) else { continue }
                capturedImages.append((image, multiDisplay ? index : nil))
            }
        }

        guard !capturedImages.isEmpty else { throw ScreenCaptureError.noDisplayFound }
        return try capturedImages.map { captured in
            try autoreleasepool {
                try ScreenCaptureStorage.save(
                    image: SendableScreenCaptureImage(value: captured.image),
                    displayIndex: captured.displayIndex,
                    date: Date(),
                    configuration: saveConfiguration
                )
            }
        }
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
        try await SnapzySingleFrameCaptureSession.capture(
            contentFilter: filter,
            configuration: configuration
        )
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
    @ObservedObject var recording: ScreenRecordingModel
    @Binding var openShortcutEditor: Bool
    @State private var showingFolderPicker = false
    @State private var showingSmartShortcutEditor = false
    @State private var showingShortcutListEditor = false
    @State private var showingRecordingShortcutEditor = false
    @State private var editingShortcutKind: ScreenCaptureShortcutKind = .smartElement
    @State private var resetFailureMessage: String?

    init(
        capture: ScreenCaptureModel,
        recording: ScreenRecordingModel,
        openShortcutEditor: Binding<Bool> = .constant(false)
    ) {
        self.capture = capture
        self.recording = recording
        self._openShortcutEditor = openShortcutEditor
    }

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
                    recordingCard
                    outputCard
                    scheduleCard
                    qualityCard
                    historyCard
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
            SmartCaptureShortcutEditor(capture: capture, kind: editingShortcutKind)
        }
        .sheet(isPresented: $showingShortcutListEditor) {
            SmartCaptureShortcutListEditor(capture: capture)
        }
        .sheet(isPresented: $openShortcutEditor) {
            SmartCaptureShortcutListEditor(capture: capture)
        }
        .sheet(isPresented: $showingRecordingShortcutEditor) {
            ScreenRecordingShortcutEditor(recording: recording)
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
                shortcutBadge(for: .smartElement)
                Button(t("scChangeShortcut")) { editShortcut(.smartElement) }
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
            Toggle(t("scCopyAfterCapture"), isOn: Binding(
                get: { capture.settings.copyAfterCapture },
                set: { capture.setCopyAfterCapture($0) }
            ))
            .toggleStyle(.checkbox)
            Toggle(t("scShowQuickAccess"), isOn: Binding(
                get: { capture.settings.showQuickAccess },
                set: { capture.setShowQuickAccess($0) }
            ))
            .toggleStyle(.checkbox)
            Toggle(t("scPinAfterSmartCapture"), isOn: Binding(
                get: { capture.settings.pinAfterCapture },
                set: { capture.setPinAfterCapture($0) }
            ))
            .toggleStyle(.checkbox)
            Text(t("scSmartCaptureResources"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                Text(t("scShortcutModes"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    showingShortcutListEditor = true
                } label: {
                    Label(t("scEditShortcuts"), systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
            }
            shortcutRow(.area, action: { capture.startAreaCapture() })
            shortcutRow(.repeatArea, action: { capture.repeatSmartCapture() })
            shortcutRow(.applicationWindow, action: { capture.startApplicationWindowCapture() })
            shortcutRow(.fullscreen, action: { capture.captureFullscreen() })
            shortcutRow(.activeWindow, action: { capture.captureActiveWindow() })
            shortcutRow(.areaAnnotate, action: { capture.startAreaAnnotateCapture() })
            shortcutRow(.ocr, action: { capture.startOCRCapture() })
            shortcutRow(.scrolling, action: { capture.startScrollingCapture() })
            shortcutRow(.objectCutout, action: { capture.startObjectCutoutCapture() })
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(Color.red.opacity(0.13))
                    Image(systemName: recording.state == .recording || recording.state == .paused ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(t("scRecording")).font(.headline)
                    Text(recordingStatusText)
                        .font(.caption)
                        .foregroundStyle(recording.state == .recording ? .red : recording.state == .paused ? .orange : .secondary)
                }
                Spacer()
                Text(recording.settings.shortcut.displayName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(t("scChangeShortcut")) { showingRecordingShortcutEditor = true }
                    .buttonStyle(.bordered)
                if recording.state == .recording || recording.state == .paused || recording.state == .stopping {
                    if recording.state == .recording {
                        Button(t("scRecordingPause")) { recording.pause() }
                            .buttonStyle(.bordered)
                    } else if recording.state == .paused {
                        Button(t("scRecordingResume")) { recording.resume() }
                            .buttonStyle(.bordered)
                    }
                    Button(t("scRecordingStop")) { recording.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(recording.state == .stopping)
                } else if recording.state == .preparing {
                    Button(t("scRecordingCancel")) { recording.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button(t("scRecordingStart")) { recording.start() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            HStack(spacing: 14) {
                Picker(t("scRecordingCaptureMode"), selection: Binding(
                    get: { recording.settings.captureMode },
                    set: { recording.setCaptureMode($0) }
                )) {
                    ForEach(ScreenRecordingCaptureMode.allCases) { mode in
                        Text(t(mode.titleKey)).tag(mode)
                    }
                }
                .frame(width: 150)

                Picker(t("scRecordingFormat"), selection: Binding(
                    get: { recording.settings.format },
                    set: { recording.setFormat($0) }
                )) {
                    ForEach(ScreenRecordingFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .frame(width: 120)

                Picker(t("scRecordingFPS"), selection: Binding(
                    get: { recording.settings.framesPerSecond },
                    set: { recording.setFramesPerSecond($0) }
                )) {
                    ForEach([15, 24, 30, 60], id: \.self) { fps in
                        Text(t("scRecordingFPSValue", fps)).tag(fps)
                    }
                }
                .frame(width: 130)

                Toggle(t("scRecordingCursor"), isOn: Binding(
                    get: { recording.settings.showsCursor },
                    set: { recording.setShowsCursor($0) }
                ))
                .toggleStyle(.checkbox)
                Toggle(t("scRecordingSystemAudio"), isOn: Binding(
                    get: { recording.settings.capturesSystemAudio },
                    set: { recording.setCapturesSystemAudio($0) }
                ))
                .toggleStyle(.checkbox)
            }

            HStack {
                Button(t("scRecordingOpenFolder")) { recording.openOutputFolder() }
                    .buttonStyle(.bordered)
                if let url = recording.lastRecordingURL {
                    Text(t("scRecordingLastFile", url.lastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(recording.isConvertingGIF ? t("scRecordingConvertingGIF") : t("scRecordingExportGIF")) {
                        recording.convertLastRecordingToGIF()
                    }
                    .buttonStyle(.bordered)
                    .disabled(recording.isConvertingGIF || recording.state != .idle)
                }
                Spacer()
            }
            if let error = recording.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var recordingStatusText: String {
        switch recording.state {
        case .idle:
            return t("scRecordingIdle")
        case .preparing:
            return t("scRecordingPreparing")
        case .recording:
            return t("scRecordingActive", formattedRecordingDuration)
        case .paused:
            return t("scRecordingPaused", formattedRecordingDuration)
        case .stopping:
            return t("scRecordingStopping")
        }
    }

    private var formattedRecordingDuration: String {
        let totalSeconds = max(0, Int(recording.elapsedTime.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func editShortcut(_ kind: ScreenCaptureShortcutKind) {
        editingShortcutKind = kind
        showingSmartShortcutEditor = true
    }

    private func shortcutBadge(for kind: ScreenCaptureShortcutKind) -> some View {
        Text(capture.shortcutBinding(for: kind).displayName)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func shortcutRow(_ kind: ScreenCaptureShortcutKind, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .area ? "rectangle.dashed" : kind == .repeatArea ? "arrow.clockwise" : kind == .applicationWindow ? "macwindow.on.rectangle" : kind == .fullscreen ? "rectangle.inset.filled" : kind == .activeWindow ? "macwindow" : kind == .scrolling ? "arrow.down.to.line.compact" : kind == .objectCutout ? "person.crop.circle" : "text.viewfinder")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(t(kind.titleKey))
            Spacer()
            if let conflict = SmartCaptureSystemShortcutDetector.conflicts(
                for: capture.shortcutBinding(for: kind)
            ).first {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(AppText.value(conflict.titleKey, language: appModel.language))
                    .accessibilityLabel(AppText.value(conflict.titleKey, language: appModel.language))
            }
            shortcutBadge(for: kind)
            Button(t("scChangeShortcut")) { editShortcut(kind) }
                .buttonStyle(.bordered)
            Button(t("scStartMode")) { action() }
                .buttonStyle(.borderedProminent)
        }
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
                    Button(t("scOpenPermissionSettings")) { capture.openScreenCaptureSettings() }
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

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("scHistory")).font(.headline)
                Spacer()
                Text("\(capture.captureHistory.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if capture.captureHistory.isEmpty {
                Text(t("scHistoryEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(capture.captureHistory) { item in
                        HStack(spacing: 10) {
                            SmartCaptureHistoryThumbnail(url: item.url, kind: item.kind)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.url.lastPathComponent)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 5) {
                                    Text(historyKindLabel(item.kind))
                                    if let duration = item.duration, duration > 0 {
                                        Text("· \(formatMediaDuration(duration))")
                                    }
                                    Text("· \(item.width) × \(item.height) · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))")
                                }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(item.date.formatted(.dateTime.month().day().hour().minute().locale(appModel.language.locale)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.kind.isMedia {
                                Button(t("scEditMedia")) { capture.editHistoryItem(item) }
                                    .buttonStyle(.bordered)
                            } else {
                                Button(t("scReveal")) { capture.revealHistoryItem(item) }
                                    .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) { capture.deleteHistoryItem(item) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func historyKindLabel(_ kind: SmartCaptureHistoryKind) -> String {
        switch kind {
        case .screenshot: return t("scHistoryScreenshot")
        case .video: return t("scHistoryVideo")
        case .gif: return t("scHistoryGIF")
        }
    }

    private func formatMediaDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
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

private struct SmartCaptureHistoryThumbnail: View {
    let url: URL
    let kind: SmartCaptureHistoryKind
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: kind == .screenshot ? "photo" : "play.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 100, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: url) {
            if let thumbnail = await SmartCaptureThumbnail.load(url: url) {
                image = NSImage(
                    cgImage: thumbnail,
                    size: NSSize(width: thumbnail.width, height: thumbnail.height)
                )
            } else {
                image = nil
            }
        }
        .onDisappear { image = nil }
    }
}

private struct ScreenRecordingShortcutEditor: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recording: ScreenRecordingModel
    @State private var recordedKeyCode: UInt16?
    @State private var recordedModifiers: InputSourceShortcutModifiers
    @State private var validationMessage: String?

    init(recording: ScreenRecordingModel) {
        self.recording = recording
        let binding = recording.settings.shortcut
        _recordedKeyCode = State(initialValue: binding.keyCode)
        _recordedModifiers = State(initialValue: binding.modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppText.value("scRecording", language: appModel.language))
                .font(.title2.bold())
            Text(AppText.value("scShortcutHint", language: appModel.language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SmartCaptureShortcutRecorder(
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                placeholder: AppText.value("scRecordShortcut", language: appModel.language),
                onRejected: { error in
                    validationMessage = AppText.value(error.messageKey, language: appModel.language)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            if let conflict = candidateConflicts.first {
                Label(AppText.value(conflict.titleKey, language: appModel.language), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let duplicateKind {
                Label(
                    AppText.value(
                        "scShortcutDuplicate",
                        language: appModel.language,
                        arguments: [AppText.value(duplicateKind.titleKey, language: appModel.language)]
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button(AppText.value("scResetShortcut", language: appModel.language, arguments: [
                    ScreenRecordingSettings.defaultShortcut.displayName
                ])) {
                    let binding = ScreenRecordingSettings.defaultShortcut
                    recordedKeyCode = binding.keyCode
                    recordedModifiers = binding.modifiers
                }
                Spacer()
                Button(AppText.value("cancel", language: appModel.language), role: .cancel) { dismiss() }
                Button(AppText.value("save", language: appModel.language)) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        recordedKeyCode == nil
                            || candidateBinding.validationError != nil
                            || !candidateConflicts.isEmpty
                            || duplicateKind != nil
                    )
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: recordedKeyCode) { _, _ in validationMessage = nil }
        .onChange(of: recordedModifiers) { _, _ in validationMessage = nil }
        .onAppear { recording.suspendShortcut() }
        .onDisappear { recording.resumeShortcut() }
    }

    private var candidateBinding: SmartCaptureShortcutBinding {
        SmartCaptureShortcutBinding(
            keyCode: recordedKeyCode ?? recording.settings.shortcut.keyCode,
            modifiers: recordedModifiers
        )
    }

    private var candidateConflicts: [SmartCaptureSystemShortcutConflict] {
        SmartCaptureSystemShortcutDetector.conflicts(for: candidateBinding)
    }

    private var duplicateKind: ScreenCaptureShortcutKind? {
        ScreenCaptureShortcutKind.allCases.first { captureKind in
            // The screenshot model is owned by the shared app model, so this
            // editor only blocks a duplicate when it can observe that model.
            appModel.screenCapture.shortcutBinding(for: captureKind) == candidateBinding
        }
    }

    private func save() {
        guard recordedKeyCode != nil else { return }
        if recording.setShortcut(candidateBinding) {
            dismiss()
        } else {
            validationMessage = recording.errorMessage
        }
    }
}

private struct SmartCaptureShortcutListEditor: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var capture: ScreenCaptureModel
    @State private var editingKind: ScreenCaptureShortcutKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppText.value("scEditShortcuts", language: appModel.language))
                .font(.title2.bold())
            Text(AppText.value("scShortcutHint", language: appModel.language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ScreenCaptureShortcutKind.allCases) { kind in
                        HStack(spacing: 12) {
                            Text(AppText.value(kind.titleKey, language: appModel.language))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let conflict = SmartCaptureSystemShortcutDetector.conflicts(
                                for: capture.shortcutBinding(for: kind)
                            ).first {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(AppText.value(conflict.titleKey, language: appModel.language))
                            }
                            Text(capture.shortcutBinding(for: kind).displayName)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            Button(AppText.value("scChangeShortcut", language: appModel.language)) {
                                editingKind = kind
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                Button(AppText.value("cancel", language: appModel.language), role: .cancel) {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .sheet(item: $editingKind) { kind in
            SmartCaptureShortcutEditor(capture: capture, kind: kind)
        }
    }
}

private struct SmartCaptureShortcutEditor: View {
    @EnvironmentObject private var appModel: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var capture: ScreenCaptureModel
    let kind: ScreenCaptureShortcutKind
    @State private var recordedKeyCode: UInt16?
    @State private var recordedModifiers: InputSourceShortcutModifiers
    @State private var validationMessage: String?

    init(capture: ScreenCaptureModel, kind: ScreenCaptureShortcutKind) {
        self.capture = capture
        self.kind = kind
        let binding = capture.shortcutBinding(for: kind)
        _recordedKeyCode = State(initialValue: binding.keyCode)
        _recordedModifiers = State(initialValue: binding.modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppText.value(kind.titleKey, language: appModel.language))
                .font(.title2.bold())
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.tint)
                Text(capture.shortcutBinding(for: kind).displayName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            Text(AppText.value("scShortcutHint", language: appModel.language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !candidateConflicts.isEmpty {
                Label(
                    AppText.value("scShortcutSystemConflict", language: appModel.language),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let duplicateKind {
                Label(
                    AppText.value(
                        "scShortcutDuplicate",
                        language: appModel.language,
                        arguments: [AppText.value(duplicateKind.titleKey, language: appModel.language)]
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            SmartCaptureShortcutRecorder(
                keyCode: $recordedKeyCode,
                modifiers: $recordedModifiers,
                placeholder: AppText.value("scRecordShortcut", language: appModel.language),
                onRejected: { error in
                    validationMessage = AppText.value(error.messageKey, language: appModel.language)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let conflict = candidateConflicts.first {
                HStack(spacing: 8) {
                    Text(AppText.value(conflict.titleKey, language: appModel.language))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(AppText.value("scOpenKeyboardSettings", language: appModel.language)) {
                        SmartCaptureSystemShortcutDetector.openSystemSettings()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                Button(AppText.value(
                    "scResetShortcut",
                    language: appModel.language,
                    arguments: [kind.defaultBinding.displayName]
                )) {
                    let binding = kind.defaultBinding
                    recordedKeyCode = binding.keyCode
                    recordedModifiers = binding.modifiers
                }
                Spacer()
                Button(AppText.value("cancel", language: appModel.language), role: .cancel) { dismiss() }
                Button(AppText.value("save", language: appModel.language)) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        recordedKeyCode == nil
                            || candidateBinding.validationError != nil
                            || !candidateConflicts.isEmpty
                            || duplicateKind != nil
                    )
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: recordedKeyCode) { _, _ in validationMessage = nil }
        .onChange(of: recordedModifiers) { _, _ in validationMessage = nil }
        .onAppear { capture.suspendSmartCaptureShortcut() }
        .onDisappear { capture.resumeSmartCaptureShortcut() }
    }

    private func save() {
        guard recordedKeyCode != nil else { return }
        let didSave = capture.setShortcut(kind, binding: candidateBinding)
        if didSave { dismiss() }
        else { validationMessage = capture.errorMessage }
    }

    private var candidateBinding: SmartCaptureShortcutBinding {
        SmartCaptureShortcutBinding(
            keyCode: recordedKeyCode ?? kind.defaultBinding.keyCode,
            modifiers: recordedModifiers
        )
    }

    private var candidateConflicts: [SmartCaptureSystemShortcutConflict] {
        SmartCaptureSystemShortcutDetector.conflicts(for: candidateBinding)
    }

    private var duplicateKind: ScreenCaptureShortcutKind? {
        ScreenCaptureShortcutKind.allCases.first { otherKind in
            otherKind != kind && capture.shortcutBinding(for: otherKind) == candidateBinding
        }
    }
}

private struct SmartCaptureShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16?
    @Binding var modifiers: InputSourceShortcutModifiers
    let placeholder: String
    let onRejected: (SmartCaptureShortcutError) -> Void

    func makeNSView(context: Context) -> SmartCaptureShortcutRecorderNSView {
        let view = SmartCaptureShortcutRecorderNSView()
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.placeholder = placeholder
        view.onRejected = onRejected
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
        nsView.onRejected = onRejected
        nsView.needsDisplay = true
    }
}

@MainActor
private final class SmartCaptureShortcutRecorderNSView: NSView {
    var keyCode: UInt16?
    var modifiers: InputSourceShortcutModifiers = []
    var placeholder = ""
    var onCapture: ((UInt16, InputSourceShortcutModifiers) -> Void)?
    var onRejected: ((SmartCaptureShortcutError) -> Void)?
    private var isFocused = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The sheet may not have become key at the point this view is
        // attached. Deferring one turn makes the recorder reliably focusable
        // when the editor opens, while mouseDown below still lets the user
        // explicitly re-focus it at any time.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !record(event) {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Command-modified combinations are offered to menu key equivalents
        // before keyDown. Capture them here so command-modified shortcuts can be
        // recorded instead of triggering the menu/system action.
        guard record(event) else { return super.performKeyEquivalent(with: event) }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { isFocused = true }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { isFocused = false }
        return result
    }

    @discardableResult
    private func record(_ event: NSEvent) -> Bool {
        let modifierKeys: Set<UInt16> = [
            UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), UInt16(kVK_RightCommand)
        ]
        guard !modifierKeys.contains(event.keyCode) else { return false }
        let modifiers = InputSourceShortcutModifiers(event.modifierFlags)
        let binding = SmartCaptureShortcutBinding(
            keyCode: event.keyCode,
            modifiers: modifiers
        )
        if let error = binding.validationError {
            onRejected?(error)
            needsDisplay = true
            // Escape is reserved for cancelling the editor/selection. Let it
            // continue through the responder chain after showing the inline
            // validation message instead of trapping the sheet in recording.
            return error != .reservedKey
        }
        onCapture?(event.keyCode, modifiers)
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            dirtyRect.fill()
        }
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
        (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
    }
}
