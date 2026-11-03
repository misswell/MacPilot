//
//  QuickAccessPinWindow.swift
//  Snapzy
//
//  Borderless pin window with lock-mode mouse passthrough.
//

import AppKit

@MainActor
final class QuickAccessPinWindow: NSPanel, QuickAccessPinMouseTracking {
  private static let pinnedWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
  internal static let scrollZoomSensitivityPrecise: CGFloat = 0.0015
  internal static let scrollZoomSensitivityCoarse: CGFloat = 0.02
  internal static let magnificationZoomSensitivity: CGFloat = 0.2

  var onEscapeRequested: (() -> Void)?
  var onZoomStepRequested: ((CGFloat) -> Void)?

  private weak var pinState: QuickAccessPinWindowState?
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  /// Hover state carried between pointer events, because the verdict about
  /// another application's window covering the pin costs a window-server sweep
  /// and must not be re-asked on every mouse-move.
  private var lastPointerWasInsideFrame = false
  private var hoverIsCovered = false
  private var lastHoverSweepAt: Date?

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
    updateMousePassthrough(at: NSEvent.mouseLocation, now: Date())
  }

  func updateMousePassthrough(at mouseLocation: CGPoint, now: Date) {
    guard let pinState else {
      ignoresMouseEvents = false
      return
    }

    let isGeometricallyInside = frame.contains(mouseLocation)
    let didCrossIntoFrame = isGeometricallyInside && !lastPointerWasInsideFrame
    lastPointerWasInsideFrame = isGeometricallyInside

    guard let ownWindowID = CGWindowID.identifiable(windowNumber) else {
      // An unordered window has no identity to sweep against; leave hover off
      // rather than trap on the conversion.
      hoverIsCovered = false
      return
    }

    if QuickAccessPinHoverCoverage.sweepIsWorthRunning(
      pointerIsInsideFrame: isGeometricallyInside,
      didCrossIntoFrame: didCrossIntoFrame,
      isKeyWindow: isKeyWindow,
      hoverIsSuppressed: hoverIsCovered,
      lastSweepAt: lastHoverSweepAt,
      now: now
    ) {
      lastHoverSweepAt = now
      hoverIsCovered = !QuickAccessPinHoverCoverage.isPinExposed(
        at: mouseLocation,
        pinWindowNumber: ownWindowID,
        surfaces: QuickAccessPinHoverCoverage.liveSurfaces()
      )
    }

    // The hover answers to the window the pointer is actually on.  A dropdown
    // that hangs over the pin therefore costs the pin nothing: no chrome and,
    // above all, no key window — taking key status is what used to close the
    // other application's popup out from under the user.
    let isInside = isGeometricallyInside && !hoverIsCovered
    pinState.updateMouseInside(isInside)

    guard pinState.isLocked else {
      if pinState.isPointerInLockHotspot {
        pinState.isPointerInLockHotspot = false
      }
      ignoresMouseEvents = false
      if isInside {
        if !isKeyWindow {
          makeKey()
        }
      } else if !isGeometricallyInside, isKeyWindow {
        // Only a pointer that really left hands key status away.  While the pin
        // is merely covered, another focus change would be the same mistake in
        // the other direction, so the pin just waits.
        if let otherWindow = NSApp.windows.first(where: { $0 != self && $0.canBecomeKey && $0.isVisible }) {
          otherWindow.makeKey()
        }
      }
      return
    }

    let isInsideLockHotspot = lockHotspotScreenRect.contains(mouseLocation)
    // Assigned only when it actually changes: this runs on every mouse-move,
    // and a published write would redraw the pin for no visible reason.
    if pinState.isPointerInLockHotspot != isInsideLockHotspot {
      pinState.isPointerInLockHotspot = isInsideLockHotspot
    }
    // A locked pin never takes key status and never shows hover chrome, so a
    // cover costs nothing here — and its passthrough has to stay geometric, or
    // a click through a transparent surface above would stop reaching the pin.
    ignoresMouseEvents = isGeometricallyInside && !isInsideLockHotspot
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

  /// The one square of a locked pin that still takes the mouse.  It is larger
  /// than the unlock control drawn inside it so the control is reachable by
  /// feel; the token keeps this and the drawn chrome in agreement.
  private var lockHotspotScreenRect: NSRect {
    let side = PinnedScreenshotChromeStyle.lockHotspotSide
    return NSRect(x: frame.maxX - side, y: frame.maxY - side, width: side, height: side)
  }

  private func installMouseMonitors() {
    QuickAccessPinMouseMonitor.shared.add(self)

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
    QuickAccessPinMouseMonitor.shared.remove(self)
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
