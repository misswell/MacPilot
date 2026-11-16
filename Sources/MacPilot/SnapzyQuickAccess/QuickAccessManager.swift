//
//  QuickAccessManager.swift
//  Snapzy
//
//  State management for quick access screenshot stack
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import ImageIO
import os.log
import SwiftUI

private let logger = Logger(subsystem: "Snapzy", category: "QuickAccessManager")

enum QuickAccessAnimationStyle: String, CaseIterable, Identifiable {
  case slide
  case scale

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .slide: L10n.PreferencesQuickAccess.animationStyleSlide
    case .scale: L10n.PreferencesQuickAccess.animationStyleScale
    }
  }
}

/// Manages the quick access screenshot preview stack
@MainActor
final class QuickAccessManager: ObservableObject {
  static let shared = QuickAccessManager()

  /// Clipboard surface for card and annotation copies. Production uses the
  /// system pasteboard; tests inject a named pasteboard so they exercise the
  /// real write/lease path without touching the user's clipboard.
  var clipboardPasteboard: NSPasteboard = .general

  // MARK: - Published State

  @Published private(set) var items: [QuickAccessItem] = [] {
    didSet {
      refreshPanelInteractionMetrics()
      invalidateHoverIfItemGone()
    }
  }

  @Published var position: QuickAccessPosition = .bottomRight {
    didSet {
      UserDefaults.standard.set(position.rawValue, forKey: Keys.position)
      panelController.updatePosition(position)
    }
  }

  @Published var isEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
      if !isEnabled {
        dismissAll()
      }
    }
  }

  @Published var autoDismissEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(autoDismissEnabled, forKey: Keys.autoDismissEnabled)
    }
  }

  @Published var hideCardWhenWindowOpen: Bool = true {
    didSet {
      UserDefaults.standard.set(hideCardWhenWindowOpen, forKey: Keys.hideCardWhenWindowOpen)
      refreshPanelInteractionMetrics()
    }
  }

  @Published var animationStyle: QuickAccessAnimationStyle = .slide {
    didSet {
      UserDefaults.standard.set(animationStyle.rawValue, forKey: Keys.quickAccessAnimationStyle)
    }
  }

  @Published var autoDismissDelay: TimeInterval = 10 {
    didSet {
      UserDefaults.standard.set(autoDismissDelay, forKey: Keys.autoDismissDelay)
    }
  }

  @Published var overlayScale: Double = 1.0 {
    didSet {
      UserDefaults.standard.set(overlayScale, forKey: Keys.overlayScale)
      // Live-resize panel when slider changes
      if panelController.isVisible {
        panelController.updateSize(calculateMaxPanelSize())
      }
      refreshPanelInteractionMetrics()
    }
  }

  @Published var dragDropEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(dragDropEnabled, forKey: Keys.dragDropEnabled)
    }
  }

  @Published var twoFingerSwipeToDismissEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(twoFingerSwipeToDismissEnabled, forKey: Keys.twoFingerSwipeToDismissEnabled)
    }
  }

  @Published var swipeSensitivity: Double = 1.0 {
    didSet {
      UserDefaults.standard.set(swipeSensitivity, forKey: Keys.swipeSensitivity)
    }
  }

  @Published var pauseCountdownOnHover: Bool = true {
    didSet {
      UserDefaults.standard.set(pauseCountdownOnHover, forKey: Keys.pauseCountdownOnHover)
    }
  }

  @Published private(set) var openEditorShortcut: ShortcutConfig?
  @Published var openEditorShortcutEnabled: Bool = false {
    didSet {
      UserDefaults.standard.set(openEditorShortcutEnabled, forKey: Keys.openEditorShortcutEnabled)
      if openEditorShortcutEnabled {
        if panelController.isVisible {
          installEditHotKeyIfNeeded()
        }
      } else {
        removeEditHotKey()
      }
    }
  }

  static let defaultOpenEditorShortcut = ShortcutConfig(
    keyCode: UInt32(kVK_Return),
    modifiers: UInt32(cmdKey)
  )

  /// Card the pointer is currently over. Card action shortcuts are only live
  /// while this is non-nil, so it must be cleared on every path that ends a hover.
  ///
  /// Deliberately NOT `@Published`: only this manager reads it (shortcut
  /// targeting), and publishing it would invalidate every manager observer —
  /// including `QuickAccessStackView` and all visible cards — on every hover
  /// enter/exit, re-rendering the stack without changing anything visible.
  private(set) var hoveredItemID: UUID?

  /// Emits when a card action shortcut fires, targeted at the hovered card.
  /// `QuickAccessCardView` owns the availability rules, so it runs the action.
  let cardShortcutTrigger = PassthroughSubject<QuickAccessCardShortcutTrigger, Never>()

  // MARK: - Configuration

  let maxVisibleItems = 5

  // MARK: - Private

  private let panelController = QuickAccessPanelController()
  private let pinWindowManager = QuickAccessPinWindowManager.shared
  private let fileAccessManager = SandboxFileAccessManager.shared
  private let tempCaptureManager = TempCaptureManager.shared
  private var dismissTimers: [UUID: QuickAccessCountdownTimer] = [:]
  private var artifactRetryHandlers: [UUID: @MainActor () -> Void] = [:]
  @Published private(set) var lastOperationError: String?
  /// Monotonic per-item save tokens; guards the async save-and-close thumbnail push
  /// against out-of-order arrival when the same item is saved twice quickly.
  private var thumbnailSaveGenerations: [UUID: UInt64] = [:]
  /// Tracks which item IDs are currently being edited (paused by editor)
  private var editingItemIds: Set<UUID> = []
  /// The current annotation editor replaces the existing Quick Access panel
  /// content in-place, so no second centered editor window is needed.
  private var annotationEditingItemID: UUID?
  /// Tracks items doing async work, such as GIF conversion or cloud upload.
  private var activityHoldItemIds: Set<UUID> = []
  private let hoverShortcutRegistry = QuickAccessHoverShortcutRegistry()
  private var editHotKeyRef: EventHotKeyRef?
  private var editHotKeyHandler: EventHandlerRef?
  fileprivate let editHotKeyID = EventHotKeyID(signature: OSType(0x5A51_4145), id: 1)

  // MARK: - UserDefaults Keys (preserved for backward compatibility)

  private enum Keys {
    static let enabled = "floatingScreenshot.enabled"
    static let position = "floatingScreenshot.position"
    static let autoDismissEnabled = "floatingScreenshot.autoDismissEnabled"
    static let hideCardWhenWindowOpen = "quickAccess.hideCardWhenWindowOpen"
    static let quickAccessAnimationStyle = "quickAccess.animationStyle"
    static let autoDismissDelay = "floatingScreenshot.autoDismissDelay"
    static let overlayScale = "floatingScreenshot.overlayScale"
    static let dragDropEnabled = "floatingScreenshot.dragDropEnabled"
    static let twoFingerSwipeToDismissEnabled = "floatingScreenshot.twoFingerSwipeToDismissEnabled"
    static let swipeSensitivity = "floatingScreenshot.swipeSensitivity"
    static let pauseCountdownOnHover = "floatingScreenshot.pauseCountdownOnHover"
    static let openEditorShortcut = "quickAccess.openEditorShortcut"
    static let openEditorShortcutEnabled = "quickAccess.openEditorShortcutEnabled"
  }

  private let explicitEmptyShortcutData = Data("null".utf8)

  // MARK: - Init

  private init() {
    loadSettings()
    hoverShortcutRegistry.onTrigger = { [weak self] action in
      self?.handleCardShortcut(action)
    }
  }

  private func loadSettings() {
    isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true

    if let positionRaw = UserDefaults.standard.string(forKey: Keys.position),
       let savedPosition = QuickAccessPosition(rawValue: positionRaw) {
      position = savedPosition
    }

    autoDismissEnabled =
      UserDefaults.standard.object(forKey: Keys.autoDismissEnabled) as? Bool ?? true
    hideCardWhenWindowOpen =
      UserDefaults.standard.object(forKey: Keys.hideCardWhenWindowOpen) as? Bool ?? true

    if let savedAnimStyle = UserDefaults.standard.string(forKey: Keys.quickAccessAnimationStyle),
       let style = QuickAccessAnimationStyle(rawValue: savedAnimStyle) {
      animationStyle = style
    }

    autoDismissDelay =
      UserDefaults.standard.object(forKey: Keys.autoDismissDelay) as? Double ?? 10
    overlayScale =
      UserDefaults.standard.object(forKey: Keys.overlayScale) as? Double ?? 1.0
    dragDropEnabled =
      UserDefaults.standard.object(forKey: Keys.dragDropEnabled) as? Bool ?? true
    twoFingerSwipeToDismissEnabled =
      UserDefaults.standard.object(forKey: Keys.twoFingerSwipeToDismissEnabled) as? Bool ?? true
    swipeSensitivity =
      UserDefaults.standard.object(forKey: Keys.swipeSensitivity) as? Double ?? 1.0
    pauseCountdownOnHover =
      UserDefaults.standard.object(forKey: Keys.pauseCountdownOnHover) as? Bool ?? true
    openEditorShortcutEnabled =
      UserDefaults.standard.object(forKey: Keys.openEditorShortcutEnabled) as? Bool ?? false
    loadOpenEditorShortcut()
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Quick access settings loaded",
      context: [
        "enabled": isEnabled ? "true" : "false",
        "position": position.rawValue,
        "autoDismiss": autoDismissEnabled ? "true" : "false",
        "delay": "\(autoDismissDelay)",
        "twoFingerSwipeToDismiss": twoFingerSwipeToDismissEnabled ? "true" : "false",
        "swipeSensitivity": "\(swipeSensitivity)",
      ]
    )
  }

  // MARK: - Public Methods

  /// Add a new screenshot to the quick access stack
  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem? {
    guard isEnabled else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access screenshot skipped; feature disabled",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }
    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }
    let result = await ThumbnailGenerator.generate(from: url)

    // Use placeholder if thumbnail generation failed
    let thumbnail: NSImage
    let needsRetry: Bool
    if let generated = result.thumbnail {
      thumbnail = generated
      needsRetry = false
    } else {
      logger.warning("Thumbnail failed for \(url.lastPathComponent), using placeholder")
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "Quick access screenshot thumbnail failed; using placeholder",
        context: ["fileName": url.lastPathComponent]
      )
      thumbnail = ThumbnailGenerator.placeholderThumbnail()
      needsRetry = true
    }

    let item = QuickAccessItem(url: url, thumbnail: thumbnail)

    insertScreenshotItem(item, retryURL: needsRetry ? url : nil)

    return item
  }

  /// Insert a screenshot with a caller-provided in-memory thumbnail.
  ///
  /// Fresh screen captures use this path so the preview can appear before the
  /// original image and temporary card file finish encoding on disk.
  @discardableResult
  func addScreenshot(url: URL, thumbnail: NSImage) -> QuickAccessItem? {
    guard isEnabled else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access screenshot skipped; feature disabled",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }

    let item = QuickAccessItem(url: url, thumbnail: thumbnail)
    insertScreenshotItem(item)
    return item
  }

  // MARK: - Capture Artifact Lifecycle

  /// Insert a card whose file is still being written. The card shows the
  /// in-memory thumbnail; every file-backed action stays disabled until the
  /// artifact reaches `.ready`, so a card can never point at a missing file.
  @discardableResult
  func addCaptureArtifactPlaceholder(
    artifactID: UUID,
    captureID: UUID,
    url: URL,
    thumbnail: NSImage,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> QuickAccessItem? {
    guard isEnabled else { return nil }
    let item = QuickAccessItem(
      url: url,
      thumbnail: thumbnail,
      artifactID: artifactID,
      captureID: captureID,
      artifactState: .reserved,
      isTemporaryArtifact: true,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    insertCapturePlaceholderItem(item)
    return item
  }

  func markArtifactWriting(id: UUID) {
    updateArtifactState(id: id, state: .writing, error: nil)
  }

  /// Commit the artifact URL. `byteCount` and `warning` describe the finished
  /// file; the auto-dismiss countdown starts only now.
  func artifactDidBecomeReady(
    id: UUID,
    url: URL,
    isTemporary: Bool,
    warning: String? = nil
  ) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].url = url
    items[index].artifactState = .ready
    items[index].artifactErrorDescription = warning
    items[index].isTemporaryArtifact = isTemporary
    artifactRetryHandlers.removeValue(forKey: id)
    if warning != nil {
      lastOperationError = warning
    }
    if autoDismissEnabled, QuickAccessOperationCoordinator.shouldRunCountdown(state: .ready) {
      startDismissTimer(for: id)
    }
  }

  func artifactDidFail(id: UUID, error: String) {
    updateArtifactState(id: id, state: .failed, error: error)
    lastOperationError = error
  }

  func setArtifactRetryHandler(for id: UUID, handler: @escaping @MainActor () -> Void) {
    artifactRetryHandlers[id] = handler
  }

  /// Retry a failed artifact write. The handler re-runs only the persistence
  /// step for the original capture, never a new capture.
  func retryArtifact(id: UUID) {
    guard let item = items.first(where: { $0.id == id }), item.artifactState == .failed else { return }
    guard let handler = artifactRetryHandlers[id] else { return }
    lastOperationError = nil
    updateArtifactState(id: id, state: .writing, error: nil)
    handler()
  }

  private func updateArtifactState(
    id: UUID,
    state: CaptureArtifactState,
    error: String?
  ) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].artifactState = state
    items[index].artifactErrorDescription = error
    if QuickAccessOperationCoordinator.shouldRunCountdown(state: state), autoDismissEnabled {
      startDismissTimer(for: id)
    } else {
      cancelDismissTimer(for: id)
    }
  }

  /// Add a new video recording to the quick access stack
  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem? {
    guard isEnabled else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access video skipped; feature disabled",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }
    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }
    let result = await ThumbnailGenerator.generate(from: url)

    // Use placeholder if thumbnail generation failed
    let thumbnail: NSImage
    let needsRetry: Bool
    if let generated = result.thumbnail {
      thumbnail = generated
      needsRetry = false
    } else {
      logger.warning("Video thumbnail failed for \(url.lastPathComponent), using placeholder")
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "Quick access video thumbnail failed; using placeholder",
        context: ["fileName": url.lastPathComponent]
      )
      thumbnail = ThumbnailGenerator.placeholderThumbnail()
      needsRetry = true
    }

    // Use actual duration or nil (will show no badge if duration unavailable)
    let item = QuickAccessItem(url: url, thumbnail: thumbnail, duration: result.duration ?? 0)

    // Animate insertion explicitly — no implicit .animation on the stack
    withAnimation(QuickAccessAnimations.cardInsert) {
      if items.count >= maxVisibleItems, let oldestId = items.last?.id {
        cancelDismissTimer(for: oldestId)
        pinWindowManager.close(id: oldestId)
        items.removeLast()
        DiagnosticLogger.shared.log(
          .debug,
          .ui,
          "Quick access trimmed oldest item",
          context: ["maxVisibleItems": "\(maxVisibleItems)"]
        )
      }
      items.insert(item, at: 0)
    }

    // Ensure the panel window exists — heals any state where items outlived
    // the panel (e.g. a previously interrupted show/hide transition).
    showPanelIfNeeded()

    if autoDismissEnabled {
      startDismissTimer(for: item.id)
    }

    // Schedule background thumbnail retry if needed
    if needsRetry {
      scheduleThumbnailRetry(for: item.id, url: url)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access video added",
      context: [
        "fileName": url.lastPathComponent,
        "itemCount": "\(items.count)",
        "duration": "\(result.duration ?? 0)",
      ]
    )

    return item
  }

  /// Present a history record as a Quick Access card and return the session item.
  /// This intentionally restores through Quick Access even for manually opened
  /// history records, so editors get the same item-scoped save/session behavior
  /// as fresh captures.
  func restoreHistoryItem(_ record: CaptureHistoryRecord) async -> QuickAccessItem? {
    let url = record.fileURL

    if let existingItem = item(matching: url) {
      showPanelIfNeeded()
      DiagnosticLogger.shared.log(
        .info,
        .history,
        "History restore reused quick access item",
        context: [
          "fileName": record.fileName,
          "type": record.captureType.rawValue,
          "itemId": existingItem.id.uuidString,
        ]
      )
      return existingItem
    }

    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }

    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History restore skipped; file missing",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
      return nil
    }

    let result = await ThumbnailGenerator.generate(from: url)
    let thumbnail: NSImage
    let needsRetry: Bool
    if let generated = result.thumbnail {
      thumbnail = generated
      needsRetry = false
    } else {
      thumbnail = ThumbnailGenerator.placeholderThumbnail()
      needsRetry = true
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "History restore thumbnail failed; using placeholder",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
    }

    let item = switch record.captureType {
    case .screenshot:
      QuickAccessItem(
        id: UUID(),
        url: url,
        thumbnail: thumbnail,
        capturedAt: record.capturedAt,
        itemType: .screenshot,
        duration: nil
      )
    case .video, .gif:
      QuickAccessItem(
        id: UUID(),
        url: url,
        thumbnail: thumbnail,
        capturedAt: record.capturedAt,
        itemType: .video,
        duration: record.duration ?? result.duration ?? 0
      )
    }

    insertRestoredHistoryItem(item, needsRetry: needsRetry, retryURL: url)
    DiagnosticLogger.shared.log(
      .info,
      .history,
      "History restored into quick access",
      context: [
        "fileName": record.fileName,
        "type": record.captureType.rawValue,
        "itemId": item.id.uuidString,
      ]
    )
    return item
  }

  /// Remove an item (screenshot or video) from the stack
  func removeItem(id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else {
      cancelDismissTimer(for: id)
      editingItemIds.remove(id)
      activityHoldItemIds.remove(id)
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access remove requested for missing item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    let url = item.url
    let isTempFile = tempCaptureManager.isTempFile(url)

    cancelDismissTimer(for: id)
    pinWindowManager.close(id: id)
    editingItemIds.remove(id)
    activityHoldItemIds.remove(id)
    artifactRetryHandlers.removeValue(forKey: id)
    // Fast animation (0.15s) for immediate perceived response
    withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
      items.removeAll { $0.id == id }
    }

    if items.isEmpty {
      hidePanel()
    }

    scheduleDismissCleanup(for: url, isTempFile: isTempFile)
  }

  /// Remove a screenshot from the stack (backward compatible alias)
  func removeScreenshot(id: UUID) {
    removeItem(id: id)
  }

  private func scheduleDismissCleanup(for url: URL, isTempFile: Bool) {
    guard isTempFile else {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access item dismissed; saved file retained",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }

    // Let SwiftUI commit the card removal before checking history or touching disk.
    Task { @MainActor in
      await Task.yield()

      // Auto-delete temp files on dismiss (unsaved captures).
      // Skip deletion if history is enabled and the file has a history record —
      // the retention service will clean it up when the record ages out.
      let historyEnabled = UserDefaults.standard.snapzyHistoryEnabled
      let hasHistoryRecord = historyEnabled && CaptureHistoryStore.shared.hasRecord(forFilePath: url.path)

      if hasHistoryRecord {
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access item dismissed; temp file preserved for history",
          context: ["fileName": url.lastPathComponent]
        )
      } else if ClipboardHelper.isReferencedByGeneralPasteboard(url) {
        // The capture was auto-copied to the clipboard and nothing has been
        // copied since: receivers resolve the file URL at paste time, so
        // deleting it now would break the paste (#234). Leave reclamation to
        // launch-time orphan cleanup.
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access item dismissed; temp file preserved while referenced by pasteboard",
          context: ["fileName": url.lastPathComponent]
        )
      } else {
        ClipboardArtifactLeaseManager.shared.synchronizeWithGeneralPasteboard()
        guard ClipboardArtifactLeaseManager.shared.canReclaim(url: url) else {
          DiagnosticLogger.shared.log(
            .info,
            .clipboard,
            "Quick access item dismissed; temp file preserved by clipboard lease",
            context: ["fileName": url.lastPathComponent]
          )
          return
        }
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access item dismissed; temp file auto-delete requested",
          context: ["fileName": url.lastPathComponent]
        )
        tempCaptureManager.deleteTempFile(at: url)
      }
    }
  }

  /// Remove card from UI only — does NOT delete the underlying file.
  /// Used after drag-to-app so the receiving app can still read the file.
  /// Orphaned temp files get cleaned up on next launch via cleanupOrphanedFiles().
  func dismissCard(id: UUID) {
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access card dismissed without deleting file",
      context: ["itemId": id.uuidString]
    )
    cancelDismissTimer(for: id)
    pinWindowManager.close(id: id)
    editingItemIds.remove(id)
    activityHoldItemIds.remove(id)
    artifactRetryHandlers.removeValue(forKey: id)
    withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
      items.removeAll { $0.id == id }
    }
    if items.isEmpty {
      hidePanel()
    }
  }

  /// Toggle pin state for an item. Pinned items bypass auto-dismiss.
  func togglePin(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access toggle pin missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    setPinState(id: id, isPinned: !items[index].isPinned, closePinWindow: true)
  }

  /// Pin a screenshot item without toggling it back off.
  func pinScreenshot(id: UUID) {
    setPinState(id: id, isPinned: true, closePinWindow: false)
  }

  /// Pin a saved screenshot URL, creating a transient pin window if no Quick Access item owns it.
  @discardableResult
  func pinScreenshot(url: URL) async -> QuickAccessItem? {
    guard isEnabled else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access pin skipped; feature disabled",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }
    if let existingItem = item(matching: url) {
      pinScreenshot(id: existingItem.id)
      return item(matching: url) ?? existingItem
    }

    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }

    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access direct pin skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }

    let result = await ThumbnailGenerator.generate(from: url)
    let thumbnail = result.thumbnail ?? ThumbnailGenerator.placeholderThumbnail()
    let item = QuickAccessItem(url: url, thumbnail: thumbnail)
    let didShowWindow = pinWindowManager.show(item: item) { closedId in
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Transient pinned screenshot closed",
        context: ["itemId": closedId.uuidString]
      )
    }

    guard didShowWindow else { return nil }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Screenshot URL pinned directly",
      context: ["fileName": url.lastPathComponent, "itemId": item.id.uuidString]
    )
    return item
  }

  func setWindowOpen(id: UUID, isOpen: Bool) {
    if let index = items.firstIndex(where: { $0.id == id }) {
      PerfSignpost.event("setWindowOpenCommit")
      // No inline withAnimation here: QuickAccessStackView's
      // `.animation(value: visibleItems.count)` is the single driver for the
      // hide/reappear spring. Wrapping this mutation too would compound two springs.
      items[index].isWindowOpen = isOpen

      if !isOpen {
        // An editor window just closed and the card reappeared: self-heal the
        // hover monitors in case the runloop stall got the global event tap killed.
        panelController.reinstallMouseMonitors()
      }
    }
  }

  private func setPinState(id: UUID, isPinned: Bool, closePinWindow: Bool) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      if closePinWindow {
        pinWindowManager.close(id: id)
      }
      return
    }

    guard !items[index].isVideo else {
      items[index].isPinned = false
      pinWindowManager.close(id: id)
      return
    }

    items[index].isPinned = isPinned

    if isPinned {
      let didShowWindow = pinWindowManager.show(item: items[index]) { [weak self] closedId in
        self?.handlePinWindowClosed(id: closedId)
      }

      guard didShowWindow else {
        items[index].isPinned = false
        return
      }

      cancelDismissTimer(for: id)
      setWindowOpen(id: id, isOpen: true)

      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access item pinned",
        context: ["itemId": id.uuidString]
      )
    } else {
      if closePinWindow {
        pinWindowManager.close(id: id)
      }
      if autoDismissEnabled {
        startDismissTimer(for: id)
      }
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access item unpinned",
        context: ["itemId": id.uuidString]
      )
    }
  }

  private func handlePinWindowClosed(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].isPinned = false
    if autoDismissEnabled {
      startDismissTimer(for: id)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Pin window closed, item unpinned",
      context: ["itemId": id.uuidString]
    )
  }

  /// Update processing state for an item (used during GIF conversion)
  func updateProcessingState(id: UUID, state: QuickAccessProcessingState) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access processing state update missed item",
        context: ["itemId": id.uuidString, "state": "\(state)"]
      )
      return
    }
    items[index].processingState = state
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access processing state changed",
      context: ["itemId": id.uuidString, "state": "\(state)"]
    )
    if state == .idle {
      resumeCountdownForActivity(id)
    } else {
      pauseCountdownForActivity(id)
    }
  }

  /// Replace item URL and thumbnail after processing (e.g. GIF conversion)
  func updateItemURL(id: UUID, newURL: URL, newThumbnail: NSImage? = nil) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access item URL update missed item",
        context: ["itemId": id.uuidString, "fileName": newURL.lastPathComponent]
      )
      return
    }
    let existing = items[index]
    let thumbnail = newThumbnail ?? existing.thumbnail
    items[index] = QuickAccessItem(
      id: existing.id,
      url: newURL,
      thumbnail: thumbnail,
      capturedAt: existing.capturedAt,
      itemType: existing.itemType,
      duration: existing.duration,
      cloudURL: existing.cloudURL,
      cloudKey: existing.cloudKey,
      isCloudStale: existing.isCloudStale,
      isPinned: existing.isPinned
    )
    pinWindowManager.update(item: items[index])
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access item URL updated",
      context: ["itemId": id.uuidString, "fileName": newURL.lastPathComponent]
    )
  }

  /// Update thumbnail directly from an already-rendered image (synchronous, instant)
  /// Used after annotation save — avoids the slow ThumbnailGenerator pipeline.
  /// Preserves existing isCloudStale — callers should use markCloudStale(id:) if needed.
  func updateItemThumbnail(id: UUID, image: NSImage) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let existing = items[index]
    let maxSize: CGFloat = 200
    let thumbnail = scaleThumbnail(image, maxSize: maxSize)
    items[index] = QuickAccessItem(
      id: existing.id,
      url: existing.url,
      thumbnail: thumbnail,
      capturedAt: existing.capturedAt,
      itemType: existing.itemType,
      duration: existing.duration,
      cloudURL: existing.cloudURL,
      cloudKey: existing.cloudKey,
      isCloudStale: existing.isCloudStale,
      isPinned: existing.isPinned
    )
    pinWindowManager.update(item: items[index], imageOverride: image)
    logger.info("Thumbnail updated directly for item \(id)")
  }

  /// Update thumbnail directly with an already-scaled thumbnail and an optional full-resolution image.
  /// Skips lockFocus scaling on the main thread.
  /// - `fullResImage`: when non-nil, also pushed to the pin window as `imageOverride`
  ///   (pin sizing derives from it, so never pass a downscaled thumb here).
  /// - `generation`: stale-write guard from `nextThumbnailGeneration(for:)`; a late
  ///   off-main render with an older generation is dropped so last-save-wins holds.
  func updateItemThumbnail(id: UUID, thumbnail: NSImage, fullResImage: NSImage?, generation: UInt64? = nil) {
    if let generation {
      guard generation >= thumbnailSaveGenerations[id, default: 0] else { return }
    }
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    let existing = items[index]
    items[index] = QuickAccessItem(
      id: existing.id,
      url: existing.url,
      thumbnail: thumbnail,
      capturedAt: existing.capturedAt,
      itemType: existing.itemType,
      duration: existing.duration,
      cloudURL: existing.cloudURL,
      cloudKey: existing.cloudKey,
      isCloudStale: existing.isCloudStale,
      isPinned: existing.isPinned
    )
    if let fullResImage {
      pinWindowManager.update(item: items[index], imageOverride: fullResImage)
    }
    logger.info("Thumbnail updated directly with pre-scaled image for item \(id)")
  }

  /// Monotonic per-item token for the save-and-close async thumbnail push.
  /// Call on main when the save starts; pass the token to the async `updateItemThumbnail`
  /// so a slower earlier render can never overwrite a newer one.
  func nextThumbnailGeneration(for id: UUID) -> UInt64 {
    let next = thumbnailSaveGenerations[id, default: 0] + 1
    thumbnailSaveGenerations[id] = next
    return next
  }

  /// Scale image to thumbnail size using CGContext (thread-safe, runs on any queue)
  nonisolated static func cgScaleThumbnail(_ image: NSImage, maxSize: CGFloat) -> NSImage {
    let originalSize = image.size
    guard originalSize.width > 0, originalSize.height > 0 else { return image }

    let scale = min(maxSize / max(originalSize.width, originalSize.height), 1.0)
    if scale >= 1.0 { return image }

    let newSize = CGSize(
      width: originalSize.width * scale,
      height: originalSize.height * scale
    )

    var rect = CGRect(origin: .zero, size: originalSize)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
    let width = Int(newSize.width)
    let height = Int(newSize.height)

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return image }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))

    guard let scaledCgImage = context.makeImage() else { return image }
    return NSImage(cgImage: scaledCgImage, size: newSize)
  }

  /// Build a Quick Access thumbnail directly from a captured frame without
  /// waiting for a temporary file or ImageIO decode.
  nonisolated static func cgImageThumbnail(_ image: CGImage, maxSize: CGFloat = 200) -> NSImage {
    autoreleasepool {
      let nsImage = NSImage(
        cgImage: image,
        size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
      )
      return cgScaleThumbnail(nsImage, maxSize: maxSize)
    }
  }

  /// Scale image to thumbnail size (synchronous, no file I/O)
  private func scaleThumbnail(_ image: NSImage, maxSize: CGFloat) -> NSImage {
    PerfSignpost.measure("scaleThumbnailInner") {
      let originalSize = image.size
      guard originalSize.width > 0, originalSize.height > 0 else { return image }

      let scale: CGFloat = if originalSize.width > originalSize.height {
        min(maxSize / originalSize.width, 1.0)
      } else {
        min(maxSize / originalSize.height, 1.0)
      }
      if scale >= 1.0 { return image }

      let newSize = CGSize(
        width: originalSize.width * scale,
        height: originalSize.height * scale
      )
      let thumbnail = NSImage(size: newSize)
      thumbnail.lockFocus()
      NSGraphicsContext.current?.imageInterpolation = .high
      image.draw(
        in: NSRect(origin: .zero, size: newSize),
        from: NSRect(origin: .zero, size: originalSize),
        operation: .copy,
        fraction: 1.0
      )
      thumbnail.unlockFocus()
      return thumbnail
    }
  }

  /// Refresh thumbnail for an item after its image was updated on disk (e.g. annotation saved)
  func refreshItemThumbnail(id: UUID) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .debug,
        .ui,
        "Quick access thumbnail refresh skipped; item missing",
        context: ["itemId": id.uuidString]
      )
      return
    }
    let url = items[index].url
    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }
    let result = await ThumbnailGenerator.generate(from: url)
    guard let newThumbnail = result.thumbnail else {
      logger.warning("Thumbnail refresh failed for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "Quick access thumbnail refresh failed",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }
    // Re-check index (item may have been removed during async thumbnail generation)
    guard let freshIndex = items.firstIndex(where: { $0.id == id }) else { return }
    let existing = items[freshIndex]
    items[freshIndex] = QuickAccessItem(
      id: existing.id,
      url: existing.url,
      thumbnail: newThumbnail,
      capturedAt: existing.capturedAt,
      itemType: existing.itemType,
      duration: existing.duration,
      cloudURL: existing.cloudURL,
      cloudKey: existing.cloudKey,
      isCloudStale: existing.isCloudStale,
      isPinned: existing.isPinned
    )
    pinWindowManager.update(item: items[freshIndex])
    logger.info("Thumbnail refreshed for \(url.lastPathComponent)")
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Quick access thumbnail refreshed",
      context: ["fileName": url.lastPathComponent]
    )
  }

  // MARK: - Card Action Shortcuts

  /// Single writer for hover state. Card action shortcuts shadow the frontmost
  /// app's keyboard while registered, so hover-exit must always reach here.
  func setHoveredItem(id: UUID, hovering: Bool) {
    if hovering {
      guard items.contains(where: { $0.id == id }) else { return }
      hoveredItemID = id
    } else {
      guard hoveredItemID == id else { return }
      hoveredItemID = nil
    }
    hoverShortcutRegistry.setHoverActive(hoveredItemID != nil)
  }

  func clearHoveredItem() {
    guard hoveredItemID != nil else { return }
    hoveredItemID = nil
    hoverShortcutRegistry.setHoverActive(false)
  }

  /// A card can vanish under the pointer (countdown, delete, editor open) without
  /// SwiftUI reporting hover-exit, which would leave the bindings registered.
  private func invalidateHoverIfItemGone() {
    guard let hoveredItemID else { return }
    guard !items.contains(where: { $0.id == hoveredItemID }) else { return }
    clearHoveredItem()
  }

  private func handleCardShortcut(_ action: QuickAccessActionKind) {
    guard let hoveredItemID, items.contains(where: { $0.id == hoveredItemID }) else { return }
    guard QuickAccessActionConfigurationStore.shared.isEnabled(action) else { return }

    cardShortcutTrigger.send(
      QuickAccessCardShortcutTrigger(itemID: hoveredItemID, action: action)
    )
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access card action triggered via shortcut",
      context: ["itemId": hoveredItemID.uuidString, "action": action.rawValue]
    )
  }

  func suspendForCapture() {
    clearHoveredItem()
    panelController.suspendMouseMonitors()
    pinWindowManager.suspendAllMouseMonitors()
  }

  func resumeAfterCapture() {
    panelController.resumeMouseMonitors()
    pinWindowManager.resumeAllMouseMonitors()
  }

  /// Dismiss all screenshots
  func dismissAll() {
    let count = items.count
    if annotationEditingItemID != nil {
      annotationEditingItemID = nil
      panelController.setAnnotationEditorInteractionEnabled(false)
    }
    for item in items {
      cancelDismissTimer(for: item.id)
    }
    pinWindowManager.closeAll()
    items.removeAll()
    editingItemIds.removeAll()
    activityHoldItemIds.removeAll()
    artifactRetryHandlers.removeAll()
    hidePanel()
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access dismissed all items",
      context: ["itemCount": "\(count)"]
    )
  }

  /// Copy item to clipboard (cloud link if available, otherwise image or video file URL)
  func copyToClipboard(id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .clipboard,
        "Quick access clipboard copy missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    // If cloud URL is available, copy the cloud link as text
    if let cloudURL = item.cloudURL {
      guard item.allows(.copy) else {
        reportNotReady(item, operation: .copy)
        return
      }
      let pasteboard = clipboardPasteboard
      pasteboard.clearContents()
      guard pasteboard.setString(cloudURL.absoluteString, forType: .string) else {
        lastOperationError = AppText.value("qaClipboardFailed", language: .system)
        return
      }
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Quick access copied cloud link to clipboard",
        context: ["fileName": item.url.lastPathComponent]
      )
      dismissCard(id: id)
      SoundManager.play("Pop")
      return
    }

    guard item.allows(.copy) else {
      reportNotReady(item, operation: .copy)
      return
    }

    let url = item.url
    let isVideo = item.isVideo

    // Write to the clipboard BEFORE removing the card. Image copies register a
    // lease so the temp file survives dismissal and stays readable until the
    // pasteboard changes.
    let copied: Bool
    if isVideo {
      copied = ClipboardHelper.copyMediaFile(from: url)
    } else {
      copied = SmartCaptureClipboard.copy(
        imageURL: url,
        artifactID: item.artifactID,
        captureID: item.captureID,
        to: clipboardPasteboard
      )
    }

    guard copied else {
      lastOperationError = AppText.value("qaClipboardFailed", language: .system)
      DiagnosticLogger.shared.log(
        .error,
        .clipboard,
        "Quick access clipboard copy failed; card kept",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }

    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      isVideo
        ? "Quick access copied video file to clipboard"
        : "Quick access copied image to clipboard",
      context: ["fileName": url.lastPathComponent]
    )

    // Remove card from UI without deleting the temp file (same as drag-to-app).
    dismissCard(id: id)

    // File-based clipboard: the file must stay on disk so the receiving app
    // can read it at paste time. The lease is released when the pasteboard
    // changeCount moves past this copy.

    SoundManager.play("Pop")
  }

  private func reportNotReady(_ item: QuickAccessItem, operation: QuickAccessFileOperation) {
    guard let key = QuickAccessOperationCoordinator.userMessageKey(for: item.artifactState) else { return }
    let message = AppText.value(key, language: .system)
    lastOperationError = message
    DiagnosticLogger.shared.log(
      .warning,
      .action,
      "Quick access \(operation.rawValue) rejected before artifact became ready",
      context: [
        "itemId": item.id.uuidString,
        "state": item.artifactState.rawValue,
      ]
    )
  }

  /// Delete item from disk and remove from stack.
  ///
  /// The card is removed only after the file operation succeeded, so a failed
  /// delete never leaves the user with no way to retry.
  func deleteItem(id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access delete missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    guard QuickAccessOperationCoordinator.mayStartDelete(state: item.artifactState) else {
      reportNotReady(item, operation: .delete)
      return
    }

    let url = item.url
    let isTempFile = item.isTemporaryArtifact || tempCaptureManager.isTempFile(url)
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access delete requested",
      context: ["fileName": url.lastPathComponent, "temp": isTempFile ? "true" : "false"]
    )

    cancelDismissTimer(for: id)
    do {
      if isTempFile {
        try tempCaptureManager.deleteTempFileIfPresent(at: url)
      } else if FileManager.default.fileExists(atPath: url.path) {
        let fileAccess = fileAccessManager.beginAccessingURL(url)
        defer { fileAccess.stop() }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if item.isVideo {
          try? RecordingMetadataStore.delete(for: url)
        }
      }
    } catch {
      let message = AppText.value("qaDeleteFailed", language: .system)
      if let index = items.firstIndex(where: { $0.id == id }) {
        items[index].artifactErrorDescription = message
      }
      lastOperationError = message
      logger.error("Failed to delete item \(url.lastPathComponent): \(error.localizedDescription)")
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Quick access delete failed; card kept",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }

    CaptureHistoryStore.shared.removeByFilePath(url.path)
    removeItem(id: id)
  }

  /// Open screenshot in Finder
  func openInFinder(id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access reveal in Finder missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    guard item.allows(.open) else {
      reportNotReady(item, operation: .open)
      return
    }

    guard !item.isTemporaryArtifact else {
      // Revealing a temp file in Finder used to delete it right after the
      // card dismissal. Promote first, then reveal the permanent artifact.
      promoteItem(id: id, revealInFinder: true)
      return
    }

    let url = item.url
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access reveal in Finder requested",
      context: ["fileName": url.lastPathComponent]
    )
    dismissCard(id: id)
    Task { @MainActor in
      let fileAccess = fileAccessManager.beginAccessingURL(url)
      defer { fileAccess.stop() }
      NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
  }

  func saveItem(id: UUID) {
    promoteItem(id: id, revealInFinder: false)
  }

  /// Promote a temporary artifact into the export folder. The card, history
  /// path and Finder reveal are committed only after the file operation
  /// succeeded; on failure the card stays and shows a retryable error.
  private func promoteItem(id: UUID, revealInFinder: Bool) {
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access save missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    guard QuickAccessOperationCoordinator.mayStartSave(state: item.artifactState) else {
      reportNotReady(item, operation: revealInFinder ? .open : .save)
      return
    }

    guard item.isTemporaryArtifact else {
      // Already permanent: never copy it a second time.
      if revealInFinder {
        lastOperationError = nil
        dismissCard(id: id)
        Task { @MainActor in
          NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
        }
      } else {
        NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
      }
      return
    }

    let tempURL = item.url
    let artifact = CaptureArtifact(
      id: item.artifactID,
      captureID: item.captureID,
      url: tempURL,
      isTemporary: true,
      format: ScreenCaptureImageFormat(fileExtension: tempURL.pathExtension) ?? .png,
      pixelWidth: item.pixelWidth,
      pixelHeight: item.pixelHeight,
      state: .ready
    )
    let exportDirectory = fileAccessManager.resolvedExportDirectoryURL()
    let baseName = tempURL.deletingPathExtension().lastPathComponent
    cancelDismissTimer(for: id)
    updateArtifactState(id: id, state: .promoting, error: nil)

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access manual save requested",
      context: ["fileName": tempURL.lastPathComponent]
    )

    Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) {
        Result { try CaptureArtifactStore.shared.promote(artifact, to: exportDirectory, baseName: baseName) }
      }.value

      guard let self else { return }
      switch result {
      case .success(let promoted):
        CaptureHistoryStore.shared.recordSavedCapture(
          url: promoted.url,
          width: promoted.pixelWidth,
          height: promoted.pixelHeight,
          byteCount: promoted.byteCount,
          previousPath: tempURL.path,
          isVideo: item.isVideo
        )

        if let index = self.items.firstIndex(where: { $0.id == id }) {
          self.items[index].url = promoted.url
          self.items[index].artifactState = .ready
          self.items[index].artifactErrorDescription = nil
          self.items[index].isTemporaryArtifact = false
        }
        self.artifactRetryHandlers.removeValue(forKey: id)
        self.lastOperationError = nil

        let captureType: CaptureType = item.isVideo ? .recording : .screenshot
        PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(
          for: captureType,
          url: promoted.url
        )

        if revealInFinder {
          let fileAccess = self.fileAccessManager.beginAccessingURL(promoted.url)
          defer { fileAccess.stop() }
          NSWorkspace.shared.selectFile(promoted.url.path, inFileViewerRootedAtPath: "")
        }
        self.dismissCard(id: id)
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access manual save completed",
          context: ["fileName": promoted.url.lastPathComponent]
        )

      case .failure(let error):
        let message = AppText.value("qaArtifactFailed", language: .system)
        self.updateArtifactState(id: id, state: .ready, error: message)
        self.lastOperationError = message
        DiagnosticLogger.shared.logError(
          .fileAccess,
          error,
          "Quick access manual save failed; card kept",
          context: ["fileName": tempURL.lastPathComponent]
        )
      }
    }
  }

  /// Update position setting
  func setPosition(_ newPosition: QuickAccessPosition) {
    position = newPosition
    DiagnosticLogger.shared.log(
      .info,
      .preferences,
      "Quick access position changed",
      context: ["position": newPosition.rawValue]
    )
  }

  // MARK: - Private Methods

  private func showPanel() {
    let stackView = QuickAccessStackView(manager: self)
    let size = calculateMaxPanelSize()
    panelController.show(
      stackView,
      size: size,
      itemCount: visiblePanelItemCount,
      scale: CGFloat(overlayScale)
    )
    installEditHotKeyIfNeeded()
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Quick access panel shown",
      context: ["itemCount": "\(items.count)"]
    )
  }

  /// Ensure a panel exists for the capture that just landed, on the display that
  /// capture happened on. A panel already sliding out is not reusable — it would
  /// finish closing and swallow the new card — so that case gets a fresh show.
  private func showPanelIfNeeded() {
    guard panelController.isVisible, !panelController.isDismissing else {
      showPanel()
      return
    }
    panelController.moveToActiveScreenIfNeeded()
  }

  #if DEBUG
  /// Test seam: panel visibility is private state, but "last card copied closes
  /// the panel" is a product guarantee that needs a real assertion.
  var testIsPanelVisible: Bool { panelController.isVisible }
  #endif

  private func hidePanel() {
    clearHoveredItem()
    removeEditHotKey()
    panelController.hide()
  }

  /// Replace the visible Quick Access stack with the annotation editor in the
  /// same floating panel. This keeps the screenshot at its current screen
  /// position and avoids opening a second centered window.
  @discardableResult
  func presentAnnotationEditor(for item: QuickAccessItem, language: AppLanguage) -> Bool {
    guard !item.isVideo,
          let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return false
    }

    if annotationEditingItemID != nil {
      restoreAnnotationEditor()
    }
    if !panelController.isVisible {
      showPanel()
    }

    annotationEditingItemID = item.id
    setWindowOpen(id: item.id, isOpen: true)
    pauseCountdownForEditingItem(item.id)
    let model = SmartAnnotationModel(initialTool: .rectangle)
    let editor = SmartAnnotationEditor(
      image: image,
      language: language,
      model: model,
      embedded: true,
      onCancel: { [weak self] in
        self?.restoreAnnotationEditor()
      },
      onComplete: { [weak self] in
        guard let self,
              let annotated = SmartAnnotationRenderer.render(
                image: image,
                annotations: model.annotations,
                styles: model.styledAnnotations.map(\.style)
              ) else {
          self?.lastOperationError = AppText.value("qaArtifactFailed", language: .system)
          self?.restoreAnnotationEditor()
          return
        }
        let targetURL = item.url
        Task { [weak self] in
          let result = await Task.detached(priority: .userInitiated) {
            await CaptureImageWorkGate.shared.withPermit {
              Result { try Self.writeAnnotatedImage(annotated, to: targetURL) }
            }
          }.value
          guard let self else { return }
          switch result {
          case .success:
            let thumbnailImage = NSImage(
              cgImage: annotated,
              size: NSSize(width: annotated.width, height: annotated.height)
            )
            self.lastOperationError = nil
            self.updateItemThumbnail(id: item.id, image: thumbnailImage)
          case .failure(let error):
            let message = AppText.value("qaArtifactFailed", language: .system)
            self.lastOperationError = message
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
              self.items[index].artifactErrorDescription = message
            }
            DiagnosticLogger.shared.logError(
              .fileAccess,
              error,
              "Quick access annotation write failed; original kept",
              context: ["fileName": targetURL.lastPathComponent]
            )
          }
          self.restoreAnnotationEditor()
        }
      },
      onCopyAndClose: { [weak self] in
        guard let self else { return }
        guard let annotated = SmartAnnotationRenderer.render(
          image: image,
          annotations: model.annotations,
          styles: model.styledAnnotations.map(\.style)
        ) else {
          self.lastOperationError = AppText.value("qaArtifactFailed", language: .system)
          return
        }
        // Copy first. A failed clipboard write keeps the editor and every
        // annotation on screen; only a successful copy closes it.
        guard SmartCaptureClipboard.copy(
          image: annotated,
          to: clipboardPasteboard
        ) else {
          self.lastOperationError = AppText.value("qaClipboardFailed", language: .system)
          DiagnosticLogger.shared.log(
            .error,
            .clipboard,
            "Quick access annotate Copy & Close failed; editor kept"
          )
          return
        }
        // Close immediately after the clipboard succeeded, then persist the
        // edited bytes in the background and refresh the card thumbnail.
        self.restoreAnnotationEditor()
        let targetURL = item.url
        Task { [weak self] in
          let result = await Task.detached(priority: .userInitiated) {
            await CaptureImageWorkGate.shared.withPermit {
              Result { try Self.writeAnnotatedImage(annotated, to: targetURL) }
            }
          }.value
          guard let self else { return }
          switch result {
          case .success:
            let thumbnailImage = NSImage(
              cgImage: annotated,
              size: NSSize(width: annotated.width, height: annotated.height)
            )
            self.lastOperationError = nil
            self.updateItemThumbnail(id: item.id, image: thumbnailImage)
          case .failure(let error):
            let message = AppText.value("qaArtifactFailed", language: .system)
            self.lastOperationError = message
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
              self.items[index].artifactErrorDescription = message
            }
            DiagnosticLogger.shared.logError(
              .fileAccess,
              error,
              "Quick access annotate Copy & Close save failed; original kept",
              context: ["fileName": targetURL.lastPathComponent]
            )
          }
        }
      }
    )
    panelController.updateContent(editor)
    panelController.setAnnotationEditorInteractionEnabled(true)
    return true
  }

  /// Encode and replace the capture only after the new bytes decode at the
  /// expected pixel size. A failure leaves the original file untouched; the
  /// staging file never outlives the attempt.
  ///
  /// This is still one artifact-store write: the store owns staging, decode
  /// validation and the atomic replacement, so an annotation save cannot grow
  /// a second, weaker file-writing path beside the capture pipeline.
  nonisolated static func writeAnnotatedImage(_ image: CGImage, to url: URL) throws {
    let format = ScreenCaptureImageFormat(fileExtension: url.pathExtension) ?? .png
    _ = try CaptureArtifactStore.shared.write(
      to: url,
      image: SendableScreenCaptureImage(value: image),
      format: format,
      quality: 1
    )
  }

  private func restoreAnnotationEditor() {
    guard let id = annotationEditingItemID else { return }
    annotationEditingItemID = nil
    panelController.setAnnotationEditorInteractionEnabled(false)
    setWindowOpen(id: id, isOpen: false)
    resumeCountdownForEditingItem(id)
    guard !items.isEmpty else {
      hidePanel()
      return
    }
    panelController.updateContent(QuickAccessStackView(manager: self))
    refreshPanelInteractionMetrics()
  }

  @discardableResult
  func openEditorForNewestItem() -> Bool {
    guard isEnabled, panelController.isVisible, let item = items.first else { return false }
    if item.isVideo {
      VideoEditorManager.shared.openEditor(for: item)
    } else {
      AnnotateManager.shared.openAnnotation(for: item)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access editor opened via keyboard shortcut",
      context: ["itemId": item.id.uuidString, "isVideo": item.isVideo ? "true" : "false"]
    )
    return true
  }

  private func installEditHotKeyIfNeeded() {
    guard openEditorShortcutEnabled else { return }
    guard editHotKeyRef == nil, let shortcut = openEditorShortcut else { return }

    if editHotKeyHandler == nil {
      var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: OSType(kEventHotKeyPressed)
      )
      let callback: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        let manager = Unmanaged<QuickAccessManager>.fromOpaque(userData).takeUnretainedValue()
        guard hotKeyID.signature == manager.editHotKeyID.signature else {
          return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { _ = manager.openEditorForNewestItem() }
        }
        return noErr
      }
      InstallEventHandler(
        GetApplicationEventTarget(),
        callback,
        1,
        &spec,
        Unmanaged.passUnretained(self).toOpaque(),
        &editHotKeyHandler
      )
    }

    RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.modifiers,
      editHotKeyID,
      GetApplicationEventTarget(),
      0,
      &editHotKeyRef
    )
  }

  private func removeEditHotKey() {
    if let editHotKeyRef {
      UnregisterEventHotKey(editHotKeyRef)
      self.editHotKeyRef = nil
    }
  }

  func setOpenEditorShortcut(_ config: ShortcutConfig?) {
    openEditorShortcut = config
    if let config, let data = try? JSONEncoder().encode(config) {
      UserDefaults.standard.set(data, forKey: Keys.openEditorShortcut)
    } else {
      UserDefaults.standard.set(explicitEmptyShortcutData, forKey: Keys.openEditorShortcut)
    }
    if editHotKeyRef != nil || openEditorShortcutEnabled {
      removeEditHotKey()
      installEditHotKeyIfNeeded()
    }
  }

  private func loadOpenEditorShortcut() {
    guard let data = UserDefaults.standard.data(forKey: Keys.openEditorShortcut) else {
      openEditorShortcut = Self.defaultOpenEditorShortcut
      return
    }
    if data == explicitEmptyShortcutData {
      openEditorShortcut = nil
      return
    }
    openEditorShortcut =
      (try? JSONDecoder().decode(ShortcutConfig.self, from: data)) ?? Self.defaultOpenEditorShortcut
  }

  private var visiblePanelItemCount: Int {
    let actuallyVisibleItems = items.filter { !(hideCardWhenWindowOpen && $0.isWindowOpen) }
    return min(actuallyVisibleItems.count, maxVisibleItems)
  }

  private func refreshPanelInteractionMetrics() {
    panelController.updateInteractionMetrics(
      itemCount: visiblePanelItemCount,
      scale: CGFloat(overlayScale)
    )
  }

  private func item(matching url: URL) -> QuickAccessItem? {
    let standardizedURL = url.standardizedFileURL
    return items.first { $0.url.standardizedFileURL == standardizedURL }
  }

  private func insertRestoredHistoryItem(
    _ item: QuickAccessItem,
    needsRetry: Bool,
    retryURL: URL
  ) {
    withAnimation(QuickAccessAnimations.cardInsert) {
      if items.count >= maxVisibleItems, let oldestId = items.last?.id {
        cancelDismissTimer(for: oldestId)
        pinWindowManager.close(id: oldestId)
        items.removeLast()
        DiagnosticLogger.shared.log(
          .debug,
          .ui,
          "Quick access trimmed oldest item for history restore",
          context: ["maxVisibleItems": "\(maxVisibleItems)"]
        )
      }
      items.insert(item, at: 0)
    }

    showPanelIfNeeded()

    if autoDismissEnabled {
      startDismissTimer(for: item.id)
    }

    if needsRetry {
      scheduleThumbnailRetry(for: item.id, url: retryURL)
    }
  }

  private func insertCapturePlaceholderItem(_ item: QuickAccessItem) {
    withAnimation(QuickAccessAnimations.cardInsert) {
      if items.count >= maxVisibleItems, let oldestId = items.last?.id {
        cancelDismissTimer(for: oldestId)
        pinWindowManager.close(id: oldestId)
        items.removeLast()
      }
      items.insert(item, at: 0)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access placeholder added",
      context: [
        "fileName": item.url.lastPathComponent,
        "itemCount": "\(items.count)",
        "artifactId": item.artifactID.uuidString,
      ]
    )
    showPanelIfNeeded()
    // No countdown until the artifact reaches .ready.
  }

  private func insertScreenshotItem(_ item: QuickAccessItem, retryURL: URL? = nil) {
    // Animate insertion explicitly — no implicit .animation on the stack.
    withAnimation(QuickAccessAnimations.cardInsert) {
      if items.count >= maxVisibleItems, let oldestId = items.last?.id {
        cancelDismissTimer(for: oldestId)
        pinWindowManager.close(id: oldestId)
        items.removeLast()
        DiagnosticLogger.shared.log(
          .debug,
          .ui,
          "Quick access trimmed oldest item",
          context: ["maxVisibleItems": "\(maxVisibleItems)"]
        )
      }
      items.insert(item, at: 0)
    }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access screenshot added",
      context: ["fileName": item.url.lastPathComponent, "itemCount": "\(items.count)"]
    )

    // Ensure the panel window exists — heals any state where items outlived
    // the panel (e.g. a previously interrupted show/hide transition).
    showPanelIfNeeded()

    if autoDismissEnabled {
      startDismissTimer(for: item.id)
    }

    if let retryURL {
      scheduleThumbnailRetry(for: item.id, url: retryURL)
    }
  }

  /// Fixed max-size panel — never resizes, prevents SwiftUI re-layout jitter
  private func calculateMaxPanelSize() -> CGSize {
    let itemCount = maxVisibleItems
    let scale = CGFloat(overlayScale)
    let cardW = QuickAccessLayout.scaledCardWidth(scale)
    let cardH = QuickAccessLayout.scaledCardHeight(scale)
    let height =
      CGFloat(itemCount) * cardH
        + CGFloat(itemCount - 1) * QuickAccessLayout.cardSpacing
        + QuickAccessLayout.containerPadding * 2
    let width = cardW + QuickAccessLayout.containerPadding * 2
    return CGSize(width: width, height: height)
  }

  private func startDismissTimer(for id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isPinned else { return }
    guard QuickAccessOperationCoordinator.shouldRunCountdown(state: items[index].artifactState) else { return }
    let delay = autoDismissDelay
    let timer = QuickAccessCountdownTimer(duration: delay) { [weak self] in
      self?.removeScreenshot(id: id)
    }
    dismissTimers[id] = timer
    timer.start()

    if isItemCountdownHeld(id) {
      timer.pause()
    }
  }

  private func cancelDismissTimer(for id: UUID) {
    dismissTimers[id]?.cancel()
    dismissTimers.removeValue(forKey: id)
  }

  // MARK: - Pause / Resume Countdown

  /// Pause countdown for a single item (used by hover)
  func pauseCountdown(for id: UUID) {
    dismissTimers[id]?.pause()
  }

  /// Resume countdown for a single item (used by hover un-hover)
  func resumeCountdown(for id: UUID) {
    // Don't resume if an editor, upload, or conversion still owns the countdown.
    guard !isItemCountdownHeld(id) else { return }
    dismissTimers[id]?.resume()
  }

  /// Pause countdown while an async activity is running for an item.
  func pauseCountdownForActivity(_ id: UUID) {
    activityHoldItemIds.insert(id)
    dismissTimers[id]?.pause()
  }

  /// Resume countdown after an async activity finishes, unless another hold remains.
  func resumeCountdownForActivity(_ id: UUID) {
    activityHoldItemIds.remove(id)
    guard !isItemCountdownHeld(id) else { return }
    dismissTimers[id]?.resume()
  }

  private func isItemCountdownHeld(_ id: UUID) -> Bool {
    activityHoldItemIds.contains(id) || isItemPausedByEditing(id)
  }

  /// Check if an item should remain paused because of an active editing session.
  /// True if the item itself is being edited, OR if it's newer (above) than any edited item.
  private func isItemPausedByEditing(_ id: UUID) -> Bool {
    guard !editingItemIds.isEmpty else { return false }
    if editingItemIds.contains(id) { return true }
    guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return false }
    for editId in editingItemIds {
      if let editIndex = items.firstIndex(where: { $0.id == editId }), itemIndex < editIndex {
        return true
      }
    }
    return false
  }

  /// Pause countdown for an item being edited + all items captured after it (newer/above)
  func pauseCountdownForEditingItem(_ id: UUID) {
    editingItemIds.insert(id)
    guard let editIndex = items.firstIndex(where: { $0.id == id }) else { return }
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access countdown paused for editing",
      context: ["itemId": id.uuidString, "affectedCount": "\(editIndex + 1)"]
    )

    // Pause the edited item + items at lower indices (captured after, newer)
    for i in 0 ... editIndex {
      dismissTimers[items[i].id]?.pause()
    }
  }

  /// Resume countdown for an item done editing + all items captured after it (newer/above)
  func resumeCountdownForEditingItem(_ id: UUID) {
    editingItemIds.remove(id)
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access countdown resumed after editing",
      context: ["itemId": id.uuidString]
    )

    if let editIndex = items.firstIndex(where: { $0.id == id }) {
      // Item still exists — restart it + items at lower indices (newer) with a fresh countdown
      for i in 0 ... editIndex {
        let itemId = items[i].id
        guard !isItemCountdownHeld(itemId) else { continue }
        dismissTimers[itemId]?.restart(duration: autoDismissDelay)
      }
    } else {
      // Edited item was already removed (swiped/dismissed during editing).
      // Resume all remaining items that aren't held by another editor.
      for item in items {
        guard !isItemCountdownHeld(item.id) else { continue }
        dismissTimers[item.id]?.resume()
      }
    }
  }

  /// Retry thumbnail generation in background and update item if successful
  private func scheduleThumbnailRetry(for id: UUID, url: URL) {
    Task { @MainActor in
      // Wait 500ms then retry
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      guard items.contains(where: { $0.id == id }) else { return }

      let fileAccess = fileAccessManager.beginAccessingURL(url)
      defer { fileAccess.stop() }

      let result = await ThumbnailGenerator.generate(from: url)
      guard let newThumbnail = result.thumbnail else {
        logger.error("Thumbnail retry also failed for \(url.lastPathComponent)")
        DiagnosticLogger.shared.log(
          .error,
          .ui,
          "Quick access thumbnail retry failed",
          context: ["fileName": url.lastPathComponent]
        )
        return
      }

      if let index = items.firstIndex(where: { $0.id == id }) {
        let existing = items[index]
        items[index] = QuickAccessItem(
          id: existing.id,
          url: existing.url,
          thumbnail: newThumbnail,
          capturedAt: existing.capturedAt,
          itemType: existing.itemType,
          duration: existing.duration,
          cloudURL: existing.cloudURL,
          cloudKey: existing.cloudKey,
          isCloudStale: existing.isCloudStale
        )
        logger.info("Thumbnail retry succeeded for \(url.lastPathComponent)")
        DiagnosticLogger.shared.log(
          .debug,
          .ui,
          "Quick access thumbnail retry succeeded",
          context: ["fileName": url.lastPathComponent]
        )
      }
    }
  }

  /// Set cloud URL and key for an item after successful upload
  func setCloudURL(id: UUID, url: URL, key: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .cloud,
        "Quick access cloud URL update missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    items[index].cloudURL = url
    items[index].cloudKey = key
    items[index].isCloudStale = false
    DiagnosticLogger.shared.log(
      .info,
      .cloud,
      "Quick access cloud URL attached",
      context: ["itemId": id.uuidString, "fileName": items[index].url.lastPathComponent]
    )
  }

  /// Mark an item's cloud state as stale (local differs from cloud)
  func markCloudStale(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .cloud,
        "Quick access cloud stale mark missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    guard items[index].cloudURL != nil else { return }
    items[index].isCloudStale = true
    DiagnosticLogger.shared.log(
      .debug,
      .cloud,
      "Quick access cloud state marked stale",
      context: ["itemId": id.uuidString, "fileName": items[index].url.lastPathComponent]
    )
  }
}
