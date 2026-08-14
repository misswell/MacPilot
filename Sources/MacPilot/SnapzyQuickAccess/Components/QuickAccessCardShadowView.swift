//
//  QuickAccessCardShadowView.swift
//  Snapzy
//
//  GPU-cached drop shadow for Quick Access cards.
//

import AppKit
import SwiftUI

/// A layer-backed rounded-rect drop shadow, used behind each Quick Access card.
///
/// Replaces SwiftUI `.shadow()` (which recomputes an offscreen Gaussian blur every
/// frame). With many stacked cards, moving the cursor while the capture-area overlay
/// recomposites the transparent Quick Access panel forced N×2 blur recomputes per
/// frame → visible lag. A `CALayer.shadowPath` + `shouldRasterize` caches the shadow
/// bitmap on the GPU, so for the lag scenario — N *static* stacked cards during passive
/// cursor movement — the blur is computed once, then GPU-composited.
///
/// Note: an active swipe applies `.offset`/`.rotationEffect` to a single dragged card,
/// which can transiently re-rasterize that one card's shadow. That is a rare, single-card
/// cost (and no worse than the prior SwiftUI `.shadow()`), so it is intentionally not
/// gated here; measure in Phase 02 before adding complexity.
///
/// Placed as a `.background()` behind the card content, so the card's `.opacity`,
/// `.offset`, `.rotationEffect`, and transitions apply to the shadow automatically.
struct QuickAccessCardShadowView: NSViewRepresentable {
  /// Corner radius of the card, used to build the shadow silhouette. Matches
  /// `QuickAccessCardView.cornerRadius`.
  var cornerRadius: CGFloat

  /// Shadow strength. Defaults reproduce the dominant of the prior dual SwiftUI shadows
  /// (`opacity 0.15 / radius 8 / y 4`). The subtle second shadow (`0.08 / r2 / y1`) is
  /// dropped; the card's white stroke overlay already reinforces the boundary.
  var shadowOpacity: Float = 0.15
  var shadowRadius: CGFloat = 8
  /// Downward offset (SwiftUI `y: 4`) expressed in the backing layer's coordinate space.
  var shadowOffsetY: CGFloat = -4

  func makeNSView(context: Context) -> ShadowHostView {
    let view = ShadowHostView()
    view.wantsLayer = true
    view.cornerRadius = cornerRadius
    if let layer = view.layer {
      // Do not clip — a clipped layer would cut off its own shadow.
      layer.masksToBounds = false
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = shadowOpacity
      layer.shadowRadius = shadowRadius
      layer.shadowOffset = CGSize(width: 0, height: shadowOffsetY)
      // Rasterize the (static) shadow so blur is computed once, then GPU-composited.
      layer.shouldRasterize = true
    }
    return view
  }

  func updateNSView(_ nsView: ShadowHostView, context: Context) {
    nsView.cornerRadius = cornerRadius
    if let layer = nsView.layer {
      layer.shadowOpacity = shadowOpacity
      layer.shadowRadius = shadowRadius
      layer.shadowOffset = CGSize(width: 0, height: shadowOffsetY)
    }
    nsView.refreshShadowPath()
  }
}

/// Tiny backing view that rebuilds its `shadowPath` only when bounds or backing scale
/// change (never per frame), and stays click-through so it never intercepts card gestures.
final class ShadowHostView: NSView {
  var cornerRadius: CGFloat = 16

  private var lastBounds: CGRect = .zero
  private var lastScale: CGFloat = 0

  // Bottom-left origin (AppKit default). The shadow offset direction relies on this:
  // in a non-flipped backing layer, `shadowOffset.height = -4` renders downward, matching
  // SwiftUI's `y: 4`. Made explicit so a later flip can't silently invert the shadow.
  override var isFlipped: Bool { false }

  override func layout() {
    super.layout()
    refreshShadowPath()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refreshShadowPath()
  }

  // On attach, the real window backing scale becomes known — refresh so a 1x display
  // isn't stuck with the retina-biased fallback used before the view had a window.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshShadowPath()
  }

  /// Recompute the cached shadow silhouette + retina scale, but only when they actually
  /// changed — avoids per-frame `CGPath` allocation during animations.
  func refreshShadowPath() {
    guard let layer else { return }
    let scale = window?.backingScaleFactor ?? 2.0
    guard bounds != lastBounds || scale != lastScale else { return }
    lastBounds = bounds
    lastScale = scale

    layer.rasterizationScale = scale
    layer.shadowPath = CGPath(
      roundedRect: bounds,
      cornerWidth: cornerRadius,
      cornerHeight: cornerRadius,
      transform: nil
    )
  }

  // The card content above owns all interaction; the shadow must never grab clicks.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
