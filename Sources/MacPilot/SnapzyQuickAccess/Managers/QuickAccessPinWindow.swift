//
//  QuickAccessPinWindow.swift
//  Snapzy
//
//  Borderless pin window with lock-mode mouse passthrough.
//

import AppKit

@MainActor
final class QuickAccessPinWindow: NSPanel {
  private static let pinnedWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
  internal static let scrollZoomSensitivityPrecise: CGFloat = 0.0015
  internal static let scrollZoomSensitivityCoarse: CGFloat = 0.02
  internal static let magnificationZoomSensitivity: CGFloat = 0.2

  var onEscapeRequested: (() -> Void)?
  var onZoomStepRequested: ((CGFloat) -> Void)?

  private weak var pinState: QuickAccessPinWindowState?
  private var localMouseMonitor: Any?
  private var globalMouseMonitor: Any?
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?

  init(contentRect: NSRect, state: QuickAccessPinWindowState) {
    pinState = state
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configure()
    installMouseMonitors()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    if handleEscapeIfNeeded(event) {
      return
    }

    super.keyDown(with: event)
  }

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .scrollWheel where handleScrollZoomIfNeeded(event):
      return
    default:
      super.sendEvent(event)
    }
  }

  private var isMouseMonitorsSuspended = false

  override func close() {
    if !isMouseMonitorsSuspended {
      removeMouseMonitorsOnly()
    }
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
      self.globalKeyMonitor = nil
    }
    isMouseMonitorsSuspended = false
    super.close()
  }

  func updateMousePassthrough() {
    guard let pinState else {
      ignoresMouseEvents = false
      return
    }

    let mouseLocation = NSEvent.mouseLocation
    let isInside = frame.contains(mouseLocation)
    pinState.isMouseInside = isInside

    guard pinState.isLocked else {
      ignoresMouseEvents = false
      if isInside {
        if !isKeyWindow {
          makeKey()
        }
      } else {
        if isKeyWindow {
          if let otherWindow = NSApp.windows.first(where: { $0 != self && $0.canBecomeKey && $0.isVisible }) {
            otherWindow.makeKey()
          }
        }
      }
      return
    }

    ignoresMouseEvents = isInside && !lockButtonScreenRect.contains(mouseLocation)
  }

  private func configure() {
    isFloatingPanel = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = false
    applyCornerRadius()
    level = Self.pinnedWindowLevel
    becomesKeyOnlyIfNeeded = false
  }

  private var lockButtonScreenRect: NSRect {
    NSRect(x: frame.maxX - 48, y: frame.maxY - 48, width: 48, height: 48)
  }

  private func installMouseMonitors() {
    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    if localMouseMonitor == nil {
      localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
        MainActor.assumeIsolated {
          self?.updateMousePassthrough()
        }
        return event
      }
    }

    if globalMouseMonitor == nil {
      globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
        Task { @MainActor in
          self?.updateMousePassthrough()
        }
      }
    }

    if localKeyMonitor == nil {
      localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let didHandle = MainActor.assumeIsolated {
          self?.handleEscapeIfNeeded(event) ?? false
        }
        return didHandle ? nil : event
      }
    }

    if globalKeyMonitor == nil {
      globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        Task { @MainActor in
          _ = self?.handleEscapeIfNeeded(event)
        }
      }
    }
  }

  private func removeEventMonitors() {
    removeMouseMonitorsOnly()
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
      self.globalKeyMonitor = nil
    }
  }

  private func removeMouseMonitorsOnly() {
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
      self.localMouseMonitor = nil
    }
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
  }

  func suspendMouseMonitors() {
    guard !isMouseMonitorsSuspended else { return }
    isMouseMonitorsSuspended = true
    removeMouseMonitorsOnly()
  }

  func resumeMouseMonitors() {
    guard isMouseMonitorsSuspended else { return }
    isMouseMonitorsSuspended = false
    installMouseMonitors()
  }

  private func handleEscapeIfNeeded(_ event: NSEvent) -> Bool {
    guard event.keyCode == 53 else { return false }
    guard let pinState, !pinState.isLocked else { return false }
    guard isKeyWindow || frame.contains(NSEvent.mouseLocation) else { return false }

    onEscapeRequested?()
    return true
  }

  private func handleScrollZoomIfNeeded(_ event: NSEvent) -> Bool {
    guard let step = Self.scrollZoomStep(
      scrollingDeltaX: event.scrollingDeltaX,
      scrollingDeltaY: event.scrollingDeltaY,
      hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
      isLocked: pinState?.isLocked == true
    ), let onZoomStepRequested else { return false }

    onZoomStepRequested(step)
    return true
  }


  @discardableResult
  func requestMagnifyZoom(magnification: CGFloat) -> Bool {
    guard let step = Self.magnifyZoomStep(
      magnification: magnification,
      isLocked: pinState?.isLocked == true
    ), let onZoomStepRequested else { return false }

    onZoomStepRequested(step)
    return true
  }

  static func scrollZoomStep(
    scrollingDeltaX deltaX: CGFloat = 0,
    scrollingDeltaY deltaY: CGFloat,
    hasPreciseScrollingDeltas: Bool,
    isLocked: Bool
  ) -> CGFloat? {
    guard !isLocked else { return nil }

    let magnitude = sqrt(deltaX * deltaX + deltaY * deltaY)
    guard magnitude.isFinite, magnitude != 0 else { return nil }

    let sign: CGFloat
    if deltaY != 0 {
      sign = deltaY > 0 ? 1.0 : -1.0
    } else {
      sign = deltaX > 0 ? 1.0 : -1.0
    }

    let combinedDelta = magnitude * sign
    let sensitivity = hasPreciseScrollingDeltas ? scrollZoomSensitivityPrecise : scrollZoomSensitivityCoarse
    return combinedDelta * sensitivity
  }

  static func magnifyZoomStep(magnification: CGFloat, isLocked: Bool) -> CGFloat? {
    guard !isLocked,
          magnification.isFinite,
          magnification != 0 else { return nil }
    return magnification * magnificationZoomSensitivity
  }
}
