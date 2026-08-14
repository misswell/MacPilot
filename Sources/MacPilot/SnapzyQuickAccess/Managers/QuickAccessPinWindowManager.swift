//
//  QuickAccessPinWindowManager.swift
//  Snapzy
//
//  Manages independent always-on-top pinned screenshot windows.
//

import AppKit
import SwiftUI

@MainActor
final class QuickAccessPinWindowManager {
  static let shared = QuickAccessPinWindowManager()

  private var controllers: [UUID: QuickAccessPinWindowController] = [:]

  private init() {}

  @discardableResult
  func show(item: QuickAccessItem, onUserClose: @escaping (UUID) -> Void) -> Bool {
    guard !item.isVideo else { return false }

    if let controller = controllers[item.id] {
      controller.update(item: item)
      controller.orderFront()
      return true
    }

    let controller = QuickAccessPinWindowController(item: item)
    controller.onUserClose = { [weak self] id in
      self?.controllers[id] = nil
      onUserClose(id)
    }
    controllers[item.id] = controller
    controller.show()
    return true
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    controllers[item.id]?.update(item: item, imageOverride: imageOverride)
  }

  func close(id: UUID) {
    controllers.removeValue(forKey: id)?.close()
  }

  func closeAll() {
    for controller in controllers.values {
      controller.close()
    }
    controllers.removeAll()
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
}

@MainActor
private final class QuickAccessPinWindowController {
  var onUserClose: ((UUID) -> Void)?

  private let id: UUID
  private let state: QuickAccessPinWindowState
  private let window: QuickAccessPinWindow

  private var targetZoomFactor: CGFloat = 1
  private var zoomTimer: Timer?
  private var zoomCenter: CGPoint?

  init(item: QuickAccessItem) {
    id = item.id

    let image = Self.loadImage(for: item)
    let screen = ScreenUtility.activeScreen()
    let sizes = QuickAccessPinWindowSizing.sizes(for: image.size, on: screen)
    state = QuickAccessPinWindowState(
      id: item.id,
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
      baseSize: sizes.base,
      maxSize: sizes.max
    )

    let frame = QuickAccessPinWindowSizing.centeredFrame(size: state.displaySize, on: screen)
    window = QuickAccessPinWindow(contentRect: frame, state: state)
    window.contentView = hostingView(size: state.displaySize)
    window.onEscapeRequested = { [weak self] in
      self?.handleUserClose()
    }
    window.onZoomStepRequested = { [weak self] step in
      self?.handleZoomStep(step)
    }
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
    window.close()
  }

  func suspendMouseMonitors() {
    window.suspendMouseMonitors()
  }

  func resumeMouseMonitors() {
    window.resumeMouseMonitors()
  }

  private func hostingView(size: CGSize) -> QuickAccessPinHostingView {
    let view = QuickAccessPinWindowView(
      state: state,
      onClose: { [weak self] in
        self?.handleUserClose()
      },
      onZoomSizeChange: { [weak self] _ in
        self?.resizeForCurrentZoom(animated: true)
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
    self.close()
    self.onUserClose?(self.id)
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
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let sizes = QuickAccessPinWindowSizing.sizes(for: state.image.size, on: screen)
    _ = state.updateSizing(baseSize: sizes.base, maxSize: sizes.max)
  }

  private static func loadImage(for item: QuickAccessItem) -> NSImage {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
    defer { access.stop() }
    return NSImage(contentsOf: item.url) ?? item.thumbnail
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
