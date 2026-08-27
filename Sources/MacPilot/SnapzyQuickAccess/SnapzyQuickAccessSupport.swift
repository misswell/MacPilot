//
//  SnapzyQuickAccessSupport.swift
//  MacPilot integration seams for the Snapzy QuickAccess sources.
//
//  The QuickAccess files in this directory are copied from Snapzy and kept
//  deliberately close to the upstream types.  This file only supplies the
//  small application-specific seams that Snapzy normally gets from its
//  preferences, cloud, history and file-access layers.
//
//  Upstream: https://github.com/duongductrong/Snapzy
//  Copyright (c) Trong Duong Duc. BSD 3-Clause License.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import ImageIO
import os.log

// MARK: - ShortcutConfig (copied from Snapzy's KeyboardShortcutManager)

/// Represents a keyboard shortcut configuration
struct ShortcutConfig: Equatable, Codable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Custom bit used to store the Fn modifier flag.
    /// Carbon does not provide a native Fn constant, so we use an otherwise-unused bit internally.
    static let functionCarbonModifier: UInt32 = 0x2000

    /// Memberwise initializer
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayString: String {
        var parts: [String] = []

        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & Self.functionCarbonModifier != 0 { parts.append("fn") }

        let keyChar = Self.keyCodeToDisplayString(keyCode)
        parts.append(keyChar)
        return parts.joined(separator: " ")
    }

    /// Individual key parts for keycap-style rendering
    var displayParts: [String] {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & Self.functionCarbonModifier != 0 { parts.append("fn") }
        parts.append(Self.keyCodeToDisplayString(keyCode))
        return parts
    }

    /// Map key code to display character
    static func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        // Punctuation & symbol keys
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        // Keypad keys
        case kVK_ANSI_KeypadDecimal: return "."
        case kVK_ANSI_KeypadMultiply: return "*"
        case kVK_ANSI_KeypadPlus: return "+"
        case kVK_ANSI_KeypadDivide: return "/"
        case kVK_ANSI_KeypadMinus: return "-"
        case kVK_ANSI_KeypadEquals: return "="
        case kVK_ANSI_KeypadEnter: return "↩"
        case kVK_ANSI_Keypad0: return "0"
        case kVK_ANSI_Keypad1: return "1"
        case kVK_ANSI_Keypad2: return "2"
        case kVK_ANSI_Keypad3: return "3"
        case kVK_ANSI_Keypad4: return "4"
        case kVK_ANSI_Keypad5: return "5"
        case kVK_ANSI_Keypad6: return "6"
        case kVK_ANSI_Keypad7: return "7"
        case kVK_ANSI_Keypad8: return "8"
        case kVK_ANSI_Keypad9: return "9"
        // Navigation keys
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case 0x3F: return "fn"
        default: return "?"
        }
    }

    /// Map key code to the key label users see on their active keyboard layout.
    static func keyCodeToDisplayString(_ keyCode: UInt32) -> String {
        let fallback = keyCodeToString(keyCode)
        if fallback.count != 1, fallback != "?" {
            return fallback
        }
        return currentLayoutPrintableKeyDisplayString(for: keyCode) ?? fallback
    }

    private static func currentLayoutPrintableKeyDisplayString(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        var layout = UCKeyboardLayout()
        guard data.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
        _ = withUnsafeMutableBytes(of: &layout) { bytes in
            data.copyBytes(to: bytes.bindMemory(to: UInt8.self))
        }

        var deadKeyState: UInt32 = 0
        var unicodeString = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            &layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            unicodeString.count,
            &length,
            &unicodeString
        )
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: unicodeString, count: length)
        return string.isEmpty ? nil : string
    }
}

// MARK: - L10n strings used by the QuickAccess sources

extension L10n {
    enum Common {
        static let save = "保存"
        static let open = "打开"
        static let deleteAction = "删除"
        static let moveToTrash = "移到废纸篓"
        static let copy = "复制"
        static let close = "关闭"
        static let ok = "好"
        static let none = "无"
    }

    enum QuickAccess {
        static let editVideo = "编辑视频"
        static let unlockPinnedWindow = "解锁固定窗口"
        static let lockPinnedWindow = "锁定固定窗口"
        static let zoomPinnedWindow = "缩放固定窗口"
        static let fitPinnedWindow = "适合窗口"
    }

    enum AnnotateUI {
        static let modeAnnotate = "标注"
        static let uploadedToCloud = "已上传"
        static let reuploadToCloud = "重新上传"
        static let uploadToCloud = "上传到云端"
        static let dragToAppHelp = "拖到应用中以共享"
    }

    enum PreferencesQuickAccess {
        static let slotCenterTop = "中央上方"
        static let slotCenterBottom = "中央下方"
        static let slotTopRight = "右上角"
        static let slotTopLeft = "左上角"
        static let slotBottomLeft = "左下角"
        static let slotBottomRight = "右下角"
        static let saveOrOpenAction = "保存或打开"
        static let editAction = "编辑"
        static let pinToScreenAction = "固定到屏幕"
        static let unpinAction = "取消固定"
        static let primaryActionBadge = "主要操作"
        static let cornerActionBadge = "边角操作"
        static let animationStyleSlide = "滑动"
        static let animationStyleScale = "缩放"
        static let swipeLeftAction = "左滑操作"
        static let swipeRightAction = "右滑操作"
        static let trackpadSwipeModeNatural = "自然"
        static let trackpadSwipeModeInverted = "反向"
    }

    enum KeystrokePosition {
        static let topLeft = "左上"
        static let topRight = "右上"
        static let bottomLeft = "左下"
        static let bottomRight = "右下"
    }
}

// MARK: - PreferencesKeys additions

extension PreferencesKeys {
    static let quickAccessActionOrder = "quickAccess.actionOrder"
    static let quickAccessEnabledActions = "quickAccess.enabledActions"
    static let quickAccessActionSlotAssignments = "quickAccess.actionSlotAssignments"
    static let quickAccessSwipeLeftAction = "quickAccess.swipeLeftAction"
    static let quickAccessSwipeRightAction = "quickAccess.swipeRightAction"
    static let quickAccessTrackpadSwipeMode = "quickAccess.trackpadSwipeMode"
    static let playSounds = "MacPilot.playSounds"
}

// MARK: - ScreenUtility

/// Screen helpers used by the QuickAccess panel and pin windows.
enum ScreenUtility {
    static func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.snapzyDisplayID
    }

    static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.snapzyDisplayID == displayID }
    }
}

// MARK: - SandboxFileAccessManager (non-sandboxed no-op seam)

/// MacPilot runs outside the sandbox, so security-scoped access is a no-op.
/// Kept under Snapzy's original name so the migrated sources compile unchanged.
@MainActor
final class SandboxFileAccessManager {
    static let shared = SandboxFileAccessManager()

    struct ScopedAccess: Sendable {
        let url: URL
        nonisolated func stop() {}
    }

    var defaultExportDirectory: URL {
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop.appendingPathComponent("MacPilot", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MacPilot", isDirectory: true)
    }

    func resolvedExportDirectoryURL() -> URL {
        let path = UserDefaults.standard.string(forKey: PreferencesKeys.exportLocation)
            ?? defaultExportDirectory.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func beginAccessingURL(_ targetURL: URL) -> ScopedAccess {
        ScopedAccess(url: targetURL)
    }
}

@MainActor
protocol SandboxFileAccessing {
    func resolvedExportDirectoryURL() -> URL
    func beginAccessingURL(_ targetURL: URL) -> SandboxFileAccessManager.ScopedAccess
}

extension SandboxFileAccessManager: SandboxFileAccessing {}

// MARK: - PreferencesKeys additions

extension PreferencesKeys {
    static let exportLocation = "MacPilot.exportLocation"
}

// MARK: - PreferencesManager (minimal ObservableObject stub)

/// Snapzy's QuickAccessCardView observes this singleton but does not read any
/// of its state on the card surface; keep the same seam so the view compiles.
@MainActor
final class PreferencesManager: ObservableObject {
    static let shared = PreferencesManager()
    private init() {}
}

// MARK: - CaptureType

enum CaptureType: String, Equatable {
    case screenshot
    case recording
}

enum CaptureHistoryType: String, Codable, Equatable, CaseIterable {
    case screenshot
    case video
    case gif
}

// MARK: - CaptureHistoryStore (no-op seam)

struct CaptureHistoryRecord {
    var fileURL: URL
    var fileName: String
    var captureType: CaptureHistoryType
    var capturedAt: Date
    var duration: TimeInterval?
}

@MainActor
final class CaptureHistoryStore {
    static let shared = CaptureHistoryStore()
    var isDatabaseAvailable = false

    func hasRecord(forFilePath: String) -> Bool { false }
    func removeByFilePath(_ path: String) {}
    func updateFilePath(from: String, to: String) {}
}

extension UserDefaults {
    var snapzyHistoryEnabled: Bool {
        object(forKey: "MacPilot.historyEnabled") as? Bool ?? false
    }
}

// MARK: - AnnotationSessionStore (no-op seam)

@MainActor
final class AnnotationSessionStore {
    static let shared = AnnotationSessionStore()

    func deleteSession(for url: URL) {}
    func moveSession(from: URL, to: URL) -> Bool { false }
    func shouldPersist(for url: URL) -> Bool { false }
    func persist(_ data: Data?, for url: URL) {}
}

// MARK: - AnnotateManager (bridge to the app's annotation editor)

/// The QuickAccess card's annotation action is handled by the app's editor,
/// which replaces the existing floating panel content in place.
@MainActor
final class AnnotateManager {
    static let shared = AnnotateManager()

    /// Registered by the app at startup so the card's "标注" action can open
    /// the annotation editor with the captured item.
    var onOpenAnnotation: ((QuickAccessItem) -> Void)?

    func openAnnotation(for item: QuickAccessItem) {
        onOpenAnnotation?(item)
    }

    func clearSessionData(for id: UUID) {}
    func getSessionData(for id: UUID) -> Data? { nil }
}

// MARK: - VideoEditorManager (no-op seam; video editing is not part of the migrated slice)

@MainActor
final class VideoEditorManager {
    static let shared = VideoEditorManager()

    func openEditor(for item: QuickAccessItem) {
        NSWorkspace.shared.open(item.url)
    }
}

// MARK: - PostCaptureActionHandler (no-op seam)

@MainActor
final class PostCaptureActionHandler {
    static let shared = PostCaptureActionHandler()

    func copyEditedCaptureToClipboardIfEnabled(for type: CaptureType, url: URL) {}
}

// MARK: - SoundManager

enum SoundManager {
    static func play(_ name: String) {
        QuickAccessSound.complete.play()
    }
}

// MARK: - PerfSignpost (no-op seam)

enum PerfSignpost {
    static func event(_ name: String) {}
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        try body()
    }
}

// MARK: - RecordingMetadataStore (no-op seam)

enum RecordingMetadataStore {
    static func delete(for url: URL) throws {}
    static func load(for url: URL) -> Data? { nil }
    static func save(_ data: Data, for url: URL) throws {}
}

// MARK: - ClipboardHelper

/// Clipboard helpers matching Snapzy's file-based paste semantics: the temp
/// file is registered on the pasteboard so the receiving app can read it at
/// paste time, and it must stay on disk until then.
enum ClipboardHelper {
    static func copyImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func copyMediaFile(from url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    static func isReferencedByGeneralPasteboard(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        for item in pasteboard.pasteboardItems ?? [] {
            if let string = item.string(forType: .fileURL), string == url.absoluteString {
                return true
            }
            if let fileURL = item.propertyList(forType: .fileURL) as? String,
               fileURL == url.absoluteString {
                return true
            }
        }
        return false
    }
}

// MARK: - TempCaptureManager (Snapzy temp-capture lifecycle, MacPilot paths)

/// Manages temporary capture files, mirroring Snapzy's flow: fresh captures
/// land in the temp directory, the QuickAccess card offers save/delete, and
/// dismissed temp files are reclaimed unless history or the pasteboard needs
/// them.  MacPilot keeps its own Application Support root and export folder.
@MainActor
final class TempCaptureManager {
    static let shared = TempCaptureManager()

    private let defaults = UserDefaults.standard
    private let fileAccess = SandboxFileAccessManager.shared

    /// Temp directory for unsaved captures (Application Support/MacPilot/Captures/).
    /// Uses Application Support instead of /tmp/ so macOS won't purge files
    /// during drag-and-drop — same pattern as CleanShot X and Snapzy.
    let tempCaptureDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let capturesDir = base
            .appendingPathComponent("MacPilot", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)
        return capturesDir
    }()

    /// Write a captured image to the temp directory as a PNG file.
    @discardableResult
    func saveScreenshot(_ image: CGImage) -> URL? {
        let url = makeScreenshotURL()
        return Self.writeScreenshot(SendableScreenCaptureImage(value: image), to: url) ? url : nil
    }

    /// Reserve a temp URL without encoding the image. This lets Quick Access
    /// publish its in-memory preview while the PNG is written in the background.
    func makeScreenshotURL() -> URL {
        CaptureOutputNaming.makeUniqueFileURL(
            in: tempCaptureDirectory,
            baseName: "MacPilotCapture",
            fileExtension: "png"
        )
    }

    /// Encode and write a temp capture off the main actor.
    @discardableResult
    nonisolated static func writeScreenshot(_ image: SendableScreenCaptureImage, to url: URL) -> Bool {
        autoreleasepool {
            let temporaryURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL,
                "public.png" as CFString,
                1,
                nil
            ) else { return false }
            CGImageDestinationAddImage(destination, image.value, nil)
            guard CGImageDestinationFinalize(destination) else { return false }

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: url)
                return true
            } catch {
                return false
            }
        }
    }

    /// Check if a URL is in the temp capture directory
    func isTempFile(_ url: URL) -> Bool {
        let tempPath = tempCaptureDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath == tempPath || filePath.hasPrefix(tempPath + "/")
    }

    /// Move a temp file to the permanent export location.
    /// Returns the new URL on success, nil on failure.
    func saveToExportLocation(tempURL: URL) -> URL? {
        guard isTempFile(tempURL) else { return nil }
        let exportDir = fileAccess.resolvedExportDirectoryURL()
        do {
            try FileManager.default.createDirectory(
                at: exportDir,
                withIntermediateDirectories: true
            )
            let destinationURL = exportDir.appendingPathComponent(tempURL.lastPathComponent)
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    /// Delete a temp file
    func deleteTempFile(at url: URL) {
        guard isTempFile(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Cleanup all orphaned temp files (call on app launch).
    func cleanupOrphanedFiles() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: tempCaptureDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            try? fm.removeItem(at: fileURL)
        }
    }
}

// MARK: - CaptureOutputNaming (Snapzy naming helper, kept small)

enum CaptureOutputNaming {
    static func makeUniqueFileURL(in directory: URL, baseName: String, fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        let stamp = formatter.string(from: Date())
        var url = directory.appendingPathComponent("\(baseName)_\(stamp).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName)_\(stamp)_\(counter).\(fileExtension)")
            counter += 1
        }
        return url
    }
}

// MARK: - Size (Snapzy design-system radii used by the pin window)

enum Size {
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12
}

// MARK: - AnnotateExporter (PNG/JPEG encoding used by the pinned drag handle)

enum AnnotateExporter {
    nonisolated static func imageData(from image: NSImage, for fileExtension: String) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        let ext = fileExtension.lowercased()
        let utType: CFString
        switch ext {
        case "jpg", "jpeg":
            utType = "public.jpeg" as CFString
        default:
            utType = "public.png" as CFString
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, utType, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}

/// AppKit delivers local event-monitor callbacks on the main thread, but
/// `NSEvent` is non-Sendable. This box carries the event across the
/// `MainActor.assumeIsolated` boundary used by the QuickAccess monitor views.
final class UncheckedEventBox: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

// MARK: - NSWindow + CornerRadius (Snapzy's window styling extension)

extension NSWindow {
    /// Default corner radius for app windows
    static let defaultCornerRadius: CGFloat = 24

    /// Apply custom corner radius to the window
    /// - Parameter radius: The corner radius to apply (default: 24)
    func applyCornerRadius(_ radius: CGFloat = NSWindow.defaultCornerRadius) {
        // Apply corner radius to the window itself using setValue
        // This modifies the actual window frame corner radius
        setValue(radius, forKey: "cornerRadius")

        // Access the window's content view and apply corner radius
        if let contentView = contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = radius
            contentView.layer?.masksToBounds = true
        }

        // Apply to the window's frame view (NSThemeFrame) for border consistency
        if let frameView = contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = radius
            frameView.layer?.masksToBounds = true

            // Find and update any visual effect views within the frame
            for subview in frameView.subviews {
                if let visualEffectView = subview as? NSVisualEffectView {
                    visualEffectView.wantsLayer = true
                    visualEffectView.layer?.cornerRadius = radius
                    visualEffectView.layer?.masksToBounds = true
                }
            }
        }
    }
}
