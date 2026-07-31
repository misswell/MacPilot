// ScreenCapture.swift
// Periodic screenshot capture with busy/idle scheduling and high-efficiency HEIC encoding.

import AppKit
import CoreGraphics
import Foundation
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
        showsCursor: Bool = true
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
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, outputFolder, busyStartHour, busyEndHour
        case busyIntervalMinutes, idleIntervalMinutes, imageFormat, quality
        case maxRetentionDays, captureAllDisplays, showsCursor
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
            showsCursor: try c.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true
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
    case captureFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noOutputFolder: return "No output folder selected."
        case .outputFolderUnavailable: return "The output folder is unavailable."
        case .noDisplayFound: return "No display was found to capture."
        case .captureFailed(let detail): return "Screen capture failed: \(detail)"
        case .encodingFailed: return "Failed to encode the screenshot image."
        }
    }
}

// MARK: - Model

@MainActor
final class ScreenCaptureModel: ObservableObject {
    @Published private(set) var settings = ScreenCaptureSettings()
    @Published private(set) var isCapturing = false
    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var lastCaptureSize: Int64 = 0
    @Published private(set) var captureCount: Int = 0
    @Published private(set) var totalDiskUsage: Int64 = 0
    @Published private(set) var screenshotCount: Int = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasScreenPermission = false
    @Published private(set) var nextCaptureDate: Date?
    @Published private(set) var isLoopRunning = false

    var persist: (() -> Void)?
    private var isLoading = false
    private var captureTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?

    deinit {
        captureTask?.cancel()
        permissionPollTask?.cancel()
    }

    // MARK: - Configuration lifecycle

    func applyLoadedSettings(_ newSettings: ScreenCaptureSettings) {
        isLoading = true
        settings = newSettings
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        isLoading = false
    }

    func activateFromConfiguration() {
        Task { await refreshDiskUsage() }
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
            requestScreenPermission()
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
                requestScreenPermission()
                errorMessage = "Screen Recording permission is required. Grant it in System Settings, then restart OctoPilot."
                return
            }
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
                lastCaptureSize = saved.reduce(0) { $0 + $1.size }
                captureCount += 1
                screenshotCount += saved.count
                errorMessage = nil
            }
            await refreshDiskUsage()
            await cleanupOldScreenshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func captureAndSaveAllDisplays() async throws -> [(url: URL, size: Int64)] {
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

        var results: [(url: URL, size: Int64)] = []
        let multiDisplay = displays.count > 1
        for (index, display) in displays.enumerated() {
            guard let image = try? await captureDisplay(display) else { continue }
            let url = try saveImage(image, displayIndex: multiDisplay ? index : nil)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int64) ?? 0
            results.append((url, size))
        }
        return results
    }

    private func captureDisplay(_ display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = settings.showsCursor
        configuration.scalesToFit = true
        let (width, height) = pixelSize(for: display)
        configuration.width = width
        configuration.height = height
        if #available(macOS 14.2, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } else {
            guard let image = captureWithCGWindowList() else {
                throw ScreenCaptureError.captureFailed("CGWindowListCreateImage returned nil")
            }
            return image
        }
    }

    private func captureWithCGWindowList() -> CGImage? {
        CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
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

    // MARK: - Image saving

    private func saveImage(_ image: CGImage, displayIndex: Int?) throws -> URL {
        let now = Date()
        let dayFolder = try ensureDayFolder(for: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        var baseName = "OctoPilot_\(formatter.string(from: now))"
        if let displayIndex {
            baseName += "_display\(displayIndex + 1)"
        }
        let fileURL = dayFolder.appendingPathComponent("\(baseName).\(settings.imageFormat.fileExtension)")

        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            settings.imageFormat.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureError.encodingFailed
        }

        if settings.imageFormat.supportsQuality {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: settings.quality]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCaptureError.encodingFailed
        }
        return fileURL
    }

    private func ensureDayFolder(for date: Date) throws -> URL {
        guard settings.isOutputFolderValid else {
            throw ScreenCaptureError.noOutputFolder
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let dayName = formatter.string(from: date)
        let dayURL = URL(fileURLWithPath: settings.outputFolder).appendingPathComponent(dayName, isDirectory: true)
        try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)
        return dayURL
    }

    // MARK: - Disk usage & cleanup

    func refreshDiskUsage() async {
        guard settings.isOutputFolderValid else {
            totalDiskUsage = 0
            screenshotCount = 0
            return
        }
        let folder = settings.outputFolder
        let (totalBytes, count) = await Task.detached(priority: .utility) { () -> (Int64, Int) in
            var totalBytes: Int64 = 0
            var count = 0
            let extensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
            if let enumerator = FileManager.default.enumerator(atPath: folder) {
                while let path = enumerator.nextObject() as? String {
                    let ext = (path as NSString).pathExtension.lowercased()
                    guard extensions.contains(ext) else { continue }
                    let full = (folder as NSString).appendingPathComponent(path)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: full)
                    if let size = attrs?[.size] as? Int64 {
                        totalBytes += size
                        count += 1
                    }
                }
            }
            return (totalBytes, count)
        }.value
        totalDiskUsage = totalBytes
        screenshotCount = count
    }

    func cleanupOldScreenshots() async {
        guard settings.maxRetentionDays > 0, settings.isOutputFolderValid else { return }
        let folder = settings.outputFolder
        let cutoff = settings.maxRetentionDays
        let deleted = await Task.detached(priority: .utility) { () -> Bool in
            var deletedAny = false
            let calendar = Calendar.current
            let now = Date()
            guard let dayURLs = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return false }
            for dayURL in dayURLs where dayURL.hasDirectoryPath {
                let dayName = dayURL.lastPathComponent
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                guard let dayDate = formatter.date(from: dayName) else { continue }
                let daysOld = calendar.dateComponents([.day], from: dayDate, to: now).day ?? 0
                if daysOld > cutoff {
                    try? FileManager.default.removeItem(at: dayURL)
                    deletedAny = true
                }
            }
            return deletedAny
        }.value
        if deleted {
            await refreshDiskUsage()
        }
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
    @EnvironmentObject private var appModel: OctoPilotModel
    @ObservedObject var capture: ScreenCaptureModel
    @State private var showingFolderPicker = false

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
    }

    private func t(_ key: String, _ args: CVarArg...) -> String {
        AppText.value(key, language: appModel.language, arguments: args)
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
                Button(t("scGrantPermission")) { capture.requestScreenPermission() }
                    .buttonStyle(.bordered)
            }

            if let error = capture.errorMessage {
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
