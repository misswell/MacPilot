//
//  QuickAccessPinWindowManager.swift
//  Snapzy
//
//  Manages independent always-on-top pinned screenshot windows.
//
//  This is the app's single pin surface: screenshots pinned from the Quick
//  Access card, the area-selection toolbar, the clipboard-pin shortcut and the
//  "pin after capture" setting all land on the same window.
//

import AppKit
import SwiftUI

@MainActor
final class QuickAccessPinWindowManager {
  static let shared = QuickAccessPinWindowManager()

  private var controllers: [UUID: QuickAccessPinWindowController] = [:]
  private var lastEscapeAt: Date?

  private init() {}

  @discardableResult
  func show(
    item: QuickAccessItem,
    language: AppLanguage = .system,
    onUserClose: @escaping (UUID) -> Void
  ) -> Bool {
    guard !item.isVideo else { return false }

    if let controller = controllers[item.id] {
      controller.update(item: item)
      controller.orderFront()
      return true
    }

    let controller = QuickAccessPinWindowController(item: item, language: language)
    controller.onUserClose = { [weak self] id in
      self?.controllers[id] = nil
      onUserClose(id)
    }
    controllers[item.id] = controller
    controller.show()
    return true
  }

  /// Pin an in-memory image (clipboard paste, annotated capture). The pin is
  /// transient: it never joins the Quick Access card stack, so callers that
  /// need lifecycle control pass `onUserClose`.
  @discardableResult
  func showImage(
    _ image: CGImage,
    scaleFactor: CGFloat = 1,
    at anchorRect: CGRect? = nil,
    language: AppLanguage = .system,
    onUserClose: ((UUID) -> Void)? = nil
  ) -> UUID {
    let controller = QuickAccessPinWindowController(
      image: image,
      scaleFactor: scaleFactor,
      anchorRect: anchorRect,
      language: language
    )
    let id = controller.id
    controller.onUserClose = { [weak self] closedId in
      self?.controllers[closedId] = nil
      onUserClose?(closedId)
    }
    controllers[id] = controller
    controller.show()
    return id
  }

  /// Pin clipboard text as a floating card.
  @discardableResult
  func showText(
    _ text: String,
    language: AppLanguage = .system,
    onUserClose: ((UUID) -> Void)? = nil
  ) -> UUID? {
    guard !text.isEmpty else { return nil }
    let controller = QuickAccessPinWindowController(text: text, language: language)
    let id = controller.id
    controller.onUserClose = { [weak self] closedId in
      self?.controllers[closedId] = nil
      onUserClose?(closedId)
    }
    controllers[id] = controller
    controller.show()
    return id
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    controllers[item.id]?.update(item: item, imageOverride: imageOverride)
  }

  func close(id: UUID) {
    controllers.removeValue(forKey: id)?.close()
  }

  /// Silent teardown used by the Quick Access stack when the panel is cleared.
  func closeAll() {
    let all = Array(controllers.values)
    controllers.removeAll()
    for controller in all {
      controller.close()
    }
  }

  /// User-initiated teardown (double ESC): every pin runs its normal close
  /// path so pinned Quick Access cards unpin with their windows.
  func dismissAllFromUser() {
    for controller in Array(controllers.values) {
      controller.requestUserClose()
    }
  }

  func suspendAllMouseMonitors() {
    for controller in controllers.values {
      controller.suspendMouseMonitors()
    }
  }

  func resumeAllMouseMonitors() {
    for controller in controllers.values {
      controller.resumeMouseMonitors()
    }
  }

  /// Records an ESC press on a pin and reports whether it completed the
  /// double-press window that dismisses every pin.
  func registerEscapePress() -> Bool {
    let now = Date()
    guard QuickAccessPinEscapeRouting.shouldDismissPins(lastEscapeAt: lastEscapeAt, now: now) else {
      lastEscapeAt = now
      return false
    }
    lastEscapeAt = nil
    return true
  }
}

/// 双击 ESC 退出贴图的时间窗判定（可测纯函数）：两次 ESC 间隔不超过
/// `doublePressInterval` 视为「连按两次」。
enum QuickAccessPinEscapeRouting {
  static let doublePressInterval: TimeInterval = 0.8

  static func shouldDismissPins(lastEscapeAt: Date?, now: Date) -> Bool {
    guard let lastEscapeAt, now >= lastEscapeAt else { return false }
    return now.timeIntervalSince(lastEscapeAt) <= doublePressInterval
  }
}

@MainActor
private final class QuickAccessPinWindowController: NSObject {
  var onUserClose: ((UUID) -> Void)?

  let id: UUID
  private let state: QuickAccessPinWindowState
  private let window: QuickAccessPinWindow
  private let language: AppLanguage

  private var annotationHostView: NSView?
  private var targetZoomFactor: CGFloat = 1
  private var zoomTimer: Timer?
  private var zoomCenter: CGPoint?

  init(item: QuickAccessItem, language: AppLanguage) {
    id = item.id
    self.language = language

    let image = Self.loadImage(for: item)
    let screen = ScreenUtility.activeScreen()
    let sizes = QuickAccessPinWindowSizing.sizes(for: image.size, on: screen)
    let pinState = QuickAccessPinWindowState(
      id: item.id,
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
      baseSize: sizes.base,
      maxSize: sizes.max
    )
    state = pinState

    let frame = QuickAccessPinWindowSizing.centeredFrame(size: pinState.displaySize, on: screen)
    window = QuickAccessPinWindow(contentRect: frame, state: pinState)
    super.init()
    window.contentView = hostingView(size: pinState.displaySize)
    configureWindowCallbacks()
  }

  /// Pin an in-memory image. `anchorRect` places the pin back over the screen
  /// region it was captured from; `nil` centers it on the active screen.
  init(image cgImage: CGImage, scaleFactor: CGFloat, anchorRect: CGRect?, language: AppLanguage) {
    id = UUID()
    self.language = language

    let scale = max(0.25, scaleFactor)
    let pointSize = CGSize(
      width: CGFloat(cgImage.width) / scale,
      height: CGFloat(cgImage.height) / scale
    )
    let image = NSImage(cgImage: cgImage, size: pointSize)
    let screen = anchorRect
      .flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
      ?? ScreenUtility.activeScreen()
    let sizes = QuickAccessPinWindowSizing.sizes(for: pointSize, on: screen)
    let pinState = QuickAccessPinWindowState(
      id: id,
      // Reserved temp path: it names the drag-out file, and is only written
      // when the user actually drags the pin into another app.
      url: TempCaptureManager.shared.makeScreenshotURL(),
      image: image,
      thumbnail: image,
      baseSize: sizes.base,
      maxSize: sizes.max
    )
    state = pinState

    let frame = Self.frame(anchorRect: anchorRect, size: pinState.displaySize, on: screen)
    window = QuickAccessPinWindow(contentRect: frame, state: pinState)
    super.init()
    window.contentView = hostingView(size: pinState.displaySize)
    configureWindowCallbacks()
  }

  init(text: String, language: AppLanguage) {
    id = UUID()
    self.language = language

    let size = QuickAccessPinTextMetrics.baseSize(for: text)
    let pinState = QuickAccessPinWindowState(id: id, text: text, baseSize: size)
    state = pinState

    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? ScreenUtility.activeScreen()
    let frame = Self.frame(near: pointer, size: size, on: screen)
    window = QuickAccessPinWindow(contentRect: frame, state: pinState)
    super.init()
    window.contentView = hostingView(size: size)
    configureWindowCallbacks()
  }

  func show() {
    window.alphaValue = 1.0
    orderFront()
  }

  func orderFront() {
    window.orderFrontRegardless()
    window.updateMousePassthrough()
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    stopZoomAnimationLoop()
    let image = imageOverride ?? Self.loadImage(for: item)
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let sizes = QuickAccessPinWindowSizing.sizes(for: image.size, on: screen)
    let newSize = state.update(
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
      baseSize: sizes.base,
      maxSize: sizes.max
    )
    targetZoomFactor = state.zoomFactor
    resize(to: newSize, animated: false)
  }

  func close() {
    stopZoomAnimationLoop()
    annotationHostView = nil
    window.close()
  }

  func requestUserClose() {
    handleUserClose()
  }

  func suspendMouseMonitors() {
    window.suspendMouseMonitors()
  }

  func resumeMouseMonitors() {
    window.resumeMouseMonitors()
  }

  // MARK: - Window wiring

  private func configureWindowCallbacks() {
    window.onEscapeRequested = { [weak self] in
      self?.handleEscapeRequested()
    }
    window.onZoomStepRequested = { [weak self] step in
      self?.handleZoomStep(step)
    }
  }

  private func hostingView(size: CGSize) -> QuickAccessPinHostingView {
    let view = QuickAccessPinWindowView(
      state: state,
      onClose: { [weak self] in
        self?.handleUserClose()
      },
      onDoubleClick: { [weak self] in
        self?.copyToPasteboard()
      },
      onContextMenu: { [weak self] event in
        self?.presentContextMenu(with: event)
      },
      onZoomSizeChange: { [weak self] _, animated in
        self?.resizeForCurrentZoom(animated: animated)
      },
      onLockChanged: { [weak self] in
        self?.window.updateMousePassthrough()
      }
    )
    let hostingView = QuickAccessPinHostingView(rootView: view)
    hostingView.onMagnify = { [weak self] magnification in
      self?.window.requestMagnifyZoom(magnification: magnification)
    }
    hostingView.frame = NSRect(origin: .zero, size: size)
    return hostingView
  }

  private func handleUserClose() {
    QuickAccessManager.shared.setWindowOpen(id: id, isOpen: false)
    close()
    onUserClose?(id)
  }

  private func handleEscapeRequested() {
    if QuickAccessPinWindowManager.shared.registerEscapePress() {
      QuickAccessPinWindowManager.shared.dismissAllFromUser()
    } else {
      handleUserClose()
    }
  }

  // MARK: - Pin actions (shared by the context menu and double-click)

  private func copyToPasteboard() {
    if let text = state.text {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      return
    }
    guard let image = state.image else { return }
    if let cgImage = Self.cgImage(from: image) {
      SmartCaptureClipboard.copy(image: cgImage)
    } else {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
    }
  }

  private func recognizeText() {
    guard let image = state.image, let cgImage = Self.cgImage(from: image) else { return }
    Task { [weak self] in
      guard let self else { return }
      let text: String
      do {
        text = try await SmartOCRService.recognize(image: cgImage)
      } catch {
        SmartCaptureToast.shared.showOCRFailed(error: error, language: self.language)
        return
      }
      guard !text.isEmpty else {
        SmartCaptureToast.shared.showOCRNoText(language: self.language)
        return
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      SmartCaptureToast.shared.showOCRCopied(text: text, language: self.language)
    }
  }

  private func uploadImage() {
    guard let image = state.image, let cgImage = Self.cgImage(from: image) else { return }
    let language = self.language
    guard ImageHostingUploadHUD.shared.begin(language: language) else {
      showMessage(
        title: AppText.value("scImageHostingUploadFailed", language: language),
        message: ImageHostingError.uploadInProgress.localizedDescription(language: language)
      )
      return
    }
    let progressHandler = ImageHostingUploadHUD.makeProgressHandler(language: language)
    Task { @MainActor in
      do {
        let result = try await ImageHostingUploadCoordinator.upload(
          image: cgImage,
          onProgress: progressHandler
        )
        ImageHostingClipboard.copy(urls: [result.publicURL])
        ImageHostingUploadHUD.shared.succeed(url: result.publicURL, language: language)
      } catch {
        ImageHostingUploadHUD.shared.fail(error: error, language: language)
      }
    }
  }

  /// Annotate the pinned image in place: the pin window plays host to the
  /// annotation editor and swaps back to the pin surface when the edit ends.
  private func openAnnotation() {
    guard let image = state.image, let cgImage = Self.cgImage(from: image) else { return }
    let model = SmartAnnotationModel(initialTool: .rectangle)
    let editor = NSHostingView(rootView: SmartAnnotationEditor(
      image: cgImage,
      language: language,
      model: model,
      embedded: true,
      onCancel: { [weak self] in
        self?.restorePinContent()
      },
      onComplete: { [weak self] in
        guard let self,
              let annotated = SmartAnnotationRenderer.render(
                image: cgImage,
                annotations: model.annotations,
                styles: model.styledAnnotations.map(\.style)
              ) else { return }
        self.state.updateImage(NSImage(
          cgImage: annotated,
          size: NSSize(width: annotated.width, height: annotated.height)
        ))
        self.restorePinContent()
      }
    ))
    annotationHostView = editor
    window.contentView = editor
    window.makeKeyAndOrderFront(nil)
    window.updateMousePassthrough()
  }

  private func restorePinContent() {
    annotationHostView = nil
    window.contentView = hostingView(size: state.displaySize)
    window.makeKeyAndOrderFront(nil)
    window.updateMousePassthrough()
  }

  private func presentContextMenu(with event: NSEvent) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(menuItem("scCopy", action: #selector(copyRequested)))
    if state.image != nil {
      menu.addItem(menuItem("scOCR", action: #selector(ocrRequested)))
      menu.addItem(menuItem("scAnnotate", action: #selector(annotateRequested)))
      menu.addItem(menuItem("scImageHostingUpload", action: #selector(uploadRequested)))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("scClose", action: #selector(closeRequested)))
    guard let view = window.contentView else { return }
    NSMenu.popUpContextMenu(menu, with: event, for: view)
  }

  private func menuItem(_ key: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(
      title: AppText.value(key, language: language),
      action: action,
      keyEquivalent: ""
    )
    item.target = self
    return item
  }

  @objc private func copyRequested() { copyToPasteboard() }
  @objc private func ocrRequested() { recognizeText() }
  @objc private func annotateRequested() { openAnnotation() }
  @objc private func uploadRequested() { uploadImage() }
  @objc private func closeRequested() { handleUserClose() }

  private func showMessage(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = String(message.prefix(1_000))
    alert.addButton(withTitle: AppText.value("scOK", language: language))
    alert.runModal()
  }

  // MARK: - Geometry

  private static func frame(anchorRect: CGRect?, size: CGSize, on screen: NSScreen) -> NSRect {
    guard let anchorRect else {
      return QuickAccessPinWindowSizing.centeredFrame(size: size, on: screen)
    }
    let proposed = NSRect(
      x: anchorRect.midX - size.width / 2,
      y: anchorRect.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
    return QuickAccessPinWindowSizing.constrainedFrame(proposed, on: screen)
  }

  /// Text pins land next to the pointer (the Snipaste/iShot paste habit),
  /// clamped back inside the visible screen.
  private static func frame(near point: CGPoint, size: CGSize, on screen: NSScreen) -> NSRect {
    let proposed = NSRect(
      x: point.x + 8,
      y: point.y - size.height - 8,
      width: size.width,
      height: size.height
    )
    return QuickAccessPinWindowSizing.constrainedFrame(proposed, visibleFrame: screen.visibleFrame)
  }

  private func resize(to size: CGSize, animated: Bool) {
    let currentFrame = window.frame
    let center = zoomCenter ?? CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    let proposedFrame = NSRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let targetFrame = QuickAccessPinWindowSizing.constrainedFrame(proposedFrame, on: screen)
    window.setFrame(targetFrame, display: true, animate: animated)
    window.contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
    window.updateMousePassthrough()
  }

  private func handleZoomStep(_ step: CGFloat) {
    guard state.supportsZoom else { return }
    if zoomTimer == nil {
      targetZoomFactor = state.zoomFactor
      let currentFrame = window.frame
      zoomCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }
    syncSizingForCurrentScreen()
    let newTarget = targetZoomFactor + step
    targetZoomFactor = state.clampedZoomFactor(newTarget)
    startZoomAnimationLoop()
  }

  private func startZoomAnimationLoop() {
    guard zoomTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.tickZoomAnimation()
      }
    }
    zoomTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopZoomAnimationLoop() {
    zoomTimer?.invalidate()
    zoomTimer = nil
    zoomCenter = nil
  }

  private func tickZoomAnimation() {
    let diff = targetZoomFactor - state.zoomFactor
    if abs(diff) < 0.001 {
      state.updateZoomFactor(targetZoomFactor)
      stopZoomAnimationLoop()
    } else {
      state.updateZoomFactor(state.zoomFactor + diff * 0.2)
    }
    resize(to: state.displaySize, animated: false)
  }

  private func resizeForCurrentZoom(animated: Bool) {
    stopZoomAnimationLoop()
    targetZoomFactor = state.zoomFactor
    syncSizingForCurrentScreen()
    resize(to: state.displaySize, animated: animated)
  }

  private func syncSizingForCurrentScreen() {
    guard let image = state.image else { return }
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let sizes = QuickAccessPinWindowSizing.sizes(for: image.size, on: screen)
    _ = state.updateSizing(baseSize: sizes.base, maxSize: sizes.max)
  }

  // MARK: - Helpers

  private static func loadImage(for item: QuickAccessItem) -> NSImage {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
    defer { access.stop() }
    return NSImage(contentsOf: item.url) ?? item.thumbnail
  }

  private static func cgImage(from image: NSImage) -> CGImage? {
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }
}

@MainActor
private final class QuickAccessPinHostingView: NSHostingView<QuickAccessPinWindowView> {
  var onMagnify: ((CGFloat) -> Void)?

  private var lastMagnification: CGFloat = 0

  required init(rootView: QuickAccessPinWindowView) {
    super.init(rootView: rootView)
    setupGestureRecognizer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupGestureRecognizer()
  }

  private func setupGestureRecognizer() {
    let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnificationGesture(_:)))
    addGestureRecognizer(recognizer)
  }

  @objc private func handleMagnificationGesture(_ sender: NSMagnificationGestureRecognizer) {
    switch sender.state {
    case .began:
      lastMagnification = 0
    case .changed:
      let delta = sender.magnification - lastMagnification
      lastMagnification = sender.magnification
      onMagnify?(delta)
    case .ended, .cancelled:
      lastMagnification = 0
    default:
      break
    }
  }
}
