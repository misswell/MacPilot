//
//  AreaSelectionWindow.swift
//  Migrated from Snapzy/Services/Capture/AreaSelectionWindow.swift (window and overlay source).
//
import AppKit
import Foundation
import QuartzCore
@MainActor
protocol AreaSelectionWindowDelegate: AnyObject {
  func areaSelectionWindow(_ window: AreaSelectionWindow, didSelectRect rect: CGRect)
  func areaSelectionWindow(_ window: AreaSelectionWindow, didSelectWindow target: WindowCaptureTarget)
  func areaSelectionWindowDidCancel(_ window: AreaSelectionWindow)
  func areaSelectionWindowDidBecomeActive(_ window: AreaSelectionWindow)
  func areaSelectionWindow(_ window: AreaSelectionWindow, didReceiveKeyEvent event: NSEvent) -> Bool
  func areaSelectionWindowDidRequestDisplayActivation(_ window: AreaSelectionWindow)
  /// User pressed inside the overlay before the per-display backdrop snapshot arrived. The
  /// controller should enable live-fallback selection for the window's display so the click
  /// is not dropped if the user releases before the snapshot completes.
  func areaSelectionWindowDidRequestImmediateManualSelection(_ window: AreaSelectionWindow)
  func areaSelectionWindow(_ window: AreaSelectionWindow, manualSelectionBeganAt screenPoint: CGPoint)
  func areaSelectionWindow(_ window: AreaSelectionWindow, manualSelectionChangedTo screenPoint: CGPoint)
  func areaSelectionWindow(_ window: AreaSelectionWindow, manualSelectionEndedAt screenPoint: CGPoint)
}

// MARK: - AreaSelectionWindow

/// Full-screen overlay panel for area selection
/// Uses NSPanel with .nonactivatingPanel to prevent background windows from deactivating/blurring
/// Supports pooled mode for instant activation
@MainActor
final class AreaSelectionWindow: NSPanel {
  weak var selectionDelegate: AreaSelectionWindowDelegate?

  let overlayView: AreaSelectionOverlayView
  private let targetScreen: NSScreen
  private var receivesKeyboardInput = false

  /// Initialize window for a screen
  /// - Parameters:
  ///   - screen: The screen this window covers
  ///   - pooled: If true, window starts hidden for pool pre-allocation
  init(screen: NSScreen, pooled: Bool = false) {
    targetScreen = screen
    overlayView = AreaSelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))

    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    // Configure as non-activating panel to prevent background windows from blurring
    isFloatingPanel = true
    isOpaque = false
    backgroundColor = NSColor(white: 0, alpha: 0.005)
    sharingType = .none
    level = .screenSaver
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
    isReleasedWhenClosed = false
    hasShadow = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    animationBehavior = .none // Disable window animations for instant appearance
    becomesKeyOnlyIfNeeded = true

    // Lock window movement and resizing
    isMovable = false
    isMovableByWindowBackground = false
    minSize = screen.frame.size
    maxSize = screen.frame.size

    // Set up content view
    contentView = overlayView
    overlayView.delegate = self
    overlayView.keyEventHandler = { [weak self] event in
      guard let self else { return false }
      return selectionDelegate?.areaSelectionWindow(self, didReceiveKeyEvent: event) ?? false
    }

    // Hide the panel from Accessibility so VoiceOver / assistive tech ignore
    // the overlay chrome (kept as hygiene for any future AX-aware capture work).
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
    setAccessibilityRole(.unknown)

    if pooled {
      // Pooled windows start hidden
      orderOut(nil)
    } else {
      // Non-pooled windows show immediately without stealing focus
      orderFrontRegardless()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateSelectionMode(_ mode: SelectionMode) {
    overlayView.selectionMode = mode
  }

  /// Switch between window-event input (default) and live-passthrough input.
  /// Passthrough makes the panel hit-transparent (clear background — fully transparent
  /// pixels are not hit-testable). This is REQUIRED for hover persistence: any hittable
  /// window under the pointer steals pointer ownership from the app beneath, which
  /// synthesizes tracking-exit and dismisses its visible hover UI. Interaction freeze
  /// comes from the event tap consuming every mouse event before delivery; if the tap
  /// is ever disabled by the system, events hit this panel whose handlers are inert in
  /// passthrough mode — the apps beneath never see them either way. The system cursor
  /// is hidden (`CGDisplayHideCursor`, unlocked from this background agent by
  /// `BackgroundCursorControl`) and the crosshair is rendered by the drawn proxy layer,
  /// never by cursor rects — cursor rects would require this panel to be hittable.
  func setLivePassthroughInputEnabled(_ enabled: Bool) {
    ignoresMouseEvents = enabled
    acceptsMouseMovedEvents = !enabled
    backgroundColor = enabled ? .clear : NSColor(white: 0, alpha: 0.005)
    overlayView.setLivePassthroughInputEnabled(enabled)
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
    minSize = frameRect.size
    maxSize = frameRect.size
    super.setFrame(frameRect, display: displayFlag)
  }

  func setReceivesKeyboardInput(_ receivesKeyboardInput: Bool) {
    self.receivesKeyboardInput = receivesKeyboardInput
  }

  func activateKeyboardInputIfNeeded() {
    guard receivesKeyboardInput else { return }
    makeKey()
    makeFirstResponder(overlayView)
  }

  var displayID: CGDirectDisplayID? {
    targetScreen.displayID
  }

  // Non-activating: prevent stealing focus from other apps
  override var canBecomeKey: Bool {
    receivesKeyboardInput
  }

  override var canBecomeMain: Bool {
    false
  }
}

// MARK: - AreaSelectionOverlayViewDelegate

extension AreaSelectionWindow: AreaSelectionOverlayViewDelegate {
  func overlayView(_: AreaSelectionOverlayView, didSelectRect rect: CGRect) {
    // Convert from view coordinates to screen coordinates
    let screenRect = convertToScreenCoordinates(rect)
    selectionDelegate?.areaSelectionWindow(self, didSelectRect: screenRect)
  }

  func overlayView(_: AreaSelectionOverlayView, didSelectWindow target: WindowCaptureTarget) {
    selectionDelegate?.areaSelectionWindow(self, didSelectWindow: target)
  }

  func overlayViewDidCancel(_: AreaSelectionOverlayView) {
    selectionDelegate?.areaSelectionWindowDidCancel(self)
  }

  func overlayViewDidRequestDisplayActivation(_: AreaSelectionOverlayView) {
    selectionDelegate?.areaSelectionWindowDidRequestDisplayActivation(self)
  }

  func overlayViewDidRequestImmediateManualSelection(_: AreaSelectionOverlayView) {
    selectionDelegate?.areaSelectionWindowDidRequestImmediateManualSelection(self)
  }

  func overlayView(_: AreaSelectionOverlayView, manualSelectionBeganAt point: CGPoint) {
    selectionDelegate?.areaSelectionWindow(self, manualSelectionBeganAt: convertToScreenPoint(point))
  }

  func overlayView(_: AreaSelectionOverlayView, manualSelectionChangedTo point: CGPoint) {
    selectionDelegate?.areaSelectionWindow(self, manualSelectionChangedTo: convertToScreenPoint(point))
  }

  func overlayView(_: AreaSelectionOverlayView, manualSelectionEndedAt point: CGPoint) {
    selectionDelegate?.areaSelectionWindow(self, manualSelectionEndedAt: convertToScreenPoint(point))
  }

  private func convertToScreenCoordinates(_ rect: CGRect) -> CGRect {
    // The rect is in window coordinates (bottom-left origin)
    // Convert to global screen coordinates (also bottom-left origin)
    let windowFrame = frame

    return CGRect(
      x: windowFrame.origin.x + rect.origin.x,
      y: windowFrame.origin.y + rect.origin.y,
      width: rect.width,
      height: rect.height
    )
  }

  private func convertToScreenPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: frame.origin.x + point.x,
      y: frame.origin.y + point.y
    )
  }
}

// MARK: - AreaSelectionOverlayViewDelegate Protocol

@MainActor
protocol AreaSelectionOverlayViewDelegate: AnyObject {
  func overlayView(_ view: AreaSelectionOverlayView, didSelectRect rect: CGRect)
  func overlayView(_ view: AreaSelectionOverlayView, didSelectWindow target: WindowCaptureTarget)
  func overlayViewDidCancel(_ view: AreaSelectionOverlayView)
  func overlayViewDidRequestDisplayActivation(_ view: AreaSelectionOverlayView)
  /// Signals that the user pressed inside the overlay before the per-display backdrop snapshot
  /// was ready. The controller should enable live-fallback selection for the overlay's display
  /// so the click is not silently dropped.
  func overlayViewDidRequestImmediateManualSelection(_ view: AreaSelectionOverlayView)
  func overlayView(_ view: AreaSelectionOverlayView, manualSelectionBeganAt point: CGPoint)
  func overlayView(_ view: AreaSelectionOverlayView, manualSelectionChangedTo point: CGPoint)
  func overlayView(_ view: AreaSelectionOverlayView, manualSelectionEndedAt point: CGPoint)
}

// MARK: - AreaSelectionOverlayView

/// The view that handles drawing and mouse interaction
/// Uses CALayer-based rendering for 60fps crosshair movement (Phase 2 optimization)
@MainActor
final class AreaSelectionOverlayView: NSView {
  weak var delegate: AreaSelectionOverlayViewDelegate?
  var keyEventHandler: ((NSEvent) -> Bool)?
  var selectionMode: SelectionMode = .screenshot {
    didSet {
      needsDisplay = true
    }
  }

  private var interactionMode: AreaSelectionInteractionMode = .manualRegion
  private var allowsApplicationWindowSelection = false

  // MARK: - Selection State

  private var isSelecting = false
  /// True while a non-empty selection rect is on screen (drag in progress with visible area).
  /// The coordinate label stays visible until this flips true, then the dimensions label
  /// owns the size indicator layers — mirroring native macOS / CleanShot X behavior.
  private var hasVisibleSelectionRect = false
  private var pendingSelectionStartPoint: CGPoint?
  private var currentMousePosition: CGPoint = .zero
  private var windowSelectionSnapshot: WindowSelectionSnapshot?
  private var hoveredWindowCandidate: WindowSelectionCandidate?
  private var retainedMenuBarPopoverCaptures: [CGWindowID: ImmediateMenuBarPopoverCapture] = [:]
  private var retainedMenuBarPopoverWindowIDsStillOnScreen = Set<CGWindowID>()

  // MARK: - CALayer-based Rendering (Phase 2 Optimization)

  private var snapshotLayer: CALayer!
  private var retainedMenuBarPopoverLayers: [CGWindowID: CALayer] = [:]
  var dimLayer: CALayer!
  var insideSelectionOverlayLayer: CAShapeLayer!
  private var showSelectionAreaOverlay = true
  private var backdropPixelDataArray: [UInt8]?
  private var backdropWidth = 0
  private var backdropHeight = 0
  private var backdropScale: CGFloat = 1.0
  private var insideOverlayIsDark = true
  /// Throttles the "no luma pixel data" warning to once per selection (see `updateInsideOverlayAppearance`).
  private var didLogMissingLumaData = false

  // MARK: - Magnifying Glass Zoom (Pixel-level zoom)

  private let magnifier = AreaSelectionMagnifier()
  private var currentBackdropImage: CGImage?

  private lazy var reusableDimMaskLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.fillRule = .evenOdd
    return layer
  }()

  private var reusableCrosshairPath = CGMutablePath()
  private var horizontalCrosshairLayer: CAShapeLayer!
  private var verticalCrosshairLayer: CAShapeLayer!
  private var selectionBorderLayer: CAShapeLayer!
  private var crosshairIndicatorLayer: CAShapeLayer!
  /// Drawn replacement for the system cursor in live-passthrough sessions (the legacy
  /// cursor image is drawn at the pointer — pixel-parity with the window-event path's
  /// `NSCursor`; the system cursor itself stays where it is, since no public API can
  /// hide it from a background agent — see `LivePassthroughCursorHider`).
  private var cursorProxyLayer: CALayer!
  /// Source image currently assigned to `cursorProxyLayer.contents`. Assigning an
  /// NSImage forces Core Animation to re-render it into a texture, so the per-tick
  /// hover update only re-assigns when the cursor image actually changes (identity)
  /// and otherwise moves the layer via `frame` alone.
  private var cursorProxySourceImage: NSImage?
  private var sizeIndicatorBackgroundLayer: CALayer!
  private var sizeIndicatorTextLayer: CATextLayer!
  private var lastSizeIndicatorText: String?
  private var lastSizeIndicatorTextSize: CGSize = .zero
  private var modeHintBackgroundLayer: CALayer!
  private var modeHintTextLayer: CATextLayer!

  // Appearance constants
  private let dimColor = NSColor.black.withAlphaComponent(0.4)
  private let crosshairColor = NSColor.white.withAlphaComponent(0.6)
  private let selectionBorderColor = NSColor.white
  private let selectionBorderWidth: CGFloat = 2.0
  private let crosshairIndicatorSize: CGFloat = 10.0
  private let crosshairIndicatorLineWidth: CGFloat = 1.5
  private let crosshairIndicatorCenterRadius: CGFloat = 6.0
  private let overlayFont = NSFont.systemFont(ofSize: 12, weight: .medium)
  private var selectionEnabled = true
  /// Live-passthrough sessions drive the selection gesture from the capture event tap;
  /// the view's own mouse handlers stay inert (the panel gets no events anyway). The dim
  /// layer starts hidden here; the controller drives its visibility afterwards via
  /// `setLivePassthroughDimHidden(_:)`.
  private var isLivePassthroughInput = false
  /// Set once the event tap has delivered a real pointer position. While a passthrough
  /// session runs, the tap consumes every mouse move, so `NSEvent.mouseLocation` stays
  /// frozen at the session-start position — code that needs the pointer must read the
  /// tap-tracked `currentMousePosition` instead of the stale system location.
  private var hasLivePassthroughPointerPosition = false

  /// Disabled animations for instant layer updates
  private var disabledActions: [String: CAAction] {
    [
      "position": NSNull(),
      "bounds": NSNull(),
      "path": NSNull(),
      "hidden": NSNull(),
      "opacity": NSNull(),
      "backgroundColor": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "contentsScale": NSNull(),
    ]
  }

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    setupLayers()
    setupTrackingArea()
    configureAccessibilityInvisibility()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    setupLayers()
    setupTrackingArea()
    configureAccessibilityInvisibility()
  }

  private func configureAccessibilityInvisibility() {
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
    setAccessibilityRole(.unknown)
  }

  // MARK: - Layer Setup

  private func setupLayers() {
    guard let rootLayer = layer else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    snapshotLayer = CALayer()
    snapshotLayer.frame = bounds
    snapshotLayer.contentsGravity = .resize
    snapshotLayer.actions = disabledActions
    snapshotLayer.isHidden = true
    rootLayer.addSublayer(snapshotLayer)

    // Local retained popover images sit above any full-display backdrop but below the dim
    // layer, so the existing application-window cutout makes them look like live content.
    // They remain absent while the matching WindowServer window is still on screen.

    // Dim overlay layer (full screen semi-transparent)
    dimLayer = CALayer()
    dimLayer.backgroundColor = dimColor.cgColor
    dimLayer.frame = bounds
    dimLayer.actions = disabledActions
    rootLayer.addSublayer(dimLayer)

    // Inside selection dark overlay layer (when backdrop overlay is disabled)
    insideSelectionOverlayLayer = CAShapeLayer()
    insideSelectionOverlayLayer.fillColor = NSColor.black.withAlphaComponent(0.12).cgColor
    insideSelectionOverlayLayer.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
    insideSelectionOverlayLayer.lineWidth = 4.0
    insideSelectionOverlayLayer.isHidden = true
    insideSelectionOverlayLayer.actions = disabledActions
    rootLayer.addSublayer(insideSelectionOverlayLayer)

    // Horizontal crosshair line (hidden - using compact indicator instead)
    horizontalCrosshairLayer = CAShapeLayer()
    horizontalCrosshairLayer.strokeColor = crosshairColor.cgColor
    horizontalCrosshairLayer.lineWidth = 1.0
    horizontalCrosshairLayer.isHidden = true
    horizontalCrosshairLayer.actions = disabledActions
    rootLayer.addSublayer(horizontalCrosshairLayer)

    // Vertical crosshair line (hidden - using compact indicator instead)
    verticalCrosshairLayer = CAShapeLayer()
    verticalCrosshairLayer.strokeColor = crosshairColor.cgColor
    verticalCrosshairLayer.lineWidth = 1.0
    verticalCrosshairLayer.isHidden = true
    verticalCrosshairLayer.actions = disabledActions
    rootLayer.addSublayer(verticalCrosshairLayer)

    // Selection border layer
    selectionBorderLayer = CAShapeLayer()
    selectionBorderLayer.strokeColor = selectionBorderColor.cgColor
    selectionBorderLayer.fillColor = nil
    selectionBorderLayer.lineWidth = selectionBorderWidth
    selectionBorderLayer.isHidden = true
    selectionBorderLayer.actions = disabledActions
    rootLayer.addSublayer(selectionBorderLayer)

    // Crosshair indicator at mouse position (like CleanShot X)
    crosshairIndicatorLayer = CAShapeLayer()
    crosshairIndicatorLayer.strokeColor = NSColor.white.cgColor
    crosshairIndicatorLayer.fillColor = nil
    crosshairIndicatorLayer.lineWidth = crosshairIndicatorLineWidth
    crosshairIndicatorLayer.lineCap = .round
    crosshairIndicatorLayer.actions = disabledActions
    configureShadow(
      for: crosshairIndicatorLayer,
      color: .black,
      offset: .zero,
      radius: 2,
      opacity: 0.5
    )
    rootLayer.addSublayer(crosshairIndicatorLayer)

    // Drawn cursor proxy (live passthrough only; see `updateCursorProxy`). Starts hidden;
    // positioned at the pointer on every hover/drag update.
    cursorProxyLayer = CALayer()
    cursorProxyLayer.actions = disabledActions
    cursorProxyLayer.isHidden = true
    rootLayer.addSublayer(cursorProxyLayer)

    sizeIndicatorBackgroundLayer = CALayer()
    sizeIndicatorBackgroundLayer.backgroundColor = CoordinateBubbleStyle.backgroundColor.cgColor
    sizeIndicatorBackgroundLayer.cornerRadius = CoordinateBubbleStyle.cornerRadius
    sizeIndicatorBackgroundLayer.actions = disabledActions
    sizeIndicatorBackgroundLayer.isHidden = true
    // The magnifier's own layers are added lazily, well after this one, and would otherwise
    // stack on top of (and fully hide) this indicator whenever the two overlap on screen —
    // easy to hit, since the magnifier grew considerably and now near screen edges/corners
    // (exactly where users lean on this indicator most) it can flip to the same side as this
    // label. Pin both indicator layers above the magnifier's default z-position (0).
    sizeIndicatorBackgroundLayer.zPosition = 10
    rootLayer.addSublayer(sizeIndicatorBackgroundLayer)

    sizeIndicatorTextLayer = CATextLayer()
    configureOverlayTextLayer(sizeIndicatorTextLayer)
    sizeIndicatorTextLayer.font = coordinateIndicatorFont as CTFont
    sizeIndicatorTextLayer.fontSize = coordinateIndicatorFont.pointSize
    sizeIndicatorTextLayer.foregroundColor = CoordinateBubbleStyle.textColor.cgColor
    configureShadow(
      for: sizeIndicatorTextLayer,
      color: CoordinateBubbleStyle.shadowColor,
      offset: CoordinateBubbleStyle.shadowOffset,
      radius: CoordinateBubbleStyle.shadowRadius,
      opacity: CoordinateBubbleStyle.shadowOpacity
    )
    sizeIndicatorTextLayer.zPosition = 10
    rootLayer.addSublayer(sizeIndicatorTextLayer)

    modeHintBackgroundLayer = CALayer()
    modeHintBackgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
    modeHintBackgroundLayer.cornerRadius = 8
    modeHintBackgroundLayer.actions = disabledActions
    modeHintBackgroundLayer.isHidden = true
    rootLayer.addSublayer(modeHintBackgroundLayer)

    modeHintTextLayer = CATextLayer()
    configureOverlayTextLayer(modeHintTextLayer)
    rootLayer.addSublayer(modeHintTextLayer)

    CATransaction.commit()
  }

  // MARK: - Tracking Area

  private func setupTrackingArea() {
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
  }

  // MARK: - Cursor

  override func cursorUpdate(with _: NSEvent) {
    guard !isLivePassthroughInput else { return }
    applyActiveCursor()
  }

  override func mouseEntered(with event: NSEvent) {
    guard !isLivePassthroughInput else { return }
    delegate?.overlayViewDidRequestDisplayActivation(self)
    applyActiveCursor()
    let point = convert(event.locationInWindow, from: nil)
    currentMousePosition = point
    updateCoordinateIndicator(at: point)
    if selectionEnabled, interactionMode == .manualRegion, !isSelecting {
      updateCrosshairLayers()
      updateMagnifier(at: point)
    }
  }

  override func mouseExited(with _: NSEvent) {
    guard !isLivePassthroughInput else { return }
    NSCursor.arrow.set()
    hideSizeIndicator()
    hideMagnifier()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: activeCursor)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    setupTrackingArea()
  }

  private func refreshActiveCursor() {
    window?.invalidateCursorRects(for: self)
    applyActiveCursor()
  }

  func refreshCursor() {
    refreshActiveCursor()
    initializeCrosshairAtCurrentMousePosition()
    updateCoordinateIndicator(at: currentMousePosition)
  }

  /// Re-assert the crosshair while a manual drag is in progress. On a nonactivating panel the
  /// system can reset the cursor to the default arrow mid-drag (e.g. a background screen-composition
  /// capture); the panel never becomes key, so AppKit's cursor-rect machinery does not self-heal it.
  /// The selection drag monitors call this on every drag update to keep the crosshair sticky.
  func reassertCursorDuringDrag() {
    guard isManualSelectionInProgress else { return }
    applyActiveCursor()
  }

  /// Effect seam for the real-cursor set in `applyActiveCursor()` — production applies
  /// the cursor to the system, tests record it. Mirrors the injectable-effect pattern
  /// of `LivePassthroughCursorHider` / `BackgroundCursorControl`.
  var cursorSetEffect: (NSCursor) -> Void = { $0.set() }

  /// Apply the mode's cursor image to the *real* system cursor — but never during live
  /// passthrough. There the real cursor is hidden and the crosshair is drawn by
  /// `cursorProxyLayer`, so setting the real cursor is pointless; and now that
  /// `BackgroundCursorControl` makes background cursor changes stick, doing so would leak
  /// the crosshair image onto the system cursor after the session ends (e.g. onto the Quick
  /// Access card). The window-event fallback path still sets the cursor normally.
  ///
  /// Also never while the overlay is off screen: its `.activeAlways` + `.mouseMoved`
  /// tracking area keeps delivering `mouseMoved`/`cursorUpdate` to this view after the
  /// session ends and the window is ordered out (`isVisible == false`), and the passthrough
  /// flag is already cleared by `resetPooledWindows()` at that point — so without this
  /// guard every stray event re-applies the crosshair and leaks it onto whatever the
  /// pointer hovers next (observed over the Quick Access card).
  private func applyActiveCursor() {
    guard !isLivePassthroughInput else { return }
    guard window?.isVisible ?? true else { return }
    cursorSetEffect(activeCursor)
  }

  // MARK: - Public Methods

  /// Reset selection state for window pool reuse
  func resetSelection() {
    isSelecting = false
    hasVisibleSelectionRect = false
    pendingSelectionStartPoint = nil
    hoveredWindowCandidate = nil

    // Initialize crosshair at current mouse position immediately
    if selectionEnabled {
      initializeCrosshairAtCurrentMousePosition()
    } else {
      currentMousePosition = .zero
    }

    // Rebuild tracking areas for current bounds (prevents stale hit-testing)
    updateTrackingAreas()

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Keep crosshair layers hidden (using indicator instead)
    horizontalCrosshairLayer.isHidden = true
    verticalCrosshairLayer.isHidden = true
    selectionBorderLayer.isHidden = true
    crosshairIndicatorLayer.isHidden = true
    cursorProxyLayer.isHidden = true
    updateCoordinateIndicator(at: currentMousePosition)
    showSelectionAreaOverlay = UserDefaults.standard
      .object(forKey: PreferencesKeys.screenshotShowSelectionAreaOverlay) as? Bool ?? true
    magnifier.reverseZoomDirection = UserDefaults.standard
      .object(forKey: PreferencesKeys.screenshotReverseMagnifierZoomDirection) as? Bool ?? false
    dimLayer.backgroundColor = showSelectionAreaOverlay ? dimColor.cgColor : nil
    dimLayer.mask = nil
    dimLayer.frame = bounds
    insideSelectionOverlayLayer.isHidden = true
    insideOverlayIsDark = true
    didLogMissingLumaData = false

    CATransaction.commit()
    refreshCursor()

    // Update interaction state immediately
    if selectionEnabled {
      refreshInteractionState()
      refreshActiveCursor()
    }

    updateModeHint()
  }

  /// Switch between window-event input (default) and live-passthrough input.
  /// In passthrough mode the dim layer starts hidden — the controller drives its
  /// visibility afterwards via `setLivePassthroughDimHidden(_:)`.
  func setLivePassthroughInputEnabled(_ enabled: Bool) {
    isLivePassthroughInput = enabled
    dimLayer.isHidden = enabled
    if !enabled {
      hasLivePassthroughPointerPosition = false
      hideCursorProxy()
    }
  }

  /// Set dim layer visibility in a live-passthrough session. Driven by the controller's
  /// `updateLivePassthroughDimVisibility()` — in manual mode visible from session start when
  /// the selection-area-overlay preference is on (otherwise revealed by the first drag),
  /// always visible in window-selection mode (mirroring the legacy window-event appearance).
  /// No-op outside passthrough mode.
  func setLivePassthroughDimHidden(_ hidden: Bool) {
    guard isLivePassthroughInput else { return }
    dimLayer.isHidden = hidden
  }

  func setSelectionEnabled(_ enabled: Bool) {
    let wasSelectionEnabled = selectionEnabled
    selectionEnabled = enabled
    if enabled, !wasSelectionEnabled {
      initializeCrosshairAtCurrentMousePosition()
      refreshInteractionState()
    } else if !enabled {
      isSelecting = false
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      crosshairIndicatorLayer.isHidden = true
      selectionBorderLayer.isHidden = true
      insideSelectionOverlayLayer.isHidden = true
      dimLayer.mask = nil
      CATransaction.commit()
    }
    refreshActiveCursor()
  }

  func activatePendingSelectionIfNeeded() {
    guard selectionEnabled, interactionMode == .manualRegion else { return }
    guard let pendingSelectionStartPoint else { return }
    self.pendingSelectionStartPoint = nil
    isSelecting = true
    delegate?.overlayView(self, manualSelectionBeganAt: pendingSelectionStartPoint)
    delegate?.overlayView(self, manualSelectionChangedTo: currentMousePosition)
  }

  /// Max long-edge of the cached backdrop bitmap. The cache only feeds the 5×5 average-luminance
  /// sample grid, so a tiny image is plenty; this avoids a ~59 MB main-thread raster + copy on
  /// 5K Retina displays.
  private static let backdropPixelCacheMaxLongEdge: CGFloat = 512

  private func cacheBackdropPixels(from cgImage: CGImage, scale: CGFloat) {
    let startedAt = Date()
    let sourceWidth = cgImage.width
    let sourceHeight = cgImage.height
    guard sourceWidth > 0, sourceHeight > 0 else {
      backdropWidth = 0
      backdropHeight = 0
      backdropScale = scale
      backdropPixelDataArray = nil
      return
    }

    let downscale = min(1, Self.backdropPixelCacheMaxLongEdge / CGFloat(max(sourceWidth, sourceHeight)))
    let width = max(1, Int((CGFloat(sourceWidth) * downscale).rounded()))
    let height = max(1, Int((CGFloat(sourceHeight) * downscale).rounded()))
    backdropWidth = width
    backdropHeight = height
    backdropScale = scale

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
      backdropPixelDataArray = nil
      DiagnosticLogger.shared.log(
        .error,
        .capture,
        "Failed to create CGContext for backdrop pixel caching",
        context: ["width": "\(width)", "height": "\(height)"]
      )
      return
    }

    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    if let dataPtr = context.data {
      let totalBytes = width * height * 4
      let bufferPointer = UnsafeBufferPointer(start: dataPtr.assumingMemoryBound(to: UInt8.self), count: totalBytes)
      backdropPixelDataArray = Array(bufferPointer)
    } else {
      backdropPixelDataArray = nil
    }

    DiagnosticLogger.shared.log(
      .debug,
      .capture,
      "cacheBackdropPixels completed",
      context: [
        "width": "\(width)",
        "height": "\(height)",
        "sourceWidth": "\(sourceWidth)",
        "sourceHeight": "\(sourceHeight)",
        "scale": "\(scale)",
        "cachedBytes": "\(backdropPixelDataArray?.count ?? 0)",
        "duration_ms": "\(Date().timeIntervalSince(startedAt) * 1000)",
      ]
    )
  }

  private func calculateAverageLuminance(for rect: CGRect) -> Double? {
    guard let pixelData = backdropPixelDataArray,
          backdropWidth > 0,
          backdropHeight > 0,
          !rect.isEmpty else {
      return nil
    }

    // Map the selection rect (view points) into backdrop pixels. Derive the scale from the ACTUAL
    // cached image dimensions vs the view bounds rather than trusting `backdropScale`: the live luma
    // backdrop is captured at `.nominalResolution` (point-sized), so a stored `backingScaleFactor`
    // (2× on Retina) overshoots and clamps the sample grid to the screen edge — which made small /
    // centered selections mis-detect the background. Deriving from real dims is correct for both
    // nominal (ratio ≈ 1) and best-resolution (ratio ≈ backingScale) images.
    let scaleX = bounds.width > 0 ? CGFloat(backdropWidth) / bounds.width : backdropScale
    let scaleY = bounds.height > 0 ? CGFloat(backdropHeight) / bounds.height : backdropScale
    let pixelRect = CGRect(
      x: rect.origin.x * scaleX,
      y: rect.origin.y * scaleY,
      width: rect.width * scaleX,
      height: rect.height * scaleY
    )

    let gridCount = 5
    var totalLuma = 0.0
    var sampleCount = 0

    for row in 0 ..< gridCount {
      for col in 0 ..< gridCount {
        let pctX = Double(col + 1) / Double(gridCount + 1)
        let pctY = Double(row + 1) / Double(gridCount + 1)

        let sampleX = Int(pixelRect.origin.x + pixelRect.width * CGFloat(pctX))
        let sampleYInCocoa = Int(pixelRect.origin.y + pixelRect.height * CGFloat(pctY))

        let x = max(0, min(backdropWidth - 1, sampleX))
        // Invert y because Cocoa origin is bottom-left, while CGImage origin is top-left
        let y = max(0, min(backdropHeight - 1, backdropHeight - 1 - sampleYInCocoa))

        let pixelOffset = (y * backdropWidth + x) * 4
        if pixelOffset + 2 < pixelData.count {
          let r = Double(pixelData[pixelOffset]) / 255.0
          let g = Double(pixelData[pixelOffset + 1]) / 255.0
          let b = Double(pixelData[pixelOffset + 2]) / 255.0
          // BT.601 luminance formula
          let luma = 0.299 * r + 0.587 * g + 0.114 * b
          totalLuma += luma
          sampleCount += 1
        }
      }
    }

    return sampleCount > 0 ? (totalLuma / Double(sampleCount)) : nil
  }

  private func updateInsideOverlayAppearance(for localRect: CGRect) {
    if let avgLuma = calculateAverageLuminance(for: localRect) {
      didLogMissingLumaData = false
      let wasDark = insideOverlayIsDark
      if insideOverlayIsDark {
        if avgLuma < 0.4 {
          insideOverlayIsDark = false
        }
      } else {
        if avgLuma > 0.6 {
          insideOverlayIsDark = true
        }
      }

      // Log only on an actual light/dark flip. This runs per drag frame (60+ fps), so logging
      // every frame would add string-building + I/O to the hot path and risk dropped frames.
      if wasDark != insideOverlayIsDark {
        DiagnosticLogger.shared.log(
          .debug,
          .capture,
          "updateInsideOverlayAppearance flipped",
          context: [
            "avgLuma": String(format: "%.3f", avgLuma),
            "isDark": "\(insideOverlayIsDark)",
          ]
        )
      }
    } else if !didLogMissingLumaData {
      // Log the missing-data case at most once per selection: while the async luma backdrop is still
      // being captured the user can already drag, and logging every frame would spam warnings.
      didLogMissingLumaData = true
      DiagnosticLogger.shared.log(
        .warning,
        .capture,
        "updateInsideOverlayAppearance failed to calculate average luma (no pixel data cached)",
        context: [
          "hasPixelData": "\(backdropPixelDataArray != nil)",
          "width": "\(backdropWidth)",
          "height": "\(backdropHeight)",
        ]
      )
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if insideOverlayIsDark {
      insideSelectionOverlayLayer.fillColor = NSColor.black.withAlphaComponent(0.12).cgColor
      insideSelectionOverlayLayer.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
    } else {
      insideSelectionOverlayLayer.fillColor = NSColor.white.withAlphaComponent(0.15).cgColor
      insideSelectionOverlayLayer.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
    }
    CATransaction.commit()
  }

  func applyBackdrop(_ backdrop: AreaSelectionBackdrop, animated: Bool = false) {
    let shouldAnimate = animated
      && BackdropTransitionEffect.shouldCrossfade(
        isReapplication: currentBackdropImage != nil,
        isVisible: backdrop.isVisible
      )

    // Frame, scale, and visibility are never animated.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotLayer.frame = bounds
    snapshotLayer.contentsScale = backdrop.scaleFactor
    snapshotLayer.isHidden = !backdrop.isVisible
    CATransaction.commit()

    // Contents swap: crossfade on re-apply when opted-in, hard swap otherwise.
    CATransaction.begin()
    if shouldAnimate {
      BackdropTransitionEffect.addCrossfade(to: snapshotLayer)
    } else {
      CATransaction.setDisableActions(true)
    }
    snapshotLayer.contents = backdrop.image
    CATransaction.commit()

    currentBackdropImage = backdrop.image
    cacheBackdropPixels(from: backdrop.image, scale: backdrop.scaleFactor)
    if magnifier.zoom > 1.0 {
      updateMagnifier(at: currentMousePosition)
    }
    if selectionEnabled {
      updateCoordinateIndicator(at: currentMousePosition)
    }
  }

  func clearBackdrop() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotLayer.contents = nil
    snapshotLayer.contentsScale = 1.0
    snapshotLayer.isHidden = true
    magnifier.removeLayers()
    CATransaction.commit()

    backdropPixelDataArray = nil
    backdropWidth = 0
    backdropHeight = 0
    backdropScale = 1.0
    currentBackdropImage = nil
    magnifier.zoom = 1.0
  }

  /// Applies the magnifier's session-start preferences ("show magnifier by default", "show
  /// color picker panel") to a window newly entering a selection session. Called from
  /// `configureSessionWindow` — shared by session start and mid-session display attach —
  /// rather than from `applyBackdrop`/`clearBackdrop` directly, since a frozen session (e.g.
  /// screenshot-and-annotate) already has its backdrop ready and takes the `applyBackdrop`
  /// path, which must not reset these on every reapplication.
  func resetMagnifierZoomForNewSession() {
    let showsMagnifierByDefault = UserDefaults.standard
      .object(forKey: PreferencesKeys.screenshotShowMagnifierByDefault) as? Bool ?? false
    magnifier.resetZoom(showByDefault: showsMagnifierByDefault)
    magnifier.showsColorPanel = UserDefaults.standard
      .object(forKey: PreferencesKeys.screenshotShowMagnifierColorPanel) as? Bool ?? true
    // Coordinates live in the panel, not the separate `updateCoordinateIndicator` bubble, once
    // the magnifier is active — see the comment there. Same behavior as screenshot-and-annotate.
    magnifier.showsCoordinatesInPanel = true
  }

  // MARK: - Magnifying Glass Zoom Implementation

  private func updateMagnifier(at point: CGPoint) {
    guard isMouseOver else {
      magnifier.removeLayers()
      return
    }
    magnifier.update(
      at: point,
      bounds: bounds,
      backdropImage: currentBackdropImage,
      contentsScale: screenScaleFactor,
      in: layer ?? CALayer()
    )
  }

  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
      let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
      if delta != 0 {
        applyMagnifierScroll(delta: delta, hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas)
      }
    } else {
      super.scrollWheel(with: event)
    }
  }

  /// Shared magnifier-zoom step for both input paths (window scroll events and
  /// the live-passthrough event tap). Redraws at the tracked pointer position
  /// when the zoom actually changed.
  func applyMagnifierScroll(delta: CGFloat, hasPreciseScrollingDeltas: Bool) {
    if magnifier.handleScroll(delta: delta, hasPreciseScrollingDeltas: hasPreciseScrollingDeltas) {
      updateMagnifier(at: currentMousePosition)
    }
  }

  /// Live-passthrough input: the event tap consumes scroll-wheel events before
  /// they can become `NSEvent`s, so the controller forwards them here. Applies
  /// the same ⌘ gate as `scrollWheel(with:)`.
  func handleLivePassthroughScroll(deltaY: CGFloat, hasPreciseScrollingDeltas: Bool, isCommandDown: Bool) {
    guard isCommandDown, deltaY != 0 else { return }
    applyMagnifierScroll(delta: deltaY, hasPreciseScrollingDeltas: hasPreciseScrollingDeltas)
  }

  #if DEBUG

    var testSnapshotLayer: CALayer {
      snapshotLayer
    }

    var testBackdropPixelDataArray: [UInt8]? {
      backdropPixelDataArray
    }

    var testMagnifierZoom: CGFloat {
      get { magnifier.zoom }
      set { magnifier.zoom = newValue }
    }

    func testUpdateMagnifier(at point: CGPoint) {
      updateMagnifier(at: point)
    }

    var testMagnifierContainerLayer: CALayer? {
      magnifier.containerLayer
    }

    var testMagnifierImageLayer: CALayer? {
      magnifier.imageLayer
    }

    var testMagnifierGridLayer: CAShapeLayer? {
      magnifier.gridLayer
    }

    var testMagnifierCrosshairLayer: CAShapeLayer? {
      magnifier.crosshairLayer
    }

    var testMagnifierPanelLayer: CALayer? {
      magnifier.panelLayer
    }

    var testMagnifierColorTextLayer: CATextLayer? {
      magnifier.colorTextLayer
    }

    var testMagnifierCoordinateTextLayer: CATextLayer? {
      magnifier.coordinateTextLayer
    }

    var testMagnifierImageOuterBorderLayer: CALayer? {
      magnifier.imageOuterBorderLayer
    }

    var testMagnifierShowsColorPanel: Bool {
      get { magnifier.showsColorPanel }
      set { magnifier.showsColorPanel = newValue }
    }

    var testMagnifierShowsCoordinatesInPanel: Bool {
      get { magnifier.showsCoordinatesInPanel }
      set { magnifier.showsCoordinatesInPanel = newValue }
    }

    var testMagnifierHintPrefixTextLayer: CATextLayer? {
      magnifier.hintPrefixTextLayer
    }

    var testMagnifierHintTextLayer: CATextLayer? {
      magnifier.hintTextLayer
    }

    var testMagnifierKeyCapBackgroundLayer: CALayer? {
      magnifier.hintKeyCapBackgroundLayer
    }

    var testMagnifierTotalHeight: CGFloat {
      magnifier.totalHeight
    }

    var testMagnifierLastHexColor: String? {
      magnifier.lastHexColor
    }

    @discardableResult
    func testCopyMagnifierColor() -> Bool {
      magnifier.copyColorToClipboard()
    }

    var testReverseMagnifierZoomDirection: Bool {
      get { magnifier.reverseZoomDirection }
      set { magnifier.reverseZoomDirection = newValue }
    }

    func testScrollWheel(
      deltaY: CGFloat,
      modifierFlags: NSEvent.ModifierFlags,
      hasPreciseScrollingDeltas: Bool = false
    ) {
      if modifierFlags.contains(.command) {
        if deltaY != 0 {
          applyMagnifierScroll(delta: deltaY, hasPreciseScrollingDeltas: hasPreciseScrollingDeltas)
        }
      }
    }

    var testSizeIndicatorTextLayer: CATextLayer {
      sizeIndicatorTextLayer
    }

    var testSizeIndicatorBackgroundLayer: CALayer {
      sizeIndicatorBackgroundLayer
    }

    var testCurrentMousePosition: CGPoint {
      currentMousePosition
    }

    var testCursorProxyLayer: CALayer {
      cursorProxyLayer
    }
  #endif

  /// Initialize crosshair at current mouse position (called on activation)
  private func initializeCrosshairAtCurrentMousePosition() {
    // Live passthrough: the event tap consumes every mouse move, so `NSEvent.mouseLocation`
    // is frozen at the session-start position. Once the tap has delivered a real position
    // keep it — re-reading the stale system location would snap the crosshair and the
    // coordinate indicator back to where the session started (observed after a tap).
    guard !(isLivePassthroughInput && hasLivePassthroughPointerPosition) else { return }
    // Get the current mouse location in screen coordinates
    let mouseLocationInScreen = NSEvent.mouseLocation

    // Convert to window coordinates, then to view coordinates
    if let window {
      let mouseLocationInWindow = window.convertPoint(fromScreen: mouseLocationInScreen)
      currentMousePosition = convert(mouseLocationInWindow, from: nil)
    } else {
      // Fallback: use screen coordinates relative to view frame
      currentMousePosition = CGPoint(
        x: mouseLocationInScreen.x - frame.origin.x,
        y: mouseLocationInScreen.y - frame.origin.y
      )
    }
  }

  /// Current mouse location converted to view coordinates, falling back to the last
  /// tracked position when the view has no window (e.g. unit tests).
  private func currentLocalMousePoint() -> CGPoint {
    // Live passthrough: `NSEvent.mouseLocation` is stale (see
    // `initializeCrosshairAtCurrentMousePosition`); the tap-tracked position is fresh.
    if isLivePassthroughInput, hasLivePassthroughPointerPosition {
      return currentMousePosition
    }
    if let window {
      return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }
    return currentMousePosition
  }

  /// Re-evaluates the coordinate indicator after a non-mouse event (layout pass, bounds
  /// change, selection re-render). `updateCoordinateIndicator(at:)` applies its own guards
  /// (mouse-over, interaction mode, visible selection rect), so this only restores the label
  /// where it belongs on screen and keeps it hidden everywhere else — including during a
  /// drag, where the dimensions label owns the size indicator layers.
  private func refreshCoordinateIndicatorAfterPassiveUpdate() {
    updateCoordinateIndicator(at: currentLocalMousePoint())
  }

  /// Update bounds when screen configuration changes
  func updateBounds(_ newFrame: CGRect) {
    frame = CGRect(origin: .zero, size: newFrame.size)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotLayer.frame = bounds
    updateRetainedMenuBarPopoverLayers()
    dimLayer.frame = bounds
    refreshCoordinateIndicatorAfterPassiveUpdate()
    CATransaction.commit()

    // Rebuild tracking areas for new bounds
    updateTrackingAreas()
    updateModeHint()
  }

  /// Diagnostic snapshot of the layer tree for the presentation watchdog's anomaly logs —
  /// answers "would anything paint?" without exposing the private layers. The keys are
  /// merged into the watchdog's log context so a field report shows the exact rendering
  /// state at the moment the window failed to present.
  func presentationDiagnostics() -> [String: String] {
    [
      "overlayBounds": "\(bounds)",
      "overlayLayerAttached": "\(layer != nil)",
      "overlaySublayerCount": "\(layer?.sublayers?.count ?? 0)",
      "snapshotLayerHidden": "\(snapshotLayer?.isHidden ?? true)",
      "snapshotLayerHasContents": "\(snapshotLayer?.contents != nil)",
      "dimLayerHidden": "\(dimLayer?.isHidden ?? true)",
      "dimLayerFrame": "\(dimLayer?.frame ?? .zero)",
      "cursorProxyHidden": "\(cursorProxyLayer?.isHidden ?? true)",
      "selectionBorderHidden": "\(selectionBorderLayer?.isHidden ?? true)",
      "backdropImagePresent": "\(currentBackdropImage != nil)",
      "isLivePassthroughInput": "\(isLivePassthroughInput)",
      "showSelectionAreaOverlay": "\(showSelectionAreaOverlay)",
    ]
  }

  // MARK: - First Mouse

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override func keyDown(with event: NSEvent) {
    if keyEventHandler?(event) == true {
      return
    }
    super.keyDown(with: event)
  }

  // MARK: - Layout

  override func layout() {
    super.layout()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotLayer.frame = bounds
    updateRetainedMenuBarPopoverLayers()
    dimLayer.frame = bounds
    insideSelectionOverlayLayer.frame = bounds
    refreshCoordinateIndicatorAfterPassiveUpdate()
    CATransaction.commit()
    updateModeHint()
  }

  // MARK: - CALayer Updates (60fps performance)

  private func updateCrosshairLayers() {
    guard selectionEnabled, interactionMode == .manualRegion else {
      crosshairIndicatorLayer.isHidden = true
      hideSizeIndicator()
      return
    }

    crosshairIndicatorLayer.isHidden = true
    updateCoordinateIndicator(at: currentMousePosition)
  }

  /// Updates and returns the reusable crosshair indicator path centered at the given point
  private func createCrosshairIndicatorPath(at point: CGPoint) -> CGPath {
    let size = crosshairIndicatorSize
    reusableCrosshairPath = CGMutablePath()

    // Vertical line
    reusableCrosshairPath.move(to: CGPoint(x: point.x, y: point.y - size))
    reusableCrosshairPath.addLine(to: CGPoint(x: point.x, y: point.y + size))

    // Horizontal line
    reusableCrosshairPath.move(to: CGPoint(x: point.x - size, y: point.y))
    reusableCrosshairPath.addLine(to: CGPoint(x: point.x + size, y: point.y))

    return reusableCrosshairPath
  }

  private func updateDimLayerMask(for selectionRect: CGRect) {
    // Reuse mask layer to avoid per-frame CAShapeLayer allocation
    let path = CGMutablePath()
    path.addRect(bounds)
    path.addRect(selectionRect)
    reusableDimMaskLayer.path = path
    if dimLayer.mask !== reusableDimMaskLayer {
      dimLayer.mask = reusableDimMaskLayer
    }
  }

  private var screenScaleFactor: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
  }

  private var overlayTextAttributes: [NSAttributedString.Key: Any] {
    [
      .font: overlayFont,
      .foregroundColor: NSColor.white,
    ]
  }

  private let coordinateIndicatorFont = CoordinateBubbleStyle.font

  private var coordinateTextAttributes: [NSAttributedString.Key: Any] {
    [
      .font: coordinateIndicatorFont,
      .foregroundColor: CoordinateBubbleStyle.textColor,
    ]
  }

  private func multiLineTextSize(_ text: String, attributes: [NSAttributedString.Key: Any]) -> CGSize {
    let lines = text.components(separatedBy: "\n")
    let maxWidth = lines.map { $0.size(withAttributes: attributes).width }.max() ?? 0
    let lineHeight = "0".size(withAttributes: attributes).height
    let totalHeight = lineHeight * CGFloat(lines.count) + 2.0
    return CGSize(width: maxWidth, height: totalHeight)
  }

  private func configureShadow(
    for layer: CALayer,
    color: NSColor,
    offset: CGSize,
    radius: CGFloat,
    opacity: Float
  ) {
    layer.shadowColor = color.cgColor
    layer.shadowOffset = offset
    layer.shadowRadius = radius
    layer.shadowOpacity = opacity
  }

  private func configureOverlayTextLayer(_ textLayer: CATextLayer) {
    textLayer.actions = disabledActions
    textLayer.font = overlayFont as CTFont
    textLayer.fontSize = overlayFont.pointSize
    textLayer.foregroundColor = NSColor.white.cgColor
    textLayer.alignmentMode = .left
    textLayer.contentsScale = screenScaleFactor
    textLayer.truncationMode = .none
    textLayer.isWrapped = false
    textLayer.isHidden = true
  }

  private func updateTextLayerScales() {
    let scale = screenScaleFactor
    sizeIndicatorTextLayer.contentsScale = scale
    modeHintTextLayer.contentsScale = scale
  }

  func hideSizeIndicator() {
    sizeIndicatorBackgroundLayer.isHidden = true
    sizeIndicatorTextLayer.isHidden = true
    lastSizeIndicatorText = nil
  }

  func hideMagnifier() {
    magnifier.removeLayers()
  }

  /// Copies the magnifier's currently sampled pixel color to the clipboard if the plain "C"
  /// key (no modifiers) was pressed while the magnifier is active. Returns false — and leaves
  /// the event unhandled — for any other key or when the magnifier is inactive, so normal
  /// typing (e.g. future shortcuts sharing this key) is never swallowed.
  func copyMagnifierColorIfActive(for event: NSEvent) -> Bool {
    guard event.keyCode == 8 else { return false } // kVK_ANSI_C
    guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
    return magnifier.copyColorToClipboard()
  }

  /// Hide the drawn cursor proxy (pointer left this display, session ended, or
  /// passthrough disabled). No-op when already hidden.
  func hideCursorProxy() {
    cursorProxyLayer.isHidden = true
  }

  /// Drawn replacement for the system cursor in live-passthrough sessions. The system
  /// cursor is hidden for the session (`BackgroundCursorControl` +
  /// `LivePassthroughCursorHider`), so this proxy renders the visible cursor: the exact
  /// legacy cursor image (`activeCursor` — crosshair in manual mode, camera in window
  /// mode, arrow fallback) is drawn at the pointer with the same hotspot, giving
  /// pixel-parity with the window-event path. The position follows `currentMousePosition`,
  /// which hover and drag renders keep fresh.
  private func updateCursorProxy() {
    guard isLivePassthroughInput, isMouseOver else {
      cursorProxyLayer.isHidden = true
      return
    }
    let cursor = activeCursor
    let image = cursor.image
    let hotSpot = cursor.hotSpot
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if image !== cursorProxySourceImage {
      cursorProxyLayer.contents = image
      cursorProxySourceImage = image
    }
    cursorProxyLayer.frame = CGRect(
      x: currentMousePosition.x - hotSpot.x,
      y: currentMousePosition.y - (image.size.height - hotSpot.y),
      width: image.size.width,
      height: image.size.height
    )
    cursorProxyLayer.isHidden = false
    CATransaction.commit()
  }

  #if DEBUG
    var testMouseLocationOverride: CGPoint?
  #endif

  private var isMouseOver: Bool {
    #if DEBUG
      if NSClassFromString("XCTestCase") != nil, self.window == nil {
        return true
      }
    #endif
    // Live passthrough: `NSEvent.mouseLocation` is frozen at the session-start position
    // (the tap consumes every move), so hit-test the tap-tracked pointer position
    // instead — otherwise the coordinate indicator and cursor proxy follow the stale
    // point, and vanish entirely once the pointer is on another display.
    if isLivePassthroughInput, hasLivePassthroughPointerPosition {
      guard let window, window.isVisible else { return false }
      let pointerOnScreen = window.convertPoint(toScreen: convert(currentMousePosition, to: nil))
      return window.frame.contains(pointerOnScreen)
    }
    #if DEBUG
      let mouseLocation = testMouseLocationOverride ?? NSEvent.mouseLocation
    #else
      let mouseLocation = NSEvent.mouseLocation
    #endif
    guard let window,
          window.isVisible,
          window.frame.contains(mouseLocation) else {
      return false
    }
    return true
  }

  private func updateSizeIndicator(for rect: CGRect, measuredSize: CGSize? = nil) {
    let displayedSize = measuredSize ?? rect.size
    let sizeText = "\(Int(displayedSize.width))\n\(Int(displayedSize.height))"
    let attributes = coordinateTextAttributes
    let textSize: CGSize
    // Assigning `CATextLayer.string` re-rasterizes the text even when unchanged, and
    // this runs per pointer tick — so measure and re-assign only on actual changes.
    let textChanged = sizeText != lastSizeIndicatorText
    if textChanged {
      textSize = multiLineTextSize(sizeText, attributes: attributes)
      lastSizeIndicatorText = sizeText
      lastSizeIndicatorTextSize = textSize
    } else {
      textSize = lastSizeIndicatorTextSize
    }

    let point = currentMousePosition
    let offset: CGFloat = 12
    var textRect = CGRect(
      x: point.x + offset,
      y: point.y - textSize.height - 4,
      width: textSize.width,
      height: textSize.height
    )

    if textRect.maxX > bounds.maxX {
      textRect.origin.x = point.x - textSize.width - offset
    }
    if textRect.minY < bounds.minY {
      textRect.origin.y = point.y + offset
    }

    updateTextLayerScales()
    sizeIndicatorBackgroundLayer.frame = textRect.insetBy(dx: -4, dy: -2)
    sizeIndicatorBackgroundLayer.isHidden = false

    if textChanged {
      sizeIndicatorTextLayer.string = sizeText
    }
    sizeIndicatorTextLayer.frame = textRect
    sizeIndicatorTextLayer.isHidden = false
  }

  private func updateCoordinateIndicator(at point: CGPoint) {
    // While the magnifier is active, its own panel shows coordinates (see
    // `AreaSelectionMagnifier.showsCoordinatesInPanel`) — matching screenshot-and-annotate,
    // which has no indicator of its own and relies on that panel exclusively. Showing this
    // indicator too would just duplicate it, so this one stands down and leaves the panel as
    // the single source once the magnifier takes over.
    guard isMouseOver, interactionMode == .manualRegion, !hasVisibleSelectionRect,
          magnifier.zoom <= 1.0 else {
      hideSizeIndicator()
      return
    }

    let localX = Int(point.x)
    let localY = Int(bounds.height - point.y)
    let text = "\(localX)\n\(localY)"

    let attributes = coordinateTextAttributes
    let textSize: CGSize
    // Same per-tick re-raster guard as `updateSizeIndicator` (shared layer + cache).
    let textChanged = text != lastSizeIndicatorText
    if textChanged {
      textSize = multiLineTextSize(text, attributes: attributes)
      lastSizeIndicatorText = text
      lastSizeIndicatorTextSize = textSize
    } else {
      textSize = lastSizeIndicatorTextSize
    }

    let offset: CGFloat = 12
    var textRect = CGRect(
      x: point.x + offset,
      y: point.y - textSize.height - 4,
      width: textSize.width,
      height: textSize.height
    )

    if textRect.maxX > bounds.maxX {
      textRect.origin.x = point.x - textSize.width - offset
    }
    if textRect.minY < bounds.minY {
      textRect.origin.y = point.y + offset
    }

    updateTextLayerScales()
    sizeIndicatorBackgroundLayer.frame = textRect.insetBy(dx: -4, dy: -2)
    sizeIndicatorBackgroundLayer.isHidden = false

    if textChanged {
      sizeIndicatorTextLayer.string = text
    }
    sizeIndicatorTextLayer.frame = textRect
    sizeIndicatorTextLayer.isHidden = false
  }

  private func updateModeHint() {
    guard allowsApplicationWindowSelection else {
      modeHintBackgroundLayer.isHidden = true
      modeHintTextLayer.isHidden = true
      return
    }

    let shortcut: CaptureOverlayShortcut? = switch selectionMode {
    case .screenshot, .scrollingCapture:
      CaptureOverlayShortcutSettings.applicationCaptureShortcut
    case .recording:
      CaptureOverlayShortcutSettings.recordingApplicationCaptureShortcut
    }

    guard let shortcut, !shortcut.isIndependent else {
      modeHintBackgroundLayer.isHidden = true
      modeHintTextLayer.isHidden = true
      return
    }

    let hint = interactionMode == .manualRegion
      ? L10n.ScreenCapture.applicationModeHint(shortcut.displayString)
      : L10n.ScreenCapture.manualModeHint(shortcut.displayString)
    let attributes = overlayTextAttributes
    let hintSize = hint.size(withAttributes: attributes)
    let padding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    let backgroundRect = CGRect(
      x: (bounds.width - hintSize.width) / 2 - padding.left,
      y: 24,
      width: hintSize.width + padding.left + padding.right,
      height: hintSize.height + padding.top + padding.bottom
    )

    updateTextLayerScales()
    modeHintBackgroundLayer.frame = backgroundRect
    modeHintBackgroundLayer.isHidden = false
    modeHintTextLayer.string = hint
    modeHintTextLayer.frame = CGRect(
      x: backgroundRect.minX + padding.left,
      y: backgroundRect.minY + padding.bottom - 1,
      width: hintSize.width,
      height: hintSize.height
    )
    modeHintTextLayer.isHidden = false
  }

  func setAllowsApplicationWindowSelection(_ allowsApplicationWindowSelection: Bool) {
    self.allowsApplicationWindowSelection = allowsApplicationWindowSelection
    updateModeHint()
  }

  func setInteractionMode(
    _ interactionMode: AreaSelectionInteractionMode,
    resetSelection: Bool = true
  ) {
    self.interactionMode = interactionMode
    if resetSelection {
      self.resetSelection()
    } else {
      refreshInteractionState()
    }
    refreshActiveCursor()
    updateModeHint()
  }

  func renderManualSelection(screenRect: CGRect?, currentScreenPoint: CGPoint?) {
    guard interactionMode == .manualRegion else { return }

    let localCurrentPoint: CGPoint?
    if let currentScreenPoint, let window {
      let pointInWindow = window.convertPoint(fromScreen: currentScreenPoint)
      localCurrentPoint = convert(pointInWindow, from: nil)
      currentMousePosition = localCurrentPoint ?? currentMousePosition
    } else {
      localCurrentPoint = nil
    }

    if magnifier.zoom > 1.0 {
      updateMagnifier(at: currentMousePosition)
    }

    // Keep the drawn cursor proxy glued to the pointer during drags (passthrough only;
    // no-op otherwise). Hover updates position it via `handlePrimaryMouseMoved`.
    updateCursorProxy()

    guard let screenRect, !screenRect.isEmpty else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      hasVisibleSelectionRect = false
      selectionBorderLayer.isHidden = true
      dimLayer.mask = nil
      insideSelectionOverlayLayer.isHidden = true
      crosshairIndicatorLayer.isHidden = true
      if selectionEnabled {
        // No drag point: fall back to the fresh mouse location so the coordinate
        // indicator survives re-renders triggered before the first mouse move
        // (e.g. an async backdrop landing right after the session starts, or the
        // mouseDown that begins a selection before the first drag movement).
        updateCoordinateIndicator(at: localCurrentPoint ?? currentLocalMousePoint())
      } else {
        hideSizeIndicator()
      }
      CATransaction.commit()
      return
    }

    let localRect = convertToLocalRect(screenRect).intersection(bounds)
    let showsCurrentPointer = localCurrentPoint.map { bounds.contains($0) } == true

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hasVisibleSelectionRect = !localRect.isEmpty
    horizontalCrosshairLayer.isHidden = true
    verticalCrosshairLayer.isHidden = true
    crosshairIndicatorLayer.isHidden = true

    if localRect.isEmpty {
      selectionBorderLayer.isHidden = true
      dimLayer.mask = nil
      insideSelectionOverlayLayer.isHidden = true
      hideSizeIndicator()
    } else {
      selectionBorderLayer.isHidden = false
      selectionBorderLayer.path = CGPath(rect: localRect, transform: nil)
      if showSelectionAreaOverlay {
        updateDimLayerMask(for: localRect)
        insideSelectionOverlayLayer.isHidden = true
      } else {
        dimLayer.mask = nil
        insideSelectionOverlayLayer.path = CGPath(rect: localRect, transform: nil)
        updateInsideOverlayAppearance(for: localRect)
        insideSelectionOverlayLayer.isHidden = false
      }
      if showsCurrentPointer {
        updateSizeIndicator(for: localRect, measuredSize: screenRect.size)
      } else {
        hideSizeIndicator()
      }
    }
    CATransaction.commit()
  }

  func setWindowSelectionSnapshot(_ windowSelectionSnapshot: WindowSelectionSnapshot?) {
    self.windowSelectionSnapshot = windowSelectionSnapshot
    if interactionMode == .applicationWindow {
      refreshInteractionState()
    }
  }

  func setRetainedMenuBarPopoverCaptures(_ captures: [ImmediateMenuBarPopoverCapture]) {
    retainedMenuBarPopoverCaptures = Dictionary(
      uniqueKeysWithValues: captures.map { ($0.target.windowID, $0) }
    )
    // Hide every retained crop until the controller has performed its post-activation
    // WindowServer liveness check.
    retainedMenuBarPopoverWindowIDsStillOnScreen = Set(retainedMenuBarPopoverCaptures.keys)
    updateRetainedMenuBarPopoverLayers()
  }

  func setRetainedMenuBarPopoverWindowIDsStillOnScreen(_ windowIDs: Set<CGWindowID>) {
    retainedMenuBarPopoverWindowIDsStillOnScreen = windowIDs
    updateRetainedMenuBarPopoverLayers()
  }

  private func updateRetainedMenuBarPopoverLayers() {
    guard let rootLayer = layer, let window, let displayID = window.screen?.displayID else { return }

    let capturesForDisplay = retainedMenuBarPopoverCaptures.values.filter {
      $0.target.displayID == displayID
    }
    let captureIDs = Set(capturesForDisplay.map(\.target.windowID))
    for windowID in retainedMenuBarPopoverLayers.keys.filter({ !captureIDs.contains($0) }) {
      retainedMenuBarPopoverLayers[windowID]?.removeFromSuperlayer()
      retainedMenuBarPopoverLayers[windowID] = nil
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for capture in capturesForDisplay {
      let popoverLayer: CALayer
      if let existing = retainedMenuBarPopoverLayers[capture.target.windowID] {
        popoverLayer = existing
      } else {
        let created = CALayer()
        created.contentsGravity = .resize
        created.actions = disabledActions
        rootLayer.insertSublayer(created, above: snapshotLayer)
        retainedMenuBarPopoverLayers[capture.target.windowID] = created
        popoverLayer = created
      }
      popoverLayer.frame = convertToLocalRect(capture.target.frame).intersection(bounds)
      popoverLayer.contents = capture.image
      popoverLayer.contentsScale = capture.scaleFactor
      popoverLayer.isHidden = !WindowCaptureSelectionPolicy.shouldShowRetainedMenuBarPopover(
        isWindowStillOnScreen: retainedMenuBarPopoverWindowIDsStillOnScreen.contains(capture.target.windowID)
      )
    }
    CATransaction.commit()
  }

  private func refreshInteractionState() {
    switch interactionMode {
    case .manualRegion:
      hoveredWindowCandidate = nil
      dimLayer.mask = nil
      if !isSelecting {
        selectionBorderLayer.isHidden = true
        updateCrosshairLayers()
      }
    case .applicationWindow:
      refreshWindowHover()
    }
  }

  private func refreshWindowHover() {
    guard selectionEnabled, interactionMode == .applicationWindow else {
      hoveredWindowCandidate = nil
      updateApplicationSelectionLayers()
      return
    }
    let localPoint: CGPoint
    if let window {
      let mouseLocationInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
      localPoint = convert(mouseLocationInWindow, from: nil)
    } else {
      localPoint = currentMousePosition
    }
    updateWindowHover(at: localPoint)
  }

  private func updateWindowHover(at point: CGPoint) {
    currentMousePosition = point
    guard window != nil else {
      hoveredWindowCandidate = nil
      if interactionMode == .applicationWindow {
        updateApplicationSelectionLayers()
      }
      return
    }
    let screenPoint = NSEvent.mouseLocation
    hoveredWindowCandidate = windowSelectionSnapshot?.hitTest(at: screenPoint)
    if interactionMode == .applicationWindow {
      updateApplicationSelectionLayers()
    }
  }

  private func updateApplicationSelectionLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    crosshairIndicatorLayer.isHidden = true
    horizontalCrosshairLayer.isHidden = true
    verticalCrosshairLayer.isHidden = true
    hideSizeIndicator()

    if let hoveredWindowCandidate {
      let localRect = convertToLocalRect(hoveredWindowCandidate.target.frame).intersection(bounds)
      if localRect.isEmpty {
        selectionBorderLayer.isHidden = true
        dimLayer.mask = nil
        insideSelectionOverlayLayer.isHidden = true
      } else {
        selectionBorderLayer.isHidden = false
        selectionBorderLayer.path = CGPath(rect: localRect, transform: nil)
        if showSelectionAreaOverlay {
          updateDimLayerMask(for: localRect)
          insideSelectionOverlayLayer.isHidden = true
        } else {
          dimLayer.mask = nil
          insideSelectionOverlayLayer.path = CGPath(rect: localRect, transform: nil)
          updateInsideOverlayAppearance(for: localRect)
          insideSelectionOverlayLayer.isHidden = false
        }
      }
    } else {
      selectionBorderLayer.isHidden = true
      dimLayer.mask = nil
      insideSelectionOverlayLayer.isHidden = true
    }

    CATransaction.commit()
    updateModeHint()
  }

  private func convertToLocalRect(_ screenRect: CGRect) -> CGRect {
    guard let window else { return screenRect }
    return CGRect(
      x: screenRect.origin.x - window.frame.origin.x,
      y: screenRect.origin.y - window.frame.origin.y,
      width: screenRect.width,
      height: screenRect.height
    )
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    guard !isLivePassthroughInput else { return }
    handlePrimaryMouseDown(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isLivePassthroughInput else { return }
    handlePrimaryMouseDragged(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    guard !isLivePassthroughInput else { return }
    handlePrimaryMouseUp(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    guard !isLivePassthroughInput else { return }
    handlePrimaryMouseMoved(at: convert(event.locationInWindow, from: nil))
  }

  override func rightMouseDown(with _: NSEvent) {
    guard !isLivePassthroughInput else { return }
    delegate?.overlayViewDidCancel(self)
  }

  // MARK: - Live Passthrough Input

  /// Feed a pointer event from the capture event tap (live-passthrough sessions only).
  /// `screenPoint` is in AppKit global coordinates; the shared point-based handlers keep
  /// tap-driven input on the exact same code path as the window-event fallback.
  func handleLivePassthroughMouseDown(atScreenPoint screenPoint: CGPoint) {
    guard isLivePassthroughInput, let localPoint = localPoint(fromScreenPoint: screenPoint) else { return }
    hasLivePassthroughPointerPosition = true
    handlePrimaryMouseDown(at: localPoint)
  }

  func handleLivePassthroughMouseDragged(atScreenPoint screenPoint: CGPoint) {
    guard isLivePassthroughInput, let localPoint = localPoint(fromScreenPoint: screenPoint) else { return }
    hasLivePassthroughPointerPosition = true
    handlePrimaryMouseDragged(at: localPoint)
  }

  func handleLivePassthroughMouseUp(atScreenPoint screenPoint: CGPoint) {
    guard isLivePassthroughInput, let localPoint = localPoint(fromScreenPoint: screenPoint) else { return }
    hasLivePassthroughPointerPosition = true
    handlePrimaryMouseUp(at: localPoint)
  }

  func handleLivePassthroughMouseMoved(atScreenPoint screenPoint: CGPoint) {
    guard isLivePassthroughInput, let localPoint = localPoint(fromScreenPoint: screenPoint) else { return }
    hasLivePassthroughPointerPosition = true
    handlePrimaryMouseMoved(at: localPoint)
  }

  private func localPoint(fromScreenPoint screenPoint: CGPoint) -> CGPoint? {
    guard let window else { return nil }
    return convert(window.convertPoint(fromScreen: screenPoint), from: nil)
  }

  // MARK: - Shared Mouse Handling

  private func handlePrimaryMouseDown(at point: CGPoint) {
    currentMousePosition = point
    if let areaWindow = window as? AreaSelectionWindow {
      DiagnosticLogger.shared.log(
        .debug,
        .capture,
        "Area selection mouseDown received",
        context: [
          "displayID": "\(areaWindow.displayID.map(String.init(describing:)) ?? "nil")",
          "selectionEnabled": "\(selectionEnabled)",
          "point": "\(point)",
          "interactionMode": "\(interactionMode)",
        ]
      )
    }
    delegate?.overlayViewDidRequestDisplayActivation(self)
    guard selectionEnabled else {
      if interactionMode == .manualRegion {
        pendingSelectionStartPoint = point
        // Backdrop snapshot is still being prepared for this display. Ask the controller to
        // enable live-fallback selection so the click isn't silently dropped if the user
        // releases before the snapshot arrives. The lazy snapshot continues in the background
        // and will replace the live view via applyBackdrop() once ready.
        delegate?.overlayViewDidRequestImmediateManualSelection(self)
      }
      return
    }
    applyActiveCursor()
    switch interactionMode {
    case .manualRegion:
      isSelecting = true
      delegate?.overlayView(self, manualSelectionBeganAt: point)
    case .applicationWindow:
      updateWindowHover(at: point)
    }
  }

  private func handlePrimaryMouseDragged(at point: CGPoint) {
    currentMousePosition = point
    delegate?.overlayViewDidRequestDisplayActivation(self)
    guard selectionEnabled else {
      if pendingSelectionStartPoint != nil {
        currentMousePosition = point
      }
      return
    }
    applyActiveCursor()
    switch interactionMode {
    case .manualRegion:
      guard isSelecting else { return }
      delegate?.overlayView(self, manualSelectionChangedTo: point)
      updateMagnifier(at: point)
    case .applicationWindow:
      updateWindowHover(at: point)
    }
  }

  private func handlePrimaryMouseUp(at point: CGPoint) {
    currentMousePosition = point
    delegate?.overlayViewDidRequestDisplayActivation(self)
    guard selectionEnabled else {
      pendingSelectionStartPoint = nil
      return
    }

    switch interactionMode {
    case .manualRegion:
      guard isSelecting else { return }
      isSelecting = false

      delegate?.overlayView(self, manualSelectionEndedAt: point)
    case .applicationWindow:
      updateWindowHover(at: point)
      if let hoveredWindowCandidate {
        delegate?.overlayView(self, didSelectWindow: hoveredWindowCandidate.target)
      }
    }
  }

  private func handlePrimaryMouseMoved(at point: CGPoint) {
    currentMousePosition = point
    delegate?.overlayViewDidRequestDisplayActivation(self)
    applyActiveCursor()
    updateCoordinateIndicator(at: point)
    updateCursorProxy()
    guard selectionEnabled else { return }
    switch interactionMode {
    case .manualRegion:
      if !isSelecting {
        updateCrosshairLayers()
        updateMagnifier(at: point)
      }
    case .applicationWindow:
      updateWindowHover(at: point)
    }
  }

  private var activeCursor: NSCursor {
    switch interactionMode {
    case .manualRegion:
      return showSelectionAreaOverlay ? NSCursor.vectorScreenshotCrosshairLight : NSCursor
        .vectorScreenshotCrosshairHighContrast
    case .applicationWindow:
      guard selectionEnabled else { return .arrow }
      return NSCursor.applicationWindowCursor
    }
  }

  var isManualSelectionInProgress: Bool {
    interactionMode == .manualRegion && isSelecting
  }
}

// MARK: - Recreated macOS Crosshair Cursors

extension NSCursor {
  static var vectorScreenshotCrosshairHighContrast: NSCursor {
    let size = NSSize(width: 32, height: 32)
    let image = NSImage(size: size)
    image.isTemplate = false

    image.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()

    let verticalPath = NSBezierPath()
    // Bottom segment (y: 5 to 16)
    verticalPath.move(to: NSPoint(x: 15.5, y: 5))
    verticalPath.line(to: NSPoint(x: 15.5, y: 16))
    // Top segment (y: 17 to 28)
    verticalPath.move(to: NSPoint(x: 15.5, y: 17))
    verticalPath.line(to: NSPoint(x: 15.5, y: 28))

    let horizontalPath = NSBezierPath()
    // Left segment (x: 4 to 15)
    horizontalPath.move(to: NSPoint(x: 4, y: 16.5))
    horizontalPath.line(to: NSPoint(x: 15, y: 16.5))
    // Right segment (x: 16 to 27)
    horizontalPath.move(to: NSPoint(x: 16, y: 16.5))
    horizontalPath.line(to: NSPoint(x: 27, y: 16.5))

    let circleRect = NSRect(x: 9.5, y: 10.5, width: 12.0, height: 12.0)
    let circlePath = NSBezierPath(ovalIn: circleRect)

    // Circle fill (no shadow) - black with alpha 0.15 matching native A=38
    NSColor.black.withAlphaComponent(0.15).setFill()
    circlePath.fill()

    // Configure white shadow for high contrast on dark backgrounds
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.white.withAlphaComponent(0.65)
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = 1.5

    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()

    // Draw dark core lines (width 1.0) with shadow - white 0.20, alpha 0.85 matching native (51,51,51,217)
    let lineColor = NSColor(white: 0.20, alpha: 0.85)
    lineColor.setStroke()
    verticalPath.lineWidth = 1.0
    verticalPath.stroke()
    horizontalPath.lineWidth = 1.0
    horizontalPath.stroke()

    // Circle dark stroke - black with alpha 0.32 matching native A=81
    NSColor.black.withAlphaComponent(0.32).setStroke()
    circlePath.lineWidth = 1.0
    circlePath.stroke()

    NSGraphicsContext.current?.restoreGraphicsState()

    image.unlockFocus()
    return NSCursor(image: image, hotSpot: NSPoint(x: 15, y: 15))
  }

  static var vectorScreenshotCrosshairLight: NSCursor {
    let size = NSSize(width: 32, height: 32)
    let image = NSImage(size: size)
    image.isTemplate = false

    image.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()

    let verticalPath = NSBezierPath()
    // Bottom segment (y: 5 to 16)
    verticalPath.move(to: NSPoint(x: 15.5, y: 5))
    verticalPath.line(to: NSPoint(x: 15.5, y: 16))
    // Top segment (y: 17 to 28)
    verticalPath.move(to: NSPoint(x: 15.5, y: 17))
    verticalPath.line(to: NSPoint(x: 15.5, y: 28))

    let horizontalPath = NSBezierPath()
    // Left segment (x: 4 to 15)
    horizontalPath.move(to: NSPoint(x: 4, y: 16.5))
    horizontalPath.line(to: NSPoint(x: 15, y: 16.5))
    // Right segment (x: 16 to 27)
    horizontalPath.move(to: NSPoint(x: 16, y: 16.5))
    horizontalPath.line(to: NSPoint(x: 27, y: 16.5))

    let circleRect = NSRect(x: 9.5, y: 10.5, width: 12.0, height: 12.0)
    let circlePath = NSBezierPath(ovalIn: circleRect)

    let lightColor = NSColor.white

    // Circle fill (no shadow)
    lightColor.withAlphaComponent(0.15).setFill()
    circlePath.fill()

    // Configure black shadow for white lines
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -1.0)
    shadow.shadowBlurRadius = 1.0

    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()

    // Draw clean single light-colored line with shadow
    lightColor.withAlphaComponent(0.85).setStroke()
    verticalPath.lineWidth = 1.0
    verticalPath.stroke()
    horizontalPath.lineWidth = 1.0
    horizontalPath.stroke()

    // Circle stroke - white with alpha 0.30 matching native A=81 proportion
    lightColor.withAlphaComponent(0.30).setStroke()
    circlePath.lineWidth = 1.0
    circlePath.stroke()

    NSGraphicsContext.current?.restoreGraphicsState()

    image.unlockFocus()
    return NSCursor(image: image, hotSpot: NSPoint(x: 15, y: 15))
  }

  static var applicationWindowCursor: NSCursor {
    let pointSize: CGFloat = 16
    let baseConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let whiteConfig = baseConfig.applying(
      NSImage.SymbolConfiguration(paletteColors: [.white])
    )
    let blackConfig = baseConfig.applying(
      NSImage.SymbolConfiguration(paletteColors: [.black])
    )

    guard
      let whiteSymbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(whiteConfig),
      let blackSymbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(blackConfig)
    else {
      return .pointingHand
    }

    let padding: CGFloat = 5
    let canvasSize = NSSize(
      width: whiteSymbol.size.width + padding * 2,
      height: whiteSymbol.size.height + padding * 2
    )
    let composed = NSImage(size: canvasSize)
    composed.lockFocus()

    // Stamp the black symbol at 1px offsets around the center to form a dark
    // outline halo. This guarantees contrast against both bright and dark
    // window backgrounds without relying on a soft shadow that can wash out
    // against pure white.
    let haloOffsets: [(CGFloat, CGFloat)] = [
      (-1, 0), (1, 0), (0, -1), (0, 1),
      (-1, -1), (1, -1), (-1, 1), (1, 1),
    ]
    for (dx, dy) in haloOffsets {
      blackSymbol.draw(
        at: NSPoint(x: padding + dx, y: padding + dy),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
      )
    }

    whiteSymbol.draw(
      at: NSPoint(x: padding, y: padding),
      from: .zero,
      operation: .sourceOver,
      fraction: 1.0
    )

    composed.unlockFocus()

    return NSCursor(
      image: composed,
      hotSpot: NSPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    )
  }
}
